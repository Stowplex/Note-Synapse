import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/services/conversation_ai_engine.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';

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
        makeMessage(
          type: MessageType.user,
          content: 'Hi',
          id: 'user-1',
        ),
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
      final assistantMessages =
          result.where((m) => m.role == PromptRole.assistant).toList();
      expect(assistantMessages, hasLength(1));
      expect(assistantMessages.first.content, 'Hello!');
    });

    test(
        'same model (modelUsed in metadata matches current) keeps assistant role',
        () async {
      final messages = [
        makeMessage(
          id: 'ai-1',
          type: MessageType.ai,
          content: 'Hello!',
          // modelUsed NOT in DB column, only in metadata
          metadata: {
            'modelUsed': 'gemini-2.0-flash',
            'parts_history': [],
          },
        ),
      ];

      final result = await ConversationAiEngine.buildConversationMessages(
        messages: messages,
        currentModelId: 'gemini-2.0-flash',
        loadAttachments: noAttachments,
      );

      final assistantMessages =
          result.where((m) => m.role == PromptRole.assistant).toList();
      expect(assistantMessages, hasLength(1));
    });

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

      final assistantMessages =
          result.where((m) => m.role == PromptRole.assistant).toList();
      expect(assistantMessages, isEmpty);

      // Should have been converted to user with prefix
      final userMessages =
          result.where((m) => m.role == PromptRole.user).toList();
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

      final assistantMessages =
          result.where((m) => m.role == PromptRole.assistant).toList();
      expect(assistantMessages, isEmpty);

      final userMessages =
          result.where((m) => m.role == PromptRole.user).toList();
      expect(
        userMessages
            .any((m) => m.content.contains('[Response from an earlier model]')),
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

      final assistantMessages =
          result.where((m) => m.role == PromptRole.assistant).toList();
      expect(assistantMessages, hasLength(1));
      // metadata should now contain modelUsed for downstream consumers
      expect(
        assistantMessages.first.metadata?['modelUsed'],
        'gemini-2.0-flash',
      );
    });

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

      final toolMessages =
          result.where((m) => m.role == PromptRole.tool).toList();
      expect(toolMessages, hasLength(1));
      expect(toolMessages.first.content, 'Tool result text');
    });

    test('tool results NOT injected when model mismatch (role becomes user)',
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

      final toolMessages =
          result.where((m) => m.role == PromptRole.tool).toList();
      expect(toolMessages, isEmpty);
    });

    test('user messages get timestamp context prepended', () async {
      final messages = [
        makeMessage(
          id: 'user-1',
          type: MessageType.user,
          content: 'Hello',
        ),
      ];

      final result = await ConversationAiEngine.buildConversationMessages(
        messages: messages,
        currentModelId: 'gemini-2.0-flash',
        loadAttachments: noAttachments,
      );

      // Should have 2 user messages: timestamp context + actual message
      final userMessages =
          result.where((m) => m.role == PromptRole.user).toList();
      expect(userMessages, hasLength(2));
      expect(userMessages.first.content, contains('Message created at:'));
      expect(userMessages.last.content, 'Hello');
    });

    test('attachments loaded for user messages, empty for AI messages',
        () async {
      final testFile = PlatformFile(
        name: 'test.png',
        size: 100,
        bytes: null,
      );

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
              (m) => m.role == PromptRole.user && m.content == 'Look at this')
          .toList();
      expect(userContentMessages, hasLength(1));
      expect(userContentMessages.first.attachments, hasLength(1));

      // Assistant message should have no attachments
      final assistantMessages =
          result.where((m) => m.role == PromptRole.assistant).toList();
      expect(assistantMessages, hasLength(1));
      expect(assistantMessages.first.attachments, isEmpty);
    });
  });
}
