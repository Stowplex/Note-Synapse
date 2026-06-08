import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/model_capabilities.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/services/local_model_attachment_constraint_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('LocalModelAttachmentConstraintService', () {
    late ModelConfig gemmaModel;
    late ModelConfig cloudDocumentModel;

    setUp(() async {
      await resetForTesting();
      FlutterSecureStorage.setMockInitialValues({});
      setupServiceLocator();
      SharedPreferences.setMockInitialValues({});

      gemmaModel = ModelConfig(
        id: 'local_gemma4_e2b',
        type: ModelType.localMnn,
        modelName: 'gemma4_e2b',
        displayName: 'Gemma 4 E2B',
        tokenWindow: 16384,
        customCapabilitiesObject: const ModelCapabilities(
          maxInputTokens: 16384,
          maxOutputTokens: 8192,
          supportsImages: true,
          supportsDocuments: false,
          supportsAudio: false,
          supportsVideo: false,
          supportsToolOrchestration: true,
          supportedImageFormats: ['png', 'jpg', 'jpeg'],
          supportedDocumentFormats: [],
        ),
        isConfigured: true,
      );

      cloudDocumentModel = ModelConfig(
        id: 'cloud_docs',
        type: ModelType.gemini,
        displayName: 'Cloud Docs',
        customCapabilitiesObject: const ModelCapabilities(
          maxInputTokens: 128000,
          maxOutputTokens: 4096,
          supportsImages: true,
          supportsDocuments: true,
          supportsAudio: false,
          supportsVideo: false,
        ),
        isConfigured: true,
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'configured_models',
        jsonEncode([gemmaModel.toJson(), cloudDocumentModel.toJson()]),
      );
      await prefs.setString('active_model_id', gemmaModel.id);
    });

    tearDown(() async {
      await resetForTesting();
    });

    test('does not warn for a manageable PNG attachment', () async {
      final warning =
          await LocalModelAttachmentConstraintService.analyzeForGemma4(
            config: gemmaModel,
            prompt: 'Summarize this image',
            attachments: [
              PlatformFile(
                name: 'image.png',
                size: 4,
                bytes: Uint8List.fromList([137, 80, 78, 71]),
              ),
            ],
          );

      expect(warning, isNull);
    });

    test('warns for unsupported non-image attachments', () async {
      final warning =
          await LocalModelAttachmentConstraintService.analyzeForGemma4(
            config: gemmaModel,
            prompt: 'Transcribe this audio',
            attachments: [
              PlatformFile(
                name: 'audio.mp3',
                size: 4,
                bytes: Uint8List.fromList([73, 68, 51, 4]),
              ),
            ],
          );

      expect(warning, isNotNull);
      expect(warning!.messages.join(' '), contains('audio.mp3'));
    });

    test('warns when pdf expands past Gemma image budget', () async {
      final pdfFile = await _createPdf(pageCount: 9);

      final warning =
          await LocalModelAttachmentConstraintService.analyzeForGemma4(
            config: gemmaModel,
            prompt: 'Summarize this PDF',
            attachments: [
              PlatformFile(
                name: 'report.pdf',
                path: pdfFile.path,
                size: await pdfFile.length(),
              ),
            ],
          );

      expect(warning, isNotNull);
      expect(
        warning!.messages.join(' '),
        contains('only handles up to 8 images reliably'),
      );
      expect(warning.suggestedModel?.id, cloudDocumentModel.id);
    });

    test('warns when pdf token estimate nears Gemma context limit', () async {
      final pdfFile = await _createPdf(pageCount: 15);

      final warning =
          await LocalModelAttachmentConstraintService.analyzeForGemma4(
            config: gemmaModel,
            prompt: 'Summarize this PDF',
            attachments: [
              PlatformFile(
                name: 'book.pdf',
                path: pdfFile.path,
                size: await pdfFile.length(),
              ),
            ],
          );

      expect(warning, isNotNull);
      expect(
        warning!.messages.join(' '),
        contains('70% of Gemma 4\'s context window'),
      );
    });
  });
}

Future<File> _createPdf({required int pageCount}) async {
  final document = pw.Document();
  for (int i = 0; i < pageCount; i++) {
    document.addPage(
      pw.Page(build: (_) => pw.Center(child: pw.Text('Page ${i + 1}'))),
    );
  }

  final directory = await Directory.systemTemp.createTemp(
    'local_model_constraint_test_',
  );
  final file = File('${directory.path}/test.pdf');
  await file.writeAsBytes(await document.save(), flush: true);
  return file;
}
