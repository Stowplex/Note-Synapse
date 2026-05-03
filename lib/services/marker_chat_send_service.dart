import 'dart:async';

import 'package:file_picker/file_picker.dart';

import '../models/generation_context.dart';
import '../models/mcp_endpoint.dart';
import '../models/model_config.dart';
import '../models/note.dart';
import 'agent_service.dart';
import 'built_in_tools_service.dart';
import 'context_manager_service.dart';
import 'conversation_ai_engine.dart';
import 'conversation_service.dart';
import 'database_service.dart';
import 'logger_service.dart';
import 'mcp_service.dart';
import 'mcp_tool_integration_service.dart';
import 'model_selector.dart';
import 'prompts/ai_prompts.dart';
import 'prompts/note_prompt_builder.dart';
import 'prompts/prompt_configuration_service.dart';
import 'prompts/prompt_models.dart';
import 'prompts/registrations/chat_prompt_configuration.dart';
import 'prompts/system_prompt_builder.dart';
import 'service_locator.dart';

/// Send orchestration for the marker chat panel sheet.
///
/// Mirrors the immersive screen's `_generateAiResponse` chain but uses
/// auto-loaded defaults for tools/MCP/AI bundles (the marker sheet has
/// no per-session toggle UI). Runs `addUserMessage` then
/// `ConversationAiEngine.generate(...)` then `addAIResponse` with the
/// resulting `parts_history` metadata.
///
/// Marker-sheet defaults:
/// - All MCP endpoints with cached tools (auto)
/// - All native system tools from [AgentService] (auto)
/// - No attachments (marker sheet has no file picker)
/// - No scratchpad inclusion
/// - No drawing actions
/// - `maxToolIterations` = 8
///
/// NOT supported in marker sheet (deferred to v1.1):
/// - User-defined AI tool bundles (require [AppProvider] for runtime construction)
/// - Built-in "Agent" tool toggle (no UI surface in the sheet)
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
  Future<void> sendUserPrompt({
    required String conversationId,
    required String prompt,
    required AgentService agentService,
    ModelConfig? modelOverride,
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
      // 1. Persist the user message.
      await conversations.addUserMessage(
        conversationId: conversationId,
        content: prompt,
      );

      // 2. Resolve the conversation's notes for context.
      final conv = await conversations.getConversation(conversationId);
      final notes = <Note>[];
      for (final id in conv?.noteIds ?? const <String>[]) {
        final note = await db.getNote(id);
        if (note != null) notes.add(note);
      }

      // 3. Build active tools from auto-loaded defaults.
      final activeTools = await _loadActiveToolsMap(agentService);

      // 4. Build prompt request.
      final noteBuilder = NotePromptBuilder(db);
      final contextMessage = await noteBuilder.buildContextMessage(notes);
      final systemMessage = await _buildSystemPrompt(
        hasNotes: notes.isNotEmpty,
        activeTools: activeTools,
      );

      final messages = await db.getConversationMessages(conversationId);
      final convMessages = await ConversationAiEngine.buildConversationMessages(
        messages: messages,
        currentModelId: modelOverride?.id ??
            getIt<ModelSelector>().currentModelConfig?.id,
        // Marker sheet has no attachments — return empty for every message.
        loadAttachments: (_) async => const <PlatformFile>[],
      );

      final request = PromptRequest(
        systemMessage: systemMessage,
        contextMessages: contextMessage.content.trim().isEmpty &&
                contextMessage.attachments.isEmpty
            ? const []
            : [contextMessage],
        conversationMessages: convMessages,
      );

      // 5. Build executeTool dispatcher (system tools + MCP tools).
      final enabledMcpEndpointIds = await _loadEnabledMcpEndpointIds();
      Future<String> executeTool(
        String serviceName,
        String toolName,
        Map<String, dynamic> params,
        GenerationContext context,
      ) async {
        // System tools (native)
        if (serviceName == BuiltInToolsService.systemToolsServiceKey) {
          final nativeTool = agentService.nativeTools
              .where((t) => t.name == toolName)
              .firstOrNull;
          if (nativeTool != null) {
            final result = await nativeTool.execute(params);
            return result is String ? result : result.toString();
          }
          return 'Error: System tool "$toolName" not found';
        }
        // MCP tools (AI tool bundles aren't supported in the marker sheet —
        // see class doc comment).
        return McpToolIntegrationService.executeToolCall(
          serviceName: serviceName,
          toolName: toolName,
          parameters: params,
          enabledEndpointIds: enabledMcpEndpointIds,
          generationContext: context,
        );
      }

      // 6. Generate.
      final response = await _aiEngine.generate(
        request: request,
        activeTools: activeTools,
        enableTools: activeTools.isNotEmpty,
        executeTool: executeTool,
        isCancelled: () => _cancelledRequestIds.contains(requestId),
        generationContext: genCtx,
        maxToolIterations: 8,
        onStreamChunk: onStreamChunk,
      );

      // 7. Persist the AI message with full metadata.
      await conversations.addAIResponse(
        conversationId: conversationId,
        content: response.content,
        modelUsed: response.metadata?['modelUsed'] as String? ??
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

  /// Aggregates marker-sheet active tools. Auto-loads:
  /// - All MCP endpoints with cached tools
  /// - All native system tools from [AgentService]
  ///
  /// Built-in tools and AI tool bundles (the "Agent" toggle / per-app AI
  /// tools) are intentionally excluded — the marker sheet doesn't render
  /// that surface and AI bundles require a hosting AppProvider (deferred
  /// to v1.1).
  Future<Map<String, List<McpTool>>> _loadActiveToolsMap(
    AgentService agentService,
  ) async {
    final combined = <String, List<McpTool>>{};

    // MCP endpoints — service.name → cached tools
    try {
      final endpointIds = await _loadEnabledMcpEndpointIds();
      if (endpointIds.isNotEmpty) {
        final mcpTools =
            await McpToolIntegrationService.getAvailableTools(endpointIds);
        combined.addAll(mcpTools);
      }
    } catch (e) {
      LoggerService.warning(
        'MarkerChatSendService: MCP tool load failed (non-fatal): $e',
      );
    }

    // Native system tools
    final nativeTools = agentService.nativeTools;
    if (nativeTools.isNotEmpty) {
      combined[BuiltInToolsService.systemToolsServiceKey] = nativeTools
          .map((t) => McpTool(
                name: t.name,
                description: t.description,
                inputSchema: t.inputSchema,
              ))
          .toList(growable: false);
    }

    return combined;
  }

  /// Returns the IDs of all MCP endpoints that have cached tools — i.e. all
  /// endpoints that *would* show up in the immersive screen's MCP picker.
  Future<List<String>> _loadEnabledMcpEndpointIds() async {
    try {
      final endpoints = await getIt<McpService>().getEndpoints();
      final enabled = <String>[];
      for (final ep in endpoints) {
        final cache = await getIt<McpService>().getCachedTools(ep.id);
        if (cache != null && cache.tools.isNotEmpty) {
          enabled.add(ep.id);
        }
      }
      return enabled;
    } catch (e) {
      LoggerService.warning(
        'MarkerChatSendService: failed to enumerate MCP endpoints: $e',
      );
      return const [];
    }
  }

  /// Builds the system prompt mirroring the immersive screen's structure.
  Future<PromptMessage> _buildSystemPrompt({
    required bool hasNotes,
    required Map<String, List<McpTool>> activeTools,
  }) async {
    final hasTools = activeTools.isNotEmpty;
    final lines = <String>[
      'Engage in a focused conversation grounded in the selected notes and attachments.',
      'Reference the note titles when citing content and prefer concise, direct answers.',
      'Format your responses using markdown.',
    ];
    if (hasTools) {
      lines.add(
        'The user has enabled external tools (MCP services or user-defined AI tools). Prefer calling them when they can improve accuracy before responding.',
      );
    }
    if (!hasNotes) {
      lines.add(
        'No note text is attached inline. Use enabled tools when they can retrieve the needed note or workflow context.',
      );
    }
    final taskContext = lines.join('\n');

    final budget = await _getChatPromptBudget();
    final mcpToolsPrompt = McpToolIntegrationService.buildMcpSystemPrompt(
      activeTools,
      maxBudgetTokens: budget,
    );

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
    if (mcpToolsPrompt.trim().isNotEmpty) {
      contextBuffer
        ..writeln()
        ..writeln(mcpToolsPrompt.trim());
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

  Future<int> _getChatPromptBudget() async {
    try {
      return await getIt<ContextManagerService>().getModelContextBudget();
    } catch (_) {
      return getIt<ModelSelector>().currentModelConfig?.maxInputTokens ??
          100000;
    }
  }
}
