import 'package:flutter/material.dart';

import 'dart:convert';
import 'dart:typed_data';
import 'package:file_saver/file_saver.dart';
import '../l10n/app_localizations.dart';

import '../models/user_app.dart';
import '../services/database_service.dart';

class ExportAppScreen extends StatefulWidget {
  final UserApp app;

  const ExportAppScreen({super.key, required this.app});

  @override
  State<ExportAppScreen> createState() => _ExportAppScreenState();
}

class _ExportAppScreenState extends State<ExportAppScreen> {
  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _authorController;
  late TextEditingController _licenseController;
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.app.name);
    _descriptionController = TextEditingController(
      text: widget.app.description,
    );
    _authorController = TextEditingController(text: widget.app.author);
    _licenseController = TextEditingController(text: widget.app.license);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Set default license text if empty
    if (widget.app.license.isEmpty && _licenseController.text.isEmpty) {
      final l10n = AppLocalizations.of(context)!;
      _licenseController.text = l10n.private;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _authorController.dispose();
    _licenseController.dispose();
    super.dispose();
  }

  Future<void> _exportApp() async {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.nameRequired),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isExporting = true;
    });

    try {
      // Update the app with the new information
      final updatedApp = widget.app.copyWith(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        author: _authorController.text.trim(),
        license: _licenseController.text.trim(),
        updatedAt: DateTime.now(),
      );

      // Generate YAML content
      final yamlContent = await _generateYamlContent(updatedApp);

      // Save the file
      await _saveYamlFile(yamlContent, updatedApp.name);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.appExportedSuccessfully,
            ),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.errorExportingApp(e.toString()),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  Future<String> _generateYamlContent(UserApp app) async {
    final databaseService = DatabaseService();

    // Get the pinned revision
    final pinnedRevision = await databaseService.getAppRevision(
      app.selectedRevisionId!,
    );
    if (pinnedRevision == null) {
      throw Exception('Pinned revision not found');
    }

    // Get libraries for the pinned revision
    final libraries = await databaseService.getUserAppLibraries(
      app.uuid,
      pinnedRevision.revisionNumber,
    );

    // Build libraries section
    final librariesYaml = <String>[];
    for (final library in libraries) {
      final dependencies = await databaseService.getUserAppLibraryDependencies(
        library['id'] as int,
      );
      final dependenciesYaml = <String>[];

      for (final dependency in dependencies) {
        dependenciesYaml.add(
          '      - link: ${jsonEncode(dependency['original_url']?.toString() ?? '')}',
        );
      }

      librariesYaml.add(
        '  - name: ${jsonEncode(library['name']?.toString() ?? '')}',
      );
      if (library['usage_instructions'] != null &&
          library['usage_instructions'].toString().isNotEmpty) {
        librariesYaml.add(
          '    instructions: ${jsonEncode(library['usage_instructions'].toString())}',
        );
      }
      if (dependenciesYaml.isNotEmpty) {
        librariesYaml.add('    dependencies:');
        librariesYaml.addAll(dependenciesYaml);
      }
    }

    // Encode the app code to base64
    final codeBytes = utf8.encode(pinnedRevision.appCode);
    final base64Code = base64Encode(codeBytes);

    // Convert app type enum to string
    final appTypeString = _appTypeToString(app.type);

    // Build the YAML content
    final yamlLines = <String>[
      'name: ${jsonEncode(app.name)}',
      'uuid: ${jsonEncode(app.uuid)}',
      'app_type: ${jsonEncode(appTypeString)}',
      'description: ${jsonEncode(app.description)}',
      'author: ${jsonEncode(app.author)}',
      'license: ${jsonEncode(app.license)}',
    ];

    final exportedI18n = app.name == widget.app.name
        ? (app.description == widget.app.description
              ? app.i18n
              : app.i18nWithoutDescriptions)
        : (app.description == widget.app.description
              ? app.i18nWithoutNames
              : const <String, UserAppLocalizedMetadata>{});
    if (exportedI18n.isNotEmpty) {
      yamlLines.add('i18n:');
      final localeTags = exportedI18n.keys.toList()..sort();
      for (final localeTag in localeTags) {
        final metadata = exportedI18n[localeTag]!;
        yamlLines.add('  ${jsonEncode(localeTag)}:');
        if (metadata.name != null) {
          yamlLines.add('    name: ${jsonEncode(metadata.name)}');
        }
        if (metadata.description != null) {
          yamlLines.add('    description: ${jsonEncode(metadata.description)}');
        }
      }
    }

    if (librariesYaml.isNotEmpty) {
      yamlLines.add('libraries:');
      yamlLines.addAll(librariesYaml);
    }

    yamlLines.add('code: $base64Code');

    return yamlLines.join('\n');
  }

  /// Converts UserAppType enum to string representation for YAML export.
  String _appTypeToString(UserAppType type) {
    switch (type) {
      case UserAppType.normal:
        return 'normal';
      case UserAppType.noteAction:
        return 'note_action';
      case UserAppType.aiTool:
        return 'ai_tool';
    }
  }

  Future<void> _saveYamlFile(String content, String appName) async {
    final bytes = utf8.encode(content);
    final fileName = appName
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .replaceAll(' ', '_');

    await FileSaver.instance.saveAs(
      name: fileName,
      bytes: Uint8List.fromList(bytes),
      fileExtension: 'yaml',
      mimeType: MimeType.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.exportApp)),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.exportAppDescription,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.name,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              decoration: InputDecoration(
                labelText: l10n.description,
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _authorController,
              decoration: InputDecoration(
                labelText: l10n.author,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _licenseController,
              decoration: InputDecoration(
                labelText: l10n.license,
                border: const OutlineInputBorder(),
                hintText: 'e.g., BSD 3-clause, MIT, Apache 2.0',
              ),
            ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isExporting
                        ? null
                        : () => Navigator.pop(context),
                    child: Text(l10n.cancel),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isExporting ? null : _exportApp,
                    child: _isExporting
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.save),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
