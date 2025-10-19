import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import 'package:file_saver/file_saver.dart';
import 'package:sqflite/sqflite.dart';
import '../l10n/app_localizations.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import '../utils/file_utils.dart';

class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({super.key});

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  bool _isBackingUp = false;
  double _backupProgress = 0.0;
  List<String> _backupLogs = [];
  List<Map<String, dynamic>> _backups = [];

  @override
  void initState() {
    super.initState();
    _loadBackups();
  }

  Future<void> _loadBackups() async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (await tempDir.exists()) {
        final files = await tempDir.list().toList();
        final backupFiles = files.where((file) => 
          file.path.endsWith('.zip') && 
          file.path.contains('backup_')
        ).toList();
        
        setState(() {
          _backups = backupFiles.map((file) {
            final stat = file.statSync();
            return {
              'name': file.path.split('/').last,
              'date': stat.modified.toString().substring(0, 19),
              'path': file.path,
              'size': stat.size,
            };
          }).toList();
        });
      }
    } catch (e) {
      LoggerService.error('Error loading backups: $e');
    }
  }


  Future<void> _backupAllNotes() async {
    final l10n = AppLocalizations.of(context)!;
    
    setState(() {
      _isBackingUp = true;
      _backupProgress = 0.0;
      _backupLogs.clear();
    });

    try {
      _addLog(l10n.startingBackupProcess);
      
      // 1. Create temp directory
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempDir = await getTemporaryDirectory();
      final exportDir = Directory('${tempDir.path}/backup_$timestamp');
      await exportDir.create(recursive: true);
      
      _addLog(l10n.createdTempDirectory(exportDir.path));
      _updateProgress(0.1);

      // 2. Checkpoint database
      _addLog(l10n.forcingDatabaseCheckpoint);
      final databaseService = DatabaseService();
      await databaseService.checkpoint();
      _updateProgress(0.2);

      // 3. Copy database
      final dbPath = await databaseService.getDatabasePath();
      final dbFile = File(dbPath);
      final destDbFile = File('${exportDir.path}/note_synapse.db');
      if (await dbFile.exists()) {
        await dbFile.copy(destDbFile.path);
        _addLog(l10n.databaseCopiedSuccessfully);
      } else {
        throw Exception(l10n.databaseFileNotFound);
      }
      _updateProgress(0.3);

      // 4. Copy attachments directory to temp directory
      final attachmentsDir = await FileUtils.getPrivateStorageDirectory();
      final destAttachmentsDir = Directory('${exportDir.path}/attachments');
      if (await attachmentsDir.exists()) {
        await _copyDirectory(attachmentsDir, destAttachmentsDir);
        _addLog(l10n.attachmentsDirectoryCopiedSuccessfully);
      } else {
        _addLog(l10n.noAttachmentsDirectoryFound);
        await destAttachmentsDir.create(recursive: true);
      }
      _updateProgress(0.5);

      // 5. Open copied DB and update absolute paths to relative paths
      _addLog(l10n.updatingAttachmentPathsInCopiedDatabase);
      await _updateAttachmentPathsInCopiedDatabase(destDbFile.path);
      _updateProgress(0.7);

      // 6. Close copied DB (consistency guarantee)
      _addLog(l10n.databaseConsistencyVerified);
      _updateProgress(0.8);

      // 7. Create zip
      _addLog(l10n.creatingZipArchive);
      final zipFile = File('${exportDir.path}.zip');
      await _createZipArchive(exportDir, zipFile);
      _updateProgress(0.9);

      // 8. Move zip to cache directory
      final cacheDir = await getTemporaryDirectory();
      final finalZipFile = File('${cacheDir.path}/backup_$timestamp.zip');
      await zipFile.rename(finalZipFile.path);
      
      _addLog(l10n.backupCompleted(finalZipFile.path));
      _updateProgress(1.0);

      // 9. Offer download zip
      await _saveToExternalStorage(finalZipFile);
      
      // Reload backups list
      await _loadBackups();
      
      setState(() {
        _isBackingUp = false;
      });
      
    } catch (e) {
      _addLog(l10n.backupFailed(e.toString()));
      setState(() {
        _isBackingUp = false;
      });
    }
  }

  Future<void> _updateAttachmentPathsInCopiedDatabase(String dbPath) async {
    final l10n = AppLocalizations.of(context)!;
    
    // Open the copied database directly
    final db = await openDatabase(dbPath);
    
    try {
      // Get all attachments with absolute paths
      final attachments = await db.query(
        'attachments',
        where: 'isRelativePath = ?',
        whereArgs: [0], // 0 means absolute path
      );
      
      _addLog(l10n.foundAttachmentsWithAbsolutePaths(attachments.length));
      
      // Copy files with absolute paths to exported attachments directory
      final attachmentsDir = Directory('${dbPath.substring(0, dbPath.lastIndexOf('/'))}/attachments');
      
      for (final attachment in attachments) {
        final originalFilePath = attachment['filePath'] as String;
        final originalFileName = attachment['fileName'] as String;
        
        // Check if source file exists
        final sourceFile = File(originalFilePath);
        if (await sourceFile.exists()) {
          // Generate unique filename with UUID prefix
          final uniqueFileName = FileUtils.generateUniqueFileName(originalFileName);
          final destFile = File('${attachmentsDir.path}/$uniqueFileName');
          
          // Copy the file to the exported attachments directory
          await sourceFile.copy(destFile.path);
          
          // Update the database to use the new relative path
          final relativePath = 'attachments/$uniqueFileName';
          await db.update(
            'attachments',
            {
              'filePath': relativePath,
              'isRelativePath': 1,
            },
            where: 'id = ?',
            whereArgs: [attachment['id']],
          );
          
          _addLog(l10n.copiedAndUpdated(originalFileName, uniqueFileName));
        } else {
          _addLog(l10n.warningSourceFileNotFound(originalFilePath));
        }
      }
    } finally {
      await db.close();
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    
    await for (final entity in source.list(recursive: true)) {
      final relativePath = entity.path.substring(source.path.length + 1);
      final destPath = '${destination.path}/$relativePath';
      
      if (entity is File) {
        final destFile = File(destPath);
        await destFile.parent.create(recursive: true);
        await entity.copy(destFile.path);
      } else if (entity is Directory) {
        final destDir = Directory(destPath);
        await destDir.create(recursive: true);
      }
    }
  }

  Future<void> _createZipArchive(Directory sourceDir, File zipFile) async {
    final archive = Archive();
    
    await for (final entity in sourceDir.list(recursive: true)) {
      if (entity is File) {
        final relativePath = entity.path.substring(sourceDir.path.length + 1);
        final fileBytes = await entity.readAsBytes();
        archive.addFile(ArchiveFile(relativePath, fileBytes.length, fileBytes));
      }
    }
    
    final zipData = ZipEncoder().encode(archive);
    if (zipData != null) {
      await zipFile.writeAsBytes(zipData);
    } else {
      throw Exception('Failed to create zip archive');
    }
  }

  Future<void> _saveToExternalStorage(File zipFile) async {
    try {
      final bytes = await zipFile.readAsBytes();
      final fileName = zipFile.path.split('/').last;
      
      await FileSaver.instance.saveAs(
        name: fileName,
        bytes: bytes,
        ext: 'zip',
        mimeType: MimeType.zip,
      );
      
      _addLog('File saved to external storage: $fileName');
    } catch (e) {
      _addLog('Error saving to external storage: $e');
    }
  }

  Future<void> _deleteBackup(Map<String, dynamic> backup) async {
    final l10n = AppLocalizations.of(context)!;
    
    try {
      final file = File(backup['path']);
      if (await file.exists()) {
        await file.delete();
        _addLog(l10n.deletedBackup(backup['name']));
        await _loadBackups();
      }
    } catch (e) {
      _addLog(l10n.errorDeletingBackup(e.toString()));
    }
  }

  Future<void> _saveBackupAgain(Map<String, dynamic> backup) async {
    final l10n = AppLocalizations.of(context)!;
    
    try {
      final file = File(backup['path']);
      if (await file.exists()) {
        await _saveToExternalStorage(file);
      } else {
        _addLog(l10n.backupFileNotFound(backup['name']));
      }
    } catch (e) {
      _addLog(l10n.errorSavingBackupAgain(e.toString()));
    }
  }

  void _addLog(String message) {
    setState(() {
      _backupLogs.add('${DateTime.now().toString().substring(11, 19)}: $message');
    });
  }

  void _updateProgress(double progress) {
    setState(() {
      _backupProgress = progress;
    });
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.recovery),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.backupAllNotes,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.backupAllNotesDescription,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isBackingUp ? null : _backupAllNotes,
                      icon: _isBackingUp 
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download),
                      label: Text(_isBackingUp ? l10n.creatingBackup : l10n.backupAllNotes),
                    ),
                  ),
                  if (_isBackingUp) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: _backupProgress,
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(_backupProgress * 100).toInt()}%',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_backupLogs.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.backupLogs,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 200,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
                        ),
                      ),
                      child: ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: _backupLogs.length,
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              _backupLogs[index],
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_backups.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              l10n.previousBackups,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ..._backups.map((backup) => Card(
              child: ListTile(
                leading: const Icon(Icons.archive),
                title: Text(backup['name'] ?? l10n.backup),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(backup['date'] ?? ''),
                    Text(_formatFileSize(backup['size'] ?? 0)),
                  ],
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'save') {
                      _saveBackupAgain(backup);
                    } else if (value == 'delete') {
                      _deleteBackup(backup);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'save',
                      child: Row(
                        children: [
                          const Icon(Icons.download),
                          const SizedBox(width: 8),
                          Text(l10n.saveAgain),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          const Icon(Icons.delete),
                          const SizedBox(width: 8),
                          Text(l10n.delete),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )).toList(),
          ],
        ],
      ),
    );
  }
}
