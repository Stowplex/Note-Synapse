import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import 'package:file_saver/file_saver.dart';
import 'package:sqflite/sqflite.dart';
import '../l10n/app_localizations.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';

class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({super.key});

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  bool _isExporting = false;
  double _exportProgress = 0.0;
  List<String> _exportLogs = [];
  List<Map<String, dynamic>> _exports = [];

  @override
  void initState() {
    super.initState();
    _loadExports();
  }

  Future<void> _loadExports() async {
    try {
      final exportsDir = await _getExportsDirectory();
      if (await exportsDir.exists()) {
        final files = await exportsDir.list().toList();
        final exportFiles = files.where((file) => file.path.endsWith('.zip')).toList();
        
        setState(() {
          _exports = exportFiles.map((file) {
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
      LoggerService.error('Error loading exports: $e');
    }
  }

  Future<Directory> _getExportsDirectory() async {
    final tempDir = await getTemporaryDirectory();
    final exportsDir = Directory('${tempDir.path}/exports');
    if (!await exportsDir.exists()) {
      await exportsDir.create(recursive: true);
    }
    return exportsDir;
  }

  Future<void> _exportAllNotes() async {
    setState(() {
      _isExporting = true;
      _exportProgress = 0.0;
      _exportLogs.clear();
    });

    try {
      _addLog('Starting export process...');
      
      // Create timestamped export directory
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempDir = await getTemporaryDirectory();
      final exportDir = Directory('${tempDir.path}/export_$timestamp');
      await exportDir.create(recursive: true);
      
      _addLog('Created export directory: ${exportDir.path}');
      _updateProgress(0.1);

      // Force database checkpoint first
      _addLog('Forcing database checkpoint...');
      final databaseService = DatabaseService();
      await databaseService.checkpoint();
      _updateProgress(0.2);

      // Copy database to export directory first
      final dbPath = await databaseService.getDatabasePath();
      final dbFile = File(dbPath);
      final destDbFile = File('${exportDir.path}/note_synapse.db');
      if (await dbFile.exists()) {
        await dbFile.copy(destDbFile.path);
        _addLog('Database copied successfully');
      } else {
        throw Exception('Database file not found');
      }
      _updateProgress(0.3);

      // Get all attachments from the original database (read-only)
      final attachments = await databaseService.getAllAttachments();
      
      _addLog('Found ${attachments.length} attachments to process');
      _updateProgress(0.4);

      // Create attachments directory
      final attachmentsDir = Directory('${exportDir.path}/attachments');
      await attachmentsDir.create(recursive: true);

      // Internalize attachments and prepare path updates
      int processedAttachments = 0;
      final List<Map<String, String>> pathUpdates = [];
      
      for (final attachment in attachments) {
        try {
          final sourceFile = File(attachment['filePath']);
          if (await sourceFile.exists()) {
            // Convert path separators to underscores
            final safePath = attachment['filePath'].replaceAll('/', '_').replaceAll('\\', '_');
            final destFile = File('${attachmentsDir.path}/$safePath');
            
            // Copy file
            await sourceFile.copy(destFile.path);
            
            // Store path update for later (don't update original database)
            pathUpdates.add({
              'id': attachment['id'],
              'newPath': 'attachments/$safePath'
            });
            
            processedAttachments++;
            _addLog('Processed attachment: ${attachment['fileName']}');
          } else {
            _addLog('Warning: Attachment file not found: ${attachment['filePath']}');
          }
        } catch (e) {
          _addLog('Error processing attachment ${attachment['fileName']}: $e');
        }
      }

      _addLog('Processed $processedAttachments attachments');
      _updateProgress(0.6);

      // Update paths in the copied database only
      if (pathUpdates.isNotEmpty) {
        _addLog('Updating attachment paths in exported database...');
        await _updateAttachmentPathsInCopiedDatabase(destDbFile.path, pathUpdates);
        _addLog('Updated ${pathUpdates.length} attachment paths in exported database');
      }
      _updateProgress(0.8);

      // Create zip file
      _addLog('Creating zip archive...');
      final zipFile = File('${exportDir.path}.zip');
      await _createZipArchive(exportDir, zipFile);
      _updateProgress(0.9);

      // Move zip to exports directory
      final exportsDir = await _getExportsDirectory();
      final finalZipFile = File('${exportsDir.path}/export_$timestamp.zip');
      await zipFile.rename(finalZipFile.path);
      
      _addLog('Export completed: ${finalZipFile.path}');
      _updateProgress(1.0);

      // Offer to save to external storage
      await _saveToExternalStorage(finalZipFile);
      
      // Reload exports list
      await _loadExports();
      
      setState(() {
        _isExporting = false;
      });
      
    } catch (e) {
      _addLog('Export failed: $e');
      setState(() {
        _isExporting = false;
      });
    }
  }

  Future<void> _updateAttachmentPathsInCopiedDatabase(String dbPath, List<Map<String, String>> pathUpdates) async {
    // Open the copied database directly
    final db = await openDatabase(dbPath);
    
    try {
      // Update each attachment path
      for (final update in pathUpdates) {
        await db.update(
          'attachments',
          {'filePath': update['newPath']},
          where: 'id = ?',
          whereArgs: [update['id']],
        );
      }
    } finally {
      await db.close();
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

  Future<void> _deleteExport(Map<String, dynamic> export) async {
    try {
      final file = File(export['path']);
      if (await file.exists()) {
        await file.delete();
        _addLog('Deleted export: ${export['name']}');
        await _loadExports();
      }
    } catch (e) {
      _addLog('Error deleting export: $e');
    }
  }

  Future<void> _saveExportAgain(Map<String, dynamic> export) async {
    try {
      final file = File(export['path']);
      if (await file.exists()) {
        await _saveToExternalStorage(file);
      } else {
        _addLog('Export file not found: ${export['name']}');
      }
    } catch (e) {
      _addLog('Error saving export again: $e');
    }
  }

  void _addLog(String message) {
    setState(() {
      _exportLogs.add('${DateTime.now().toString().substring(11, 19)}: $message');
    });
  }

  void _updateProgress(double progress) {
    setState(() {
      _exportProgress = progress;
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
                    l10n.exportAllNotes,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.exportAllNotesDescription,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isExporting ? null : _exportAllNotes,
                      icon: _isExporting 
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download),
                      label: Text(_isExporting ? l10n.exporting : l10n.exportAllNotes),
                    ),
                  ),
                  if (_isExporting) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: _exportProgress,
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(_exportProgress * 100).toInt()}%',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_exportLogs.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.exportLogs,
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
                        itemCount: _exportLogs.length,
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              _exportLogs[index],
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
          if (_exports.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              l10n.previousExports,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ..._exports.map((export) => Card(
              child: ListTile(
                leading: const Icon(Icons.archive),
                title: Text(export['name'] ?? 'Export'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(export['date'] ?? ''),
                    Text(_formatFileSize(export['size'] ?? 0)),
                  ],
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'save') {
                      _saveExportAgain(export);
                    } else if (value == 'delete') {
                      _deleteExport(export);
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
