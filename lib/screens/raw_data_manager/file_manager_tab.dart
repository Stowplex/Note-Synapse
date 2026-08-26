import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
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
  Database? _rawDb;
  String? _dbConnectionError;
  List<FileSystemEntity> _files = [];
  final Set<String> _usedFileNames = {};
  final Set<String> _selectedFiles = {};
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
    _rawDb?.close();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initPaths() async {
    try {
      final attachmentsDir = await FileUtils.getPrivateStorageDirectory();
      _rootAttachmentsPath = attachmentsDir.path;

      final cacheDir = await getTemporaryDirectory();
      _rootCachePath = cacheDir.path;

      // Open raw database connection for file usage checking
      try {
        final dbPath = await DatabaseService().getDatabasePath();
        _rawDb = await openDatabase(dbPath);
        _dbConnectionError = null;
      } catch (e) {
        _dbConnectionError = e.toString();
        LoggerService.error(
          'Could not connect to database for usage check: $e',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Database connection failed: $e'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }

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
    if (_rawDb == null) {
      // Cannot check usage without DB connection
      return;
    }
    try {
      final db = _rawDb!;

      // Check attachments table - check BOTH filePath and fileName columns
      // for consistency with _showFileUsageDetails query. M1.11: only live
      // rows count as "used" -- a soft-deleted attachment's file should be
      // eligible for cleanup here just like a hard-deleted one always was
      // (same reasoning as the conversation_attachments filter below, M1.8,
      // now that `attachments` has its own `__deleted__` column too).
      final attachments = await db.query(
        'attachments',
        columns: ['filePath', 'fileName'],
        where: '__deleted__ = 0',
      );
      for (final row in attachments) {
        final filePath = row['filePath'] as String;
        final fileName = row['fileName'] as String?;
        // Add basename from filePath (works for both relative and absolute paths)
        _usedFileNames.add(path.basename(filePath));
        // Also add fileName directly if present
        if (fileName != null && fileName.isNotEmpty) {
          _usedFileNames.add(fileName);
        }
      }

      // Check conversation_attachments table. M1.8: only live rows count as
      // "used" -- a soft-deleted attachment's file should be eligible for
      // cleanup here just like a hard-deleted one always was.
      final convAttachments = await db.query(
        'conversation_attachments',
        columns: ['filePath', 'fileName'],
        where: '__deleted__ = 0',
      );
      for (final row in convAttachments) {
        final filePath = row['filePath'] as String;
        final fileName = row['fileName'] as String?;
        _usedFileNames.add(path.basename(filePath));
        if (fileName != null && fileName.isNotEmpty) {
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

  Future<void> _showFileUsageDetails(String fileName) async {
    final l10n = AppLocalizations.of(context)!;
    if (_rawDb == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.databaseNotConnected),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    List<Map<String, Object?>> noteReferences = [];
    List<Map<String, Object?>> convReferences = [];

    try {
      // Query note attachments that reference this file. M1.11: excludes
      // soft-deleted rows, consistent with the conversation_attachments
      // query below (M1.8) and with _checkFileUsage above -- a tombstoned
      // attachment should not appear as a live "usage" of the file. The
      // OUTER join carries the same filter for the note it names: deletion
      // is a tombstone, so an unfiltered join would print a deleted note's
      // title and content digest into this dialog. Filtering on the join
      // (not in WHERE) keeps an attachment whose note row is simply absent
      // listed, with no note attributed to it.
      noteReferences = await _rawDb!.rawQuery(
        '''
        SELECT n.id, n.title, substr(n.content, 1, 100) as digest
        FROM attachments a
        LEFT JOIN notes n ON a.noteId = n.id AND n.__deleted__ = 0
        WHERE (a.filePath LIKE ? OR a.fileName = ?) AND a.__deleted__ = 0
      ''',
        ['%$fileName', fileName],
      );

      // Query conversation attachments that reference this file. M1.8:
      // excludes soft-deleted rows, consistent with _checkFileUsage above
      // -- a tombstoned attachment should not appear as a live "usage" of
      // the file. Same tombstone filter on the message join as on the note
      // join above, for the same reason: the digest it selects is content
      // from a row that may already have been deleted.
      convReferences = await _rawDb!.rawQuery(
        '''
        SELECT ca.messageId, substr(cm.content, 1, 100) as digest
        FROM conversation_attachments ca
        LEFT JOIN conversation_messages cm
          ON ca.messageId = cm.id AND cm.__deleted__ = 0
        WHERE (ca.filePath LIKE ? OR ca.fileName = ?) AND ca.__deleted__ = 0
      ''',
        ['%$fileName', fileName],
      );
    } catch (e) {
      LoggerService.error('Error querying file usage: $e');
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.fileUsageDetails),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fileName,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                if (noteReferences.isEmpty && convReferences.isEmpty)
                  Text(
                    l10n.noReferencesFound,
                    style: TextStyle(color: Colors.orange[700]),
                  )
                else ...[
                  if (noteReferences.isNotEmpty) ...[
                    Text(
                      l10n.usedByNotes(noteReferences.length),
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 8),
                    ...noteReferences.map((ref) {
                      final title = ref['title'] as String?;
                      final digest = ref['digest'] as String?;
                      final noteExists = title != null;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                noteExists ? title : l10n.noteNoLongerExists,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: noteExists ? null : Colors.red,
                                ),
                              ),
                              if (digest != null && digest.isNotEmpty)
                                Text(
                                  digest,
                                  style: Theme.of(context).textTheme.bodySmall,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                  if (convReferences.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      l10n.usedByConversations(convReferences.length),
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 8),
                    ...convReferences.map((ref) {
                      final digest = ref['digest'] as String?;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            digest ?? l10n.messageNoLongerExists,
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      );
                    }),
                  ],
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
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
        // Warning banner when DB not connected
        if (_rawDb == null && _isAttachmentsDir)
          Container(
            color: Colors.red.withValues(alpha: 0.1),
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.warning, color: Colors.red),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${l10n.databaseNotConnected}. ${l10n.fileUsageUnavailable}\n${_dbConnectionError ?? ""}',
                    style: const TextStyle(color: Colors.red),
                  ),
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
                      if (!isDir && _isAttachmentsDir && isAtRoot)
                        IconButton(
                          icon: const Icon(Icons.info_outline),
                          tooltip: l10n.showDetails,
                          onPressed: () => _showFileUsageDetails(name),
                        ),
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
                      _navigateToDirectory(entity);
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
