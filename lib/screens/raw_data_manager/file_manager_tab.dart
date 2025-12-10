import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:note_synapse/l10n/app_localizations.dart';
import '../../services/database_service.dart';
import '../../utils/file_utils.dart';
import '../../services/logger_service.dart';

class FileManagerTab extends StatefulWidget {
  const FileManagerTab({super.key});

  @override
  State<FileManagerTab> createState() => _FileManagerTabState();
}

class _FileManagerTabState extends State<FileManagerTab> {
  List<FileSystemEntity> _files = [];
  Set<String> _usedFileNames = {};
  Set<String> _selectedFiles = {};
  bool _isLoading = true;
  String _currentPath = '';
  String _rootAttachmentsPath = '';
  String _rootCachePath = '';
  bool _isAttachmentsDir = true; // Toggle between Attachments and Cache
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initPaths();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initPaths() async {
    try {
      final attachmentsDir = await FileUtils.getPrivateStorageDirectory();
      _rootAttachmentsPath = attachmentsDir.path;

      final cacheDir = await getTemporaryDirectory();
      _rootCachePath = cacheDir.path;

      _currentPath = _rootAttachmentsPath;
      await _loadFiles();
    } catch (e) {
      LoggerService.error('Error initializing paths: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error initializing paths: $e')));
      }
    }
  }

  Future<void> _loadFiles() async {
    setState(() {
      _isLoading = true;
      _selectedFiles.clear();
    });

    try {
      final dir = Directory(_currentPath);
      if (await dir.exists()) {
        final entities = await dir.list().toList();
        // Sort: Directories first, then files. Alphabetical.
        entities.sort((a, b) {
          if (a is Directory && b is File) return -1;
          if (a is File && b is Directory) return 1;
          return a.path.toLowerCase().compareTo(b.path.toLowerCase());
        });

        _files = entities;

        // Only check usage if we are in the attachments directory root
        if (_currentPath == _rootAttachmentsPath) {
          await _checkFileUsage();
        } else {
          _usedFileNames.clear();
        }
      } else {
        _files = [];
      }
    } catch (e) {
      LoggerService.error('Error loading files: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _checkFileUsage() async {
    _usedFileNames.clear();
    try {
      final db = await DatabaseService().database;

      // Check attachments table
      final attachments = await db.query(
        'attachments',
        columns: ['filePath', 'isRelativePath'],
      );
      for (final row in attachments) {
        final filePath = row['filePath'] as String;
        final isRelative = (row['isRelativePath'] as int) == 1;
        if (isRelative) {
          // Extract filename from relative path (e.g., attachments/filename.ext)
          final fileName = path.basename(filePath);
          _usedFileNames.add(fileName);
        }
      }

      // Check conversation_attachments table
      final convAttachments = await db.query(
        'conversation_attachments',
        columns: ['filePath', 'isRelativePath'],
      );
      for (final row in convAttachments) {
        final filePath = row['filePath'] as String;
        final isRelative = (row['isRelativePath'] as int) == 1;
        if (isRelative) {
          final fileName = path.basename(filePath);
          _usedFileNames.add(fileName);
        }
      }
    } catch (e) {
      LoggerService.error('Error checking file usage: $e');
    }
  }

  Future<void> _switchDirectory(bool isAttachments) async {
    setState(() {
      _isAttachmentsDir = isAttachments;
      _currentPath = isAttachments ? _rootAttachmentsPath : _rootCachePath;
    });
    await _loadFiles();
  }

  Future<void> _navigateToDirectory(Directory dir) async {
    setState(() {
      _currentPath = dir.path;
    });
    await _loadFiles();
  }

  Future<void> _navigateUp() async {
    final parent = Directory(_currentPath).parent;
    final root = _isAttachmentsDir ? _rootAttachmentsPath : _rootCachePath;

    // Check if parent is still within root (or is root)
    if (_currentPath != root) {
      setState(() {
        _currentPath = parent.path;
      });
      await _loadFiles();
    }
  }

  void _toggleSelection(String filePath) {
    setState(() {
      if (_selectedFiles.contains(filePath)) {
        _selectedFiles.remove(filePath);
      } else {
        _selectedFiles.add(filePath);
      }
    });
  }

  void _selectAllUnused() {
    setState(() {
      _selectedFiles.clear();
      for (final entity in _files) {
        if (entity is File) {
          final fileName = path.basename(entity.path);
          if (!_usedFileNames.contains(fileName)) {
            _selectedFiles.add(entity.path);
          }
        }
      }
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedFiles.clear();
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedFiles.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteFilesTitle),
        content: Text(l10n.deleteFilesConfirmation(_selectedFiles.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );

    if (confirm == true) {
      int deletedCount = 0;
      for (final filePath in _selectedFiles) {
        try {
          final file = File(filePath);
          if (await file.exists()) {
            await file.delete();
            deletedCount++;
          }
        } catch (e) {
          LoggerService.error('Error deleting file $filePath: $e');
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.deletedFilesMessage(deletedCount))),
        );
        await _loadFiles();
      }
    }
  }

  Future<void> _renameFile(File file) async {
    final l10n = AppLocalizations.of(context)!;
    final fileName = path.basename(file.path);
    final controller = TextEditingController(text: fileName);

    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.renameFile),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(labelText: l10n.newName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l10n.rename),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != fileName) {
      try {
        final newPath = path.join(path.dirname(file.path), newName);
        await file.rename(newPath);
        await _loadFiles();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.errorRenamingFile(e.toString()))),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final root = _isAttachmentsDir ? _rootAttachmentsPath : _rootCachePath;
    final isAtRoot = _currentPath == root;

    final displayedFiles = _files.where((entity) {
      final searchText = _searchController.text.toLowerCase();
      if (searchText.isEmpty) return true;
      return path.basename(entity.path).toLowerCase().contains(searchText);
    }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: true,
                      label: Text(l10n.attachments),
                      icon: const Icon(Icons.attachment),
                    ),
                    ButtonSegment(
                      value: false,
                      label: Text(l10n.cache),
                      icon: const Icon(Icons.cached),
                    ),
                  ],
                  selected: {_isAttachmentsDir},
                  onSelectionChanged: (Set<bool> newSelection) {
                    _switchDirectory(newSelection.first);
                  },
                ),
              ),
            ],
          ),
        ),
        // Path and Navigation
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_upward),
                onPressed: isAtRoot ? null : _navigateUp,
                tooltip: 'Go Up',
              ),
              Expanded(
                child: Text(
                  path.basename(_currentPath).isEmpty
                      ? l10n.root
                      : path.basename(_currentPath),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        // Search Bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              labelText: 'Search',
              hintText: 'Search files...',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            onChanged: (value) {
              setState(() {});
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(l10n.itemsCount(_files.length)),
              Row(
                children: [
                  if (_selectedFiles.isNotEmpty) ...[
                    TextButton.icon(
                      onPressed: _deleteSelected,
                      icon: const Icon(Icons.delete, color: Colors.red),
                      label: Text(
                        '${l10n.delete} (${_selectedFiles.length})',
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                    TextButton(
                      onPressed: _deselectAll,
                      child: Text(l10n.deselectAll),
                    ),
                  ],
                  if (_selectedFiles.isEmpty)
                    TextButton(
                      onPressed: _selectAllUnused,
                      child: Text(l10n.selectUnused),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (_isLoading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_files.isEmpty)
          Expanded(child: Center(child: Text(l10n.noFilesFound)))
        else
          Expanded(
            child: ListView.builder(
              itemCount: displayedFiles.length,
              itemBuilder: (context, index) {
                final entity = displayedFiles[index];
                final name = path.basename(entity.path);
                final isDir = entity is Directory;
                final isSelected = _selectedFiles.contains(entity.path);
                final isUsed = _usedFileNames.contains(name);

                return ListTile(
                  leading: isDir
                      ? const Icon(Icons.folder, color: Colors.amber)
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Checkbox(
                              value: isSelected,
                              onChanged: (val) => _toggleSelection(entity.path),
                            ),
                            Icon(
                              _getFileIcon(name),
                              color: isUsed ? Colors.green : Colors.grey,
                            ),
                          ],
                        ),
                  title: Text(name),
                  subtitle: !isDir && _isAttachmentsDir && isAtRoot
                      ? Text(
                          isUsed ? l10n.used : l10n.unused,
                          style: TextStyle(
                            color: isUsed ? Colors.green : Colors.orange,
                          ),
                        )
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isDir)
                        IconButton(
                          icon: const Icon(Icons.edit),
                          onPressed: () => _renameFile(entity as File),
                        ),
                      if (!isDir)
                        IconButton(
                          icon: const Icon(Icons.visibility),
                          onPressed: () =>
                              FileUtils.openFile(entity.path, context),
                        ),
                      if (isDir) const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () {
                    if (isDir) {
                      _navigateToDirectory(entity as Directory);
                    } else {
                      _toggleSelection(entity.path);
                    }
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  IconData _getFileIcon(String fileName) {
    final ext = path.extension(fileName).toLowerCase();
    switch (ext) {
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.gif':
      case '.webp':
        return Icons.image;
      case '.pdf':
        return Icons.picture_as_pdf;
      case '.txt':
      case '.md':
      case '.json':
        return Icons.description;
      default:
        return Icons.insert_drive_file;
    }
  }
}
