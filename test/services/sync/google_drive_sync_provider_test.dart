import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/sync/google_drive_api_client.dart';
import 'package:note_synapse/services/sync/google_drive_sync_provider.dart';

import 'google_drive_sync_provider_test.mocks.dart';

@GenerateMocks([GoogleDriveApiClient])
void main() {
  late MockGoogleDriveApiClient mockClient;
  late GoogleDriveSyncProvider provider;

  setUp(() {
    mockClient = MockGoogleDriveApiClient();
    provider = GoogleDriveSyncProvider(
      client: mockClient,
      syncRootName: 'Test Sync',
    );
  });

  group('listFiles', () {
    setUp(() async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => [
            DriveFileInfo(id: 'root-folder', name: 'Test Sync'),
          ]);
      await provider.initialize();
    });

    test('lists files in a subfolder and populates cache', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => [
            DriveFileInfo(id: 'oplogs-folder', name: 'oplogs'),
          ]);
      when(mockClient.listChildren('oplogs-folder')).thenAnswer((_) async => [
            DriveFileInfo(
              id: 'op1',
              name: 'op-001.bin',
              size: 512,
              modifiedTime: DateTime(2026, 2, 28),
            ),
          ]);

      final files = await provider.listFiles('oplogs');

      expect(files.length, equals(1));
      expect(files[0].path, equals('oplogs/op-001.bin'));
      expect(files[0].sizeBytes, equals(512));
    });

    test('returns empty list when folder does not exist', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => []);

      final files = await provider.listFiles('nonexistent');
      expect(files, isEmpty);
    });

    test('second call uses cache — no extra API calls', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => [
            DriveFileInfo(id: 'snap-id', name: 'snapshot.db', size: 100),
          ]);
      when(mockClient.downloadFile('snap-id'))
          .thenAnswer((_) async => Uint8List.fromList([1, 2, 3]));

      // First call — populates _idCache with 'snapshot.db' -> 'snap-id'
      await provider.listFiles('');
      // readFile reuses the cached ID without listing again
      await provider.readFile('snapshot.db');

      // listChildren on root-folder should be called only once (from listFiles)
      verify(mockClient.listChildren('root-folder')).called(1);
      verify(mockClient.downloadFile('snap-id')).called(1);
    });
  });

  group('readFile', () {
    setUp(() async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => [
            DriveFileInfo(id: 'root-folder', name: 'Test Sync'),
          ]);
      await provider.initialize();
    });

    test('downloads file by resolved ID', () async {
      final expected = Uint8List.fromList([1, 2, 3]);
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => [
            DriveFileInfo(id: 'snap-id', name: 'snapshot.db'),
          ]);
      when(mockClient.downloadFile('snap-id')).thenAnswer((_) async => expected);

      final bytes = await provider.readFile('snapshot.db');
      expect(bytes, equals(expected));
    });

    test('throws GoogleDriveException when file does not exist', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => []);

      await expectLater(
        provider.readFile('missing.db'),
        throwsA(isA<GoogleDriveException>()),
      );
    });
  });

  group('getFileInfo', () {
    setUp(() async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => [
            DriveFileInfo(id: 'root-folder', name: 'Test Sync'),
          ]);
      await provider.initialize();
    });

    test('returns SyncFileInfo for existing file', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => [
            DriveFileInfo(id: 'cfg-id', name: 'sync-config.json'),
          ]);
      when(mockClient.getFileInfo('cfg-id')).thenAnswer((_) async => DriveFileInfo(
            id: 'cfg-id',
            name: 'sync-config.json',
            size: 256,
            modifiedTime: DateTime.utc(2026, 2, 28),
          ));

      final info = await provider.getFileInfo('sync-config.json');

      expect(info.path, equals('sync-config.json'));
      expect(info.sizeBytes, equals(256));
    });

    test('throws GoogleDriveException when file not found', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => []);

      await expectLater(
        provider.getFileInfo('missing.json'),
        throwsA(isA<GoogleDriveException>()),
      );
    });
  });

  group('initialize', () {
    test('uses existing folder when syncRootName found in Drive root', () async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => [
            DriveFileInfo(id: 'existing-folder-id', name: 'Test Sync'),
          ]);

      await provider.initialize();

      verify(mockClient.listChildren('root')).called(1);
      verifyNever(mockClient.createFolder(
        name: anyNamed('name'),
        parentId: anyNamed('parentId'),
      ));
    });

    test('creates folder when syncRootName not found', () async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => []);
      when(mockClient.createFolder(name: 'Test Sync', parentId: 'root'))
          .thenAnswer((_) async =>
              DriveFileInfo(id: 'new-folder-id', name: 'Test Sync'));

      await provider.initialize();

      verify(mockClient.createFolder(
        name: 'Test Sync',
        parentId: 'root',
      )).called(1);
    });

    test('throws StateError when methods called before initialize()', () async {
      // provider not yet initialized — _rootFolderId is null
      await expectLater(
        provider.listFiles('/'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
