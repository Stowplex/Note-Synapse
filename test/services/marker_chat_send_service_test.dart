import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
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

import '../utils/test_prompt_template_setup.dart';
import 'marker_chat_send_service_test.mocks.dart';

/// Records the [ConversationAiEngine.generate] call args and returns a
/// canned response. Lets us assert what the service hands to the engine
/// without needing to mock a non-abstract class via mockito.
class _RecordingAiEngine extends ConversationAiEngine {
  _RecordingAiEngine({
    required this.responseToReturn,
    this.shouldThrow,
  }) : super();

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
    when(mockConv.getConversation(any))
        .thenAnswer((_) async => _stubConversation('c1'));
    when(mockConv.addUserMessage(
      conversationId: anyNamed('conversationId'),
      content: anyNamed('content'),
    )).thenAnswer((_) async => _stubMessage('u-1', MessageType.user));
    when(mockConv.addAIResponse(
      conversationId: anyNamed('conversationId'),
      content: anyNamed('content'),
      modelUsed: anyNamed('modelUsed'),
      metadata: anyNamed('metadata'),
    )).thenAnswer((_) async => _stubMessage('ai-1', MessageType.ai));
    when(mockDb.getConversationMessages(any)).thenAnswer((_) async => const []);
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

    verify(mockConv.addUserMessage(
      conversationId: 'c1',
      content: 'Hello?',
    )).called(1);
    expect(engine.capturedRequest, isNotNull);
    expect(completedFired, isTrue);
  });

  test('engine.generate is invoked with maxToolIterations=8 and built request',
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
    expect(engine.capturedEnableTools, isFalse,
        reason: 'No tools wired in the default mock environment');
    expect(engine.capturedActiveTools, isEmpty);
    expect(engine.capturedRequest!.systemMessage.role, PromptRole.system);
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

  test('addAIResponse persists the engine response content + metadata',
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

    final captured = verify(mockConv.addAIResponse(
      conversationId: 'c1',
      content: captureAnyNamed('content'),
      modelUsed: captureAnyNamed('modelUsed'),
      metadata: captureAnyNamed('metadata'),
    )).captured;
    expect(captured[0], 'Final answer.');
    expect(captured[1], 'gemini-2.0-flash');
    expect(captured[2], isA<Map<String, dynamic>>());
    expect((captured[2] as Map)['modelUsed'], 'gemini-2.0-flash');
  });

  test('onCompleted fires in the finally block even when the engine throws',
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
    expect(completedFired, isTrue,
        reason: 'finally block must fire onCompleted even on failure');
    // addAIResponse must NOT be called when generation failed.
    verifyNever(mockConv.addAIResponse(
      conversationId: anyNamed('conversationId'),
      content: anyNamed('content'),
      modelUsed: anyNamed('modelUsed'),
      metadata: anyNamed('metadata'),
    ));
  });
}

Conversation _stubConversation(String id) {
  final now = DateTime.now();
  return Conversation(
    id: id,
    title: 'T',
    noteIds: const [],
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
