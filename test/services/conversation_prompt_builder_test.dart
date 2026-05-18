import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/services/conversation_ai_engine.dart';
import 'package:note_synapse/services/conversation_prompt_builder.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';

class _MockPathProviderPlatform extends PathProviderPlatform {
  _MockPathProviderPlatform(this.appDocPath);

  final String appDocPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => appDocPath;

  @override
  Future<String?> getTemporaryPath() async => appDocPath;
}

void main() {
  group('ConversationAiEngine.buildConversationMessages', () {
    // Helper to create a ConversationMessage
    ConversationMessage makeMessage({
      String id = 'msg-1',
      String conversationId = 'conv-1',
      MessageType type = MessageType.ai,
      String content = 'Hello from AI',
      String? modelUsed,
      Map<String, dynamic>? metadata,
    }) {
      return ConversationMessage(
        id: id,
        conversationId: conversationId,
        type: type,
        content: content,
        timestamp: DateTime(2026, 3, 23, 10, 0),
        modelUsed: modelUsed,
        metadata: metadata,
      );
    }

    // Default attachment loader: returns empty for all messages
    Future<List<PlatformFile>> noAttachments(ConversationMessage _) async =>
        const [];

    test(
      'same model (modelUsed in DB column matches current) keeps assistant role',
      () async {
        final messages = [
          makeMessage(type: MessageType.user, content: 'Hi', id: 'user-1'),
          makeMessage(
            id: 'ai-1',
            type: MessageType.ai,
            content: 'Hello!',
            modelUsed: 'gemini-2.0-flash',
            metadata: {'parts_history': []},
          ),
        ];

        final result = await ConversationAiEngine.buildConversationMessages(
          messages: messages,
          currentModelId: 'gemini-2.0-flash',
          loadAttachments: noAttachments,
        );

        // Find the assistant message (skip timestamp context messages)
        final assistantMessages = result
            .where((m) => m.role == PromptRole.assistant)
            .toList();
        expect(assistantMessages, hasLength(1));
        expect(assistantMessages.first.content, 'Hello!');
      },
    );

    test(
      'same model (modelUsed in metadata matches current) keeps assistant role',
      () async {
        final messages = [
          makeMessage(
            id: 'ai-1',
            type: MessageType.ai,
            content: 'Hello!',
            // modelUsed NOT in DB column, only in metadata
            metadata: {'modelUsed': 'gemini-2.0-flash', 'parts_history': []},
          ),
        ];

        final result = await ConversationAiEngine.buildConversationMessages(
          messages: messages,
          currentModelId: 'gemini-2.0-flash',
          loadAttachments: noAttachments,
        );

        final assistantMessages = result
            .where((m) => m.role == PromptRole.assistant)
            .toList();
        expect(assistantMessages, hasLength(1));
      },
    );

    test('different model converts assistant to user role', () async {
      final messages = [
        makeMessage(
          id: 'ai-1',
          type: MessageType.ai,
          content: 'Hello from GPT!',
          modelUsed: 'gpt-4o',
          metadata: {'modelUsed': 'gpt-4o', 'parts_history': []},
        ),
      ];

      final result = await ConversationAiEngine.buildConversationMessages(
        messages: messages,
        currentModelId: 'gemini-2.0-flash',
        loadAttachments: noAttachments,
      );

      final assistantMessages = result
          .where((m) => m.role == PromptRole.assistant)
          .toList();
      expect(assistantMessages, isEmpty);

      // Should have been converted to user with prefix
      final userMessages = result
          .where((m) => m.role == PromptRole.user)
          .toList();
      expect(
        userMessages.any((m) => m.content.contains('[Response from gpt-4o]')),
        isTrue,
      );
    });

    test('null modelUsed (legacy) treated as different model', () async {
      final messages = [
        makeMessage(
          id: 'ai-1',
          type: MessageType.ai,
          content: 'Legacy response',
          // No modelUsed anywhere
          metadata: {'parts_history': []},
        ),
      ];

      final result = await ConversationAiEngine.buildConversationMessages(
        messages: messages,
        currentModelId: 'gemini-2.0-flash',
        loadAttachments: noAttachments,
      );

      final assistantMessages = result
          .where((m) => m.role == PromptRole.assistant)
          .toList();
      expect(assistantMessages, isEmpty);

      final userMessages = result
          .where((m) => m.role == PromptRole.user)
          .toList();
      expect(
        userMessages.any(
          (m) => m.content.contains('[Response from an earlier model]'),
        ),
        isTrue,
      );
    });

    test(
      'modelUsed in DB column but NOT in metadata gets injected into metadata',
      () async {
        final messages = [
          makeMessage(
            id: 'ai-1',
            type: MessageType.ai,
            content: 'Hello!',
            modelUsed: 'gemini-2.0-flash',
            // metadata has NO modelUsed key
            metadata: {'parts_history': []},
          ),
        ];

        final result = await ConversationAiEngine.buildConversationMessages(
          messages: messages,
          currentModelId: 'gemini-2.0-flash',
          loadAttachments: noAttachments,
        );

        final assistantMessages = result
            .where((m) => m.role == PromptRole.assistant)
            .toList();
        expect(assistantMessages, hasLength(1));
        // metadata should now contain modelUsed for downstream consumers
        expect(
          assistantMessages.first.metadata?['modelUsed'],
          'gemini-2.0-flash',
        );
      },
    );

    test(
      'same concrete Gemini config id preserves assistant parts history',
      () async {
        final partsHistory = [
          {
            'type': 'tool_call',
            'function_call': {
              'name': 'call_tool',
              'args': {
                'service_name': 'SkillTools',
                'tool_name': 'load_skill',
                'params': {'skillRef': 'knowledge-exploration'},
              },
            },
            'thought_signature': 'sig-1',
            'is_included': true,
          },
          {'type': 'text', 'text': 'Tool-based answer', 'is_included': true},
        ];
        final messages = [
          makeMessage(
            id: 'ai-1',
            type: MessageType.ai,
            content: 'Tool-based answer',
            modelUsed: 'gemini-3-1-flash-lite-config',
            metadata: {'parts_history': partsHistory},
          ),
        ];

        final result = await ConversationAiEngine.buildConversationMessages(
          messages: messages,
          currentModelId: 'gemini-3-1-flash-lite-config',
          loadAttachments: noAttachments,
        );

        final assistantMessages = result
            .where((m) => m.role == PromptRole.assistant)
            .toList();
        expect(assistantMessages, hasLength(1));
        expect(
          assistantMessages.first.metadata?['modelUsed'],
          'gemini-3-1-flash-lite-config',
        );
        expect(
          assistantMessages.first.metadata?['parts_history'],
          partsHistory,
        );
        expect(
          result.any((m) => m.content.contains('[Response from gemini]')),
          isFalse,
        );
      },
    );

    test(
      'legacy Gemini provider id is not treated as current concrete config',
      () async {
        final messages = [
          makeMessage(
            id: 'ai-1',
            type: MessageType.ai,
            content: 'Legacy Gemini response',
            modelUsed: 'gemini',
            metadata: {
              'modelUsed': 'gemini',
              'parts_history': [
                {
                  'type': 'text',
                  'text': 'Legacy Gemini response',
                  'is_included': true,
                },
              ],
            },
          ),
        ];

        final result = await ConversationAiEngine.buildConversationMessages(
          messages: messages,
          currentModelId: 'gemini-3-1-flash-lite-config',
          loadAttachments: noAttachments,
        );

        expect(result.where((m) => m.role == PromptRole.assistant), isEmpty);
        expect(
          result.any((m) => m.content.contains('[Response from gemini]')),
          isTrue,
        );
      },
    );

    test('synthesized error messages are filtered out', () async {
      final messages = [
        makeMessage(
          id: 'ai-1',
          type: MessageType.ai,
          content: 'Error occurred',
          metadata: {'isSynthesized': true},
        ),
      ];

      final result = await ConversationAiEngine.buildConversationMessages(
        messages: messages,
        currentModelId: 'gemini-2.0-flash',
        loadAttachments: noAttachments,
      );

      expect(result, isEmpty);
    });

    test('tool results injected when role stays assistant', () async {
      final toolCallsWithResults = [
        {
          'id': 'tc-1',
          'function_call': {'name': 'call_tool', 'args': {}},
          'result': 'Tool result text',
        },
      ];

      final messages = [
        makeMessage(
          id: 'ai-1',
          type: MessageType.ai,
          content: 'Let me call a tool',
          modelUsed: 'gemini-2.0-flash',
          metadata: {
            'modelUsed': 'gemini-2.0-flash',
            'parts_history': [],
            'tool_calls_with_results': toolCallsWithResults,
          },
        ),
      ];

      final result = await ConversationAiEngine.buildConversationMessages(
        messages: messages,
        currentModelId: 'gemini-2.0-flash',
        loadAttachments: noAttachments,
      );

      final toolMessages = result
          .where((m) => m.role == PromptRole.tool)
          .toList();
      expect(toolMessages, hasLength(1));
      expect(toolMessages.first.content, 'Tool result text');
    });

    test(
      'tool results NOT injected when model mismatch (role becomes user)',
      () async {
        final toolCallsWithResults = [
          {
            'id': 'tc-1',
            'function_call': {'name': 'call_tool', 'args': {}},
            'result': 'Tool result text',
          },
        ];

        final messages = [
          makeMessage(
            id: 'ai-1',
            type: MessageType.ai,
            content: 'Let me call a tool',
            modelUsed: 'gpt-4o',
            metadata: {
              'modelUsed': 'gpt-4o',
              'parts_history': [],
              'tool_calls_with_results': toolCallsWithResults,
            },
          ),
        ];

        final result = await ConversationAiEngine.buildConversationMessages(
          messages: messages,
          currentModelId: 'gemini-2.0-flash',
          loadAttachments: noAttachments,
        );

        final toolMessages = result
            .where((m) => m.role == PromptRole.tool)
            .toList();
        expect(toolMessages, isEmpty);
      },
    );

    test('user messages get timestamp context prepended', () async {
      final messages = [
        makeMessage(id: 'user-1', type: MessageType.user, content: 'Hello'),
      ];

      final result = await ConversationAiEngine.buildConversationMessages(
        messages: messages,
        currentModelId: 'gemini-2.0-flash',
        loadAttachments: noAttachments,
      );

      // Should have 2 user messages: timestamp context + actual message
      final userMessages = result
          .where((m) => m.role == PromptRole.user)
          .toList();
      expect(userMessages, hasLength(2));
      expect(userMessages.first.content, contains('Message created at:'));
      expect(userMessages.last.content, 'Hello');
    });

    test(
      'attachments loaded for user messages, empty for AI messages',
      () async {
        final testFile = PlatformFile(name: 'test.png', size: 100, bytes: null);

        final messages = [
          makeMessage(
            id: 'user-1',
            type: MessageType.user,
            content: 'Look at this',
          ),
          makeMessage(
            id: 'ai-1',
            type: MessageType.ai,
            content: 'I see it',
            modelUsed: 'gemini-2.0-flash',
            metadata: {'modelUsed': 'gemini-2.0-flash'},
          ),
        ];

        final result = await ConversationAiEngine.buildConversationMessages(
          messages: messages,
          currentModelId: 'gemini-2.0-flash',
          loadAttachments: (msg) async {
            if (msg.type == MessageType.user) return [testFile];
            return const [];
          },
        );

        // Find the actual user content message (not the timestamp context)
        final userContentMessages = result
            .where(
              (m) => m.role == PromptRole.user && m.content == 'Look at this',
            )
            .toList();
        expect(userContentMessages, hasLength(1));
        expect(userContentMessages.first.attachments, hasLength(1));

        // Assistant message should have no attachments
        final assistantMessages = result
            .where((m) => m.role == PromptRole.assistant)
            .toList();
        expect(assistantMessages, hasLength(1));
        expect(assistantMessages.first.attachments, isEmpty);
      },
    );
  });

  group('ConversationPromptBuilder attachment loading', () {
    late Directory tempDir;
    late ConversationPromptBuilder builder;

    ConversationMessage makeMessage({
      String id = 'user-1',
      MessageType type = MessageType.user,
      List<String> attachmentPaths = const [],
    }) {
      return ConversationMessage(
        id: id,
        conversationId: 'conv-1',
        type: type,
        content: 'message',
        timestamp: DateTime(2026, 3, 23, 10, 0),
        attachmentPaths: attachmentPaths,
      );
    }

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'conversation_prompt_builder_',
      );
      PathProviderPlatform.instance = _MockPathProviderPlatform(tempDir.path);
      builder = ConversationPromptBuilder(DatabaseService());
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('stored portable attachment path resolves and loads bytes', () async {
      final attachmentsDir = Directory('${tempDir.path}/attachments');
      await attachmentsDir.create();
      final file = File('${attachmentsDir.path}/stored.txt');
      await file.writeAsBytes(<int>[1, 2, 3]);
      final message = makeMessage(
        attachmentPaths: const ['attachments/stored.txt'],
      );

      final result = await builder.loadMessageAttachments(
        message: message,
        messageHistory: [message],
      );

      expect(result, hasLength(1));
      expect(result.single.name, 'stored.txt');
      expect(result.single.bytes, <int>[1, 2, 3]);
      expect(result.single.path, file.path);
    });

    test('URI attachments are preserved without loading bytes', () async {
      final message = makeMessage(
        attachmentPaths: const ['https://example.com/file.pdf'],
      );

      final result = await builder.loadMessageAttachments(
        message: message,
        messageHistory: [message],
      );

      expect(result, hasLength(1));
      expect(result.single.name, 'file.pdf');
      expect(result.single.path, 'https://example.com/file.pdf');
      expect(result.single.bytes, isNull);
    });

    test(
      'latest in-memory attachment is used for latest user message',
      () async {
        final file = File('${tempDir.path}/latest.png');
        await file.writeAsBytes(<int>[4, 5, 6]);
        final first = makeMessage(id: 'first');
        final latest = makeMessage(id: 'latest');

        final result = await builder.loadMessageAttachments(
          message: latest,
          messageHistory: [first, latest],
          latestUserAttachments: [
            PlatformFile(name: 'latest.png', path: file.path, size: 0),
          ],
        );

        expect(result, hasLength(1));
        expect(result.single.name, 'latest.png');
        expect(result.single.bytes, <int>[4, 5, 6]);
      },
    );

    test('AI messages return no attachments', () async {
      final message = makeMessage(
        type: MessageType.ai,
        attachmentPaths: const ['https://example.com/file.pdf'],
      );

      final result = await builder.loadMessageAttachments(
        message: message,
        messageHistory: [message],
      );

      expect(result, isEmpty);
    });
  });
}
