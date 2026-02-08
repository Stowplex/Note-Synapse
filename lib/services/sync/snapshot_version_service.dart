import 'dart:convert';
import 'dart:typed_data';

import 'sync_storage_provider.dart';

/// Manages the monotonic snapshot version counter on the remote sync root.
///
/// The version is stored in `meta/snapshot-version.json` as a simple JSON
/// object: `{"version": N}`. It is never encrypted (like sync-config.json)
/// so any device can read it without needing the encryption key first.
class SnapshotVersionService {
  final SyncStorageProvider _provider;

  static const _path = 'meta/snapshot-version.json';

  SnapshotVersionService({required SyncStorageProvider provider})
      : _provider = provider;

  /// Reads the current snapshot version from remote. Returns 0 if not found.
  Future<int> readVersion() async {
    final exists = await _provider.exists(_path);
    if (!exists) return 0;

    final bytes = await _provider.readFile(_path);
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return json['version'] as int? ?? 0;
  }

  /// Increments the snapshot version on remote and returns the new version.
  Future<int> incrementVersion() async {
    final current = await readVersion();
    final next = current + 1;
    final json = jsonEncode({'version': next});
    await _provider.writeFile(_path, Uint8List.fromList(utf8.encode(json)));
    return next;
  }
}
