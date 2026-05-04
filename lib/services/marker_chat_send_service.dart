import '../models/conversation.dart';
import '../models/generation_context.dart';
import '../models/mcp_endpoint.dart';
import '../models/model_config.dart';
import 'agent_service.dart';
import 'conversation_ai_engine.dart';
import 'conversation_prompt_builder.dart';
import 'conversation_service.dart';
import 'database_service.dart';
import 'logger_service.dart';
import 'model_selector.dart';
import 'prompts/ai_prompts.dart';
import 'prompts/prompt_configuration_service.dart';
import 'prompts/prompt_models.dart';
import 'prompts/registrations/chat_prompt_configuration.dart';
import 'prompts/system_prompt_builder.dart';
import 'service_locator.dart';
import 'skill_service.dart';
import '../utils/conversation_title_directive.dart';

/// Send orchestration for the marker chat panel sheet.
///
/// Mirrors the immersive screen's `_generateAiResponse` chain but uses
/// the immersive screen's context construction. Runs `addUserMessage` then
/// `ConversationAiEngine.generate(...)` then `addAIResponse` with the resulting
/// `parts_history` metadata.
///
/// Marker-sheet defaults:
/// - No tools unless a future marker UI explicitly enables them
/// - Stored conversation attachments are rehydrated for user messages
/// - No scratchpad inclusion
/// - No drawing actions
/// - `maxToolIterations` = 8
///
/// NOT supported in marker sheet (deferred to v1.1):
/// - MCP / native / built-in / AI tool toggles (no UI surface in the sheet)
/// - User-defined AI tool bundles (require [AppProvider] for runtime construction)
class MarkerChatSendService {
  MarkerChatSendService({ConversationAiEngine? aiEngine})
    : _aiEngine = aiEngine ?? const ConversationAiEngine();

  final ConversationAiEngine _aiEngine;
  final Set<String> _cancelledRequestIds = <String>{};

  /// Send [prompt] as a new user message in [conversationId], then generate
  /// the AI reply. Streams partial AI text via [onStreamChunk] (host updates
  /// `streamingContent`). On completion (success OR error), [onCompleted]
  /// fires — host should refresh ChatPanel via reload().
  ///
  /// [agentService] is passed in (rather than read from getIt) because it
  /// lives in the Provider tree and may have native-tool config from the
  /// hosting screen.
  Future<void> sendNewUserPrompt({
    required String conversationId,
    required String prompt,
    required AgentService agentService,
    ModelConfig? modelOverride,
    int? currentPdfPage,
    required void Function(String chunk) onStreamChunk,
    required void Function() onCompleted,
  }) async {
    final conversations = getIt<ConversationService>();
    await conversations.addUserMessage(
      conversationId: conversationId,
      content: prompt,
    );
    await continueAfterExistingUserPrompt(
      conversationId: conversationId,
      agentService: agentService,
      modelOverride: modelOverride,
      currentPdfPage: currentPdfPage,
      onStreamChunk: onStreamChunk,
      onCompleted: onCompleted,
    );
  }

  /// Backwards-compatible alias for older callers. New code should prefer
  /// [sendNewUserPrompt] so chip callbacks can explicitly use
  /// [continueAfterExistingUserPrompt] and avoid duplicate prompts.
  Future<void> sendUserPrompt({
    required String conversationId,
    required String prompt,
    required AgentService agentService,
    ModelConfig? modelOverride,
    int? currentPdfPage,
    required void Function(String chunk) onStreamChunk,
    required void Function() onCompleted,
  }) {
    return sendNewUserPrompt(
      conversationId: conversationId,
      prompt: prompt,
      agentService: agentService,
      modelOverride: modelOverride,
      currentPdfPage: currentPdfPage,
      onStreamChunk: onStreamChunk,
      onCompleted: onCompleted,
    );
  }

  /// Generate the AI reply for [conversationId] after the latest user message
  /// has already been persisted. Used by chip taps, which fork and write the
  /// chip prompt before asking the host to continue.
  Future<void> continueAfterExistingUserPrompt({
    required String conversationId,
    required AgentService agentService,
    ModelConfig? modelOverride,
    int? currentPdfPage,
    required void Function(String chunk) onStreamChunk,
    required void Function() onCompleted,
  }) async {
    final conversations = getIt<ConversationService>();
    final db = getIt<DatabaseService>();

    final genCtx = GenerationContext();
    if (modelOverride != null) {
      genCtx.modelOverride = modelOverride;
    }
    final requestId = genCtx.ensureRequestId();

    try {
      // 1. Resolve the conversation's notes for context.
      final conversation = await conversations.getConversation(conversationId);
      final notes = await conversations.getConversationNotes(conversationId);

      // 2. Marker sheets have no tool picker; keep tools disabled by default.
      const activeTools = <String, List<McpTool>>{};

      // 3. Build prompt request.
      final promptBuilder = ConversationPromptBuilder(db);
      final contextMessage = await promptBuilder.buildNoteContextMessage(
        notes,
        currentPdfPage: currentPdfPage,
      );
      final systemMessage = await _buildSystemPrompt(
        hasNotes: notes.isNotEmpty,
        activeTools: activeTools,
        requestForkTitle: ConversationTitleDirective.shouldRequestTitle(
          conversation,
        ),
      );

      final messages = await db.getConversationMessages(conversationId);
      final convMessages = await promptBuilder.buildConversationMessages(
        messages: messages,
        currentModelId:
            modelOverride?.id ?? getIt<ModelSelector>().currentModelConfig?.id,
      );

      final request = PromptRequest(
        systemMessage: systemMessage,
        contextMessages: contextMessage == null ? const [] : [contextMessage],
        conversationMessages: convMessages,
      );

      // 4. Tools are intentionally disabled for marker sheets until the UI has
      // an explicit tool-selection surface.
      Future<String> executeTool(
        String serviceName,
        String toolName,
        Map<String, dynamic> params,
        GenerationContext context,
      ) async {
        return 'Error: tools are disabled for marker conversations.';
      }

      // 5. Generate.
      final response = await _aiEngine.generate(
        request: request,
        activeTools: activeTools,
        enableTools: false,
        executeTool: executeTool,
        isCancelled: () => _cancelledRequestIds.contains(requestId),
        generationContext: genCtx,
        maxToolIterations: 8,
        onStreamChunk: onStreamChunk,
      );

      // 6. Persist the AI message with full metadata.
      await conversations.addAIResponse(
        conversationId: conversationId,
        content: response.content,
        modelUsed:
            response.metadata?['modelUsed'] as String? ??
            modelOverride?.id ??
            getIt<ModelSelector>().currentModelConfig?.id,
        metadata: response.metadata,
      );
    } on ConversationCancelledException {
      LoggerService.info('MarkerChatSendService: request $requestId cancelled');
      rethrow;
    } catch (e, st) {
      LoggerService.error(
        'MarkerChatSendService: send failed: $e',
        error: e,
        stackTrace: st,
      );
      rethrow;
    } finally {
      _cancelledRequestIds.remove(requestId);
      onCompleted();
    }
  }

  /// Marks a request as cancelled. The in-flight engine call will see this
  /// via the cancellation check on its next poll and throw
  /// [ConversationCancelledException]. Currently unused by [MarkerChatPanelHost]
  /// (no abort button in the marker sheet) but exposed for future wiring.
  void cancelRequest(String requestId) {
    _cancelledRequestIds.add(requestId);
  }

  /// Builds the system prompt mirroring the immersive screen's structure.
  Future<PromptMessage> _buildSystemPrompt({
    required bool hasNotes,
    required Map<String, List<McpTool>> activeTools,
    required bool requestForkTitle,
  }) async {
    final hasTools = activeTools.isNotEmpty;
    final lines = <String>[
      'Engage in a focused conversation grounded in the selected notes and attachments.',
      'Reference the note titles when citing content and prefer concise, direct answers.',
      'Format your responses using markdown.',
    ];
    if (requestForkTitle) {
      lines.add(ConversationTitleDirective.promptInstruction);
    }
    if (hasTools) {
      lines.add(
        'The user has enabled external tools (MCP services or user-defined AI tools). Prefer calling them when they can improve accuracy before responding.',
      );
    }
    if (!hasNotes) {
      lines.add(
        'No note text is attached inline. Rely on the conversation history and your own knowledge.',
      );
    }
    final taskContext = lines.join('\n');

    final systemAddOn = PromptConfigurationService.instance.getValue(
      ChatPromptConfiguration.systemAddendumId,
    );
    final contextBuffer = StringBuffer(taskContext);
    if (systemAddOn != null && systemAddOn.trim().isNotEmpty) {
      contextBuffer
        ..writeln()
        ..writeln('User-defined conversation guidance:')
        ..writeln(systemAddOn.trim());
    }
    final skillPrompt = await _buildSkillPromptSection();
    if (skillPrompt.trim().isNotEmpty) {
      contextBuffer
        ..writeln()
        ..writeln(skillPrompt.trim());
    }

    return SystemPromptBuilder.build(
      taskContext: contextBuffer.toString(),
      guidelines: [
        'Highlight referenced note sections explicitly when possible.',
        if (hasNotes) AIPrompts.relationshipGuidelines,
        if (hasNotes) AIPrompts.promptInjectionProtectionGuidelines,
      ],
      now: DateTime.now(),
      needTimeInContext: false,
    );
  }

  Future<String> _buildSkillPromptSection() async {
    try {
      final skillService = getIt<SkillService>();
      final conversationService = getIt<ConversationService>();
      final index = conversationService.skillsEnabled
          ? conversationService.skillIndex
          : await skillService.buildSkillIndex();
      if (index.isEmpty) return '';
      final budget =
          getIt<ModelSelector>().currentModelConfig?.maxInputTokens ?? 100000;
      final skillIndexPrompt = skillService.buildSkillIndexPrompt(
        index,
        maxBudgetTokens: budget,
      );
      final defaultActions = skillService.buildDefaultActionPromptSection(
        index,
      );
      return [
        if (skillIndexPrompt.trim().isNotEmpty) skillIndexPrompt.trim(),
        if (defaultActions.trim().isNotEmpty) defaultActions.trim(),
      ].join('\n\n');
    } catch (e) {
      LoggerService.warning(
        'MarkerChatSendService: skill prompt build failed (non-fatal): $e',
      );
      return '';
    }
  }
}
