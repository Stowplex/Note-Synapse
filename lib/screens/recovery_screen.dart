import 'dart:io';
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
import '../services/recovery_merge_service.dart';
import '../services/search/note_index_service.dart';
import '../services/service_locator.dart';
import '../utils/file_utils.dart';
import '../providers/app_provider.dart';
import 'raw_data_manager/raw_data_manager_screen.dart';

/// Sub-directory of `attachments/` holding derived figure crops
/// (`<attachmentId>_p<N>_f<i>.png`), written by the search index's figures
/// stage. Mirrors `FigureRegionExtractor.defaultDerivedFigureDirectory`.
const String kDerivedFigureDirName = 'derived';

/// Whether [relativePath] (relative to the attachments directory) is index-
/// derived data that export/import must NOT carry.
///
/// Only `derived/` today: those PNGs are regenerated on demand by
/// FigureResolver from the figure chunk's stored region, so a restore that
/// arrives without them is the NORMAL state, not data loss.
@visibleForTesting
bool isExcludedAttachmentPath(String relativePath) {
  final normalized = relativePath.replaceAll('\\', '/');
  return normalized == kDerivedFigureDirName ||
      normalized.startsWith('$kDerivedFigureDirName/');
}

/// Recursive directory copy that skips entries [skip] rejects (matched on the
/// path RELATIVE to [source], so a nested `derived` folder elsewhere is
/// unaffected). Top-level so export/import share one implementation and tests
/// can exercise it without a widget.
@visibleForTesting
Future<void> copyDirectoryFiltered(
  Directory source,
  Directory destination, {
  bool Function(String relativePath)? skip,
  void Function(String message)? onWarning,
}) async {
  await destination.create(recursive: true);

  await for (final entity in source.list(recursive: true)) {
    final relativePath = entity.path.substring(source.path.length + 1);
    if (skip != null && skip(relativePath)) continue;
    final destPath = '${destination.path}/$relativePath';

    if (entity is File) {
      final destFile = File(destPath);
      await destFile.parent.create(recursive: true);
      try {
        await entity.copy(destFile.path);
      } catch (e) {
        onWarning?.call('Warning: could not copy ${entity.path}: $e');
      }
    } else if (entity is Directory) {
      final destDir = Directory(destPath);
      await destDir.create(recursive: true);
    }
  }
}

class RecoveryScreen extends StatefulWidget {
  final String? error;

  const RecoveryScreen({super.key, this.error});

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  // M1.6: the actual per-table merge logic lives in RecoveryMergeService
  // (lib/services/recovery_merge_service.dart), extracted out of this
  // State class specifically so it can be exercised by dedicated, isolated
  // tests (test/recovery_merge_service_test.dart) independent of this
  // widget's file-picker/BuildContext/l10n/platform-channel machinery.
  final RecoveryMergeService _mergeService = RecoveryMergeService();

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

  /// The search indexer must not write while the database file is being
  /// swapped underneath the live connection. Null when the locator has no
  /// indexer (e.g. isolated tests).
  NoteIndexService? get _noteIndexService =>
      getIt.isRegistered<NoteIndexService>() ? getIt<NoteIndexService>() : null;

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
        await _copyAttachmentsDirectory(attachmentsDir, destAttachmentsDir);
        _addLog(l10n.attachmentsDirectoryCopiedSuccessfully);
      } else {
        _addLog(l10n.noAttachmentsDirectoryFound);
        await destAttachmentsDir.create(recursive: true);
      }
      _updateProgress(0.5);

      // 4b. Copy tag_images directory to temp directory
      final appDocsDir = await getApplicationDocumentsDirectory();
      final tagImagesDir = Directory('${appDocsDir.path}/tag_images');
      final destTagImagesDir = Directory('${exportDir.path}/tag_images');
      if (await tagImagesDir.exists()) {
        await _copyDirectory(tagImagesDir, destTagImagesDir);
        _addLog('Tag images directory copied successfully');
      } else {
        _addLog('No tag images directory found');
      }

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

          try {
            // Ensure destination directory exists before copying
            await destFile.parent.create(recursive: true);
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
          } catch (e) {
            _addLog(l10n.warningSourceFileNotFound(originalFilePath));
          }
        } else {
          _addLog(l10n.warningSourceFileNotFound(originalFilePath));
        }
      }
    } finally {
      await db.close();
    }
  }

  Future<void> _copyDirectory(
    Directory source,
    Directory destination, {
    bool Function(String relativePath)? skip,
  }) => copyDirectoryFiltered(
    source,
    destination,
    skip: skip,
    onWarning: _addLog,
  );

  /// Copies the attachments directory for export/import, SKIPPING
  /// `attachments/derived/` (plan §4.1). Derived figure crops are
  /// regenerable index artifacts, not user data: FigureResolver re-renders a
  /// missing crop on demand from the chunk's stored region, which is exactly
  /// why a restored backup is allowed to arrive without them. Shipping them
  /// would bloat every archive with data the app rebuilds for free.
  Future<void> _copyAttachmentsDirectory(
    Directory source,
    Directory destination,
  ) => _copyDirectory(source, destination, skip: isExcludedAttachmentPath);

  Future<void> _createZipArchive(Directory sourceDir, File zipFile) async {
    final start = DateTime.now();
    _addLog('Starting zip creation...');

    try {
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);

      await for (final entity in sourceDir.list(recursive: true)) {
        if (entity is File) {
          final relativePath = entity.path.substring(sourceDir.path.length + 1);
          await encoder.addFile(entity, relativePath);
        }
      }

      await encoder.close();

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
      // Pause the indexer for the whole merge + swap; pause() drains any
      // in-flight index write before the file is touched, and the finally's
      // resume() re-indexes the swapped-in database. INSIDE the try because
      // pause() flips the paused flag synchronously and only then awaits the
      // drain: a throwing drain outside the try would leave the indexer
      // paused for the rest of the session with no resume, silently dropping
      // every later note edit. The import still proceeds only on a clean
      // drain — a throw here lands in the catch below.
      await _noteIndexService?.pause();

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
      final archive = ZipDecoder().decodeStream(inputStream);

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
      // Use _schema_version table (authoritative), not PRAGMA user_version which
      // is set to 999 as a sentinel to prevent sqflite's built-in onUpgrade.
      int backupVersion;
      final schemaTableCheck = await backupDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='_schema_version'",
      );
      if (schemaTableCheck.isNotEmpty) {
        final sv = await backupDb.query('_schema_version');
        backupVersion = sv.isNotEmpty ? sv.first['version'] as int : 0;
      } else {
        // Legacy DB: _schema_version doesn't exist, read PRAGMA user_version.
        final versionResult = await backupDb.rawQuery('PRAGMA user_version');
        backupVersion = versionResult.first['user_version'] as int;
      }
      await backupDb.close();

      // Check if backup version is compatible
      if (backupVersion > DatabaseService.DATABASE_VERSION &&
          backupVersion != DatabaseService.SQFLITE_VERSION) {
        throw Exception(l10n.backupVersionTooNew);
      }

      _addImportLog(l10n.migratingBackupDatabase);
      _updateImportProgress(0.25);

      // Step 4: Upgrade the backup database to current version
      // Existing databases use PRAGMA user_version=999 as a sqflite
      // sentinel. Passing the application schema version to openDatabase
      // would therefore request a downgrade and fail before migration.
      final migratedBackupDb = await openDatabase(backupDbPath);
      await databaseService.migrateBackupDatabase(
        migratedBackupDb,
        backupVersion,
        DatabaseService.DATABASE_VERSION,
      );

      _addImportLog(l10n.mergingNotes);
      _updateImportProgress(0.06);

      // Step 1: Merge the notes table
      await _mergeService.mergeNotes(stagingDb, migratedBackupDb);

      _addImportLog(l10n.mergingSubNotes);
      _updateImportProgress(0.12);

      // Step 2: Insert all subnotes
      await _mergeService.mergeSubNotes(stagingDb, migratedBackupDb);

      _addImportLog(l10n.mergingTags);
      _updateImportProgress(0.18);

      // Step 3: Insert all tags
      await _mergeService.mergeTags(stagingDb, migratedBackupDb);

      _addImportLog('Merging tag images...');
      await _mergeService.mergeTagImages(stagingDb, migratedBackupDb);

      _addImportLog('Merging note-tag relationships...');
      _updateImportProgress(0.24);

      // Step 4: Merge note_tags table
      await _mergeService.mergeNoteTags(stagingDb, migratedBackupDb);

      _addImportLog(l10n.mergingRelationships);
      _updateImportProgress(0.30);

      // Step 5: Insert all relationships
      await _mergeService.mergeRelationships(stagingDb, migratedBackupDb);

      _addImportLog(l10n.mergingFilters);
      _updateImportProgress(0.36);

      // Step 6: Insert all unique filters
      await _mergeService.mergeFilters(stagingDb, migratedBackupDb);

      _addImportLog(l10n.mergingUserApps);
      _updateImportProgress(0.42);

      // Step 7: Merge user apps
      await _mergeService.mergeUserApps(stagingDb, migratedBackupDb);

      _addImportLog(l10n.copyingAttachments);
      _updateImportProgress(0.48);

      // Copy attachments
      final attachmentsDir = Directory('${extractDir.path}/attachments');
      if (await attachmentsDir.exists()) {
        final appAttachmentsDir = await FileUtils.getPrivateStorageDirectory();
        // Mirror of the export exclusion: an archive from an older build may
        // still contain `derived/`, and importing it would resurrect crops
        // whose figure chunks this install has not re-extracted yet.
        await _copyAttachmentsDirectory(attachmentsDir, appAttachmentsDir);
      }

      // Copy tag images
      final tagImagesDir = Directory('${extractDir.path}/tag_images');
      if (await tagImagesDir.exists()) {
        final appDocsDir = await getApplicationDocumentsDirectory();
        final appTagImagesDir = Directory('${appDocsDir.path}/tag_images');
        await appTagImagesDir.create(recursive: true);
        await _copyDirectory(tagImagesDir, appTagImagesDir);
        _addImportLog('Tag images copied successfully');
      }

      _addImportLog('Merging attachments...');
      _updateImportProgress(0.54);

      // Step 8: Merge attachments table
      await _mergeService.mergeAttachments(stagingDb, migratedBackupDb);

      _addImportLog('Merging conversations...');
      _updateImportProgress(0.60);

      // Step 9: Insert all conversations that are not already in the db (by id)
      await _mergeService.mergeConversations(stagingDb, migratedBackupDb);

      _addImportLog('Merging conversation messages...');
      _updateImportProgress(0.66);

      // Step 10: Insert all conversation messages that are not already in the db (by message id)
      await _mergeService.mergeConversationMessages(
        stagingDb,
        migratedBackupDb,
      );

      _addImportLog('Merging conversation attachments...');
      _updateImportProgress(0.72);

      // Step 11: Insert all conversation attachments that are not already in db (by id)
      await _mergeService.mergeConversationAttachments(
        stagingDb,
        migratedBackupDb,
      );

      _addImportLog('Merging conversation-message mappings...');
      _updateImportProgress(0.78);

      // Step 12: Insert all unique conversation - message mappings by (conversationId, messageId)
      await _mergeService.mergeConversationMessageMappings(
        stagingDb,
        migratedBackupDb,
      );

      _addImportLog('Merging message parents...');
      _updateImportProgress(0.84);

      // Step 13: Insert all unique message parents (unique by messageId, parentMessageId)
      await _mergeService.mergeMessageParents(stagingDb, migratedBackupDb);

      _addImportLog('Merging conversation-tag mappings...');
      _updateImportProgress(0.87);

      // Step 14: Insert all unique conversation tag mappings (conversationId, tagId)
      await _mergeService.mergeConversationTagMappings(
        stagingDb,
        migratedBackupDb,
      );

      _addImportLog('Merging conversation-note mappings...');
      _updateImportProgress(0.90);

      // Step 15: Insert all conversation note mapping unique by (noteId, conversationId)
      await _mergeService.mergeConversationNoteMappings(
        stagingDb,
        migratedBackupDb,
      );

      _addImportLog('Merging note annotations...');
      _updateImportProgress(0.92);

      // Step 16: Merge note_annotations (immutable: insert-or-skip by UUID)
      await _mergeService.mergeNoteAnnotations(stagingDb, migratedBackupDb);

      _addImportLog('Merging tag workflow bindings...');
      // Step 17: Merge tag_workflow_bindings (insert-if-absent by pattern
      // primary key; a pattern already present in staging, in whatever
      // liveness state, is left untouched — see mergeTagWorkflowBindings's
      // own M1.7 doc comment for why this is no longer an unconditional
      // upsert)
      await _mergeService.mergeTagWorkflowBindings(stagingDb, migratedBackupDb);

      // search_chunks, chunk_embeddings and search_index_state are
      // deliberately NOT merged: they hold search index data derived from
      // notes/attachments, which the indexer rebuilds from source content.
      // The staging DB starts as a copy of the current DB, so its global
      // "backfill complete" flag would be stale for merged-in notes that
      // have no chunks yet — clear it so the indexer re-backfills after the
      // swap (an empty/missing flag row means "not complete").
      await _clearGlobalSearchIndexState(stagingDb);

      // Deliberately NOT merged, by design, and not merely omitted —
      // `multi_function_apps` and the fifteen M1.1 CRDT-cloud-sync
      // control-plane tables (`sync_field_state`, `sync_set_state`,
      // `sync_grave`, `sync_touch_log`, `sync_pending_ops`, `sync_state`,
      // `sync_ack_frontier`, `sync_device_labels`, `sync_view_cache`,
      // `sync_blob_refs`, `sync_publish_intent`, `sync_materialize_queue`,
      // `sync_conflict_copies`, `sync_dedup_index`, `sync_dot_redirects`).
      // See RecoveryMergeService's own class doc comment
      // (lib/services/recovery_merge_service.dart) for the full rationale
      // — kept there now, alongside the merge methods it documents, rather
      // than here.
      await migratedBackupDb.close();
      await stagingDb.close();

      _addImportLog(l10n.swappingDatabases);
      _updateImportProgress(0.94);

      // Force cleanup of staging DB connection before copying
      await stagingDb.close(); // Ensure strictly closed

      // Step 17: Copy staging DB to app's DB directory
      await stagingDbFile.copy(currentDbPath);

      _addImportLog(l10n.reloadingData);
      _updateImportProgress(1.0);

      // Step 18: Reload data in the app
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
    } finally {
      _noteIndexService?.resume();
    }
  }

  /// The three layered-search index tables (`search_chunks`,
  /// `chunk_embeddings`, `search_index_state`) are deliberately NOT merged
  /// during import — they hold data derived from notes/attachments, which
  /// the indexer rebuilds from source content (see RecoveryMergeService's
  /// class doc comment, which lists every deliberate exclusion).
  ///
  /// The staging DB starts as a copy of the current DB, so its global
  /// "backfill complete" flag would be stale for merged-in notes that have
  /// no chunks yet — clearing it makes the indexer re-backfill after the
  /// swap (an empty/missing flag row means "not complete").
  Future<void> _clearGlobalSearchIndexState(Database stagingDb) async {
    // search_index_state may not exist yet when recovering from a failed
    // pre-v62 migration — skip gracefully
    final tables = await stagingDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='search_index_state'",
    );
    if (tables.isEmpty) return;

    await stagingDb.delete(
      'search_index_state',
      where: 'scopeType = ?',
      whereArgs: ['global'],
    );
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
      // Same pause/resume as the import path (and inside the try for the same
      // reason): the DB file is replaced under the live connection, so drain
      // in-flight index writes first, and a drain that throws must still
      // reach the finally's resume() rather than strand the indexer paused.
      await _noteIndexService?.pause();

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
    } finally {
      _noteIndexService?.resume();
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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.recoveryManager),
        leading: widget.error != null
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  // Should we allow closing?
                  // If it's a critical error, maybe not, but user might want to try restarting app.
                  // Let's allow exiting to main screen, maybe app will crash again if DB is broken,
                  // but at least they are not trapped.
                  Navigator.of(context).pop();
                },
              )
            : const BackButton(),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.error != null) ...[
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.error_outline,
                              color: theme.colorScheme.onErrorContainer,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Database Migration Failed', // Use l10n in real app
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: theme.colorScheme.onErrorContainer,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.error!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'The database schema upgrade failed. A backup was created before the attempt. You can try to restore a previous backup below, or if this persists, contact support.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
              _buildSectionTitle(l10n.backupAndRestore),
              const SizedBox(height: 16),
              // Backup section
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.backupAllNotes,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
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
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
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
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
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
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.upload),
                          label: Text(
                            _isImporting
                                ? l10n.importingBackup
                                : l10n.importBackup,
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
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
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
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
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
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: SelectableText(
                                  _backupLogs[index],
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
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
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
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
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: SelectableText(
                                  _importLogs[index],
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
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
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
    );
  }
}
