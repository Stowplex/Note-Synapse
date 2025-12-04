import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import '../../services/global_library_service.dart';
import '../../services/logger_service.dart';

class UserAppLibrarySettingsScreen extends StatefulWidget {
  const UserAppLibrarySettingsScreen({super.key});

  @override
  State<UserAppLibrarySettingsScreen> createState() =>
      _UserAppLibrarySettingsScreenState();
}

class _UserAppLibrarySettingsScreenState
    extends State<UserAppLibrarySettingsScreen> {
  final GlobalLibraryService _libraryService = GlobalLibraryService();

  @override
  void initState() {
    super.initState();
    _loadLibraries();
  }

  Future<void> _loadLibraries() async {
    // Libraries are already loaded in service, just refresh UI
    setState(() {});
  }

  Future<void> _toggleLibrary(GlobalLibrary lib, bool value) async {
    await _libraryService.toggleLibrary(lib.id, value);
    setState(() {});
  }

  Future<void> _deleteLibrary(GlobalLibrary lib) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${lib.name}?'),
        content: const Text('Are you sure you want to delete this library?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _libraryService.removeCustomLibrary(lib.id);
      setState(() {});
    }
  }

  void _showAddLibraryDialog() {
    showDialog(
      context: context,
      builder: (context) => const AddLibraryDialog(),
    ).then((added) {
      if (added == true) {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final libraries = _libraryService.libraries;

    return Scaffold(
      appBar: AppBar(title: const Text('User App Libraries')),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddLibraryDialog,
        child: const Icon(Icons.add),
      ),
      body: ListView.builder(
        itemCount: libraries.length,
        itemBuilder: (context, index) {
          final lib = libraries[index];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ExpansionTile(
              title: Text(lib.name),
              subtitle: Text(
                lib.isBuiltIn
                    ? 'Built-in • ${lib.version}'
                    : 'Custom • ${lib.version}',
              ),
              leading: Switch(
                value: lib.isEnabled,
                onChanged: (value) => _toggleLibrary(lib, value),
              ),
              trailing: lib.isBuiltIn
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: () => _deleteLibrary(lib),
                    ),
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (lib.description.isNotEmpty) ...[
                        Text(
                          'Description:',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(lib.description),
                        const SizedBox(height: 8),
                      ],
                      Text(
                        'Usage Instructions:',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          lib.usage,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Assets:',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      ...lib.assets.map(
                        (asset) => Text('• ${asset.path} (${asset.type})'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class AddLibraryDialog extends StatefulWidget {
  const AddLibraryDialog({super.key});

  @override
  State<AddLibraryDialog> createState() => _AddLibraryDialogState();
}

class _AddLibraryDialogState extends State<AddLibraryDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _versionController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _usageController = TextEditingController();
  final _urlController = TextEditingController();

  bool _isUrlMode = true;
  String? _selectedFilePath;
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _versionController.dispose();
    _descriptionController.dispose();
    _usageController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null) {
      setState(() {
        _selectedFilePath = result.files.single.path;
        // Auto-fill name if empty
        if (_nameController.text.isEmpty) {
          _nameController.text = path.basenameWithoutExtension(
            _selectedFilePath!,
          );
        }
      });
    }
  }

  Future<void> _saveLibrary() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_isUrlMode && _selectedFilePath == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a file')));
      return;
    }

    setState(() => _isLoading = true);

    try {
      final service = GlobalLibraryService();
      final libDir = await service.getCustomLibraryDirectory();
      final id = DateTime.now().millisecondsSinceEpoch.toString();

      String fileName;
      List<int> bytes;

      if (_isUrlMode) {
        final url = _urlController.text;
        final response = await http.get(Uri.parse(url));
        if (response.statusCode != 200) {
          throw Exception('Failed to download file: ${response.statusCode}');
        }
        bytes = response.bodyBytes;
        fileName = path.basename(Uri.parse(url).path);
        if (fileName.isEmpty) fileName = 'library_$id.js'; // Fallback
      } else {
        final file = File(_selectedFilePath!);
        bytes = await file.readAsBytes();
        fileName = path.basename(_selectedFilePath!);
      }

      // Save file
      final savedFile = File(path.join(libDir, fileName));
      await savedFile.writeAsBytes(bytes);

      // Determine type based on extension
      final type = fileName.endsWith('.css') ? 'style' : 'script';

      final library = GlobalLibrary(
        id: id,
        name: _nameController.text,
        version: _versionController.text,
        description: _descriptionController.text,
        usage: _usageController.text,
        assets: [
          GlobalLibraryAsset(
            path: savedFile.path, // Store full path for custom libs
            type: type,
          ),
        ],
        isBuiltIn: false,
      );

      await service.addCustomLibrary(library);

      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      LoggerService.error('Error adding library: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Custom Library'),
      content: SizedBox(
        width: double.maxFinite,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Name *'),
                  validator: (v) => v?.isEmpty == true ? 'Required' : null,
                ),
                TextFormField(
                  controller: _versionController,
                  decoration: const InputDecoration(labelText: 'Version'),
                ),
                TextFormField(
                  controller: _descriptionController,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: RadioListTile<bool>(
                        title: const Text('URL'),
                        value: true,
                        groupValue: _isUrlMode,
                        onChanged: (v) => setState(() => _isUrlMode = v!),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    Expanded(
                      child: RadioListTile<bool>(
                        title: const Text('File'),
                        value: false,
                        groupValue: _isUrlMode,
                        onChanged: (v) => setState(() => _isUrlMode = v!),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
                if (_isUrlMode)
                  TextFormField(
                    controller: _urlController,
                    decoration: const InputDecoration(labelText: 'URL *'),
                    validator: (v) =>
                        _isUrlMode && v?.isEmpty == true ? 'Required' : null,
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _selectedFilePath != null
                              ? path.basename(_selectedFilePath!)
                              : 'No file selected',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: _pickFile,
                        child: const Text('Select File'),
                      ),
                    ],
                  ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _usageController,
                  decoration: const InputDecoration(
                    labelText: 'Usage Instructions *',
                    hintText: 'How to use this library in the app...',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 5,
                  validator: (v) => v?.isEmpty == true ? 'Required' : null,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _saveLibrary,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}
