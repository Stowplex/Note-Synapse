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

    test('subdirectory resolution cached — listChildren not repeated on second readFile', () async {
      // First listFiles('oplogs') — triggers listChildren(root-folder) to resolve
      // 'oplogs', then listChildren(oplogs-folder) to list its contents.
      // Second readFile('oplogs/op-001.bin') should use _idCache and skip both calls.
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => [
            DriveFileInfo(id: 'oplogs-folder', name: 'oplogs'),
          ]);
      when(mockClient.listChildren('oplogs-folder')).thenAnswer((_) async => [
            DriveFileInfo(id: 'op1', name: 'op-001.bin', size: 64),
          ]);
      when(mockClient.downloadFile('op1'))
          .thenAnswer((_) async => Uint8List.fromList([9]));

      await provider.listFiles('oplogs');
      await provider.readFile('oplogs/op-001.bin');

      verify(mockClient.listChildren('root-folder')).called(1);
      verify(mockClient.listChildren('oplogs-folder')).called(1);
      verify(mockClient.downloadFile('op1')).called(1);
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

  group('writeFile', () {
    setUp(() async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => [
            DriveFileInfo(id: 'root-folder', name: 'Test Sync'),
          ]);
      await provider.initialize();
    });

    test('updates existing file via updateFile when path is cached', () async {
      // Pre-populate cache via listFiles
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => [
            DriveFileInfo(id: 'existing-id', name: 'snapshot.db'),
          ]);
      await provider.listFiles(''); // populates _idCache['snapshot.db'] = 'existing-id'

      when(mockClient.updateFile(
        fileId: 'existing-id',
        content: anyNamed('content'),
      )).thenAnswer((_) async {});

      await provider.writeFile('snapshot.db', Uint8List.fromList([9, 8]));

      verify(mockClient.updateFile(
        fileId: 'existing-id',
        content: anyNamed('content'),
      )).called(1);
      verifyNever(mockClient.uploadFile(
        name: anyNamed('name'),
        parentId: anyNamed('parentId'),
        content: anyNamed('content'),
      ));
    });

    test('uploads new file when path is not in cache', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => []);
      when(mockClient.uploadFile(
        name: 'new-file.bin',
        parentId: 'root-folder',
        content: anyNamed('content'),
      )).thenAnswer((_) async =>
          DriveFileInfo(id: 'uploaded-id', name: 'new-file.bin'));

      await provider.writeFile('new-file.bin', Uint8List.fromList([1]));

      verify(mockClient.uploadFile(
        name: 'new-file.bin',
        parentId: 'root-folder',
        content: anyNamed('content'),
      )).called(1);
      verifyNever(mockClient.updateFile(
        fileId: anyNamed('fileId'),
        content: anyNamed('content'),
      ));
    });

    test('creates parent subfolder when writing to nested path not yet in Drive', () async {
      // Writing to 'oplogs/op-001.bin' where 'oplogs' folder doesn't exist yet
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => []);
      when(mockClient.createFolder(name: 'oplogs', parentId: 'root-folder'))
          .thenAnswer((_) async =>
              DriveFileInfo(id: 'oplogs-folder-id', name: 'oplogs'));
      when(mockClient.uploadFile(
        name: 'op-001.bin',
        parentId: 'oplogs-folder-id',
        content: anyNamed('content'),
      )).thenAnswer((_) async =>
          DriveFileInfo(id: 'op1-id', name: 'op-001.bin'));

      await provider.writeFile('oplogs/op-001.bin', Uint8List.fromList([42]));

      verify(mockClient.createFolder(
        name: 'oplogs',
        parentId: 'root-folder',
      )).called(1);
      verify(mockClient.uploadFile(
        name: 'op-001.bin',
        parentId: 'oplogs-folder-id',
        content: anyNamed('content'),
      )).called(1);
    });
  });

  group('deleteFile', () {
    setUp(() async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => [
            DriveFileInfo(id: 'root-folder', name: 'Test Sync'),
          ]);
      await provider.initialize();
    });

    test('trashes file and evicts from cache', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => [
            DriveFileInfo(id: 'del-id', name: 'old.bin'),
          ]);
      await provider.listFiles(''); // populate cache

      when(mockClient.trashFile('del-id')).thenAnswer((_) async {});
      when(mockClient.listChildren('root-folder'))
          .thenAnswer((_) async => []); // file no longer in Drive after trash

      await provider.deleteFile('old.bin');

      verify(mockClient.trashFile('del-id')).called(1);

      // After eviction, exists() must re-query Drive and find nothing
      final stillExists = await provider.exists('old.bin');
      expect(stillExists, isFalse);
    });

    test('does nothing when file does not exist', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => []);

      await provider.deleteFile('nonexistent.bin'); // must not throw

      verifyNever(mockClient.trashFile(any));
    });
  });

  group('exists', () {
    setUp(() async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => [
            DriveFileInfo(id: 'root-folder', name: 'Test Sync'),
          ]);
      await provider.initialize();
    });

    test('returns true when file exists in Drive', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => [
            DriveFileInfo(id: 'file-id', name: 'config.json'),
          ]);

      final result = await provider.exists('config.json');
      expect(result, isTrue);
    });

    test('returns false when file does not exist', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => []);

      final result = await provider.exists('missing.json');
      expect(result, isFalse);
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
