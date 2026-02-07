import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../models/sync_config.dart';
import '../../models/sync_operation.dart';
import '../database_service.dart';
import '../logger_service.dart';
import 'package:path/path.dart' as p;

import 'attachment_sync_service.dart';
import 'device_identity_service.dart';
import 'merge_engine.dart';
import 'oplog_service.dart';
import 'snapshot_service.dart';
import 'sync_encryption_service.dart';
import 'sync_spec_generator.dart';
import 'sync_staging.dart';
import 'sync_storage_provider.dart';

/// Result of a sync operation containing statistics.
class SyncResult {
  final int opsPulled;
  final int opsPushed;
  final int conflictsCreated;
  final int attachmentsUploaded;
  final int attachmentsDownloaded;
  final List<String> warnings;
  final bool success;

  SyncResult({
    required this.opsPulled,
    required this.opsPushed,
    required this.conflictsCreated,
    this.attachmentsUploaded = 0,
    this.attachmentsDownloaded = 0,
    required this.warnings,
    required this.success,
  });
}

/// Orchestrates the full sync cycle: pull remote changes, merge, push local
/// changes, and optionally compact old oplog files.
///
/// This is the top-level entry point for cloud sync. It coordinates:
/// - [OplogReader] / [OplogWriter] for reading/writing oplog files
/// - [SnapshotService] for full database snapshots
/// - [MergeEngine] for applying remote operations to a staging DB
/// - [SyncStaging] for crash-safe database swaps
/// - [DeviceIdentityService] for device ID and sequence tracking
class SyncService {
  final DatabaseService _db;
  final DeviceIdentityService _identity;

  SyncStorageProvider? _provider;
  SyncEncryptionService? _encryption;

  /// Threshold for oplog file count before triggering compaction.
  static const int _compactionThreshold = 50;

  SyncService({
    required DatabaseService db,
    required DeviceIdentityService identity,
  }) : _db = db,
       _identity = identity;

  /// Whether this service has been configured with a storage provider.
  bool get isConfigured => _provider != null;

  /// Sets the storage provider and optional encryption service.
  ///
  /// Called after user completes sync setup or when reconnecting.
  void configure({
    required SyncStorageProvider provider,
    SyncEncryptionService? encryption,
  }) {
    _provider = provider;
    _encryption = encryption;
  }

  /// Resets the configuration, effectively disabling sync in memory.
  void resetConfiguration() {
    _provider = null;
    _encryption = null;
  }

  /// Main sync method. Performs pull then push, returns a [SyncResult].
  ///
  /// Throws [StateError] if no provider has been configured.
  Future<SyncResult> sync() async {
    final provider = _provider;
    if (provider == null) {
      throw StateError('SyncService not configured. Call configure() first.');
    }

    final warnings = <String>[];
    int opsPulled = 0;
    int opsPushed = 0;
    int conflictsCreated = 0;

    try {
      final deviceId = await _identity.getDeviceId();
      final schemaVersion = DatabaseService.DATABASE_VERSION;

      // ---- Pull phase ----
      final pullResult = await _pull(
        provider: provider,
        deviceId: deviceId,
        schemaVersion: schemaVersion,
        warnings: warnings,
      );
      opsPulled = pullResult.opsPulled;
      conflictsCreated = pullResult.conflictsCreated;

      // ---- Push phase ----
      opsPushed = await _push(
        provider: provider,
        deviceId: deviceId,
        schemaVersion: schemaVersion,
        warnings: warnings,
      );

      // ---- Compaction (optional) ----
      await _maybeCompact(
        provider: provider,
        deviceId: deviceId,
        schemaVersion: schemaVersion,
        warnings: warnings,
      );

      return SyncResult(
        opsPulled: opsPulled,
        opsPushed: opsPushed,
        conflictsCreated: conflictsCreated,
        warnings: warnings,
        success: true,
      );
    } catch (e, stack) {
      LoggerService.error('Sync failed', error: e, stackTrace: stack);
      warnings.add('Sync failed: $e');
      return SyncResult(
        opsPulled: opsPulled,
        opsPushed: opsPushed,
        conflictsCreated: conflictsCreated,
        warnings: warnings,
        success: false,
      );
    }
  }

  /// Pull phase: read remote oplog files, merge into local DB via staging.
  Future<_PullResult> _pull({
    required SyncStorageProvider provider,
    required String deviceId,
    required int schemaVersion,
    required List<String> warnings,
  }) async {
    // Read device registry to get last-seen sequences
    final registry = await _readDeviceRegistry();
    final lastSeenSequences = <String, int>{};
    for (final entry in registry.devices.entries) {
      lastSeenSequences[entry.key] = entry.value.lastSequence;
    }

    // Create oplog reader
    final reader = OplogReader(
      provider: provider,
      encryption: _encryption,
      ownDeviceId: deviceId,
      currentSchemaVersion: schemaVersion,
    );

    // Read new operations
    final readResult = await reader.readNewOperations(lastSeenSequences);
    warnings.addAll(readResult.warnings);

    if (readResult.applicableOps.isEmpty) {
      return _PullResult(opsPulled: 0, conflictsCreated: 0);
    }

    // Create staging DB and apply operations
    final staging = SyncStaging(db: _db);
    final stagingPath = await staging.createStagingCopy();

    try {
      final stagingDb = await staging.openStagingDb(stagingPath);

      try {
        // Ensure sync_conflicts table exists in staging
        await stagingDb.execute('''
          CREATE TABLE IF NOT EXISTS sync_conflicts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            table_name TEXT NOT NULL,
            row_id TEXT NOT NULL,
            field_name TEXT NOT NULL,
            local_value TEXT,
            remote_value TEXT,
            remote_device_id TEXT NOT NULL,
            remote_timestamp TEXT NOT NULL,
            resolved INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
          )
        ''');

        // Apply operations via merge engine
        final mergeEngine = MergeEngine(
          db: stagingDb,
          currentSchemaVersion: schemaVersion,
        );
        final mergeResult = await mergeEngine.applyOperations(
          readResult.applicableOps,
        );

        if (mergeResult.errors.isNotEmpty) {
          warnings.addAll(mergeResult.errors);
        }

        // Validate staging DB
        final isValid = await staging.validateStagingDb(stagingDb);
        if (!isValid) {
          throw Exception('Staging database validation failed after merge');
        }

        // Close staging DB before swap
        await stagingDb.close();

        // Atomic swap: staging -> live
        await staging.atomicSwap(stagingPath);

        // Update local last-seen sequences in device registry
        var updatedRegistry = await _readDeviceRegistry();
        for (final entry in readResult.newLastSeenSequences.entries) {
          if (entry.key != deviceId &&
              updatedRegistry.devices.containsKey(entry.key)) {
            updatedRegistry = updatedRegistry.updateSequence(
              entry.key,
              entry.value,
            );
          }
        }
        await _writeDeviceRegistry(updatedRegistry);

        return _PullResult(
          opsPulled: readResult.applicableOps.length,
          conflictsCreated: mergeResult.conflictsCreated,
        );
      } catch (e) {
        // Make sure staging DB is closed on error
        try {
          await stagingDb.close();
        } catch (_) {}
        rethrow;
      }
    } catch (e) {
      // Clean up staging file on error
      LoggerService.error('Pull phase failed', error: e);
      rethrow;
    }
  }

  /// Push phase: write local changes to oplog, update device registry.
  Future<int> _push({
    required SyncStorageProvider provider,
    required String deviceId,
    required int schemaVersion,
    required List<String> warnings,
  }) async {
    // We trust OplogWriter to handle the case where sync_changelog is missing
    // (it will throw keys/table missing error which is caught and reported)

    final writer = OplogWriter(
      db: _db,
      provider: provider,
      encryption: _encryption,
      deviceId: deviceId,
      schemaVersion: schemaVersion,
    );

    final currentSequence = await _identity.getLastSequence();
    final nextSequence = await writer.writeOplogBatch(currentSequence);

    final opsPushed = nextSequence - currentSequence;

    if (opsPushed > 0) {
      // Update sequence in identity service
      await _identity.setLastSequence(nextSequence);

      // Update device registry
      var registry = await _readDeviceRegistry();
      if (registry.devices.containsKey(deviceId)) {
        registry = registry.updateSequence(deviceId, nextSequence);
      } else {
        registry = registry.registerDevice(
          deviceId,
          schemaVersion: schemaVersion,
        );
        registry = registry.updateSequence(deviceId, nextSequence);
      }
      await _writeDeviceRegistry(registry);
    }

    return opsPushed;
  }

  /// Optionally compact oplog files if this device has the highest schema
  /// version and there are too many oplog files.
  Future<void> _maybeCompact({
    required SyncStorageProvider provider,
    required String deviceId,
    required int schemaVersion,
    required List<String> warnings,
  }) async {
    try {
      final registry = await _readDeviceRegistry();

      // Only compact if we have the highest schema version
      if (registry.highestSchemaVersion > schemaVersion) return;

      // Check oplog file count
      final reader = OplogReader(
        provider: provider,
        encryption: _encryption,
        ownDeviceId: deviceId,
        currentSchemaVersion: schemaVersion,
      );
      final oplogFiles = await reader.listOplogFiles();
      if (oplogFiles.length < _compactionThreshold) return;

      LoggerService.info(
        'Compacting: ${oplogFiles.length} oplog files exceed threshold',
      );

      // Write a fresh snapshot
      final snapshotService = SnapshotService(
        db: _db,
        provider: provider,
        encryption: _encryption,
      );
      await snapshotService.writeSnapshot(schemaVersion);

      // Delete old oplog files
      for (final file in oplogFiles) {
        await provider.deleteFile(file.path);
      }

      LoggerService.info(
        'Compaction complete: deleted ${oplogFiles.length} oplog files',
      );
    } catch (e) {
      warnings.add('Compaction failed (non-fatal): $e');
    }
  }

  /// Creates a new sync root from scratch.
  ///
  /// Generates encryption config, writes initial snapshot and device registry,
  /// creates directory structure, and enables sync triggers.
  Future<void> initializeSyncRoot({
    required SyncStorageProvider provider,
    String? passphrase,
    int kdfMemory = 65536,
    int kdfIterations = 3,
    int kdfParallelism = 4,
  }) async {
    final deviceId = await _identity.getDeviceId();
    final schemaVersion = DatabaseService.DATABASE_VERSION;

    // Generate random salt (16 bytes, base64 encoded)
    final saltBytes = _generateRandomBytes(16);
    final salt = base64Encode(saltBytes);

    // Determine encryption settings
    SyncEncryptionService? encryption;
    String? hmac;
    String encryptionCipher = 'none';

    if (passphrase != null && passphrase.isNotEmpty) {
      encryptionCipher = 'aes-256-gcm';
      encryption = await SyncEncryptionService.create(
        passphrase: passphrase,
        cipherId: encryptionCipher,
        salt: salt,
        kdfMemory: kdfMemory,
        kdfIterations: kdfIterations,
        kdfParallelism: kdfParallelism,
      );
    }

    // Create SyncConfig
    final config = SyncConfig(
      specVersion: 1,
      encryption: encryptionCipher,
      kdf: 'argon2id',
      kdfParams: KdfParams(
        memory: kdfMemory,
        iterations: kdfIterations,
        parallelism: kdfParallelism,
      ),
      salt: salt,
      schemaVersion: schemaVersion,
    );

    // If encrypted, compute HMAC and add it
    final SyncConfig finalConfig;
    if (encryption != null) {
      hmac = await encryption.computeHmac(config.jsonForHmac());
      finalConfig = config.copyWith(hmac: hmac);
    } else {
      finalConfig = config;
    }

    // Write sync-config.json (never encrypted)
    await _writeSyncConfig(provider, finalConfig);

    // Create device registry with this device
    var registry = DeviceRegistry(devices: {});
    registry = registry.registerDevice(deviceId, schemaVersion: schemaVersion);
    await _writeDeviceRegistryTo(provider, registry, encryption: encryption);

    // Create directories with .keep files
    final keepContent = Uint8List(0);
    await provider.writeFile('oplog/.keep', keepContent);
    await provider.writeFile('snapshots/.keep', keepContent);
    await provider.writeFile('attachments/.keep', keepContent);
    await provider.writeFile('apps/.keep', keepContent);

    // Write SYNC_SPEC.md
    final specGenerator = SyncSpecGenerator(db: _db);
    final specContent = await specGenerator.generate(
      schemaVersion: schemaVersion,
    );
    await provider.writeFile(
      'SYNC_SPEC.md',
      Uint8List.fromList(utf8.encode(specContent)),
    );

    // Write initial snapshot
    final snapshotService = SnapshotService(
      db: _db,
      provider: provider,
      encryption: encryption,
    );
    await snapshotService.writeSnapshot(schemaVersion);

    // Identify and upload referenced attachments
    // We read the snapshot we just wrote (or just re-query) to find attachments.
    // Efficient way: re-query just the attachment paths from DB since we are local.
    await _uploadInitialAttachments(provider, encryption);

    // Store encryption config locally
    await _identity.setEncryptionEnabled(encryption != null);
    if (encryption != null) {
      await _identity.setCipherId(encryptionCipher);
    }

    // Enable sync triggers
    await _db.enableSyncTriggers();

    // Configure the service with the new provider + encryption
    configure(provider: provider, encryption: encryption);
  }

  /// Nuclear option: replace all remote data with this device's state.
  ///
  /// Writes a new snapshot, deletes all oplog files, and resets the device
  /// registry to contain only this device at sequence 0.
  Future<void> resetSyncFromThisDevice() async {
    final provider = _provider;
    if (provider == null) {
      throw StateError('SyncService not configured. Call configure() first.');
    }

    final deviceId = await _identity.getDeviceId();
    final schemaVersion = DatabaseService.DATABASE_VERSION;

    // Write new snapshot from local DB
    final snapshotService = SnapshotService(
      db: _db,
      provider: provider,
      encryption: _encryption,
    );
    await snapshotService.writeSnapshot(schemaVersion);

    // Delete all oplog files
    final reader = OplogReader(
      provider: provider,
      encryption: _encryption,
      ownDeviceId: deviceId,
      currentSchemaVersion: schemaVersion,
    );
    final oplogFiles = await reader.listOplogFiles();
    for (final file in oplogFiles) {
      await provider.deleteFile(file.path);
    }

    // Reset device registry (only this device, sequence 0)
    var registry = DeviceRegistry(devices: {});
    registry = registry.registerDevice(deviceId, schemaVersion: schemaVersion);
    await _writeDeviceRegistry(registry);

    // Reset local sequence
    await _identity.setLastSequence(0);
  }

  // ---- Helper methods ----

  /// Reads the device registry from remote storage.
  Future<DeviceRegistry> _readDeviceRegistry() async {
    final provider = _provider;
    if (provider == null) {
      return DeviceRegistry(devices: {});
    }
    return _readDeviceRegistryFrom(provider);
  }

  /// Reads the device registry from a specific provider.
  Future<DeviceRegistry> _readDeviceRegistryFrom(
    SyncStorageProvider provider,
  ) async {
    const path = 'meta/device-registry.json';
    final exists = await provider.exists(path);
    if (!exists) {
      return DeviceRegistry(devices: {});
    }

    final bytes = await provider.readFile(path);

    // If encrypted, decrypt first
    // If encrypted, decrypt first
    Uint8List jsonBytes;
    if (_encryption != null) {
      try {
        jsonBytes = await _encryption!.decrypt(bytes);
      } catch (e) {
        // If decryption fails (e.g. unencrypted file), try to parse as plain JSON
        // If it looks like valid JSON, we assume it's an unencrypted file from before
        try {
          // Verify it's valid UTF-8 and JSON
          final decoded = utf8.decode(bytes);
          jsonDecode(decoded);
          // If successful, use raw bytes
          jsonBytes = bytes;
          LoggerService.warning(
            'Read unencrypted device registry while encryption enabled - migrating.',
          );
        } catch (_) {
          // If fallback fails, rethrow original error
          rethrow;
        }
      }
    } else {
      jsonBytes = bytes;
    }

    final json = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
    return DeviceRegistry.fromJson(json);
  }

  /// Writes the device registry to remote storage.
  Future<void> _writeDeviceRegistry(DeviceRegistry registry) async {
    final provider = _provider;
    if (provider == null) {
      throw StateError('SyncService not configured.');
    }
    await _writeDeviceRegistryTo(provider, registry);
  }

  /// Writes the device registry to a specific provider.
  Future<void> _writeDeviceRegistryTo(
    SyncStorageProvider provider,
    DeviceRegistry registry, {
    SyncEncryptionService? encryption,
  }) async {
    final jsonStr = jsonEncode(registry.toJson());
    final enc = encryption ?? _encryption;

    final Uint8List data;
    if (enc != null) {
      data = await enc.encrypt(Uint8List.fromList(utf8.encode(jsonStr)));
    } else {
      data = Uint8List.fromList(utf8.encode(jsonStr));
    }

    await provider.writeFile('meta/device-registry.json', data);
  }

  /// Reads the sync config from remote storage.
  // ignore: unused_element
  Future<SyncConfig> readSyncConfig() async {
    final provider = _provider;
    if (provider == null) {
      throw StateError('SyncService not configured.');
    }

    const path = 'sync-config.json';
    final bytes = await provider.readFile(path);
    // sync-config.json is never encrypted
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return SyncConfig.fromJson(json);
  }

  /// Writes the sync config to remote storage (never encrypted).
  Future<void> _writeSyncConfig(
    SyncStorageProvider provider,
    SyncConfig config,
  ) async {
    final jsonStr = jsonEncode(config.toJson());
    await provider.writeFile(
      'sync-config.json',
      Uint8List.fromList(utf8.encode(jsonStr)),
    );
  }

  /// Uploads all attachments currently in the database to the remote provider.
  /// Used during initialization.
  Future<void> _uploadInitialAttachments(
    SyncStorageProvider provider,
    SyncEncryptionService? encryption,
  ) async {
    final db = await _db.database;
    final attachmentPaths = <String>{};

    // Query standard attachments
    final attachments = await db.query('attachments', columns: ['filePath']);
    for (final row in attachments) {
      final path = row['filePath'] as String?;
      if (path != null && path.isNotEmpty) {
        attachmentPaths.add(path);
      }
    }

    // Query conversation attachments
    final convAttachments = await db.query(
      'conversation_attachments',
      columns: ['filePath'],
    );
    for (final row in convAttachments) {
      final path = row['filePath'] as String?;
      if (path != null && path.isNotEmpty) {
        attachmentPaths.add(path);
      }
    }

    if (attachmentPaths.isEmpty) return;

    final attachmentService = AttachmentSyncService(
      provider: provider,
      encryption: encryption,
    );

    try {
      final appDocDir = await getApplicationDocumentsDirectory();

      // Create synthetic ops to reuse AttachmentSyncService logic
      final ops = <SyncOperation>[];
      final timestamp = DateTime.now().toUtc();

      for (final rawPath in attachmentPaths) {
        String relativePath = rawPath;
        if (p.isAbsolute(rawPath)) {
          // Try to make it relative to appDocDir
          if (rawPath.startsWith(appDocDir.path)) {
            relativePath = p.relative(rawPath, from: appDocDir.path);
          } else {
            // Fallback: just use the filename in attachments/ folder
            // This handles cases where file might be in a different absolute path
            // but we want to sync it to standard location.
            // CAUTION: This assumes the file effectively lives in "attachments/" logically.
            relativePath = p.join('attachments', p.basename(rawPath));
          }
        }

        // Ensure we don't start with / even if p.relative failed or behaved weirdly
        if (p.isAbsolute(relativePath)) {
          relativePath = p.join('attachments', p.basename(relativePath));
        }

        ops.add(
          SyncOperation(
            id: 'init-upload-${rawPath.hashCode}', // dummy ID
            deviceId: 'init',
            sequence: 0,
            timestamp: timestamp,
            table: 'attachments',
            rowId: 'init',
            action: SyncAction.insert,
            fields: {
              'filePath': SyncFieldValue(value: relativePath, minVersion: 1),
            },
            schemaVersion: 1,
          ),
        );
      }

      final count = await attachmentService.uploadNewAttachments(
        ops,
        appDocDir.path,
      );

      LoggerService.info('Uploaded $count initial attachments');
    } catch (e, stack) {
      LoggerService.error(
        'Failed to upload initial attachments',
        error: e,
        stackTrace: stack,
      );
      // Non-fatal, user can sync later.
    }
  }

  /// Generates random bytes using Dart's secure random.
  List<int> _generateRandomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}

/// Internal pull result.
class _PullResult {
  final int opsPulled;
  final int conflictsCreated;

  _PullResult({required this.opsPulled, required this.conflictsCreated});
}
