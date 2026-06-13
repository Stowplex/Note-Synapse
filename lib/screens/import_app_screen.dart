import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:yaml/yaml.dart';

import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/user_app.dart';
import '../models/app_revision.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import '../services/network_provider.dart';

class ImportAppScreen extends StatefulWidget {
  final String yamlFilePath;

  const ImportAppScreen({super.key, required this.yamlFilePath});

  @override
  State<ImportAppScreen> createState() {
    return _ImportAppScreenState();
  }
}

class _ImportAppScreenState extends State<ImportAppScreen> {
  String _currentStatus = 'Reading YAML file...';
  double _progress = 0.0;
  bool _isComplete = false;
  bool _hasError = false;
  final List<String> _progressSteps = [];
  UserApp? _importedApp;

  @override
  void initState() {
    super.initState();
    LoggerService.debug(
      'ImportAppScreen initState called with file: ${widget.yamlFilePath}',
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Only start import once when dependencies are available
    if (_progress == 0.0 && !_hasError) {
      if (widget.yamlFilePath.isEmpty) {
        setState(() {
          _currentStatus = AppLocalizations.of(context)!.errorYamlFilePathEmpty;
          _hasError = true;
          _progressSteps.add(
            '✗ ${AppLocalizations.of(context)!.errorYamlFilePathEmpty}',
          );
        });
        return;
      }

      _importApp();
    }
  }

  Future<void> _importApp() async {
    try {
      setState(() {
        _currentStatus = AppLocalizations.of(context)!.readingYamlFile;
        _progress = 0.1;
      });

      // Read and parse YAML file
      final yamlFile = File(widget.yamlFilePath);
      final yamlContent = await yamlFile.readAsString();
      final yamlData = loadYaml(yamlContent);

      // Convert YamlMap to Map<String, dynamic>
      final Map<String, dynamic> parsedData = {};
      if (yamlData is Map) {
        yamlData.forEach((key, value) {
          if (key is String) {
            parsedData[key] = value;
          }
        });
      } else {
        throw Exception(AppLocalizations.of(context)!.errorInvalidYamlFormat);
      }

      setState(() {
        _currentStatus = AppLocalizations.of(context)!.validatingYamlStructure;
        _progress = 0.2;
        _progressSteps.add(
          '✓ ${AppLocalizations.of(context)!.yamlFileReadSuccessfully}',
        );
      });

      // Validate YAML structure
      _validateYamlStructure(parsedData);

      setState(() {
        _currentStatus = AppLocalizations.of(context)!.processingAppData;
        _progress = 0.3;
        _progressSteps.add(
          '✓ ${AppLocalizations.of(context)!.yamlStructureValidated}',
        );
      });

      // Extract app data
      final appData = _extractAppData(parsedData);

      setState(() {
        _currentStatus = AppLocalizations.of(context)!.checkingForExistingApp;
        _progress = 0.4;
        _progressSteps.add(
          '✓ ${AppLocalizations.of(context)!.appDataExtracted}',
        );
      });

      // Check if app with same UUID exists
      final databaseService = DatabaseService();
      final existingApps = await databaseService.getAllUserApps();
      final existingApp = existingApps
          .where((app) => app.uuid == appData['uuid'])
          .firstOrNull;

      LoggerService.debug('Found ${existingApps.length} existing apps');
      LoggerService.debug('Looking for UUID: ${appData['uuid']}');
      LoggerService.debug('Existing app found: ${existingApp != null}');

      if (existingApp != null) {
        setState(() {
          _currentStatus = 'Creating new revision...';
          _progress = 0.5;
          _progressSteps.add('✓ Found existing app, creating new revision');
        });

        // Create new revision for existing app
        await _createNewRevision(existingApp, appData, databaseService);
      } else {
        setState(() {
          _currentStatus = AppLocalizations.of(context)!.creatingNewApp;
          _progress = 0.5;
          _progressSteps.add(
            '✓ ${AppLocalizations.of(context)!.appCreatedSuccessfully}',
          );
        });

        // Create new app
        await _createNewApp(appData, databaseService);
      }

      LoggerService.debug(
        'After app creation, _importedApp is: ${_importedApp != null}',
      );

      if (_importedApp != null) {
        setState(() {
          _currentStatus = 'Downloading dependencies...';
          _progress = 0.6;
        });

        // Download and store dependencies
        await _downloadDependencies(appData, databaseService);
      } else {
        setState(() {
          _currentStatus = 'Skipping dependencies (no app created)...';
          _progress = 0.8;
          _progressSteps.add('⚠ Skipped dependencies - no app created');
        });
      }

      setState(() {
        _currentStatus = 'Finalizing import...';
        _progress = 0.9;
        _progressSteps.add('✓ Dependencies downloaded and stored');
      });

      // Refresh the app provider
      final appProvider = context.read<AppProvider>();
      await appProvider.loadData();

      setState(() {
        _currentStatus = AppLocalizations.of(
          context,
        )!.importCompletedSuccessfully;
        _progress = 1.0;
        _isComplete = true;
        _progressSteps.add(
          '✓ ${AppLocalizations.of(context)!.importCompletedSuccessfully}',
        );
      });
    } catch (e) {
      LoggerService.error('Error importing app: $e', error: e);
      setState(() {
        _currentStatus = AppLocalizations.of(
          context,
        )!.errorImportingApp(e.toString());
        _hasError = true;
        _progressSteps.add(
          '✗ ${AppLocalizations.of(context)!.errorImportingApp(e.toString())}',
        );
      });
    }
  }

  void _validateYamlStructure(Map<String, dynamic> yamlData) {
    final requiredFields = [
      'name',
      'uuid',
      'description',
      'author',
      'license',
      'code',
    ];

    for (final field in requiredFields) {
      if (!yamlData.containsKey(field)) {
        throw Exception(
          AppLocalizations.of(context)!.errorMissingRequiredFields,
        );
      }
    }

    if (yamlData['libraries'] != null) {
      final libraries = yamlData['libraries'];
      if (libraries is List) {
        for (final library in libraries) {
          if (library is! Map) {
            throw Exception('Invalid library structure');
          }
          final libraryMap = library;
          if (!libraryMap.containsKey('name') ||
              !libraryMap.containsKey('dependencies')) {
            throw Exception('Library must have name and dependencies');
          }
        }
      } else {
        throw Exception('Libraries must be a list');
      }
    }
  }

  Map<String, dynamic> _extractAppData(Map<String, dynamic> yamlData) {
    // Determine app type: support both old format (note_action: true/false) and new format (app_type: string)
    UserAppType appType;
    if (yamlData.containsKey('app_type')) {
      // New format: app_type: normal | note_action | ai_tool
      appType = _stringToAppType(yamlData['app_type']?.toString() ?? 'normal');
    } else if (yamlData.containsKey('note_action')) {
      // Old format: note_action: true/false (backward compatibility)
      appType = yamlData['note_action'] == true
          ? UserAppType.noteAction
          : UserAppType.normal;
    } else {
      // Default to normal if neither field exists
      appType = UserAppType.normal;
    }

    return {
      'name': yamlData['name']?.toString() ?? '',
      'uuid': yamlData['uuid']?.toString() ?? '',
      'description': yamlData['description']?.toString() ?? '',
      'author': yamlData['author']?.toString() ?? '',
      'license': yamlData['license']?.toString() ?? '',
      'app_type': appType,
      'code': yamlData['code']?.toString() ?? '',
      'libraries': _convertLibraries(yamlData['libraries']),
    };
  }

  /// Converts string representation to UserAppType enum for YAML import.
  UserAppType _stringToAppType(String typeString) {
    switch (typeString.toLowerCase()) {
      case 'normal':
        return UserAppType.normal;
      case 'note_action':
        return UserAppType.noteAction;
      case 'ai_tool':
        return UserAppType.aiTool;
      default:
        return UserAppType.normal;
    }
  }

  List<dynamic> _convertLibraries(dynamic libraries) {
    if (libraries == null) return [];
    if (libraries is! List) return [];

    return libraries.map((lib) {
      if (lib is Map) {
        final Map<String, dynamic> convertedLib = {};
        lib.forEach((key, value) {
          if (key is String) {
            if (key == 'dependencies' && value is List) {
              convertedLib[key] = value.map((dep) {
                if (dep is Map) {
                  final Map<String, dynamic> convertedDep = {};
                  dep.forEach((depKey, depValue) {
                    if (depKey is String) {
                      convertedDep[depKey] = depValue?.toString();
                    }
                  });
                  return convertedDep;
                }
                return dep;
              }).toList();
            } else {
              convertedLib[key] = value?.toString();
            }
          }
        });
        return convertedLib;
      }
      return lib;
    }).toList();
  }

  List<dynamic> _convertToList(dynamic value) {
    if (value == null) return [];
    if (value is List) return value;
    return [];
  }

  Future<void> _createNewApp(
    Map<String, dynamic> appData,
    DatabaseService databaseService,
  ) async {
    LoggerService.debug('_createNewApp called');
    final appId = DateTime.now().millisecondsSinceEpoch.toString();
    final now = DateTime.now();

    // Decode base64 code
    final decodedCode = utf8.decode(base64Decode(appData['code']));
    LoggerService.debug('Decoded code length: ${decodedCode.length}');

    final userApp = UserApp(
      id: appId,
      uuid: appData['uuid'],
      name: appData['name'],
      description: appData['description'],
      steps: ['Imported from YAML'],
      htmlContent: '', // No longer used - code is stored in revisions
      type: appData['app_type'] as UserAppType,
      createdAt: now,
      updatedAt: now,
    );

    await databaseService.insertUserApp(userApp);

    // Create initial revision
    final revisionId = '${appId}_rev_1';
    final revision = AppRevision(
      id: revisionId,
      appId: appId,
      revisionNumber: 1,
      revisionTimestamp: now,
      userPrompt: 'Imported from YAML file',
      aiResponse: 'App imported successfully from YAML file',
      appCode: decodedCode,
      attachmentPaths: [],
    );

    await databaseService.insertAppRevision(revision);

    // Update app with selected revision
    final updatedApp = userApp.copyWith(selectedRevisionId: revisionId);
    await databaseService.updateUserApp(updatedApp);

    setState(() {
      _importedApp = updatedApp;
    });
    LoggerService.debug(
      '_createNewApp completed, _importedApp set to: ${_importedApp?.name}',
    );
  }

  Future<void> _createNewRevision(
    UserApp existingApp,
    Map<String, dynamic> appData,
    DatabaseService databaseService,
  ) async {
    LoggerService.debug(
      '_createNewRevision called for app: ${existingApp.name}',
    );
    // Get next revision number
    final nextRevisionNumber = await databaseService.getNextRevisionNumber(
      existingApp.id,
    );
    final now = DateTime.now();
    LoggerService.debug('Next revision number: $nextRevisionNumber');

    // Decode base64 code
    final decodedCode = utf8.decode(base64Decode(appData['code']));

    // Create new revision
    final revisionId = '${existingApp.id}_rev_$nextRevisionNumber';
    final revision = AppRevision(
      id: revisionId,
      appId: existingApp.id,
      revisionNumber: nextRevisionNumber,
      revisionTimestamp: now,
      userPrompt: 'Imported from YAML file',
      aiResponse: 'App revision imported successfully from YAML file',
      appCode: decodedCode,
      attachmentPaths: [],
    );

    await databaseService.insertAppRevision(revision);

    // Update app with new revision
    final updatedApp = existingApp.copyWith(
      selectedRevisionId: revisionId,
      updatedAt: now,
    );
    await databaseService.updateUserApp(updatedApp);

    setState(() {
      _importedApp = updatedApp;
    });
    LoggerService.debug(
      '_createNewRevision completed, _importedApp set to: ${_importedApp?.name}',
    );
  }

  Future<void> _downloadDependencies(
    Map<String, dynamic> appData,
    DatabaseService databaseService,
  ) async {
    final libraries = _convertToList(appData['libraries']);

    for (int i = 0; i < libraries.length; i++) {
      final library = libraries[i];
      final libraryName = library['name']?.toString() ?? '';
      final dependencies = _convertToList(library['dependencies']);
      final instructions = library['instructions']?.toString();

      setState(() {
        _currentStatus = AppLocalizations.of(
          context,
        )!.downloadingLibrary(libraryName);
        _progress = 0.6 + (0.2 * (i + 1) / libraries.length);
        _progressSteps.add(
          AppLocalizations.of(context)!.downloading(libraryName),
        );
      });

      // Create library entry
      int revisionId = 1;
      if (_importedApp?.selectedRevisionId != null) {
        final revisionIdStr = _importedApp!.selectedRevisionId!;
        final parts = revisionIdStr.split('_rev_');
        if (parts.length > 1) {
          revisionId = int.tryParse(parts.last) ?? 1;
        }
      }

      final libraryId = await databaseService.insertUserAppLibrary(
        appUuid: appData['uuid'],
        revisionId: revisionId,
        name: libraryName,
        usageInstructions: instructions,
      );

      // Download dependencies
      for (int j = 0; j < dependencies.length; j++) {
        final dependency = dependencies[j];
        final link = dependency['link']?.toString() ?? '';

        setState(() {
          final fileName = Uri.parse(link).pathSegments.last;
          _currentStatus = AppLocalizations.of(
            context,
          )!.downloadingDependency(fileName);
          _progress =
              0.6 +
              (0.2 * (i + 1) / libraries.length) +
              (0.1 * (j + 1) / dependencies.length);
          _progressSteps.add(
            AppLocalizations.of(context)!.downloading(fileName),
          );
        });

        try {
          final response = await NetworkProvider.get(Uri.parse(link));
          if (response.statusCode == 200) {
            final bytes = response.bodyBytes;
            final localPath = Uri.parse(link).path;

            await databaseService.insertUserAppLibraryDependency(
              originalUrl: link,
              localPath: localPath,
              bytes: bytes,
              libraryId: libraryId,
            );

            setState(() {
              _progressSteps.add(
                '  ✓ ${AppLocalizations.of(context)!.downloaded(localPath)}',
              );
            });
          } else {
            setState(() {
              _progressSteps.add(
                '  ✗ ${AppLocalizations.of(context)!.failedToDownload(link, response.statusCode.toString())}',
              );
            });
          }
        } catch (e) {
          setState(() {
            _progressSteps.add(
              '  ✗ ${AppLocalizations.of(context)!.errorDownloading(link, e.toString())}',
            );
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.importApp),
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Progress section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.importProgress,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: _progress,
                      backgroundColor: Colors.grey[300],
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _hasError ? Colors.red : Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(_progress * 100).toInt()}%',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _currentStatus,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Log section
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            l10n.importLog,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy),
                            onPressed: () => _copyLogToClipboard(),
                            tooltip: l10n.copyLog,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.grey[900],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[700]!),
                          ),
                          child: SingleChildScrollView(
                            child: SelectableText(
                              _getLogContent(),
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Close button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () =>
                    Navigator.of(context).pop(_isComplete && !_hasError),
                icon: Icon(
                  _isComplete && !_hasError ? Icons.check : Icons.close,
                  color: _isComplete && !_hasError
                      ? Colors.white
                      : Colors.white,
                ),
                label: Text(
                  '${l10n.close} ${_isComplete && !_hasError ? '✓' : '✗'}',
                  style: const TextStyle(color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isComplete && !_hasError
                      ? Colors.green
                      : Colors.red,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getLogContent() {
    final l10n = AppLocalizations.of(context)!;
    final buffer = StringBuffer();
    buffer.writeln(l10n.importingFromFile(widget.yamlFilePath));
    buffer.writeln('');

    for (final step in _progressSteps) {
      buffer.writeln(step);
    }

    if (_hasError) {
      buffer.writeln('');
      buffer.writeln('${l10n.error}: $_currentStatus');
    } else if (_isComplete) {
      buffer.writeln('');
      buffer.writeln(l10n.importComplete);
    }

    return buffer.toString();
  }

  void _copyLogToClipboard() {
    final l10n = AppLocalizations.of(context)!;
    Clipboard.setData(ClipboardData(text: _getLogContent()));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.logCopiedToClipboard),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
