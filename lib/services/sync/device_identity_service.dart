import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class DeviceIdentityService {
  final FlutterSecureStorage _secureStorage;

  DeviceIdentityService({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _deviceIdKey = 'sync_device_id';
  static const _lastSequenceKey = 'sync_last_sequence';
  static const _encryptionEnabledKey = 'sync_encryption_enabled';
  static const _cipherIdKey = 'sync_cipher_id';

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
        key: _lastSequenceKey, value: sequence.toString());
  }

  /// Returns whether encryption is enabled, defaulting to false.
  Future<bool> isEncryptionEnabled() async {
    final value = await _secureStorage.read(key: _encryptionEnabledKey);
    return value == 'true';
  }

  /// Stores the encryption enabled flag.
  Future<void> setEncryptionEnabled(bool enabled) async {
    await _secureStorage.write(
        key: _encryptionEnabledKey, value: enabled.toString());
  }

  /// Returns the cipher ID, or null if not set.
  Future<String?> getCipherId() async {
    return await _secureStorage.read(key: _cipherIdKey);
  }

  /// Stores the cipher ID.
  Future<void> setCipherId(String cipherId) async {
    await _secureStorage.write(key: _cipherIdKey, value: cipherId);
  }

  /// Clears all sync-related keys from secure storage.
  Future<void> clearSyncIdentity() async {
    await _secureStorage.delete(key: _deviceIdKey);
    await _secureStorage.delete(key: _lastSequenceKey);
    await _secureStorage.delete(key: _encryptionEnabledKey);
    await _secureStorage.delete(key: _cipherIdKey);
  }
}
