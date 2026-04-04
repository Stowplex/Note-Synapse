import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/services/models/local_mnn_model.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';

void main() {
  group('LocalMnnModel', () {
    test('initializes successfully for Gemma preset config', () async {
      final model = LocalMnnModel();

      await model.initialize(
        config: ModelConfig(
          type: ModelType.localMnn,
          modelName: 'gemma4_e2b',
          displayName: 'Gemma 4 E2B',
          endpoint:
              'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
          backendType: 'gpu',
          tokenWindow: 32768,
        ),
      );

      expect(await model.isReady(), isTrue);
      expect(model.id, isNotEmpty);
      expect(model.name, 'Gemma 4 E2B');
      expect(model.description, contains('Flutter Gemma'));
      expect(model.supportsStreaming, isTrue);
    });

    test('is not ready for unsupported preset config', () async {
      final model = LocalMnnModel();

      await model.initialize(
        config: ModelConfig(
          type: ModelType.localMnn,
          modelName: 'legacy_qwen',
          displayName: 'Legacy Qwen',
          endpoint: '/tmp/legacy',
        ),
      );

      expect(await model.isReady(), isFalse);
    });

    test('coalesces consecutive user messages and preserves attachments', () {
      final model = LocalMnnModel();
      final firstImage = PlatformFile(
        name: 'page1.png',
        size: 3,
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      final secondImage = PlatformFile(
        name: 'selection.png',
        size: 2,
        bytes: Uint8List.fromList([4, 5]),
      );

      final result = model.coalesceMessagesForGemma([
        const PromptMessage(role: PromptRole.system, content: 'system'),
        PromptMessage(
          role: PromptRole.user,
          content: 'Context from note pages',
          attachments: [firstImage],
          isContext: true,
        ),
        PromptMessage(
          role: PromptRole.user,
          content: 'Question about the selected region',
          attachments: [secondImage],
        ),
      ]);

      expect(result, hasLength(2));
      expect(result.first.role, PromptRole.system);
      expect(result.last.role, PromptRole.user);
      expect(
        result.last.content,
        'Context from note pages\n\nQuestion about the selected region',
      );
      expect(result.last.attachments, hasLength(2));
      expect(result.last.attachments.first.name, 'page1.png');
      expect(result.last.attachments.last.name, 'selection.png');
      expect(result.last.isContext, isFalse);
    });

    test('does not merge across assistant boundaries', () {
      final model = LocalMnnModel();

      final result = model.coalesceMessagesForGemma([
        const PromptMessage(role: PromptRole.user, content: 'First'),
        const PromptMessage(role: PromptRole.assistant, content: 'Reply'),
        const PromptMessage(role: PromptRole.user, content: 'Second'),
      ]);

      expect(result, hasLength(3));
      expect(result[0].content, 'First');
      expect(result[1].role, PromptRole.assistant);
      expect(result[2].content, 'Second');
    });

    test('extracts Gemma tagged tool calls from text fallback', () {
      final model = LocalMnnModel();

      final result = model.extractTaggedToolCallsForTest(
        '<|tool_call>call_tool{service_name: "NS/ytfetcher_327c5c2c", tool_name: "fetch_youtube_data", params: {video_url: "https://youtu.be/tyknmLug2mY?si=79cgwHxw_3T-81cC"}}<tool_call|>',
      );

      expect(result.cleanedText, isEmpty);
      expect(result.calls, hasLength(1));
      expect(result.calls.single['name'], 'call_tool');
      expect(result.calls.single['args'], {
        'service_name': 'NS/ytfetcher_327c5c2c',
        'tool_name': 'fetch_youtube_data',
        'params': {
          'video_url': 'https://youtu.be/tyknmLug2mY?si=79cgwHxw_3T-81cC',
        },
      });
    });

    test('preserves surrounding text when Gemma tool call is embedded', () {
      final model = LocalMnnModel();

      final result = model.extractTaggedToolCallsForTest(
        'Let me check that.\n<|tool_call>call_tool{service_name: "svc", tool_name: "lookup", params: {q: "hello"}}<tool_call|>\nI will summarize after.',
      );

      expect(
        result.cleanedText,
        'Let me check that.\n\nI will summarize after.',
      );
      expect(result.calls, hasLength(1));
      expect(result.calls.single['name'], 'call_tool');
      expect(result.calls.single['args'], {
        'service_name': 'svc',
        'tool_name': 'lookup',
        'params': {'q': 'hello'},
      });
    });
  });
}
