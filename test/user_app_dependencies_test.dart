import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/user_app_library_service.dart';

void main() {
  group('User App Dependencies Tests', () {
    late DatabaseService databaseService;
    late UserAppLibraryService libraryService;

    setUp(() {
      databaseService = DatabaseService.createNew();
      libraryService = UserAppLibraryService();
    });

    test('should create user app library', () async {
      // Test data
      const appUuid = 'test-app-uuid';
      const revisionId = 1;
      const name = 'Test Library';
      const usageInstructions = 'Test usage instructions';

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

      // Create library with dependency
      final library = await libraryService.addLibrary(
        appUuid: appUuid,
        revisionId: revisionId,
        name: name,
        dependencies: [
          LibraryDependency(
            localPath: 'libs/example.js',
            bytes: [99, 111, 110, 115, 111, 108, 101, 46, 108, 111, 103, 40, 39, 72, 101, 108, 108, 111, 39, 41], // "console.log('Hello')" in bytes
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
      const appUuid = 'test-app-uuid-3';
      const revisionId = 1;
      const name = 'Test Library 3';

      // Create library with dependencies
      final library = await libraryService.addLibrary(
        appUuid: appUuid,
        revisionId: revisionId,
        name: name,
        dependencies: [
          LibraryDependency(
            localPath: 'libs/test1.js',
            bytes: [1, 2, 3],
          ),
          LibraryDependency(
            localPath: 'libs/test2.js',
            bytes: [4, 5, 6],
          ),
        ],
      );

      // Verify library exists
      final libraries = await libraryService.getLibraries(appUuid, revisionId);
      expect(libraries.length, equals(1));

      // Delete library
      await libraryService.deleteLibrary(library.id);

      // Verify library and dependencies are deleted
      final librariesAfterDelete = await libraryService.getLibraries(appUuid, revisionId);
      expect(librariesAfterDelete.length, equals(0));

      final dependenciesAfterDelete = await libraryService.getDependencies(library.id);
      expect(dependenciesAfterDelete.length, equals(0));
    });
  });
}
