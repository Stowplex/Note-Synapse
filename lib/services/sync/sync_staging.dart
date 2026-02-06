import 'dart:io';
import 'package:sqflite/sqflite.dart';
import '../database_service.dart';
import '../logger_service.dart';

/// Manages staging database copies for crash-safe sync operations.
///
/// The staging workflow ensures that all remote changes are merged into a
/// copy of the live database. Only after successful merge and validation
/// does the staging DB replace the live DB. If the app crashes at any point
/// during the pull, the live DB remains untouched.
class SyncStaging {
  final DatabaseService _db;

  SyncStaging({required DatabaseService db}) : _db = db;

  /// Creates a staging copy of the live database.
  ///
  /// 1. Checkpoints the live database (flushes WAL)
  /// 2. Copies the database file (and WAL/SHM companions) to a staging path
  /// 3. Returns the staging path
  Future<String> createStagingCopy() async {
    final dbPath = await _db.getDatabasePath();
    final stagingPath = '${dbPath}_sync_staging';

    // Checkpoint the live database to ensure WAL is flushed
    await _db.checkpoint();

    // Clean up any old staging files from a previous failed sync
    await _deleteFileIfExists(stagingPath);
    await _deleteFileIfExists('$stagingPath-wal');
    await _deleteFileIfExists('$stagingPath-shm');

    // Copy the live database file to staging path
    await File(dbPath).copy(stagingPath);

    // Copy WAL file if it exists
    final walFile = File('$dbPath-wal');
    if (await walFile.exists()) {
      await walFile.copy('$stagingPath-wal');
    }

    // Copy SHM file if it exists
    final shmFile = File('$dbPath-shm');
    if (await shmFile.exists()) {
      await shmFile.copy('$stagingPath-shm');
    }

    LoggerService.info('Created staging copy at: $stagingPath');
    return stagingPath;
  }

  /// Opens the staging database and validates its integrity.
  ///
  /// Throws an exception if the database fails the integrity check.
  Future<Database> openStagingDb(String stagingPath) async {
    Database stagingDb;
    try {
      stagingDb = await openDatabase(stagingPath, singleInstance: false);
    } catch (e) {
      throw Exception('Failed to open staging database at $stagingPath: $e');
    }

    // Run integrity check
    final result = await stagingDb.rawQuery('PRAGMA integrity_check');
    final status = result.first.values.first as String;

    if (status != 'ok') {
      await stagingDb.close();
      throw Exception(
        'Staging database integrity check failed: $status',
      );
    }

    LoggerService.info('Staging database opened and validated: $stagingPath');
    return stagingDb;
  }

  /// Validates the integrity of an already-opened staging database.
  ///
  /// Returns true if the integrity check passes, false otherwise.
  Future<bool> validateStagingDb(Database stagingDb) async {
    final result = await stagingDb.rawQuery('PRAGMA integrity_check');
    final status = result.first.values.first as String;
    return status == 'ok';
  }

  /// Atomically swaps the staging database with the live database.
  ///
  /// 1. Closes the live database
  /// 2. Creates a pre-sync backup of the live DB
  /// 3. Renames staging to live
  /// 4. Reinitializes the live database connection (via lazy getter)
  Future<void> atomicSwap(String stagingPath) async {
    final dbPath = await _db.getDatabasePath();
    final backupPath = '${dbPath}_pre_sync_backup';

    // Close the live database
    await _db.close();

    try {
      // Create a backup of the live DB
      final liveFile = File(dbPath);
      if (await liveFile.exists()) {
        await liveFile.copy(backupPath);
      }

      // Rename staging to live
      await File(stagingPath).rename(dbPath);

      // Rename WAL if it exists
      final stagingWal = File('$stagingPath-wal');
      if (await stagingWal.exists()) {
        await stagingWal.rename('$dbPath-wal');
      } else {
        // Delete live WAL if staging didn't have one
        await _deleteFileIfExists('$dbPath-wal');
      }

      // Rename SHM if it exists
      final stagingShm = File('$stagingPath-shm');
      if (await stagingShm.exists()) {
        await stagingShm.rename('$dbPath-shm');
      } else {
        // Delete live SHM if staging didn't have one
        await _deleteFileIfExists('$dbPath-shm');
      }

      LoggerService.info('Atomic swap completed: staging -> live');

      // Delete the pre-sync backup after successful swap
      await _deleteFileIfExists(backupPath);
      await _deleteFileIfExists('$backupPath-wal');
      await _deleteFileIfExists('$backupPath-shm');
    } catch (e) {
      // If swap failed, try to restore from backup
      LoggerService.error('Atomic swap failed, attempting restore', error: e);

      final backupFile = File(backupPath);
      if (await backupFile.exists()) {
        await backupFile.copy(dbPath);
        LoggerService.info('Restored live DB from pre-sync backup');
      }

      rethrow;
    }

    // Reinitialize the live database connection by accessing the lazy getter
    // This matches the pattern used in recovery_screen.dart
    await _db.database;
    LoggerService.info('Live database connection reinitialized after swap');
  }

  /// Cleans up stale staging files from a previous crashed sync.
  ///
  /// Should be called on app startup.
  Future<void> cleanupStaleStagingFiles() async {
    final dbPath = await _db.getDatabasePath();
    final stagingPath = '${dbPath}_sync_staging';

    var cleaned = false;

    if (await _deleteFileIfExists(stagingPath)) {
      cleaned = true;
    }
    if (await _deleteFileIfExists('$stagingPath-wal')) {
      cleaned = true;
    }
    if (await _deleteFileIfExists('$stagingPath-shm')) {
      cleaned = true;
    }

    if (cleaned) {
      LoggerService.info('Cleaned up stale staging files');
    }
  }

  /// Deletes a file if it exists. Returns true if a file was deleted.
  Future<bool> _deleteFileIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
      return true;
    }
    return false;
  }
}
