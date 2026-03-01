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
