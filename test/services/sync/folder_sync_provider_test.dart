import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/sync/folder_sync_provider.dart';
import 'package:path/path.dart' as p;

void main() {
  group('FolderSyncProvider', () {
    late Directory tempDir;
    late FolderSyncProvider provider;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('folder_sync_test_');
      provider = FolderSyncProvider(rootPath: tempDir.path);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('writeFile creates file and readFile returns contents', () async {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      await provider.writeFile('test.bin', data);

      final result = await provider.readFile('test.bin');
      expect(result, equals(data));
    });

    test('writeFile creates nested directories automatically', () async {
      final data = Uint8List.fromList([10, 20, 30]);
      await provider.writeFile('a/b/c/deep.bin', data);

      final file = File(p.join(tempDir.path, 'a', 'b', 'c', 'deep.bin'));
      expect(file.existsSync(), isTrue);

      final result = await provider.readFile('a/b/c/deep.bin');
      expect(result, equals(data));
    });

    test('exists returns true for existing file', () async {
      final data = Uint8List.fromList([1]);
      await provider.writeFile('exists.bin', data);

      expect(await provider.exists('exists.bin'), isTrue);
    });

    test('exists returns false for nonexistent file', () async {
      expect(await provider.exists('nope.bin'), isFalse);
    });

    test('deleteFile removes file', () async {
      final data = Uint8List.fromList([1, 2, 3]);
      await provider.writeFile('to_delete.bin', data);
      expect(await provider.exists('to_delete.bin'), isTrue);

      await provider.deleteFile('to_delete.bin');
      expect(await provider.exists('to_delete.bin'), isFalse);
    });

    test('deleteFile does not throw for nonexistent file', () async {
      // Should not throw
      await provider.deleteFile('nonexistent.bin');
    });

    test('listFiles returns files in directory (not from other directories)',
        () async {
      // Create files in target directory
      await provider.writeFile('dir/file1.bin', Uint8List.fromList([1]));
      await provider.writeFile('dir/file2.bin', Uint8List.fromList([2]));
      // Create file in a different directory
      await provider.writeFile('other/file3.bin', Uint8List.fromList([3]));
      // Create file in a subdirectory of target (should not appear)
      await provider.writeFile('dir/sub/file4.bin', Uint8List.fromList([4]));

      final files = await provider.listFiles('dir');
      final filePaths = files.map((f) => f.path).toList()..sort();

      expect(filePaths, equals(['dir/file1.bin', 'dir/file2.bin']));
    });

    test('listFiles returns empty for nonexistent directory', () async {
      final files = await provider.listFiles('nonexistent');
      expect(files, isEmpty);
    });

    test('getFileInfo returns correct size and modification time', () async {
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      await provider.writeFile('info.bin', data);

      final info = await provider.getFileInfo('info.bin');
      expect(info.path, equals('info.bin'));
      expect(info.sizeBytes, equals(10));
      // Modification time should be recent (within the last few seconds)
      expect(
        info.lastModified.difference(DateTime.now()).abs(),
        lessThan(const Duration(seconds: 5)),
      );
    });

    test('writeFile overwrites existing file', () async {
      final data1 = Uint8List.fromList([1, 2, 3]);
      final data2 = Uint8List.fromList([4, 5, 6, 7, 8]);

      await provider.writeFile('overwrite.bin', data1);
      expect((await provider.readFile('overwrite.bin')), equals(data1));

      await provider.writeFile('overwrite.bin', data2);
      final result = await provider.readFile('overwrite.bin');
      expect(result, equals(data2));

      // Verify size changed
      final info = await provider.getFileInfo('overwrite.bin');
      expect(info.sizeBytes, equals(5));
    });

    test('listFiles returns only files not subdirectories', () async {
      await provider.writeFile('mydir/file.bin', Uint8List.fromList([1]));
      // Create a subdirectory with a file in it
      await provider.writeFile(
          'mydir/subdir/nested.bin', Uint8List.fromList([2]));

      final files = await provider.listFiles('mydir');
      final filePaths = files.map((f) => f.path).toList();

      expect(filePaths, equals(['mydir/file.bin']));
    });
  });
}
