import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class DeviceIdentityService {
  final FlutterSecureStorage _secureStorage;

  DeviceIdentityService({FlutterSecureStorage? secureStorage})
    : _secureStorage =
          secureStorage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              encryptedSharedPreferences: true,
              sharedPreferencesName: 'note_synapse_secure',
              preferencesKeyPrefix: 'note_synapse_',
            ),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  static const _deviceIdKey = 'sync_device_id';
  static const _lastSequenceKey = 'sync_last_sequence';
  static const _encryptionEnabledKey = 'sync_encryption_enabled';
  static const _cipherIdKey = 'sync_cipher_id';
  static const _providerTypeKey = 'sync_provider_type';
  static const _providerUriKey = 'sync_provider_uri';

  /// Returns the persistent device ID, generating one on first call.
  Future<String> getDeviceId() async {
    final existing = await _secureStorage.read(key: _deviceIdKey);
    if (existing != null) return existing;

    final id = const Uuid().v4();
    await _secureStorage.write(key: _deviceIdKey, value: id);
    return id;
  }

  /// Returns the last pushed sequence number, defaulting to 0.
  Future<int> getLastSequence() async {
    final value = await _secureStorage.read(key: _lastSequenceKey);
    if (value == null) return 0;
    return int.tryParse(value) ?? 0;
  }

  /// Stores the last pushed sequence number.
  Future<void> setLastSequence(int sequence) async {
    await _secureStorage.write(
      key: _lastSequenceKey,
      value: sequence.toString(),
    );
  }

  /// Returns whether encryption is enabled, defaulting to false.
  Future<bool> isEncryptionEnabled() async {
    final value = await _secureStorage.read(key: _encryptionEnabledKey);
    return value == 'true';
  }

  /// Stores the encryption enabled flag.
  Future<void> setEncryptionEnabled(bool enabled) async {
    await _secureStorage.write(
      key: _encryptionEnabledKey,
      value: enabled.toString(),
    );
  }

  /// Returns the cipher ID, or null if not set.
  Future<String?> getCipherId() async {
    return await _secureStorage.read(key: _cipherIdKey);
  }

  /// Stores the cipher ID.
  Future<void> setCipherId(String cipherId) async {
    await _secureStorage.write(key: _cipherIdKey, value: cipherId);
  }

  /// Returns the sync provider type ('folder' or 'saf'), or null if not set.
  Future<String?> getSyncProviderType() async {
    return await _secureStorage.read(key: _providerTypeKey);
  }

  /// Stores the sync provider type ('folder' or 'saf').
  Future<void> setSyncProviderType(String? type) async {
    if (type == null) {
      await _secureStorage.delete(key: _providerTypeKey);
    } else {
      await _secureStorage.write(key: _providerTypeKey, value: type);
    }
  }

  /// Returns the sync provider URI (folder path or SAF tree URI), or null.
  Future<String?> getSyncProviderUri() async {
    return await _secureStorage.read(key: _providerUriKey);
  }

  /// Stores the sync provider URI (folder path or SAF tree URI).
  Future<void> setSyncProviderUri(String? uri) async {
    if (uri == null) {
      await _secureStorage.delete(key: _providerUriKey);
    } else {
      await _secureStorage.write(key: _providerUriKey, value: uri);
    }
  }

  /// Clears all sync-related keys from secure storage.
  Future<void> clearSyncIdentity() async {
    await _secureStorage.delete(key: _deviceIdKey);
    await _secureStorage.delete(key: _lastSequenceKey);
    await _secureStorage.delete(key: _encryptionEnabledKey);
    await _secureStorage.delete(key: _cipherIdKey);
    await _secureStorage.delete(key: _providerTypeKey);
    await _secureStorage.delete(key: _providerUriKey);
  }
}
