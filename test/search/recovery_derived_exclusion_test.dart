// Export/backup must NOT carry `attachments/derived/` (plan §4.1, Step 14).
//
// Derived figure crops are regenerable index artifacts: FigureResolver
// re-renders a missing one on demand from the figure chunk's stored region,
// which is exactly why a restored backup is allowed to arrive without them.
// This covers the shared copy helper both export and import call.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:note_synapse/screens/recovery_screen.dart';

void main() {
  late Directory root;
  late Directory source;
  late Directory destination;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('derived_exclusion');
    source = Directory('${root.path}/attachments');
    destination = Directory('${root.path}/copy');
    await source.create(recursive: true);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<void> writeFile(String relativePath, String content) async {
    final file = File('${source.path}/$relativePath');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  Future<List<String>> copiedPaths() async {
    if (!await destination.exists()) return const [];
    final paths = <String>[];
    await for (final entity in destination.list(recursive: true)) {
      if (entity is File) {
        paths.add(entity.path.substring(destination.path.length + 1));
      }
    }
    paths.sort();
    return paths;
  }

  group('isExcludedAttachmentPath', () {
    test('excludes the derived directory and everything under it', () {
      expect(isExcludedAttachmentPath(kDerivedFigureDirName), isTrue);
      expect(isExcludedAttachmentPath('derived/a_p1_f0.png'), isTrue);
      expect(isExcludedAttachmentPath('derived/nested/a.png'), isTrue);
      expect(isExcludedAttachmentPath(r'derived\a_p1_f0.png'), isTrue);
    });

    test('never excludes real attachments that merely start with the name', () {
      expect(isExcludedAttachmentPath('derived-notes.pdf'), isFalse);
      expect(isExcludedAttachmentPath('derivedX/a.png'), isFalse);
      // Only the TOP-LEVEL derived dir is index data; a user folder named
      // "derived" deeper in the tree is their own content.
      expect(isExcludedAttachmentPath('scans/derived/a.png'), isFalse);
      expect(isExcludedAttachmentPath('report.pdf'), isFalse);
    });
  });

  test('the attachments copy used by export and import skips derived/ and '
      'keeps everything else', () async {
    await writeFile('report.pdf', 'pdf bytes');
    await writeFile('images/photo.png', 'png bytes');
    await writeFile('derived/att1_p1_f0.png', 'regenerable crop');
    await writeFile('derived/att1_p2_f0.png', 'regenerable crop');
    await writeFile('scans/derived/user_file.png', 'user content');

    await copyDirectoryFiltered(
      source,
      destination,
      skip: isExcludedAttachmentPath,
    );

    expect(await copiedPaths(), [
      'images/photo.png',
      'report.pdf',
      'scans/derived/user_file.png',
    ]);
    expect(
      await Directory('${destination.path}/derived').exists(),
      isFalse,
      reason: 'not even the empty directory should be archived',
    );
  });

  test('without the filter the same helper copies everything (so the '
      'exclusion really comes from the attachments call site)', () async {
    await writeFile('derived/att1_p1_f0.png', 'regenerable crop');
    await writeFile('report.pdf', 'pdf bytes');

    await copyDirectoryFiltered(source, destination);

    expect(await copiedPaths(), ['derived/att1_p1_f0.png', 'report.pdf']);
  });
}
