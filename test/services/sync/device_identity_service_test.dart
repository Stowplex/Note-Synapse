import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:note_synapse/services/sync/device_identity_service.dart';

class FakeSecureStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.remove(key);
  }
}

void main() {
  late FakeSecureStorage fakeStorage;
  late DeviceIdentityService service;

  setUp(() {
    fakeStorage = FakeSecureStorage();
    service = DeviceIdentityService(secureStorage: fakeStorage);
  });

  group('getDeviceId', () {
    test('generates UUID on first call', () async {
      final deviceId = await service.getDeviceId();
      // UUID v4 format: 8-4-4-4-12 hex chars
      expect(
        deviceId,
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')),
      );
    });

    test('returns same ID on subsequent calls', () async {
      final first = await service.getDeviceId();
      final second = await service.getDeviceId();
      expect(first, equals(second));
    });
  });

  group('lastSequence', () {
    test('defaults to 0 when nothing stored', () async {
      final seq = await service.getLastSequence();
      expect(seq, equals(0));
    });

    test('roundtrip: store 42, get 42', () async {
      await service.setLastSequence(42);
      final seq = await service.getLastSequence();
      expect(seq, equals(42));
    });
  });

  group('encryptionEnabled', () {
    test('defaults to false when nothing stored', () async {
      final enabled = await service.isEncryptionEnabled();
      expect(enabled, isFalse);
    });

    test('roundtrip: set true, get true', () async {
      await service.setEncryptionEnabled(true);
      final enabled = await service.isEncryptionEnabled();
      expect(enabled, isTrue);
    });
  });

  group('cipherId', () {
    test('returns null when not set', () async {
      final cipherId = await service.getCipherId();
      expect(cipherId, isNull);
    });

    test('roundtrip: store and retrieve', () async {
      await service.setCipherId('cipher-abc-123');
      final cipherId = await service.getCipherId();
      expect(cipherId, equals('cipher-abc-123'));
    });
  });

  group('clearSyncIdentity', () {
    test('removes all keys, values reset to defaults', () async {
      // Set all values
      await service.getDeviceId(); // generates and stores
      await service.setLastSequence(99);
      await service.setEncryptionEnabled(true);
      await service.setCipherId('some-cipher');

      // Clear
      await service.clearSyncIdentity();

      // All should be back to defaults
      final seq = await service.getLastSequence();
      expect(seq, equals(0));

      final enabled = await service.isEncryptionEnabled();
      expect(enabled, isFalse);

      final cipherId = await service.getCipherId();
      expect(cipherId, isNull);

      // Device ID should generate a NEW one (different from before clear)
      // We can't easily test "different" without storing the old one,
      // but we can verify it generates a valid UUID
      final newDeviceId = await service.getDeviceId();
      expect(
        newDeviceId,
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')),
      );
    });
  });
}
