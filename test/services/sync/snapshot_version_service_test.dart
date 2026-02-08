import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/sync/folder_sync_provider.dart';
import 'package:note_synapse/services/sync/snapshot_version_service.dart';

void main() {
  group('SnapshotVersionService', () {
    late Directory tempDir;
    late FolderSyncProvider provider;
    late SnapshotVersionService service;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('snapshot_version_test_');
      provider = FolderSyncProvider(rootPath: tempDir.path);
      service = SnapshotVersionService(provider: provider);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('returns 0 when no version file exists', () async {
      expect(await service.readVersion(), 0);
    });

    test('incrementVersion returns 1 on first call', () async {
      final version = await service.incrementVersion();
      expect(version, 1);
    });

    test('incrementVersion is monotonic', () async {
      expect(await service.incrementVersion(), 1);
      expect(await service.incrementVersion(), 2);
      expect(await service.incrementVersion(), 3);
      expect(await service.readVersion(), 3);
    });
  });
}
