import 'dart:convert';

/// Parameters for the key derivation function (KDF).
///
/// These control the computational cost of deriving encryption keys from
/// a passphrase. Higher values increase security but also processing time.
class KdfParams {
  final int memory;
  final int iterations;
  final int parallelism;

  KdfParams({
    required this.memory,
    required this.iterations,
    required this.parallelism,
  });

  factory KdfParams.fromJson(Map<String, dynamic> json) {
    return KdfParams(
      memory: json['memory'] as int,
      iterations: json['iterations'] as int,
      parallelism: json['parallelism'] as int,
    );
  }

  Map<String, dynamic> toJson() => {
        'memory': memory,
        'iterations': iterations,
        'parallelism': parallelism,
      };
}

/// Root sync configuration stored as sync-config.json.
///
/// Contains the encryption scheme, KDF parameters, and schema version.
/// The crypto scaffolding (KDF params + salt) is always present even when
/// encryption is "none", to enable later upgrade without re-initializing.
///
/// The [hmac] field signs the config contents so tampering is detectable
/// (anti-downgrade protection).
class SyncConfig {
  final int specVersion;
  final String encryption;
  final String kdf;
  final KdfParams kdfParams;
  final String salt;
  final int schemaVersion;
  final String? hmac;

  SyncConfig({
    required this.specVersion,
    required this.encryption,
    required this.kdf,
    required this.kdfParams,
    required this.salt,
    required this.schemaVersion,
    this.hmac,
  });

  /// Whether encryption is enabled (i.e. not "none").
  bool get isEncrypted => encryption != 'none';

  /// Canonical JSON string of all fields EXCEPT hmac, for HMAC computation.
  ///
  /// Keys are sorted alphabetically to produce deterministic output.
  String jsonForHmac() {
    final map = <String, dynamic>{
      'encryption': encryption,
      'kdf': kdf,
      'kdfParams': kdfParams.toJson(),
      'salt': salt,
      'schemaVersion': schemaVersion,
      'specVersion': specVersion,
    };
    // Sort top-level keys for deterministic output
    final sorted = Map.fromEntries(
      map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return jsonEncode(sorted);
  }

  /// Creates a copy with optional field overrides.
  SyncConfig copyWith({
    String? encryption,
    String? hmac,
    int? schemaVersion,
  }) {
    return SyncConfig(
      specVersion: specVersion,
      encryption: encryption ?? this.encryption,
      kdf: kdf,
      kdfParams: kdfParams,
      salt: salt,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      hmac: hmac ?? this.hmac,
    );
  }

  factory SyncConfig.fromJson(Map<String, dynamic> json) {
    return SyncConfig(
      specVersion: json['specVersion'] as int,
      encryption: json['encryption'] as String,
      kdf: json['kdf'] as String,
      kdfParams:
          KdfParams.fromJson(json['kdfParams'] as Map<String, dynamic>),
      salt: json['salt'] as String,
      schemaVersion: json['schemaVersion'] as int,
      hmac: json['hmac'] as String?,
    );
  }

  /// Serializes to JSON. The hmac field is only included if non-null.
  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'specVersion': specVersion,
      'encryption': encryption,
      'kdf': kdf,
      'kdfParams': kdfParams.toJson(),
      'salt': salt,
      'schemaVersion': schemaVersion,
    };
    if (hmac != null) {
      map['hmac'] = hmac;
    }
    return map;
  }
}

/// Information about a single device participating in sync.
class DeviceInfo {
  final int schemaVersion;
  final int lastSequence;
  final DateTime lastSeen;

  DeviceInfo({
    required this.schemaVersion,
    required this.lastSequence,
    required this.lastSeen,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    return DeviceInfo(
      schemaVersion: json['schemaVersion'] as int,
      lastSequence: json['lastSequence'] as int,
      lastSeen: DateTime.parse(json['lastSeen'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'lastSequence': lastSequence,
        'lastSeen': lastSeen.toUtc().toIso8601String(),
      };
}

/// Registry of all devices that have participated in sync.
///
/// Stored as device-registry.json. Each device is identified by a unique
/// device ID and tracks its schema version, last synced sequence number,
/// and when it was last seen.
class DeviceRegistry {
  final Map<String, DeviceInfo> devices;

  DeviceRegistry({required this.devices});

  /// The highest schema version across all registered devices, or 0 if empty.
  int get highestSchemaVersion {
    if (devices.isEmpty) return 0;
    return devices.values
        .map((d) => d.schemaVersion)
        .reduce((a, b) => a > b ? a : b);
  }

  /// Returns a new registry with the given device added.
  ///
  /// The new device starts with lastSequence=0 and lastSeen=now (UTC).
  DeviceRegistry registerDevice(
    String deviceId, {
    required int schemaVersion,
  }) {
    final newDevices = Map<String, DeviceInfo>.from(devices);
    newDevices[deviceId] = DeviceInfo(
      schemaVersion: schemaVersion,
      lastSequence: 0,
      lastSeen: DateTime.now().toUtc(),
    );
    return DeviceRegistry(devices: newDevices);
  }

  /// Returns a new registry with the specified device's sequence updated.
  ///
  /// Also updates the device's lastSeen timestamp to now (UTC).
  DeviceRegistry updateSequence(String deviceId, int sequence) {
    final newDevices = Map<String, DeviceInfo>.from(devices);
    final existing = newDevices[deviceId]!;
    newDevices[deviceId] = DeviceInfo(
      schemaVersion: existing.schemaVersion,
      lastSequence: sequence,
      lastSeen: DateTime.now().toUtc(),
    );
    return DeviceRegistry(devices: newDevices);
  }

  factory DeviceRegistry.fromJson(Map<String, dynamic> json) {
    final devicesJson = json['devices'] as Map<String, dynamic>;
    return DeviceRegistry(
      devices: devicesJson.map(
        (key, value) =>
            MapEntry(key, DeviceInfo.fromJson(value as Map<String, dynamic>)),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'devices':
            devices.map((key, value) => MapEntry(key, value.toJson())),
      };
}
