import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/models/note.dart';
import 'package:path_provider/path_provider.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'dart:io';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  String? _tempPath;
  String? _appDocPath;

  MockPathProviderPlatform({String? tempPath, String? appDocPath}) {
    _tempPath = tempPath;
    _appDocPath = appDocPath;
  }

  @override
  Future<String?> getTemporaryPath() async {
    return _tempPath;
  }

  @override
  Future<String?> getApplicationSupportPath() async {
    return _appDocPath;
  }

  @override
  Future<String?> getLibraryPath() async {
    return _appDocPath;
  }

  @override
  Future<String?> getApplicationDocumentsPath() async {
    return _appDocPath;
  }

  @override
  Future<String?> getExternalStoragePath() async {
    return _tempPath;
  }

  @override
  Future<List<String>?> getExternalCachePaths() async {
    return _tempPath != null ? [_tempPath!] : [];
  }

  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async {
    return _tempPath != null ? [_tempPath!] : [];
  }

  @override
  Future<String?> getDownloadsPath() async {
    return _tempPath;
  }
}

void main() {
  group('Reproduction: Relative Path Expansion Bug', () {
    late DatabaseService databaseService;
    late Directory tempDir;

    setUpAll(() async {
      // Initialize FFI for testing
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;

      // Mock Path Provider
      tempDir = await Directory.systemTemp.createTemp('synapse_test_');
      PathProviderPlatform.instance = MockPathProviderPlatform(
        appDocPath: tempDir.path,
        tempPath: tempDir.path,
      );
    });

    tearDownAll(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test(
      'reproduce bug: saving updated note converts relative path to absolute',
      () async {
        // 1. Create a dummy file in the "app documents" directory
        // The simulated app doc dir is tempDir.path
        // Attachments are typically in 'attachments/' subdir relative to doc dir
        final attachmentsDir = Directory('${tempDir.path}/attachments');
        if (!attachmentsDir.existsSync()) {
          attachmentsDir.createSync();
        }
        final testFile = File('${attachmentsDir.path}/test.pdf');
        testFile.writeAsStringSync('dummy content');

        final relativePath = 'attachments/test.pdf';

        // 2. Insert a note with a RELATIVE attachment path
        final note = Note(
          id: 'repro-note',
          title: 'Original Title',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          attachmentPaths: [relativePath], // Relative!
        );

        await databaseService.insertNote(note);

        // Verify the database stored it as relative
        final initialAttachments = await databaseService.getAttachmentsForNote(
          'repro-note',
        );
        expect(initialAttachments.length, 1);
        expect(initialAttachments.first.filePath, relativePath);
        expect(
          initialAttachments.first.isRelativePath,
          isTrue,
          reason: 'Initial insertion should respect relative path',
        );

        // 3. Load the note via getAllNotes or getNote
        // This triggers _batchLoadNotes which calls FileUtils.getFullFilePath
        final loadedNote = await databaseService.getNote('repro-note');
        expect(loadedNote, isNotNull);

        // CRITICAL: Verify the loaded note has an ABSOLUTE path
        // This logic exists in DatabaseService._batchLoadNotes:
        // if (isRelativePath) { finalPath = await FileUtils.getFullFilePath(...) }
        final loadedPath = loadedNote!.attachmentPaths.first;
        final expectedAbsolutePath = '${tempDir.path}/$relativePath';

        expect(
          loadedPath,
          expectedAbsolutePath,
          reason:
              'Loaded note should have absolute path due to DatabaseService expansion',
        );
        expect(
          loadedPath.startsWith('attachments/'),
          isFalse,
          reason: 'Loaded path should NOT be relative',
        );

        // 4. Update the note
        // We pass the LOADED note (with absolute paths) back to updateNote
        final updatedNote = loadedNote.copyWith(
          title: 'Updated Title',
          updatedAt: DateTime.now(),
        );

        await databaseService.updateNote(updatedNote);

        // 5. Verify the database state again
        // BUG: The updateNote function should check if path starts with attachments/, which it WON'T anymore.
        final updatedAttachments = await databaseService.getAttachmentsForNote(
          'repro-note',
        );
        expect(updatedAttachments.length, 1);

        // The actual values we expect IF THE BUG EXISTS:
        // filePath will be absolute
        // isRelativePath will be false

        print(
          'Updated Attachment Path in DB: ${updatedAttachments.first.filePath}',
        );
        print(
          'Updated IsRelative in DB: ${updatedAttachments.first.isRelativePath}',
        );

        // Asserting the BUG exists (so the test PASSES if the bug is present)
        // Or confirming the failure of "correct behavior".
        // Let's assert correct behavior and expect it to FAIL, or assert buggy behavior and expect pass?
        // Usually better to assert correct behavior and see it fail.

        expect(
          updatedAttachments.first.filePath,
          relativePath,
          reason: 'Database should store relative path after update',
        );
        expect(
          updatedAttachments.first.isRelativePath,
          isTrue,
          reason: 'Database should preserve relative flag after update',
        );
      },
    );
  });
}
