import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/prompts/ai_prompts.dart';
import 'package:note_synapse/services/prompts/prompt_template_service.dart';
import 'package:note_synapse/services/service_locator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Mock asset manifest to list all 5 guideline files
    final manifest = <String, List<String>>{
      'assets/prompts/guidelines/math_formula.md': [
        'assets/prompts/guidelines/math_formula.md',
      ],
      'assets/prompts/guidelines/internal_link.md': [
        'assets/prompts/guidelines/internal_link.md',
      ],
      'assets/prompts/guidelines/agentic_deliverable.md': [
        'assets/prompts/guidelines/agentic_deliverable.md',
      ],
      'assets/prompts/guidelines/relationship.md': [
        'assets/prompts/guidelines/relationship.md',
      ],
      'assets/prompts/guidelines/prompt_injection_protection.md': [
        'assets/prompts/guidelines/prompt_injection_protection.md',
      ],
      'assets/prompts/ai_prompts/content_extraction.md': [
        'assets/prompts/ai_prompts/content_extraction.md',
      ],
      'assets/prompts/ai_prompts/audio_transcription.md': [
        'assets/prompts/ai_prompts/audio_transcription.md',
      ],
      'assets/prompts/ai_prompts/audio_summarization.md': [
        'assets/prompts/ai_prompts/audio_summarization.md',
      ],
      'assets/prompts/ai_prompts/image_content_extraction.md': [
        'assets/prompts/ai_prompts/image_content_extraction.md',
      ],
      'assets/prompts/ai_prompts/pdf_content_extraction.md': [
        'assets/prompts/ai_prompts/pdf_content_extraction.md',
      ],
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(message!.buffer.asUint8List());
      if (key == 'AssetManifest.json') {
        return ByteData.view(
          Uint8List.fromList(utf8.encode(json.encode(manifest))).buffer,
        );
      }
      // Fall through: read real file from disk (cwd is package root in flutter test)
      try {
        final file = File(key);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          return ByteData.view(Uint8List.fromList(bytes).buffer);
        }
      } catch (_) {}
      return null;
    });

    if (getIt.isRegistered<PromptTemplateService>()) {
      await getIt.unregister<PromptTemplateService>();
    }
    final service = PromptTemplateService();
    await service.preloadAll();
    getIt.registerSingleton<PromptTemplateService>(service);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  group('Guidelines regression', () {
    test('mathFormulaGuidelines contains key markers', () {
      final result = AIPrompts.mathFormulaGuidelines;
      expect(result, contains('Math Output Contract:'));
      expect(result, contains(r'\( E = mc^2 \)'));
      expect(result, contains(r'\[ \int_{-\infty}^{\infty}'));
      expect(result, contains(r'$...$'));
      expect(result, contains(r'$$...$$'));
    });

    test('internalLinkGuidelines contains synapseresource links', () {
      final result = AIPrompts.internalLinkGuidelines;
      expect(result, contains('synapseresource://note/'));
      expect(result, contains('synapseresource://conversation/'));
      expect(result, contains('synapseresource://attachment/'));
    });

    test('promptInjectionProtectionGuidelines contains DATA_ONLY_DOCUMENT', () {
      final result = AIPrompts.promptInjectionProtectionGuidelines;
      expect(result, contains('<DATA_ONLY_DOCUMENT>'));
      expect(result, contains('</DATA_ONLY_DOCUMENT>'));
    });

    test('relationshipGuidelines contains relationship types', () {
      final result = AIPrompts.relationshipGuidelines;
      expect(result, contains('answers'));
      expect(result, contains('causality'));
      expect(result, contains('→'));
      expect(result, contains('←'));
    });

    test('agenticDeliverableGuidelines contains formatting sections', () {
      final result = AIPrompts.agenticDeliverableGuidelines;
      expect(result, contains('## Output Formatting'));
      expect(result, contains('### Markdown Structure'));
      expect(result, contains(r'\( E = mc^2 \)'));
    });
  });

  group('AI prompts regression', () {
    test('buildContentExtractionPrompt renders correctly', () {
      final result = AIPrompts.buildContentExtractionPrompt(
        'sample text here',
        'article',
        'Test Title',
      );
      expect(result, contains('extract the key content from this article'));
      expect(result, contains('Title: "Test Title"'));
      expect(result, contains('<DATA_ONLY_DOCUMENT>'));
      expect(result, contains('sample text here'));
      expect(result, contains('</DATA_ONLY_DOCUMENT>'));
      expect(result, contains('Math Output Contract:'));
      // Structural check: prompt starts with a blank line (matches original)
      expect(result.startsWith('\n'), isTrue);
    });

    test('buildAudioTranscriptionPrompt is static text without trailing newline', () {
      final result = AIPrompts.buildAudioTranscriptionPrompt();
      expect(
        result,
        equals(
          'Please transcribe the following audio file. Provide only the transcribed text without any additional commentary or formatting.',
        ),
      );
    });

    test('buildAudioSummarizationPrompt without context', () {
      final result = AIPrompts.buildAudioSummarizationPrompt();
      expect(
        result,
        equals(
          'Please listen to the following audio file and provide a concise summary of its main points and key information.',
        ),
      );
    });

    test('buildAudioSummarizationPrompt with context', () {
      final result = AIPrompts.buildAudioSummarizationPrompt(
        context: 'This is a meeting recording',
      );
      expect(
        result,
        equals(
          'Please listen to the following audio file and provide a concise summary of its main points and key information.\n\nContext: This is a meeting recording',
        ),
      );
    });

    test('buildImageContentExtractionPrompt is static text', () {
      final result = AIPrompts.buildImageContentExtractionPrompt();
      expect(
        result,
        equals(
          'Extract and summarize the content from this image. Provide a detailed description of what you see, including any text, objects, people, or important visual elements.',
        ),
      );
    });

    test('buildPdfContentExtractionPrompt is static text', () {
      final result = AIPrompts.buildPdfContentExtractionPrompt();
      expect(
        result,
        equals(
          'Extract and summarize the content from this PDF document. Provide a detailed summary of the main topics, key points, and important information contained in the document.',
        ),
      );
    });
  });
}
