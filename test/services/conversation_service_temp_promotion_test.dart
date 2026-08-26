// AI responses that embed `synapsetemp:///` images must survive OS cache
// eviction (plan §4.3 hardening): ConversationService.addAIResponse copies the
// bytes into permanent attachment storage while KEEPING the URI in the message
// text, mirroring the note-side ConversationAttachmentService path.
//
// Scope matters as much as the copy: only IMAGES in markdown image position
// are promoted. A tool that returns a temp CSV/PDF must not get a permanent,
// unreferenced copy of it in attachments/.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/utils/file_utils.dart';
import 'package:note_synapse/utils/synapse_temp_utils.dart';

String _root = Directory.systemTemp.path;

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => '$_root/documents';

  @override
  Future<String?> getTemporaryPath() async => '$_root/temp';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;
  late ConversationService service;
  late Directory rootDir;

  // One root for the whole file: SynapseTempUtils caches its cache-directory
  // future statically, so the temp dir must outlive individual tests.
  setUpAll(() async {
    PathProviderPlatform.instance = _FakePathProviderPlatform();
    rootDir = await Directory.systemTemp.createTemp('convo_temp_promotion');
    _root = rootDir.path;
    await Directory('$_root/documents').create(recursive: true);
    await Directory('$_root/temp').create(recursive: true);
    FileUtils.resetDocumentsPathCache();
  });

  tearDownAll(() async {
    if (await rootDir.exists()) await rootDir.delete(recursive: true);
    FileUtils.resetDocumentsPathCache();
  });

  setUp(() async {
    final attachments = Directory('$_root/documents/attachments');
    if (await attachments.exists()) await attachments.delete(recursive: true);
    db = DatabaseService.createNew();
    await db.clearAllData();
    service = ConversationService.createForTesting(db);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'promotes a synapsetemp image and leaves the message text alone',
    () async {
      final conversation = await service.createConversation(title: 'Figures');
      final saved = await SynapseTempUtils.saveTempData(
        mimeType: 'image/png',
        base64Data: base64Encode(const [1, 2, 3, 4]),
      );
      final content = 'Here is the diagram:\n\n![diagram](${saved.uri})';

      final message = await service.addAIResponse(
        conversationId: conversation.id,
        content: content,
      );

      // Text is untouched — the renderer resolves the URI by hash.
      expect(message.content, content);
      final stored = await db.getConversationMessages(conversation.id);
      expect(stored.single.content, content);

      // Bytes now live in permanent storage under <conversationId>_<sha256>.
      final hash = sha256.convert(utf8.encode(saved.uri)).toString();
      final attachmentsDir = await FileUtils.getPrivateStorageDirectory();
      final promoted = File(
        '${attachmentsDir.path}/${conversation.id}_$hash.png',
      );
      expect(promoted.existsSync(), isTrue);
      expect(await promoted.readAsBytes(), [1, 2, 3, 4]);

      // The promoted copy outlives the temp cache.
      await saved.file.delete();
      expect(promoted.existsSync(), isTrue);
    },
  );

  test('does not create attachment rows or change message metadata', () async {
    final conversation = await service.createConversation(title: 'Figures');
    final saved = await SynapseTempUtils.saveTempData(
      mimeType: 'image/png',
      base64Data: base64Encode(const [9, 9]),
    );

    final message = await service.addAIResponse(
      conversationId: conversation.id,
      content: '![x](${saved.uri})',
      modelUsed: 'test-model',
      metadata: const {'toolCalls': 1},
    );

    expect(message.modelUsed, 'test-model');
    expect(message.metadata, {'toolCalls': 1});
    expect(message.attachmentPaths, isEmpty);
    final raw = await db.database;
    final rows = await raw.query('conversation_attachments');
    expect(rows, isEmpty);
  });

  test('a response without temp URIs touches no files', () async {
    final conversation = await service.createConversation(title: 'Plain');
    final attachmentsDir = Directory('$_root/documents/attachments');

    await service.addAIResponse(
      conversationId: conversation.id,
      content: 'No images here.',
    );

    expect(attachmentsDir.existsSync(), isFalse);
  });

  test('a missing temp file does not break the reply', () async {
    final conversation = await service.createConversation(title: 'Broken');

    final message = await service.addAIResponse(
      conversationId: conversation.id,
      content: '![gone](synapsetemp:///syn_missing.png)',
    );

    expect(message.content, '![gone](synapsetemp:///syn_missing.png)');
  });

  test('a tool-returned temp CSV is not promoted', () async {
    // The old scope matched `synapsetemp://…` ANYWHERE in the reply, so a
    // download link handed back by a tool became a permanent, unreferenced
    // copy in attachments/.
    final conversation = await service.createConversation(title: 'Data');
    final csv = await SynapseTempUtils.saveTempData(
      mimeType: 'text/csv',
      text: 'a,b\n1,2\n',
    );
    final png = await SynapseTempUtils.saveTempData(
      mimeType: 'image/png',
      base64Data: base64Encode(const [7, 7, 7]),
    );

    await service.addAIResponse(
      conversationId: conversation.id,
      content:
          'Exported it: [results.csv](${csv.uri})\n\n'
          'and here is the chart:\n\n![chart](${png.uri})',
    );

    final attachmentsDir = await FileUtils.getPrivateStorageDirectory();
    final promoted = attachmentsDir
        .listSync()
        .whereType<File>()
        .map((f) => f.path.split('/').last)
        .toList();
    final csvHash = sha256.convert(utf8.encode(csv.uri)).toString();
    final pngHash = sha256.convert(utf8.encode(png.uri)).toString();
    expect(
      promoted,
      contains('${conversation.id}_$pngHash.png'),
      reason: 'the image still gets its permanent copy',
    );
    expect(
      promoted.any((name) => name.contains(csvHash)),
      isFalse,
      reason: 'plan §4.3 promotes images, not arbitrary tool output',
    );
  });

  test('a non-image temp file in image position is not promoted', () async {
    final conversation = await service.createConversation(title: 'Sneaky');
    final pdf = await SynapseTempUtils.saveTempData(
      mimeType: 'application/pdf',
      base64Data: base64Encode(const [1, 2]),
    );

    await service.addAIResponse(
      conversationId: conversation.id,
      content: '![looks like an image](${pdf.uri})',
    );

    expect(
      Directory('$_root/documents/attachments').existsSync(),
      isFalse,
      reason: 'nothing was promoted, so nothing created the directory',
    );
  });

  group('tempImageUrisInMarkdown', () {
    test('keeps image-position URIs, in order, de-duplicated', () {
      expect(
        ConversationService.tempImageUrisInMarkdown(
          '![a](synapsetemp:///syn_1.png) text '
          '![b](synapsetemp:///syn_2.jpeg)\n'
          '![a again](synapsetemp:///syn_1.png)',
        ),
        ['synapsetemp:///syn_1.png', 'synapsetemp:///syn_2.jpeg'],
      );
    });

    test('drops link-position and non-image URIs', () {
      expect(
        ConversationService.tempImageUrisInMarkdown(
          'see [data](synapsetemp:///syn_1.csv) and bare '
          'synapsetemp:///syn_2.png plus ![doc](synapsetemp:///syn_3.pdf)',
        ),
        isEmpty,
      );
    });

    test('keeps an extension-less URI (the MIME type is sniffed later)', () {
      expect(
        ConversationService.tempImageUrisInMarkdown(
          '![x](synapsetemp:///syn_noext)',
        ),
        ['synapsetemp:///syn_noext'],
      );
    });
  });
}
