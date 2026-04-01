import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/conversation_attachment_service.dart';
import 'package:note_synapse/utils/synapse_temp_utils.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  MockPathProviderPlatform({required this.tempPath, required this.appDocPath});

  final String tempPath;
  final String appDocPath;

  @override
  Future<String?> getTemporaryPath() async => tempPath;

  @override
  Future<String?> getApplicationSupportPath() async => appDocPath;

  @override
  Future<String?> getLibraryPath() async => appDocPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => appDocPath;

  @override
  Future<String?> getExternalStoragePath() async => tempPath;

  @override
  Future<List<String>?> getExternalCachePaths() async => [tempPath];

  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async {
    return [tempPath];
  }

  @override
  Future<String?> getDownloadsPath() async => tempPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory tempDir;
  late Directory appDocDir;

  setUp(() async {
    rootDir = await Directory.systemTemp.createTemp('conv_attach_test_');
    tempDir = Directory('${rootDir.path}/tmp')..createSync(recursive: true);
    appDocDir = Directory('${rootDir.path}/docs')..createSync(recursive: true);
    PathProviderPlatform.instance = MockPathProviderPlatform(
      tempPath: tempDir.path,
      appDocPath: appDocDir.path,
    );
  });

  tearDown(() async {
    if (await rootDir.exists()) {
      await rootDir.delete(recursive: true);
    }
  });

  test('promotes synapsetemp URI into persistent attachments path', () async {
    final saved = await SynapseTempUtils.saveTempData(
      mimeType: 'image/png',
      bytes: Uint8List.fromList([1, 2, 3, 4]),
    );

    final promoted =
        await ConversationAttachmentService.promoteAttachmentPathToPersistent(
          path: saved.uri,
          noteId: 'note-1',
        );

    expect(promoted, isNotNull);
    expect(promoted, startsWith('attachments/'));

    final promotedFile = File('${appDocDir.path}/$promoted');
    expect(await promotedFile.exists(), isTrue);
  });

  test(
    'rewrites absolute temp file path into persistent relative path',
    () async {
      final source = File('${tempDir.path}/capture.png');
      await source.writeAsBytes([9, 8, 7, 6], flush: true);

      final promoted =
          await ConversationAttachmentService.promoteAttachmentPathToPersistent(
            path: source.path,
            noteId: 'note-2',
          );

      expect(promoted, isNotNull);
      expect(promoted, startsWith('attachments/'));
      expect(promoted, isNot(source.path));
      expect(promoted!.startsWith('/'), isFalse);

      final promotedFile = File('${appDocDir.path}/$promoted');
      expect(await promotedFile.exists(), isTrue);
    },
  );

  test('keeps existing attachments path unchanged', () async {
    final attachmentsDir = Directory('${appDocDir.path}/attachments')
      ..createSync(recursive: true);
    final existing = File('${attachmentsDir.path}/existing.png');
    await existing.writeAsBytes([1, 1, 1], flush: true);

    final promoted =
        await ConversationAttachmentService.promoteAttachmentPathToPersistent(
          path: 'attachments/existing.png',
          noteId: 'note-3',
        );

    expect(promoted, 'attachments/existing.png');
  });
}
