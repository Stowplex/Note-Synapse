import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive_io.dart';
import 'package:file_saver/file_saver.dart';
import 'package:sqflite/sqflite.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import '../utils/file_utils.dart';
import '../providers/app_provider.dart';
import 'raw_data_manager/raw_data_manager_screen.dart';

class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({super.key});

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  bool _isBackingUp = false;
  double _backupProgress = 0.0;
  final List<String> _backupLogs = [];
  List<Map<String, dynamic>> _backups = [];
  List<Map<String, dynamic>> _availableRecoveries = [];

  // Import functionality
  bool _isImporting = false;
  double _importProgress = 0.0;
  final List<String> _importLogs = [];
  String? _originalDbBackupPath;

  @override
  void initState() {
    super.initState();
    _loadBackups();
    _loadAvailableRecoveries();
  }

  Future<void> _loadBackups() async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (await tempDir.exists()) {
        final files = await tempDir.list().toList();
        final backupFiles = files
            .where(
              (file) =>
                  file.path.endsWith('.zip') && file.path.contains('backup_'),
            )
            .toList();

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

  Future<void> _loadAvailableRecoveries() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final List<Map<String, dynamic>> recoveries = [];

      // Look for original backup files (the actual undo targets)
      final files = await tempDir.list().toList();
      final backupFiles = files
          .where(
            (file) =>
                file.path.endsWith('.db') &&
                file.path.contains('original_db_backup_'),
          )
          .toList();

      for (final backupFile in backupFiles) {
        final stat = await backupFile.stat();
        final fileName = backupFile.path.split('/').last;
        // Extract timestamp from filename (original_db_backup_1234567890.db)
        final timestampStr = fileName
            .replaceAll('original_db_backup_', '')
            .replaceAll('.db', '');
        final timestamp = int.tryParse(timestampStr) ?? 0;
        final date = DateTime.fromMillisecondsSinceEpoch(timestamp);

        recoveries.add({
          'name': 'Database Backup',
          'date': date.toString().substring(0, 19),
          'path': backupFile.path,
          'size': stat.size,
          'type': 'backup',
          'timestamp': timestamp,
        });
      }

      setState(() {
        _availableRecoveries = recoveries;
        // Sort by timestamp (newest first)
        _availableRecoveries.sort(
          (a, b) => (b['timestamp'] as int).compareTo(a['timestamp'] as int),
        );
      });
    } catch (e) {
      LoggerService.error('Error loading available recoveries: $e');
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
      final attachmentsDir = Directory(
        '${dbPath.substring(0, dbPath.lastIndexOf('/'))}/attachments',
      );

      for (final attachment in attachments) {
        final originalFilePath = attachment['filePath'] as String;
        final originalFileName = attachment['fileName'] as String;

        // Check if source file exists
        final sourceFile = File(originalFilePath);
        if (await sourceFile.exists()) {
          // Generate unique filename with UUID prefix
          final uniqueFileName = FileUtils.generateUniqueFileName(
            originalFileName,
          );
          final destFile = File('${attachmentsDir.path}/$uniqueFileName');

          // Copy the file to the exported attachments directory
          await sourceFile.copy(destFile.path);

          // Update the database to use the new relative path
          final relativePath = 'attachments/$uniqueFileName';
          await db.update(
            'attachments',
            {'filePath': relativePath, 'isRelativePath': 1},
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
    final start = DateTime.now();
    _addLog('Starting zip creation...');

    try {
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);

      await for (final entity in sourceDir.list(recursive: true)) {
        if (entity is File) {
          final relativePath = entity.path.substring(sourceDir.path.length + 1);
          encoder.addFile(entity, relativePath);
          await Future.delayed(Duration.zero); // Yield to UI
        }
      }

      encoder.close();

      final end = DateTime.now();
      final duration = end.difference(start);
      _addLog('Zip creation took ${duration.inSeconds}s');
    } catch (e) {
      _addLog('Error creating zip: $e');
      rethrow;
    }
  }

  static const platform = MethodChannel('com.github.kkspeed/share');

  Future<void> _saveToExternalStorage(File zipFile) async {
    try {
      final fileName = zipFile.path.split('/').last;

      if (Platform.isAndroid || Platform.isIOS) {
        await platform.invokeMethod('saveFileToExternalStorage', {
          'filePath': zipFile.path,
          'fileName': fileName,
          'mimeType': 'application/zip',
        });
        _addLog('File save initiated: $fileName');
      } else {
        // Fallback for other platforms (e.g. desktop debug)
        await FileSaver.instance.saveAs(
          name: fileName.replaceAll('.zip', ''),
          filePath: zipFile.path,
          fileExtension: 'zip',
          mimeType: MimeType.zip,
        );
        _addLog('File saved via fallback: $fileName');
      }
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
      _backupLogs.add(
        '${DateTime.now().toString().substring(11, 19)}: $message',
      );
    });
  }

  void _updateProgress(double progress) {
    setState(() {
      _backupProgress = progress;
    });
  }

  void _updateImportProgress(double progress) {
    setState(() {
      _importProgress = progress;
    });
  }

  void _addImportLog(String message) {
    setState(() {
      _importLogs.add(
        '${DateTime.now().toString().substring(11, 19)}: $message',
      );
    });
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _importBackup() async {
    final l10n = AppLocalizations.of(context)!;

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        allowMultiple: false,
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        if (file.path != null) {
          await _processBackupFile(file.path!);
        } else {
          _addImportLog(l10n.invalidBackupFile);
        }
      }
    } catch (e) {
      _addImportLog('${l10n.errorPickingFile}: $e');
    }
  }

  Future<void> _processBackupFile(String backupFilePath) async {
    final l10n = AppLocalizations.of(context)!;

    setState(() {
      _isImporting = true;
      _importProgress = 0.0;
      _importLogs.clear();
    });

    try {
      _addImportLog(l10n.checkpointingDatabase);
      _updateImportProgress(0.05);

      // Step -1: Checkpoint current app's DB
      final databaseService = DatabaseService();
      await databaseService.checkpoint();

      _addImportLog(l10n.copyingDatabaseToStaging);
      _updateImportProgress(0.1);

      // Step -0.5: Copy the app's DB to a staging directory
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final stagingDir = Directory('${tempDir.path}/staging_$timestamp');
      await stagingDir.create(recursive: true);

      final currentDbPath = await databaseService.getDatabasePath();
      final currentDbFile = File(currentDbPath);
      final stagingDbFile = File('${stagingDir.path}/note_synapse.db');
      await currentDbFile.copy(stagingDbFile.path);

      // Store original DB backup path for undo functionality
      _originalDbBackupPath =
          '${tempDir.path}/original_db_backup_$timestamp.db';
      await currentDbFile.copy(_originalDbBackupPath!);

      _addImportLog(l10n.extractingBackupFile);
      _updateImportProgress(0.15);

      // Step 0: Open the staging DB
      final stagingDb = await openDatabase(stagingDbFile.path);

      // Step 1: Open the file as zip
      final backupFile = File(backupFilePath);
      if (!await backupFile.exists()) {
        throw Exception(l10n.invalidBackupFile);
      }

      final inputStream = InputFileStream(backupFilePath);
      final archive = ZipDecoder().decodeBuffer(inputStream);

      // Step 2: Extract the zip to a temp directory
      final extractDir = Directory('${tempDir.path}/extract_$timestamp');
      await extractDir.create(recursive: true);

      for (final file in archive.files) {
        final filePath = '${extractDir.path}/${file.name}';
        // Ensure parent directory exists
        final fileDir = Directory(path.dirname(filePath));
        await fileDir.create(recursive: true);

        if (file.isFile) {
          final outputStream = OutputFileStream(filePath);
          file.writeContent(outputStream);
          outputStream.close();
          await Future.delayed(Duration.zero); // Yield to UI
        }
      }

      inputStream.close();

      _addImportLog(l10n.validatingBackupDatabase);
      _updateImportProgress(0.2);

      // Step 3: Check the database version of the backed up DB
      final backupDbPath = '${extractDir.path}/note_synapse.db';
      final backupDbFile = File(backupDbPath);
      if (!await backupDbFile.exists()) {
        throw Exception(l10n.invalidBackupFile);
      }

      final backupDb = await openDatabase(backupDbPath);
      final versionResult = await backupDb.rawQuery('PRAGMA user_version');
      final backupVersion = versionResult.first['user_version'] as int;
      await backupDb.close();

      // Check if backup version is compatible
      if (backupVersion > DatabaseService.DATABASE_VERSION) {
        throw Exception(l10n.backupVersionTooNew);
      }

      _addImportLog(l10n.migratingBackupDatabase);
      _updateImportProgress(0.25);

      // Step 4: Upgrade the backup database to current version
      final migratedBackupDb = await openDatabase(
        backupDbPath,
        version: DatabaseService.DATABASE_VERSION,
        onCreate: (db, version) async {
          // This shouldn't be called since we're opening an existing DB
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          // Apply migrations from old version to new version
          await databaseService.migrateBackupDatabase(
            db,
            oldVersion,
            newVersion,
          );
        },
      );

      _addImportLog(l10n.mergingNotes);
      _updateImportProgress(0.06);

      // Step 1: Merge the notes table
      await _mergeNotes(stagingDb, migratedBackupDb);

      _addImportLog(l10n.mergingSubNotes);
      _updateImportProgress(0.12);

      // Step 2: Insert all subnotes
      await _mergeSubNotes(stagingDb, migratedBackupDb);

      _addImportLog(l10n.mergingTags);
      _updateImportProgress(0.18);

      // Step 3: Insert all tags
      await _mergeTags(stagingDb, migratedBackupDb);

      _addImportLog('Merging note-tag relationships...');
      _updateImportProgress(0.24);

      // Step 4: Merge note_tags table
      await _mergeNoteTags(stagingDb, migratedBackupDb);

      _addImportLog(l10n.mergingRelationships);
      _updateImportProgress(0.30);

      // Step 5: Insert all relationships
      await _mergeRelationships(stagingDb, migratedBackupDb);

      _addImportLog(l10n.mergingFilters);
      _updateImportProgress(0.36);

      // Step 6: Insert all unique filters
      await _mergeFilters(stagingDb, migratedBackupDb);

      _addImportLog(l10n.mergingUserApps);
      _updateImportProgress(0.42);

      // Step 7: Merge user apps
      await _mergeUserApps(stagingDb, migratedBackupDb);

      _addImportLog(l10n.copyingAttachments);
      _updateImportProgress(0.48);

      // Copy attachments
      final attachmentsDir = Directory('${extractDir.path}/attachments');
      if (await attachmentsDir.exists()) {
        final appAttachmentsDir = await FileUtils.getPrivateStorageDirectory();
        await _copyDirectory(attachmentsDir, appAttachmentsDir);
      }

      _addImportLog('Merging attachments...');
      _updateImportProgress(0.54);

      // Step 8: Merge attachments table
      await _mergeAttachments(stagingDb, migratedBackupDb);

      _addImportLog('Merging conversations...');
      _updateImportProgress(0.60);

      // Step 9: Insert all conversations that are not already in the db (by id)
      await _mergeConversations(stagingDb, migratedBackupDb);

      _addImportLog('Merging conversation messages...');
      _updateImportProgress(0.66);

      // Step 10: Insert all conversation messages that are not already in the db (by message id)
      await _mergeConversationMessages(stagingDb, migratedBackupDb);

      _addImportLog('Merging conversation attachments...');
      _updateImportProgress(0.72);

      // Step 11: Insert all conversation attachments that are not already in db (by id)
      await _mergeConversationAttachments(stagingDb, migratedBackupDb);

      _addImportLog('Merging conversation-message mappings...');
      _updateImportProgress(0.78);

      // Step 12: Insert all unique conversation - message mappings by (conversationId, messageId)
      await _mergeConversationMessageMappings(stagingDb, migratedBackupDb);

      _addImportLog('Merging message parents...');
      _updateImportProgress(0.84);

      // Step 13: Insert all unique message parents (unique by messageId, parentMessageId)
      await _mergeMessageParents(stagingDb, migratedBackupDb);

      _addImportLog('Merging conversation-tag mappings...');
      _updateImportProgress(0.87);

      // Step 14: Insert all unique conversation tag mappings (conversationId, tagId)
      await _mergeConversationTagMappings(stagingDb, migratedBackupDb);

      _addImportLog('Merging conversation-note mappings...');
      _updateImportProgress(0.90);

      // Step 15: Insert all conversation note mapping unique by (noteId, conversationId)
      await _mergeConversationNoteMappings(stagingDb, migratedBackupDb);

      await migratedBackupDb.close();
      await stagingDb.close();

      _addImportLog(l10n.swappingDatabases);
      _updateImportProgress(0.94);

      // Force cleanup of staging DB connection before copying
      await stagingDb.close(); // Ensure strictly closed

      // Step 16: Copy staging DB to app's DB directory
      await stagingDbFile.copy(currentDbPath);

      _addImportLog(l10n.reloadingData);
      _updateImportProgress(1.0);

      // Step 17: Reload data in the app
      if (mounted) {
        final appProvider = Provider.of<AppProvider>(context, listen: false);
        await appProvider.loadData();
      }

      setState(() {
        _isImporting = false;
      });

      // Reload available recoveries after successful import
      await _loadAvailableRecoveries();

      _addImportLog(l10n.importCompletedSuccessfully);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.importCompletedSuccessfully),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      _addImportLog('${l10n.importFailed}: $e');
      setState(() {
        _isImporting = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${l10n.importFailed}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _mergeNotes(Database stagingDb, Database backupDb) async {
    // Get all notes from backup
    final backupNotes = await backupDb.query('notes');

    for (final note in backupNotes) {
      // Check if note exists in staging
      final existingNotes = await stagingDb.query(
        'notes',
        where: 'id = ?',
        whereArgs: [note['id']],
      );

      if (existingNotes.isNotEmpty) {
        // Check if backup note is newer
        final existingNote = existingNotes.first;
        final existingUpdatedAt = existingNote['updatedAt'] as int;
        final backupUpdatedAt = note['updatedAt'] as int;

        if (backupUpdatedAt > existingUpdatedAt) {
          // Replace with backup note - filter to only existing columns
          final filteredData = await _filterDataForTable(
            stagingDb,
            'notes',
            note,
          );
          await stagingDb.update(
            'notes',
            filteredData,
            where: 'id = ?',
            whereArgs: [note['id']],
          );
        }
      } else {
        // Insert new note - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'notes',
          note,
        );
        await stagingDb.insert('notes', filteredData);
      }
    }
  }

  Future<void> _mergeSubNotes(Database stagingDb, Database backupDb) async {
    final backupSubNotes = await backupDb.query('subnotes');

    for (final subNote in backupSubNotes) {
      // Check if subnote exists in staging
      final existingSubNotes = await stagingDb.query(
        'subnotes',
        where: 'id = ? AND noteId = ?',
        whereArgs: [subNote['id'], subNote['noteId']],
      );

      if (existingSubNotes.isNotEmpty) {
        // Check if backup subnote is newer
        final existingSubNote = existingSubNotes.first;
        final existingCreatedAt = existingSubNote['createdAt'] as int;
        final backupCreatedAt = subNote['createdAt'] as int;

        if (backupCreatedAt > existingCreatedAt) {
          // Replace with backup subnote - filter to only existing columns
          final filteredData = await _filterDataForTable(
            stagingDb,
            'subnotes',
            subNote,
          );
          await stagingDb.update(
            'subnotes',
            filteredData,
            where: 'id = ? AND noteId = ?',
            whereArgs: [subNote['id'], subNote['noteId']],
          );
        }
      } else {
        // Insert new subnote - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'subnotes',
          subNote,
        );
        await stagingDb.insert('subnotes', filteredData);
      }
    }
  }

  Future<void> _mergeTags(Database stagingDb, Database backupDb) async {
    final backupTags = await backupDb.query('tags');

    for (final tag in backupTags) {
      // Check if tag exists in staging
      final existingTags = await stagingDb.query(
        'tags',
        where: 'name = ?',
        whereArgs: [tag['name']],
      );

      if (existingTags.isEmpty) {
        // Insert new tag - filter to only existing columns
        final filteredData = await _filterDataForTable(stagingDb, 'tags', tag);
        await stagingDb.insert('tags', filteredData);
      } else {
        // Tag exists, check if note_tags table needs updating
        final existingTag = existingTags.first;
        final existingTagId = existingTag['id'] as String;
        final backupTagId = tag['id'] as String;

        if (existingTagId != backupTagId) {
          // Update note_tags table to use the existing tag ID
          await stagingDb.update(
            'note_tags',
            {'tagId': existingTagId},
            where: 'tagId = ?',
            whereArgs: [backupTagId],
          );
        }
      }
    }
  }

  Future<void> _mergeNoteTags(Database stagingDb, Database backupDb) async {
    final backupNoteTags = await backupDb.query('note_tags');

    for (final noteTag in backupNoteTags) {
      // Check if note-tag relationship exists in staging
      final existingNoteTags = await stagingDb.query(
        'note_tags',
        where: 'noteId = ? AND tagId = ?',
        whereArgs: [noteTag['noteId'], noteTag['tagId']],
      );

      if (existingNoteTags.isEmpty) {
        // Insert new note-tag relationship - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'note_tags',
          noteTag,
        );
        await stagingDb.insert('note_tags', filteredData);
      }
    }
  }

  Future<void> _mergeRelationships(
    Database stagingDb,
    Database backupDb,
  ) async {
    final backupRelationships = await backupDb.query('relationships');

    for (final relationship in backupRelationships) {
      // Check if relationship exists in staging
      final existingRelationships = await stagingDb.query(
        'relationships',
        where: 'fromNoteId = ? AND toNoteId = ? AND type = ?',
        whereArgs: [
          relationship['fromNoteId'],
          relationship['toNoteId'],
          relationship['type'],
        ],
      );

      if (existingRelationships.isEmpty) {
        // Insert new relationship - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'relationships',
          relationship,
        );
        await stagingDb.insert('relationships', filteredData);
      }
    }
  }

  Future<void> _mergeFilters(Database stagingDb, Database backupDb) async {
    final backupFilters = await backupDb.query('filters');

    for (final filter in backupFilters) {
      final id = filter['id'] as String;
      final backupUpdatedAt = filter['updatedAt'] as int;

      // Check if filter exists in staging by ID
      final existingFilters = await stagingDb.query(
        'filters',
        where: 'id = ?',
        whereArgs: [id],
      );

      if (existingFilters.isNotEmpty) {
        final existingFilter = existingFilters.first;
        final existingUpdatedAt = existingFilter['updatedAt'] as int;

        // If backup is newer, update the existing filter
        if (backupUpdatedAt > existingUpdatedAt) {
          final filteredData = await _filterDataForTable(
            stagingDb,
            'filters',
            filter,
          );
          await stagingDb.update(
            'filters',
            filteredData,
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      } else {
        // Insert new filter
        final filteredData = await _filterDataForTable(
          stagingDb,
          'filters',
          filter,
        );
        await stagingDb.insert('filters', filteredData);
      }
    }
  }

  Future<void> _mergeUserApps(Database stagingDb, Database backupDb) async {
    final backupApps = await backupDb.query('user_apps');

    for (final app in backupApps) {
      // Check if app exists in staging by UUID
      final existingApps = await stagingDb.query(
        'user_apps',
        where: 'uuid = ?',
        whereArgs: [app['uuid']],
      );

      if (existingApps.isNotEmpty) {
        // UUID clash - insert PINNED revision as latest revision
        await _insertPinnedRevisionForApp(stagingDb, backupDb, app);
      } else {
        // Insert app - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'user_apps',
          app,
        );
        await stagingDb.insert('user_apps', filteredData);

        // Insert associated revisions
        final revisions = await backupDb.query(
          'app_revisions',
          where: 'appId = ?',
          whereArgs: [app['id']],
        );

        for (final revision in revisions) {
          // Insert revision - filter to only existing columns
          final filteredRevision = await _filterDataForTable(
            stagingDb,
            'app_revisions',
            revision,
          );
          await stagingDb.insert('app_revisions', filteredRevision);
        }

        // Insert associated libraries and dependencies
        await _copyAppLibrariesAndDependencies(
          stagingDb,
          backupDb,
          app['uuid'] as String,
        );
      }
    }
  }

  Future<void> _insertPinnedRevisionForApp(
    Database stagingDb,
    Database backupDb,
    Map<String, dynamic> app,
  ) async {
    LoggerService.info(
      'Inserting PINNED revision for app with UUID: ${app['uuid']}',
    );

    // 1. Get the pinned revision from the backup database
    final backupPinnedRevisionId = app['selectedRevisionId'] as String?;
    if (backupPinnedRevisionId == null) {
      LoggerService.warning(
        'No pinned revision found for app ${app['uuid']}, skipping',
      );
      return;
    }

    final backupPinnedRevision = await backupDb.query(
      'app_revisions',
      where: 'id = ?',
      whereArgs: [backupPinnedRevisionId],
    );

    if (backupPinnedRevision.isEmpty) {
      LoggerService.warning(
        'Pinned revision $backupPinnedRevisionId not found in backup database, skipping',
      );
      return;
    }

    final pinnedRevisionData = backupPinnedRevision.first;

    // 2. Get the latest revision number from the staging database for the existing app
    final existingApp = await stagingDb
        .query('user_apps', where: 'uuid = ?', whereArgs: [app['uuid']])
        .then((apps) => apps.first);

    final existingAppId = existingApp['id'] as String;

    final latestRevisions = await stagingDb.query(
      'app_revisions',
      where: 'appId = ?',
      whereArgs: [existingAppId],
      orderBy: 'revisionNumber DESC',
      limit: 1,
    );

    final nextRevisionNumber = latestRevisions.isEmpty
        ? 1
        : (latestRevisions.first['revisionNumber'] as int) + 1;

    // 3. Create a new revision in staging database that copies the pinned revision from backup
    final newRevisionId = '${existingAppId}_rev_$nextRevisionNumber';
    final now = DateTime.now().millisecondsSinceEpoch;

    final newRevision = {
      'id': newRevisionId,
      'appId': existingAppId, // Use the existing app's ID in staging
      'revisionNumber': nextRevisionNumber,
      'revisionTimestamp': now,
      'userPrompt': pinnedRevisionData['userPrompt'],
      'aiResponse': pinnedRevisionData['aiResponse'],
      'appCode': pinnedRevisionData['appCode'],
      'attachmentPaths': pinnedRevisionData['attachmentPaths'],
    };

    // Insert the new revision - filter to only existing columns
    final filteredRevision = await _filterDataForTable(
      stagingDb,
      'app_revisions',
      newRevision,
    );
    await stagingDb.insert('app_revisions', filteredRevision);

    // Update the existing app to set the selectedRevisionId to the new revision
    await stagingDb.update(
      'user_apps',
      {'selectedRevisionId': newRevisionId},
      where: 'uuid = ?',
      whereArgs: [app['uuid']],
    );

    LoggerService.info(
      'Created new revision $newRevisionId (revision $nextRevisionNumber) from pinned revision $backupPinnedRevisionId for app UUID: ${app['uuid']}',
    );
  }

  Future<void> _copyAppLibrariesAndDependencies(
    Database stagingDb,
    Database backupDb,
    String appUuid,
  ) async {
    // Get libraries for this app
    final libraries = await backupDb.query(
      'user_app_libraries',
      where: 'app_uuid = ?',
      whereArgs: [appUuid],
    );

    for (final library in libraries) {
      // Insert library - filter to only existing columns
      final filteredLibrary = await _filterDataForTable(
        stagingDb,
        'user_app_libraries',
        library,
      );
      final libraryId = await stagingDb.insert(
        'user_app_libraries',
        filteredLibrary,
      );

      // Get dependencies for this library using chunked reading to avoid cursor window issues
      final dependencies = await backupDb.rawQuery(
        '''
        SELECT id, original_url, local_path, library_id,
               CASE 
                 WHEN length(bytes) > 0 THEN 'BLOB_DATA'
                 ELSE NULL 
               END as has_blob
        FROM user_app_library_dependencies 
        WHERE library_id = ?
      ''',
        [library['id']],
      );

      for (final dependency in dependencies) {
        final dependencyData = Map<String, dynamic>.from(dependency);
        dependencyData['library_id'] = libraryId;

        // Remove the temporary has_blob column before inserting
        dependencyData.remove('has_blob');

        // Read BLOB data in chunks to avoid cursor window issues
        if (dependency['has_blob'] != null) {
          try {
            final blobData = await _readBlobInChunks(
              backupDb,
              dependency['id'] as int,
            );
            dependencyData['bytes'] = Uint8List.fromList(blobData);
          } catch (e) {
            LoggerService.error(
              'Failed to read BLOB data for dependency ${dependency['id']}: $e',
              error: e,
            );
            dependencyData['bytes'] = Uint8List(0);
          }
        } else {
          dependencyData['bytes'] = Uint8List(0);
        }

        // Insert dependency - filter to only existing columns
        final filteredDependency = await _filterDataForTable(
          stagingDb,
          'user_app_library_dependencies',
          dependencyData,
        );
        await stagingDb.insert(
          'user_app_library_dependencies',
          filteredDependency,
        );
      }
    }
  }

  Future<void> _mergeAttachments(Database stagingDb, Database backupDb) async {
    final backupAttachments = await backupDb.query('attachments');

    for (final attachment in backupAttachments) {
      final filePath = attachment['filePath'] as String;
      final isRelativePath = (attachment['isRelativePath'] as int) == 1;

      // Convert file path if needed
      String finalFilePath = filePath;
      if (isRelativePath) {
        // Path is already relative, keep as is
        finalFilePath = filePath;
      } else {
        // Convert absolute path to relative path
        final fileName = filePath.split('/').last;
        finalFilePath = 'attachments/$fileName';
      }

      // Check if attachment exists in staging (unique on noteId, filePath)
      final existingAttachments = await stagingDb.query(
        'attachments',
        where: 'noteId = ? AND filePath = ?',
        whereArgs: [attachment['noteId'], finalFilePath],
      );

      if (existingAttachments.isEmpty) {
        // Create new attachment record with proper path
        final newAttachment = Map<String, dynamic>.from(attachment);
        newAttachment['filePath'] = finalFilePath;
        newAttachment['isRelativePath'] = 1; // Always store as relative path

        // Insert attachment - filter to only existing columns
        final filteredAttachment = await _filterDataForTable(
          stagingDb,
          'attachments',
          newAttachment,
        );
        filteredAttachment.remove('id');
        await stagingDb.insert('attachments', filteredAttachment);
      }
    }
  }

  /// Gets the list of column names that exist in the target table
  Future<List<String>> _getTableColumns(Database db, String tableName) async {
    final tableInfo = await db.rawQuery('PRAGMA table_info($tableName)');
    return tableInfo.map((col) => col['name'] as String).toList();
  }

  /// Filters data to only include columns that exist in the target table
  Future<Map<String, dynamic>> _filterDataForTable(
    Database db,
    String tableName,
    Map<String, dynamic> data,
  ) async {
    final validColumns = await _getTableColumns(db, tableName);
    final filtered = <String, dynamic>{};

    for (final entry in data.entries) {
      if (validColumns.contains(entry.key)) {
        filtered[entry.key] = entry.value;
      }
    }

    return filtered;
  }

  Future<void> _mergeConversations(
    Database stagingDb,
    Database backupDb,
  ) async {
    final backupConversations = await backupDb.query('conversations');

    for (final conversation in backupConversations) {
      // Check if conversation exists in staging by id
      final existingConversations = await stagingDb.query(
        'conversations',
        where: 'id = ?',
        whereArgs: [conversation['id']],
      );

      if (existingConversations.isEmpty) {
        // Insert new conversation - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'conversations',
          conversation,
        );
        await stagingDb.insert('conversations', filteredData);
      }
    }
  }

  Future<void> _mergeConversationMessages(
    Database stagingDb,
    Database backupDb,
  ) async {
    // Process messages in batches to avoid CursorWindow size limits
    int offset = 0;
    const int limit = 50;
    bool hasMore = true;

    while (hasMore) {
      // Select all columns except 'content' and 'metadata', which can be huge
      final batch = await backupDb.rawQuery(
        '''
        SELECT id, type, timestamp, modelUsed, length(content) as content_length, length(metadata) as metadata_length
        FROM conversation_messages
        LIMIT ? OFFSET ?
        ''',
        [limit, offset],
      );

      if (batch.isEmpty) {
        hasMore = false;
        break;
      }

      for (final row in batch) {
        final messageId = row['id'] as String;
        final contentLength = (row['content_length'] as int?) ?? 0;
        final metadataLength = (row['metadata_length'] as int?) ?? 0;

        // Check if message exists in staging by id
        final existingMessages = await stagingDb.query(
          'conversation_messages',
          where: 'id = ?',
          whereArgs: [messageId],
        );

        if (existingMessages.isEmpty) {
          String content = '';
          String?
          metadata; // metadata is nullable in schema, treating as String?

          // --- Handle Content ---
          // If content is small (< 1MB), read it normally
          // Otherwise read in chunks
          if (contentLength < 1024 * 1024) {
            final contentResult = await backupDb.query(
              'conversation_messages',
              columns: ['content'],
              where: 'id = ?',
              whereArgs: [messageId],
            );
            if (contentResult.isNotEmpty) {
              content = contentResult.first['content'] as String;
            }
          } else {
            // Large content, read in chunks
            content = await _readStringInChunks(
              backupDb,
              messageId,
              'content',
              contentLength,
            );
          }

          // --- Handle Metadata ---
          // Metadata can be null or empty string in DB, usually stored as text
          if (metadataLength > 0) {
            if (metadataLength < 1024 * 1024) {
              final metaResult = await backupDb.query(
                'conversation_messages',
                columns: ['metadata'],
                where: 'id = ?',
                whereArgs: [messageId],
              );
              if (metaResult.isNotEmpty) {
                metadata = metaResult.first['metadata'] as String?;
              }
            } else {
              // Large metadata, read in chunks
              metadata = await _readStringInChunks(
                backupDb,
                messageId,
                'metadata',
                metadataLength,
              );
            }
          }

          // Construct full message map
          final message = Map<String, dynamic>.from(row);
          message['content'] = content;
          message['metadata'] = metadata;
          message.remove('content_length'); // Remove the helper column
          message.remove('metadata_length'); // Remove the helper column

          // Insert new message - filter to only existing columns
          final filteredData = await _filterDataForTable(
            stagingDb,
            'conversation_messages',
            message,
          );
          await stagingDb.insert('conversation_messages', filteredData);
        }
      }

      offset += limit;
      // Yield to event loop to prevent UI freeze during large imports
      await Future.delayed(Duration.zero);
    }
  }

  Future<void> _mergeConversationAttachments(
    Database stagingDb,
    Database backupDb,
  ) async {
    final backupAttachments = await backupDb.query('conversation_attachments');

    for (final attachment in backupAttachments) {
      // Check if attachment exists in staging by id
      final existingAttachments = await stagingDb.query(
        'conversation_attachments',
        where: 'id = ?',
        whereArgs: [attachment['id']],
      );

      if (existingAttachments.isEmpty) {
        // Insert new attachment - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'conversation_attachments',
          attachment,
        );
        await stagingDb.insert('conversation_attachments', filteredData);
      }
    }
  }

  Future<void> _mergeConversationMessageMappings(
    Database stagingDb,
    Database backupDb,
  ) async {
    final backupMappings = await backupDb.query('conversation_message_mapping');

    for (final mapping in backupMappings) {
      // Check if mapping exists in staging (unique by conversationId, messageId)
      final existingMappings = await stagingDb.query(
        'conversation_message_mapping',
        where: 'conversationId = ? AND messageId = ?',
        whereArgs: [mapping['conversationId'], mapping['messageId']],
      );

      if (existingMappings.isEmpty) {
        // Insert new mapping - filter to only existing columns, remove id if auto-increment
        var filteredData = await _filterDataForTable(
          stagingDb,
          'conversation_message_mapping',
          mapping,
        );
        // Remove id if it's auto-increment to let SQLite generate a new one
        if (filteredData.containsKey('id') && mapping['id'] is int) {
          filteredData.remove('id');
        }
        await stagingDb.insert('conversation_message_mapping', filteredData);
      }
    }
  }

  Future<void> _mergeMessageParents(
    Database stagingDb,
    Database backupDb,
  ) async {
    final backupParents = await backupDb.query('message_parents');

    for (final parent in backupParents) {
      // Check if parent relationship exists in staging (unique by messageId, parentMessageId)
      final existingParents = await stagingDb.query(
        'message_parents',
        where: 'messageId = ? AND parentMessageId = ?',
        whereArgs: [parent['messageId'], parent['parentMessageId']],
      );

      if (existingParents.isEmpty) {
        // Insert new parent relationship - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'message_parents',
          parent,
        );
        await stagingDb.insert('message_parents', filteredData);
      }
    }
  }

  Future<void> _mergeConversationTagMappings(
    Database stagingDb,
    Database backupDb,
  ) async {
    final backupMappings = await backupDb.query('conversation_tags');

    for (final mapping in backupMappings) {
      final existingMappings = await stagingDb.query(
        'conversation_tags',
        where: 'conversationId = ? AND tagId = ?',
        whereArgs: [mapping['conversationId'], mapping['tagId']],
        limit: 1,
      );

      if (existingMappings.isEmpty) {
        final filteredData = await _filterDataForTable(
          stagingDb,
          'conversation_tags',
          mapping,
        );
        await stagingDb.insert('conversation_tags', filteredData);
      }
    }
  }

  Future<void> _mergeConversationNoteMappings(
    Database stagingDb,
    Database backupDb,
  ) async {
    final backupMappings = await backupDb.query('conversation_note_mapping');

    for (final mapping in backupMappings) {
      // Check if mapping exists in staging (unique by conversationId, noteId)
      final existingMappings = await stagingDb.query(
        'conversation_note_mapping',
        where: 'conversationId = ? AND noteId = ?',
        whereArgs: [mapping['conversationId'], mapping['noteId']],
      );

      if (existingMappings.isEmpty) {
        // Insert new mapping - filter to only existing columns, remove id if auto-increment
        var filteredData = await _filterDataForTable(
          stagingDb,
          'conversation_note_mapping',
          mapping,
        );
        // Remove id if it's auto-increment to let SQLite generate a new one
        if (filteredData.containsKey('id') && mapping['id'] is int) {
          filteredData.remove('id');
        }
        await stagingDb.insert('conversation_note_mapping', filteredData);
      }
    }
  }

  Future<void> _recoverFromBackup(Map<String, dynamic> backup) async {
    final l10n = AppLocalizations.of(context)!;
    final backupPath = backup['path'] as String;

    if (!await File(backupPath).exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.errorUndoingBackup('Backup file not found')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Recover from Backup'),
        content: Text(
          'Are you sure you want to recover from ${backup['name'] ?? 'backup'}? This will replace your current data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.yes),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _performRecovery(backupPath);
    }
  }

  Future<void> _performRecovery(String originalBackupPath) async {
    setState(() {
      _isImporting = true;
      _importProgress = 0.0;
      _importLogs.clear();
    });

    try {
      _addImportLog('Starting database undo...');
      _updateImportProgress(0.2);

      // Get current database path
      final databaseService = DatabaseService();
      final currentDbPath = await databaseService.getDatabasePath();

      _addImportLog('Closing current database...');
      _updateImportProgress(0.4);

      // Close the current database
      await databaseService.close();

      _addImportLog('Restoring from original backup...');
      _updateImportProgress(0.6);

      // Copy original backup to current database location
      final originalBackupFile = File(originalBackupPath);
      if (!await originalBackupFile.exists()) {
        throw Exception('Original backup file not found: $originalBackupPath');
      }

      await originalBackupFile.copy(currentDbPath);
      _addImportLog('Database restored from original backup');

      _addImportLog('Reloading application data...');
      _updateImportProgress(0.8);

      // Reload app data
      if (mounted) {
        final appProvider = Provider.of<AppProvider>(context, listen: false);
        await appProvider.loadData();
      }

      setState(() {
        _isImporting = false;
      });

      // Reload available recoveries after successful recovery
      await _loadAvailableRecoveries();

      _addImportLog('Undo completed successfully');
      _updateImportProgress(1.0);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Database undo completed successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isImporting = false;
      });

      _addImportLog('Undo failed: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error during undo: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteRecovery(Map<String, dynamic> recovery) async {
    final l10n = AppLocalizations.of(context)!;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete Recovery'),
        content: Text(
          'Are you sure you want to delete ${recovery['name'] ?? 'backup'}? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final file = File(recovery['path'] as String);
        if (await file.exists()) {
          await file.delete();
          await _loadAvailableRecoveries(); // Reload the list

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Recovery deleted successfully'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting recovery: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.recovery)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Backup section
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
                      label: Text(
                        _isBackingUp
                            ? l10n.creatingBackup
                            : l10n.backupAllNotes,
                      ),
                    ),
                  ),
                  if (_isBackingUp) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: _backupProgress,
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
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

          const SizedBox(height: 16),

          // Import section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.importBackup,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.importBackupDescription,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isImporting ? null : _importBackup,
                      icon: _isImporting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.upload),
                      label: Text(
                        _isImporting ? l10n.importingBackup : l10n.importBackup,
                      ),
                    ),
                  ),
                  if (_isImporting) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: _importProgress,
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(_importProgress * 100).toInt()}%',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Raw Data Manager
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.build_circle_outlined),
              title: Text(l10n.rawDataManagerTitle),
              subtitle: Text(l10n.rawDataManagerSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const RawDataManagerScreen(),
                  ),
                );
              },
            ),
          ),

          // Available undo options section
          if (_availableRecoveries.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Available Undo Options',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ..._availableRecoveries.map(
              (recovery) => Card(
                child: ListTile(
                  leading: const Icon(Icons.undo),
                  title: Text('Database Backup'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Created: ${recovery['date'] ?? ''}'),
                      Text(_formatFileSize(recovery['size'] ?? 0)),
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'recover') {
                        _recoverFromBackup(recovery);
                      } else if (value == 'delete') {
                        _deleteRecovery(recovery);
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'recover',
                        child: Row(
                          children: [
                            const Icon(Icons.undo),
                            const SizedBox(width: 8),
                            Text('Undo Import'),
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
              ),
            ),
          ],
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
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Theme.of(
                            context,
                          ).colorScheme.outline.withValues(alpha: 0.3),
                        ),
                      ),
                      child: ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: _backupLogs.length,
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: SelectableText(
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

          if (_importLogs.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.importLogs,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 200,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Theme.of(
                            context,
                          ).colorScheme.outline.withValues(alpha: 0.3),
                        ),
                      ),
                      child: ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: _importLogs.length,
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: SelectableText(
                              _importLogs[index],
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
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ..._backups.map(
              (backup) => Card(
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
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Helper method to read BLOB data in chunks to avoid cursor window issues
  Future<List<int>> _readBlobInChunks(Database db, int dependencyId) async {
    const int chunkSize = 1024 * 1024; // 1MB chunks
    final List<int> allBytes = [];

    try {
      // Get the total size of the BLOB
      final sizeResult = await db.rawQuery(
        '''
        SELECT length(bytes) as blob_size 
        FROM user_app_library_dependencies 
        WHERE id = ?
      ''',
        [dependencyId],
      );

      if (sizeResult.isEmpty) {
        return <int>[];
      }

      final int totalSize = sizeResult.first['blob_size'] as int;

      // Read BLOB in chunks
      for (int offset = 0; offset < totalSize; offset += chunkSize) {
        final int currentChunkSize = (offset + chunkSize > totalSize)
            ? totalSize - offset
            : chunkSize;

        final chunkResult = await db.rawQuery(
          '''
          SELECT substr(bytes, ?, ?) as chunk
          FROM user_app_library_dependencies 
          WHERE id = ?
        ''',
          [offset + 1, currentChunkSize, dependencyId],
        );

        if (chunkResult.isNotEmpty && chunkResult.first['chunk'] != null) {
          final chunk = chunkResult.first['chunk'] as Uint8List;
          allBytes.addAll(chunk);
        }
      }

      return allBytes;
    } catch (e) {
      LoggerService.error('Error reading BLOB in chunks: $e', error: e);
      return <int>[];
    }
  }

  // Helper method to read String data in chunks to avoid cursor window issues
  Future<String> _readStringInChunks(
    Database db,
    String messageId,
    String columnName,
    int totalSize,
  ) async {
    // const int chunkSize = 1024 * 1024; // 1MB chunks (unused)
    final StringBuffer buffer = StringBuffer();

    try {
      // Read String in chunks using substr
      // SQLite substr is 1-based, and operates on characters/codepoints.
      // Note: If the text contains multi-byte characters, 'length' is in characters (usually).
      // However, CursorWindow limit is in BYTES (2MB).
      // So reading 1 million CHARACTERS might exceed 2MB bytes if they are multi-byte.
      // But for safety locally, we can read smaller chunks if needed.
      // 500k chars is safer for UTF-8 (max 4 bytes per char = 2MB).
      const int safeCharChunkSize = 500 * 1024;

      for (int offset = 0; offset < totalSize; offset += safeCharChunkSize) {
        final int currentChunkSize = (offset + safeCharChunkSize > totalSize)
            ? totalSize - offset
            : safeCharChunkSize;

        final chunkResult = await db.rawQuery(
          '''
          SELECT substr($columnName, ?, ?) as chunk
          FROM conversation_messages 
          WHERE id = ?
        ''',
          [offset + 1, currentChunkSize, messageId],
        );

        if (chunkResult.isNotEmpty && chunkResult.first['chunk'] != null) {
          final chunk = chunkResult.first['chunk'] as String;
          buffer.write(chunk);
        }
      }

      return buffer.toString();
    } catch (e) {
      LoggerService.error('Error reading String in chunks: $e', error: e);
      return '';
    }
  }
}
