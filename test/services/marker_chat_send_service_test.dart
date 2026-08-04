import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/conversation_ai_engine.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/marker_chat_send_service.dart';
import 'package:note_synapse/services/mcp_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/tools/note_tools.dart';

import '../utils/test_prompt_template_setup.dart';
import 'marker_chat_send_service_test.mocks.dart';

/// Records the [ConversationAiEngine.generate] call args and returns a
/// canned response. Lets us assert what the service hands to the engine
/// without needing to mock a non-abstract class via mockito.
class _RecordingAiEngine extends ConversationAiEngine {
  _RecordingAiEngine({required this.responseToReturn, this.shouldThrow})
    : super();

  final ConversationAiResponse responseToReturn;
  final Object? shouldThrow;

  PromptRequest? capturedRequest;
  Map<String, List<McpTool>>? capturedActiveTools;
  bool? capturedEnableTools;
  int? capturedMaxToolIterations;
  void Function(String chunk)? capturedOnStreamChunk;

  @override
  Future<ConversationAiResponse> generate({
    required PromptRequest request,
    required Map<String, List<McpTool>> activeTools,
    ActiveToolsProvider? activeToolsProvider,
    required bool enableTools,
    required ToolExecutionCallback executeTool,
    required CancellationCheck isCancelled,
    required GenerationContext generationContext,
    int? maxToolIterations,
    IterationsExhaustedHandler? onIterationsExhausted,
    void Function(String chunk)? onStreamChunk,
  }) async {
    capturedRequest = request;
    capturedActiveTools = activeTools;
    capturedEnableTools = enableTools;
    capturedMaxToolIterations = maxToolIterations;
    capturedOnStreamChunk = onStreamChunk;
    if (shouldThrow != null) {
      throw shouldThrow!;
    }
    // Surface a chunk so we can assert the host-supplied stream callback fires.
    onStreamChunk?.call('partial-chunk');
    return responseToReturn;
  }
}

@GenerateMocks([
  ConversationService,
  DatabaseService,
  AgentService,
  McpService,
  ContextManagerService,
  ModelSelector,
])
void main() {
  late MockConversationService mockConv;
  late MockDatabaseService mockDb;
  late MockAgentService mockAgent;
  late MockMcpService mockMcp;
  late MockContextManagerService mockContext;
  late MockModelSelector mockSelector;

  setUpAll(() async {
    await registerTestPromptTemplateService();
  });

  setUp(() async {
    await resetForTesting();
    mockConv = MockConversationService();
    mockDb = MockDatabaseService();
    mockAgent = MockAgentService();
    mockMcp = MockMcpService();
    mockContext = MockContextManagerService();
    mockSelector = MockModelSelector();

    // Defaults: empty environment.
    when(
      mockConv.getConversation(any),
    ).thenAnswer((_) async => _stubConversation('c1'));
    when(
      mockConv.getConversationNotes(any),
    ).thenAnswer((_) async => const <Note>[]);
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});
    when(
      mockConv.addUserMessage(
        conversationId: anyNamed('conversationId'),
        content: anyNamed('content'),
      ),
    ).thenAnswer((_) async => _stubMessage('u-1', MessageType.user));
    when(
      mockConv.addAIResponse(
        conversationId: anyNamed('conversationId'),
        content: anyNamed('content'),
        modelUsed: anyNamed('modelUsed'),
        metadata: anyNamed('metadata'),
      ),
    ).thenAnswer((_) async => _stubMessage('ai-1', MessageType.ai));
    when(mockDb.getConversationMessages(any)).thenAnswer((_) async => const []);
    when(mockDb.getAttachmentsForNote(any)).thenAnswer((_) async => const []);
    when(mockDb.getRelationships(any)).thenAnswer((_) async => const []);
    when(mockDb.getNotesByTag(any)).thenAnswer((_) async => const []);
    when(mockMcp.getEndpoints()).thenAnswer((_) async => const []);
    when(mockContext.getModelContextBudget()).thenAnswer((_) async => 50000);
    when(mockSelector.currentModelConfig).thenReturn(null);
    when(mockAgent.nativeTools).thenReturn(const []);

    // Re-register the prompt template service that resetForTesting cleared.
    await registerTestPromptTemplateService();
    getIt.registerSingleton<ConversationService>(mockConv);
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<McpService>(mockMcp);
    getIt.registerSingleton<ContextManagerService>(mockContext);
    getIt.registerSingleton<ModelSelector>(mockSelector);
    getIt.registerSingleton<SkillService>(SkillService(mockDb));
  });

  tearDown(() async {
    await resetForTesting();
  });

  test('addUserMessage is called with the prompt before generation', () async {
    final engine = _RecordingAiEngine(
      responseToReturn: const ConversationAiResponse(content: 'Reply.'),
    );
    final svc = MarkerChatSendService(aiEngine: engine);

    var completedFired = false;
    await svc.sendUserPrompt(
      conversationId: 'c1',
      prompt: 'Hello?',
      agentService: mockAgent,
      onStreamChunk: (_) {},
      onCompleted: () => completedFired = true,
    );

    verify(
      mockConv.addUserMessage(conversationId: 'c1', content: 'Hello?'),
    ).called(1);
    expect(engine.capturedRequest, isNotNull);
    expect(completedFired, isTrue);
  });

  test(
    'continueAfterExistingUserPrompt does not add a duplicate user prompt',
    () async {
      final engine = _RecordingAiEngine(
        responseToReturn: const ConversationAiResponse(content: 'Reply.'),
      );
      final svc = MarkerChatSendService(aiEngine: engine);

      var completedFired = false;
      await svc.continueAfterExistingUserPrompt(
        conversationId: 'c1',
        agentService: mockAgent,
        onStreamChunk: (_) {},
        onCompleted: () => completedFired = true,
      );

      verifyNever(
        mockConv.addUserMessage(
          conversationId: anyNamed('conversationId'),
          content: anyNamed('content'),
        ),
      );
      verify(
        mockConv.addAIResponse(
          conversationId: 'c1',
          content: 'Reply.',
          modelUsed: anyNamed('modelUsed'),
          metadata: anyNamed('metadata'),
        ),
      ).called(1);
      expect(completedFired, isTrue);
    },
  );

  test(
    'engine.generate is invoked with maxToolIterations=8 and built request',
    () async {
      final engine = _RecordingAiEngine(
        responseToReturn: const ConversationAiResponse(content: 'Reply.'),
      );
      final svc = MarkerChatSendService(aiEngine: engine);

      await svc.sendUserPrompt(
        conversationId: 'c1',
        prompt: 'q',
        agentService: mockAgent,
        onStreamChunk: (_) {},
        onCompleted: () {},
      );

      expect(engine.capturedMaxToolIterations, 8);
      expect(
        engine.capturedEnableTools,
        isFalse,
        reason: 'No tools wired in the default mock environment',
      );
      expect(engine.capturedActiveTools, isEmpty);
      expect(engine.capturedRequest!.systemMessage.role, PromptRole.system);
    },
  );

  test(
    'marker sends keep tools disabled even when native tools exist',
    () async {
      final engine = _RecordingAiEngine(
        responseToReturn: const ConversationAiResponse(content: 'Reply.'),
      );
      final svc = MarkerChatSendService(aiEngine: engine);
      when(mockAgent.nativeTools).thenReturn([_FakeNativeTool()]);

      await svc.sendUserPrompt(
        conversationId: 'c1',
        prompt: 'q',
        agentService: mockAgent,
        onStreamChunk: (_) {},
        onCompleted: () {},
      );

      expect(engine.capturedEnableTools, isFalse);
      expect(engine.capturedActiveTools, isEmpty);
      verifyNever(mockMcp.getEndpoints());
    },
  );

  test('marker sends use mapped conversation notes for context', () async {
    final engine = _RecordingAiEngine(
      responseToReturn: const ConversationAiResponse(content: 'Reply.'),
    );
    final svc = MarkerChatSendService(aiEngine: engine);
    when(
      mockConv.getConversation('c1'),
    ).thenAnswer((_) async => _stubConversation('c1', noteIds: const []));
    when(
      mockConv.getConversationNotes('c1'),
    ).thenAnswer((_) async => [_stubContextNote()]);

    await svc.continueAfterExistingUserPrompt(
      conversationId: 'c1',
      agentService: mockAgent,
      onStreamChunk: (_) {},
      onCompleted: () {},
    );

    verify(mockConv.getConversationNotes('c1')).called(1);
    expect(engine.capturedRequest!.contextMessages, hasLength(1));
    expect(
      engine.capturedRequest!.contextMessages.single.content,
      contains('Mapped Note'),
    );
  });

  test('marker sends rehydrate stored user message attachments', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'marker_send_attachment_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final image = File('${tempDir.path}/marker.png');
    await image.writeAsBytes(<int>[1, 2, 3, 4]);

    final engine = _RecordingAiEngine(
      responseToReturn: const ConversationAiResponse(content: 'Reply.'),
    );
    final svc = MarkerChatSendService(aiEngine: engine);
    when(mockDb.getConversationMessages('c1')).thenAnswer(
      (_) async => [
        ConversationMessage(
          id: 'u-with-image',
          conversationId: 'c1',
          type: MessageType.user,
          content: 'explain',
          timestamp: DateTime.now(),
          attachmentPaths: [image.path, '${tempDir.path}/missing.png'],
        ),
      ],
    );

    await svc.continueAfterExistingUserPrompt(
      conversationId: 'c1',
      agentService: mockAgent,
      onStreamChunk: (_) {},
      onCompleted: () {},
    );

    final promptMessage = engine.capturedRequest!.conversationMessages
        .where((m) => m.content == 'explain')
        .single;
    expect(promptMessage.attachments, hasLength(1));
    expect(promptMessage.attachments.single.name, 'marker.png');
    expect(promptMessage.attachments.single.bytes, <int>[1, 2, 3, 4]);
  });

  test('onStreamChunk callback fires with engine-supplied chunks', () async {
    final engine = _RecordingAiEngine(
      responseToReturn: const ConversationAiResponse(content: 'Done.'),
    );
    final svc = MarkerChatSendService(aiEngine: engine);

    final chunks = <String>[];
    await svc.sendUserPrompt(
      conversationId: 'c1',
      prompt: 'q',
      agentService: mockAgent,
      onStreamChunk: chunks.add,
      onCompleted: () {},
    );

    expect(chunks, ['partial-chunk']);
  });

  test(
    'addAIResponse persists the engine response content + metadata',
    () async {
      final engine = _RecordingAiEngine(
        responseToReturn: const ConversationAiResponse(
          content: 'Final answer.',
          metadata: {'parts_history': [], 'modelUsed': 'gemini-2.0-flash'},
        ),
      );
      final svc = MarkerChatSendService(aiEngine: engine);

      await svc.sendUserPrompt(
        conversationId: 'c1',
        prompt: 'q',
        agentService: mockAgent,
        onStreamChunk: (_) {},
        onCompleted: () {},
      );

      final captured = verify(
        mockConv.addAIResponse(
          conversationId: 'c1',
          content: captureAnyNamed('content'),
          modelUsed: captureAnyNamed('modelUsed'),
          metadata: captureAnyNamed('metadata'),
        ),
      ).captured;
      expect(captured[0], 'Final answer.');
      expect(captured[1], 'gemini-2.0-flash');
      expect(captured[2], isA<Map<String, dynamic>>());
      expect((captured[2] as Map)['modelUsed'], 'gemini-2.0-flash');
    },
  );

  test(
    'onCompleted fires in the finally block even when the engine throws',
    () async {
      final engine = _RecordingAiEngine(
        responseToReturn: const ConversationAiResponse(content: ''),
        shouldThrow: Exception('boom'),
      );
      final svc = MarkerChatSendService(aiEngine: engine);

      var completedFired = false;
      await expectLater(
        () => svc.sendUserPrompt(
          conversationId: 'c1',
          prompt: 'q',
          agentService: mockAgent,
          onStreamChunk: (_) {},
          onCompleted: () => completedFired = true,
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        completedFired,
        isTrue,
        reason: 'finally block must fire onCompleted even on failure',
      );
      // addAIResponse must NOT be called when generation failed.
      verifyNever(
        mockConv.addAIResponse(
          conversationId: anyNamed('conversationId'),
          content: anyNamed('content'),
          modelUsed: anyNamed('modelUsed'),
          metadata: anyNamed('metadata'),
        ),
      );
    },
  );

  test(
    'system prompt includes skill default actions for marker sends',
    () async {
      final engine = _RecordingAiEngine(
        responseToReturn: const ConversationAiResponse(content: 'Reply.'),
      );
      final svc = MarkerChatSendService(aiEngine: engine);
      when(mockDb.getNotesByTag('agent-skill')).thenAnswer(
        (_) async => [
          _stubSkillNote('''---
name: Knowledge Exploration
skill_ref: knowledge-exploration
description: Use when explaining concepts.
enabled: true
default_action: |
  Emit a fenced chips block after explanations.
---
Skill body.
'''),
        ],
      );

      await svc.sendNewUserPrompt(
        conversationId: 'c1',
        prompt: 'Explain entropy',
        agentService: mockAgent,
        onStreamChunk: (_) {},
        onCompleted: () {},
      );

      final system = engine.capturedRequest!.systemMessage.content;
      expect(system, contains('## Skill Default Actions'));
      expect(system, contains('knowledge-exploration'));
      expect(system, contains('fenced chips block'));
    },
  );

  test(
    'system prompt asks pending fork conversations for a title directive',
    () async {
      final engine = _RecordingAiEngine(
        responseToReturn: const ConversationAiResponse(content: 'Reply.'),
      );
      final svc = MarkerChatSendService(aiEngine: engine);
      when(mockConv.getConversation('c1')).thenAnswer(
        (_) async =>
            _stubConversation('c1').copyWith(title: 'Forked conversation'),
      );

      await svc.continueAfterExistingUserPrompt(
        conversationId: 'c1',
        agentService: mockAgent,
        onStreamChunk: (_) {},
        onCompleted: () {},
      );

      final system = engine.capturedRequest!.systemMessage.content;
      expect(system, contains('```conversation-title'));
      expect(system, contains('short-kebab-case-slug'));
    },
  );
}

Conversation _stubConversation(String id, {List<String> noteIds = const []}) {
  final now = DateTime.now();
  return Conversation(
    id: id,
    title: 'T',
    noteIds: noteIds,
    createdAt: now,
    updatedAt: now,
  );
}

ConversationMessage _stubMessage(String id, MessageType type) {
  return ConversationMessage(
    id: id,
    conversationId: 'c1',
    type: type,
    content: '',
    timestamp: DateTime.now(),
  );
}

Note _stubSkillNote(String content) {
  final now = DateTime.now();
  return Note(
    id: 'skill-note',
    title: 'Knowledge Exploration',
    content: content,
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
    tags: const ['agent-skill'],
    attachmentPaths: const [],
    subNotes: const [],
  );
}

Note _stubContextNote() {
  final now = DateTime.now();
  return Note(
    id: 'mapped-note',
    title: 'Mapped Note',
    content: 'Mapped note content.',
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
    tags: const [],
    attachmentPaths: const [],
    subNotes: const [],
  );
}

class _FakeNativeTool implements NativeTool {
  @override
  String get name => 'read_note';

  @override
  String get description => 'Read a note';

  @override
  bool get isMutating => false;

  @override
  Map<String, dynamic> get inputSchema => const {};

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async => 'unused';
}
