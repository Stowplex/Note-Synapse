import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/user_app_library_service.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/models/app_revision.dart';

void main() {
  group('User App Dependencies Tests', () {
    late DatabaseService databaseService;
    late UserAppLibraryService libraryService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database; // Ensure database is initialized
      await databaseService.clearAllData();
      libraryService = UserAppLibraryService.createForTesting(databaseService);
    });

    tearDown(() async {
      await databaseService.close();
    });

    // M1.4: a library's owning revision must actually exist as an
    // app_revisions row for the library to be effectively visible (see
    // DatabaseService.computeAppRevisionVisibility's doc comment) — real
    // production code (UserAppService) always inserts the revision before
    // ever adding a library to it (see e.g.
    // UserAppService.generateUserApp: insertAppRevision, THEN
    // _downloadAndStoreLibraries -> addLibrary), so this fixture now does
    // the same instead of only inserting the app.
    Future<void> createTestApp(String appUuid, {int revisionNumber = 1}) async {
      final appId = 'id-$appUuid';
      final app = UserApp(
        id: appId,
        uuid: appUuid,
        name: 'Test App $appUuid',
        description: 'Test Description',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        steps: [],
        htmlContent: '',
        type: UserAppType.normal,
      );
      await databaseService.insertUserApp(app);
      await databaseService.insertAppRevision(
        AppRevision(
          id: '$appId-rev-$revisionNumber',
          appId: appId,
          revisionNumber: revisionNumber,
          revisionTimestamp: DateTime.now(),
          userPrompt: 'Test prompt',
          aiResponse: 'Test response',
          appCode: '<div>Test</div>',
        ),
      );
    }

    test('should create user app library', () async {
      // Test data
      const appUuid = 'test-app-uuid';
      const revisionId = 1;
      const name = 'Test Library';
      const usageInstructions = 'Test usage instructions';

      await createTestApp(appUuid);

      // Create library
      final library = await libraryService.addLibrary(
        appUuid: appUuid,
        revisionId: revisionId,
        name: name,
        usageInstructions: usageInstructions,
        dependencies: [
          LibraryDependency(
            localPath: 'libs/test.js',
            bytes: [72, 101, 108, 108, 111], // "Hello" in bytes
          ),
          LibraryDependency(
            localPath: 'styles/test.css',
            bytes: [98, 111, 100, 121, 32, 123, 125], // "body {}" in bytes
          ),
        ],
      );

      // Verify library was created
      expect(library.id, isA<int>());
      expect(library.appUuid, equals(appUuid));
      expect(library.revisionId, equals(revisionId));
      expect(library.name, equals(name));
      expect(library.usageInstructions, equals(usageInstructions));

      // Verify dependencies were created
      final dependencies = await libraryService.getDependencies(library.id);
      expect(dependencies.length, equals(2));
      expect(dependencies[0].localPath, equals('libs/test.js'));
      expect(dependencies[1].localPath, equals('styles/test.css'));
    });

    test('should retrieve dependency by app and path', () async {
      // Test data
      const appUuid = 'test-app-uuid-2';
      const revisionId = 1;
      const name = 'Test Library 2';

      await createTestApp(appUuid);

      // Create library with dependency
      await libraryService.addLibrary(
        appUuid: appUuid,
        revisionId: revisionId,
        name: name,
        dependencies: [
          LibraryDependency(
            localPath: 'libs/example.js',
            bytes: [
              99,
              111,
              110,
              115,
              111,
              108,
              101,
              46,
              108,
              111,
              103,
              40,
              39,
              72,
              101,
              108,
              108,
              111,
              39,
              41,
            ], // "console.log('Hello')" in bytes
          ),
        ],
      );

      // Test retrieving dependency by app and path
      final dependency = await databaseService.getDependencyByAppAndPath(
        appUuid,
        revisionId,
        'libs/example.js',
      );

      expect(dependency, isNotNull);
      expect(dependency!['local_path'], equals('libs/example.js'));
      expect(dependency['bytes'], isA<List<int>>());
    });

    test('should handle missing dependency gracefully', () async {
      // Test retrieving non-existent dependency
      final dependency = await databaseService.getDependencyByAppAndPath(
        'non-existent-uuid',
        1,
        'libs/missing.js',
      );

      expect(dependency, isNull);
    });

    test('should delete library and dependencies', () async {
      // Test data
      const appUuid = 'test-app-uuid-delete';
      const revisionId = 1;
      const name = 'Library to Delete';

      await createTestApp(appUuid);

      // Create library with dependencies
      final library = await libraryService.addLibrary(
        appUuid: appUuid,
        revisionId: revisionId,
        name: name,
        dependencies: [
          LibraryDependency(localPath: 'libs/test1.js', bytes: [1, 2, 3]),
          LibraryDependency(localPath: 'libs/test2.js', bytes: [4, 5, 6]),
        ],
      );

      // Verify library exists
      final libraries = await libraryService.getLibraries(appUuid, revisionId);
      expect(libraries.length, equals(1));

      // Delete library
      await libraryService.deleteLibrary(library.id);

      // Verify library and dependencies are deleted
      final librariesAfterDelete = await libraryService.getLibraries(
        appUuid,
        revisionId,
      );
      expect(librariesAfterDelete.length, equals(0));

      // Dependencies should be automatically deleted due to foreign key constraint
      // We can't check getDependencies(library.id) because the library is deleted
    });

    test('should prevent deletion of only remaining revision', () async {
      // Create a test app with one revision
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final appId = 'test-app-id-single-$timestamp';
      final appUuid = 'test-app-uuid-single-$timestamp';

      // Create app
      final app = UserApp(
        id: appId,
        uuid: appUuid,
        name: 'Test App',
        description: 'Test Description',
        steps: ['step1'],
        htmlContent: '<div>Test</div>',
        type: UserAppType.normal,
        selectedRevisionId: null,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await databaseService.insertUserApp(app);

      // Create one revision
      final revision = AppRevision(
        id: 'revision-single-$timestamp',
        appId: appId,
        revisionNumber: 1,
        revisionTimestamp: DateTime.now(),
        userPrompt: 'Test prompt',
        aiResponse: 'Test response',
        appCode: '<div>Test</div>',
        attachmentPaths: [],
      );

      await databaseService.insertAppRevision(revision);

      // Try to delete the only revision - should throw exception
      expect(
        () => databaseService.deleteAppRevision(revision.id),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Cannot delete the only remaining revision'),
          ),
        ),
      );
    });

    test('should move pinned revision when deleting pinned revision', () async {
      // Create a test app with multiple revisions
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final appId = 'test-app-id-multi-$timestamp';
      final appUuid = 'test-app-uuid-multi-$timestamp';

      // Create app
      final app = UserApp(
        id: appId,
        uuid: appUuid,
        name: 'Test App 2',
        description: 'Test Description 2',
        steps: ['step1'],
        htmlContent: '<div>Test</div>',
        type: UserAppType.normal,
        selectedRevisionId: null,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await databaseService.insertUserApp(app);

      // Create multiple revisions
      final revision1 = AppRevision(
        id: 'revision-1-test2-$timestamp',
        appId: appId,
        revisionNumber: 1,
        revisionTimestamp: DateTime.now(),
        userPrompt: 'Test prompt 1',
        aiResponse: 'Test response 1',
        appCode: '<div>Test 1</div>',
        attachmentPaths: [],
      );

      final revision2 = AppRevision(
        id: 'revision-2-test2-$timestamp',
        appId: appId,
        revisionNumber: 2,
        revisionTimestamp: DateTime.now(),
        userPrompt: 'Test prompt 2',
        aiResponse: 'Test response 2',
        appCode: '<div>Test 2</div>',
        attachmentPaths: [],
      );

      await databaseService.insertAppRevision(revision1);
      await databaseService.insertAppRevision(revision2);

      // Set revision 2 as pinned
      final updatedApp = app.copyWith(selectedRevisionId: revision2.id);
      await databaseService.updateUserApp(updatedApp);

      // Delete revision 2 (the pinned one)
      await databaseService.deleteAppRevision(revision2.id);

      // Check that the pinned revision moved to revision 1
      final finalApp = await databaseService.getUserApp(appId);
      expect(finalApp?.selectedRevisionId, equals(revision1.id));
    });
  });
}
