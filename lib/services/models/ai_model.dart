import 'package:file_picker/file_picker.dart';

import '../prompts/prompt_models.dart';
import '../prompts/system_prompt_builder.dart';
import '../mcp_tool_integration_service.dart';
import '../../models/model_config.dart';
import '../../models/generation_context.dart';
import '../../models/mcp_endpoint.dart';

/// Base interface for AI models
abstract class AIModel {
  /// Model identifier
  String get id;

  /// Model display name
  String get name;

  /// Model description
  String get description;

  /// Check if model is ready to use
  Future<bool> isReady();

  /// Initialize the model
  Future<void> initialize({ModelConfig? config});

  /// High-level prompt execution entry point.
  Future<String> generateFromPrompt(
    PromptRequest request, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) {
    final context = generationContext ?? GenerationContext();
    return generateWithMessages(
      request.buildFullMessageList(),
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      generationContext: context,
    );
  }

  /// Generate text with optional attachments.
  Future<String> generateWithAttachments(
    String prompt,
    List<PlatformFile> attachedFiles, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) {
    final context = generationContext ?? GenerationContext();
    final request = PromptRequest.singleTurn(
      systemMessage: SystemPromptBuilder.build(
        taskContext:
            'You will receive user instructions as individual messages. Respond helpfully and note any limitations.',
      ),
      userMessage: PromptMessage(
        role: PromptRole.user,
        content: prompt,
        attachments: attachedFiles,
      ),
    );

    return generateFromPrompt(
      request,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      generationContext: context,
    );
  }

  /// Generate text using prompt messages list (system + context + history).
  ///
  /// NOTE: This method MUST be overridden by model implementations.
  Future<String> generateWithMessages(
    List<PromptMessage> messages, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) {
    throw UnimplementedError('generateWithMessages must be implemented.');
  }

  /// Generate with function calling support
  /// Returns raw response data that may contain function calls
  Future<Map<String, dynamic>> generateWithTools(
    String prompt,
    List<PlatformFile> attachedFiles,
    List<Map<String, dynamic>> tools, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) async {
    final context = generationContext ?? GenerationContext();
    final request = PromptRequest.singleTurn(
      systemMessage: SystemPromptBuilder.build(
        taskContext:
            'You may call external tools to fulfill the task. Decide when a tool is necessary before responding.',
      ),
      userMessage: PromptMessage(
        role: PromptRole.user,
        content: prompt,
        attachments: attachedFiles,
      ),
    );

    return generateWithToolsAndMessages(
      request.buildFullMessageList(),
      tools,
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      generationContext: context,
    );
  }

  /// Generate with function calling support using messages array
  /// Returns raw response data that may contain function calls
  /// 
  /// NOTE: This method MUST be overridden by model implementations.
  /// The default implementation throws an exception to prevent incorrect behavior.
  Future<Map<String, dynamic>> generateWithToolsAndMessages(
    List<PromptMessage> messages,
    List<Map<String, dynamic>> tools, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) {
    throw UnimplementedError('generateWithToolsAndMessages must be implemented.');
  }

  /// Whether this model receives tool descriptions via native declarations
  /// (true) or needs them in the system prompt text (false).
  ///
  /// When true, the text-based tool catalog (buildMcpSystemPrompt) should be
  /// skipped from the system prompt to avoid redundancy and save tokens.
  /// Tool declarations are delivered via [buildToolDeclarations] instead.
  bool get usesNativeToolDeclarations => false;

  /// Whether this model supports streaming text generation.
  bool get supportsStreaming => false;

  /// Build function declarations for tool calling.
  ///
  /// Each model type defines its own strategy. Default: single `call_tool`
  /// wrapper in Gemini format. Local models override to return individual
  /// per-tool declarations (matching Google Gallery's pattern).
  ///
  /// Tool description routing:
  /// - Cloud models: text catalog in system prompt + call_tool wrapper
  /// - Local models: native per-tool declarations only (no text catalog)
  /// - Mid-conversation: [buildToolDiscoveryMessage] for new tools
  List<Map<String, dynamic>> buildToolDeclarations(
    Map<String, List<McpTool>> toolsByEndpoint,
  ) {
    if (toolsByEndpoint.isEmpty) return [];
    return [
      McpToolIntegrationService.getCallToolFunctionForGemini(toolsByEndpoint),
    ];
  }

  /// Common utility methods for all AI models

  /// Get today's date, time, and timezone context string
  static String getTodayContext() {
    final now = DateTime.now();
    final localNow = now.toLocal();
    
    // Format date
    final dateStr = '${localNow.year}-${localNow.month.toString().padLeft(2, '0')}-${localNow.day.toString().padLeft(2, '0')}';
    
    // Format time
    final timeStr = '${localNow.hour.toString().padLeft(2, '0')}:${localNow.minute.toString().padLeft(2, '0')}:${localNow.second.toString().padLeft(2, '0')}';
    
    // Get timezone offset
    final offset = localNow.timeZoneOffset;
    final offsetHours = offset.inHours;
    final offsetMinutes = offset.inMinutes.remainder(60).abs();
    final offsetSign = offset.isNegative ? '-' : '+';
    final timezoneStr = 'UTC$offsetSign${offsetHours.abs().toString().padLeft(2, '0')}:${offsetMinutes.toString().padLeft(2, '0')}';
    
    return '\n\nCurrent date and time: $dateStr (${getDayOfWeek(localNow)}) $timeStr $timezoneStr';
  }

  /// Get day of week for a given date
  static String getDayOfWeek(DateTime date) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[date.weekday - 1];
  }
}
