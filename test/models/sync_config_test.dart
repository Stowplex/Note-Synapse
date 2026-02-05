import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/sync_config.dart';

void main() {
  group('KdfParams', () {
    test('toJson returns correct map', () {
      final params = KdfParams(memory: 65536, iterations: 3, parallelism: 4);
      final json = params.toJson();

      expect(json, {
        'memory': 65536,
        'iterations': 3,
        'parallelism': 4,
      });
    });

    test('fromJson creates correct instance', () {
      final json = {'memory': 131072, 'iterations': 5, 'parallelism': 2};
      final params = KdfParams.fromJson(json);

      expect(params.memory, 131072);
      expect(params.iterations, 5);
      expect(params.parallelism, 2);
    });

    test('roundtrip preserves all fields', () {
      final original = KdfParams(memory: 65536, iterations: 3, parallelism: 4);
      final restored = KdfParams.fromJson(original.toJson());

      expect(restored.memory, original.memory);
      expect(restored.iterations, original.iterations);
      expect(restored.parallelism, original.parallelism);
    });
  });

  group('SyncConfig', () {
    late SyncConfig encryptedConfig;
    late SyncConfig unencryptedConfig;

    setUp(() {
      encryptedConfig = SyncConfig(
        specVersion: 1,
        encryption: 'xchacha20-poly1305',
        kdf: 'argon2id',
        kdfParams: KdfParams(memory: 65536, iterations: 3, parallelism: 4),
        salt: 'dGVzdHNhbHQ=',
        schemaVersion: 3,
        hmac: 'abc123hmac',
      );

      unencryptedConfig = SyncConfig(
        specVersion: 1,
        encryption: 'none',
        kdf: 'argon2id',
        kdfParams: KdfParams(memory: 65536, iterations: 3, parallelism: 4),
        salt: 'dGVzdHNhbHQ=',
        schemaVersion: 3,
      );
    });

    test('encrypted config creation', () {
      expect(encryptedConfig.specVersion, 1);
      expect(encryptedConfig.encryption, 'xchacha20-poly1305');
      expect(encryptedConfig.kdf, 'argon2id');
      expect(encryptedConfig.kdfParams.memory, 65536);
      expect(encryptedConfig.kdfParams.iterations, 3);
      expect(encryptedConfig.kdfParams.parallelism, 4);
      expect(encryptedConfig.salt, 'dGVzdHNhbHQ=');
      expect(encryptedConfig.schemaVersion, 3);
      expect(encryptedConfig.hmac, 'abc123hmac');
    });

    test('unencrypted config with pre-populated crypto scaffolding', () {
      expect(unencryptedConfig.encryption, 'none');
      // Crypto scaffolding still present even when encryption is "none"
      expect(unencryptedConfig.kdf, 'argon2id');
      expect(unencryptedConfig.kdfParams.memory, 65536);
      expect(unencryptedConfig.salt, 'dGVzdHNhbHQ=');
      expect(unencryptedConfig.hmac, isNull);
    });

    test('isEncrypted returns true for encrypted config', () {
      expect(encryptedConfig.isEncrypted, isTrue);
    });

    test('isEncrypted returns false for unencrypted config', () {
      expect(unencryptedConfig.isEncrypted, isFalse);
    });

    test('jsonForHmac excludes hmac field', () {
      final hmacJson = encryptedConfig.jsonForHmac();
      final parsed = jsonDecode(hmacJson) as Map<String, dynamic>;

      expect(parsed.containsKey('hmac'), isFalse);
      expect(parsed['specVersion'], 1);
      expect(parsed['encryption'], 'xchacha20-poly1305');
      expect(parsed['kdf'], 'argon2id');
      expect(parsed['kdfParams'], isA<Map>());
      expect(parsed['salt'], 'dGVzdHNhbHQ=');
      expect(parsed['schemaVersion'], 3);
    });

    test('jsonForHmac produces deterministic output', () {
      final result1 = encryptedConfig.jsonForHmac();
      final result2 = encryptedConfig.jsonForHmac();

      expect(result1, result2);
    });

    test('jsonForHmac is same regardless of hmac value', () {
      final configWithDifferentHmac = encryptedConfig.copyWith(
        hmac: 'different-hmac-value',
      );

      expect(encryptedConfig.jsonForHmac(), configWithDifferentHmac.jsonForHmac());
    });

    test('toJson includes hmac when non-null', () {
      final json = encryptedConfig.toJson();

      expect(json.containsKey('hmac'), isTrue);
      expect(json['hmac'], 'abc123hmac');
    });

    test('toJson excludes hmac when null', () {
      final json = unencryptedConfig.toJson();

      expect(json.containsKey('hmac'), isFalse);
    });

    test('roundtrip JSON preserves HMAC', () {
      final json = encryptedConfig.toJson();
      final restored = SyncConfig.fromJson(json);

      expect(restored.specVersion, encryptedConfig.specVersion);
      expect(restored.encryption, encryptedConfig.encryption);
      expect(restored.kdf, encryptedConfig.kdf);
      expect(restored.kdfParams.memory, encryptedConfig.kdfParams.memory);
      expect(restored.kdfParams.iterations, encryptedConfig.kdfParams.iterations);
      expect(restored.kdfParams.parallelism, encryptedConfig.kdfParams.parallelism);
      expect(restored.salt, encryptedConfig.salt);
      expect(restored.schemaVersion, encryptedConfig.schemaVersion);
      expect(restored.hmac, encryptedConfig.hmac);
    });

    test('roundtrip JSON preserves null HMAC', () {
      final json = unencryptedConfig.toJson();
      final restored = SyncConfig.fromJson(json);

      expect(restored.hmac, isNull);
      expect(restored.encryption, 'none');
    });

    test('fromJson deserialization', () {
      final json = {
        'specVersion': 1,
        'encryption': 'xchacha20-poly1305',
        'kdf': 'argon2id',
        'kdfParams': {
          'memory': 65536,
          'iterations': 3,
          'parallelism': 4,
        },
        'salt': 'dGVzdHNhbHQ=',
        'schemaVersion': 5,
        'hmac': 'some-hmac-value',
      };

      final config = SyncConfig.fromJson(json);

      expect(config.specVersion, 1);
      expect(config.encryption, 'xchacha20-poly1305');
      expect(config.kdf, 'argon2id');
      expect(config.kdfParams.memory, 65536);
      expect(config.kdfParams.iterations, 3);
      expect(config.kdfParams.parallelism, 4);
      expect(config.salt, 'dGVzdHNhbHQ=');
      expect(config.schemaVersion, 5);
      expect(config.hmac, 'some-hmac-value');
    });

    test('fromJson without hmac field', () {
      final json = {
        'specVersion': 1,
        'encryption': 'none',
        'kdf': 'argon2id',
        'kdfParams': {
          'memory': 65536,
          'iterations': 3,
          'parallelism': 4,
        },
        'salt': 'dGVzdHNhbHQ=',
        'schemaVersion': 1,
      };

      final config = SyncConfig.fromJson(json);

      expect(config.hmac, isNull);
    });

    test('copyWith updates encryption', () {
      final updated = unencryptedConfig.copyWith(
        encryption: 'xchacha20-poly1305',
      );

      expect(updated.encryption, 'xchacha20-poly1305');
      expect(updated.isEncrypted, isTrue);
      // Other fields unchanged
      expect(updated.specVersion, unencryptedConfig.specVersion);
      expect(updated.kdf, unencryptedConfig.kdf);
      expect(updated.salt, unencryptedConfig.salt);
      expect(updated.schemaVersion, unencryptedConfig.schemaVersion);
    });

    test('copyWith updates hmac', () {
      final updated = unencryptedConfig.copyWith(hmac: 'new-hmac');

      expect(updated.hmac, 'new-hmac');
    });

    test('copyWith updates schemaVersion', () {
      final updated = encryptedConfig.copyWith(schemaVersion: 10);

      expect(updated.schemaVersion, 10);
      expect(updated.encryption, encryptedConfig.encryption);
      expect(updated.hmac, encryptedConfig.hmac);
    });
  });

  group('DeviceInfo', () {
    test('toJson serializes correctly', () {
      final lastSeen = DateTime.utc(2026, 1, 15, 10, 30, 0);
      final info = DeviceInfo(
        schemaVersion: 3,
        lastSequence: 42,
        lastSeen: lastSeen,
      );

      final json = info.toJson();

      expect(json['schemaVersion'], 3);
      expect(json['lastSequence'], 42);
      expect(json['lastSeen'], '2026-01-15T10:30:00.000Z');
    });

    test('fromJson deserializes correctly', () {
      final json = {
        'schemaVersion': 5,
        'lastSequence': 100,
        'lastSeen': '2026-01-15T10:30:00.000Z',
      };

      final info = DeviceInfo.fromJson(json);

      expect(info.schemaVersion, 5);
      expect(info.lastSequence, 100);
      expect(info.lastSeen, DateTime.utc(2026, 1, 15, 10, 30, 0));
      expect(info.lastSeen.isUtc, isTrue);
    });

    test('roundtrip preserves all fields', () {
      final original = DeviceInfo(
        schemaVersion: 3,
        lastSequence: 42,
        lastSeen: DateTime.utc(2026, 1, 15, 10, 30, 0),
      );

      final restored = DeviceInfo.fromJson(original.toJson());

      expect(restored.schemaVersion, original.schemaVersion);
      expect(restored.lastSequence, original.lastSequence);
      expect(
        restored.lastSeen.millisecondsSinceEpoch,
        original.lastSeen.millisecondsSinceEpoch,
      );
      expect(restored.lastSeen.isUtc, isTrue);
    });
  });

  group('DeviceRegistry', () {
    test('register new device', () {
      final registry = DeviceRegistry(devices: {});
      final updated = registry.registerDevice(
        'device-abc',
        schemaVersion: 3,
      );

      expect(updated.devices.containsKey('device-abc'), isTrue);
      final device = updated.devices['device-abc']!;
      expect(device.schemaVersion, 3);
      expect(device.lastSequence, 0);
      expect(device.lastSeen.isUtc, isTrue);
    });

    test('register device does not modify original', () {
      final registry = DeviceRegistry(devices: {});
      registry.registerDevice('device-abc', schemaVersion: 3);

      expect(registry.devices, isEmpty);
    });

    test('update sequence', () {
      final now = DateTime.now().toUtc();
      final registry = DeviceRegistry(devices: {
        'device-abc': DeviceInfo(
          schemaVersion: 3,
          lastSequence: 0,
          lastSeen: now,
        ),
      });

      final updated = registry.updateSequence('device-abc', 42);

      expect(updated.devices['device-abc']!.lastSequence, 42);
      expect(updated.devices['device-abc']!.schemaVersion, 3);
    });

    test('update sequence does not modify original', () {
      final now = DateTime.now().toUtc();
      final registry = DeviceRegistry(devices: {
        'device-abc': DeviceInfo(
          schemaVersion: 3,
          lastSequence: 0,
          lastSeen: now,
        ),
      });

      registry.updateSequence('device-abc', 42);

      expect(registry.devices['device-abc']!.lastSequence, 0);
    });

    test('highestSchemaVersion across devices', () {
      final now = DateTime.now().toUtc();
      final registry = DeviceRegistry(devices: {
        'device-a': DeviceInfo(
          schemaVersion: 3,
          lastSequence: 10,
          lastSeen: now,
        ),
        'device-b': DeviceInfo(
          schemaVersion: 7,
          lastSequence: 5,
          lastSeen: now,
        ),
        'device-c': DeviceInfo(
          schemaVersion: 5,
          lastSequence: 20,
          lastSeen: now,
        ),
      });

      expect(registry.highestSchemaVersion, 7);
    });

    test('highestSchemaVersion with single device', () {
      final now = DateTime.now().toUtc();
      final registry = DeviceRegistry(devices: {
        'device-a': DeviceInfo(
          schemaVersion: 3,
          lastSequence: 10,
          lastSeen: now,
        ),
      });

      expect(registry.highestSchemaVersion, 3);
    });

    test('highestSchemaVersion with empty devices returns 0', () {
      final registry = DeviceRegistry(devices: {});

      expect(registry.highestSchemaVersion, 0);
    });

    test('roundtrip JSON', () {
      final now = DateTime.utc(2026, 1, 15, 10, 30, 0);
      final registry = DeviceRegistry(devices: {
        'device-a': DeviceInfo(
          schemaVersion: 3,
          lastSequence: 10,
          lastSeen: now,
        ),
        'device-b': DeviceInfo(
          schemaVersion: 5,
          lastSequence: 20,
          lastSeen: now,
        ),
      });

      final json = registry.toJson();
      final restored = DeviceRegistry.fromJson(json);

      expect(restored.devices.length, 2);
      expect(restored.devices['device-a']!.schemaVersion, 3);
      expect(restored.devices['device-a']!.lastSequence, 10);
      expect(
        restored.devices['device-a']!.lastSeen.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
      );
      expect(restored.devices['device-b']!.schemaVersion, 5);
      expect(restored.devices['device-b']!.lastSequence, 20);
    });

    test('toJson structure', () {
      final now = DateTime.utc(2026, 1, 15, 10, 30, 0);
      final registry = DeviceRegistry(devices: {
        'device-a': DeviceInfo(
          schemaVersion: 3,
          lastSequence: 10,
          lastSeen: now,
        ),
      });

      final json = registry.toJson();

      expect(json.containsKey('devices'), isTrue);
      final devices = json['devices'] as Map<String, dynamic>;
      expect(devices.containsKey('device-a'), isTrue);
      final deviceJson = devices['device-a'] as Map<String, dynamic>;
      expect(deviceJson['schemaVersion'], 3);
      expect(deviceJson['lastSequence'], 10);
      expect(deviceJson['lastSeen'], '2026-01-15T10:30:00.000Z');
    });

    test('fromJson deserialization', () {
      final json = {
        'devices': {
          'device-x': {
            'schemaVersion': 7,
            'lastSequence': 100,
            'lastSeen': '2026-06-01T12:00:00.000Z',
          },
        },
      };

      final registry = DeviceRegistry.fromJson(json);

      expect(registry.devices.length, 1);
      expect(registry.devices['device-x']!.schemaVersion, 7);
      expect(registry.devices['device-x']!.lastSequence, 100);
      expect(
        registry.devices['device-x']!.lastSeen,
        DateTime.utc(2026, 6, 1, 12, 0, 0),
      );
    });
  });
}
