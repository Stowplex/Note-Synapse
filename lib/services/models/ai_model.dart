import 'package:file_picker/file_picker.dart';

import '../prompts/prompt_models.dart';
import '../prompts/system_prompt_builder.dart';
import '../../models/model_config.dart';

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
    String? requestId,
  }) {
    return generateWithMessages(
      request.buildFullMessageList(),
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxOutputTokens: maxOutputTokens,
      requestId: requestId,
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
    String? requestId,
  }) {
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
      requestId: requestId,
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
    String? requestId,
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
    String? requestId,
  }) async {
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
      requestId: requestId,
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
    String? requestId,
  }) {
    throw UnimplementedError('generateWithToolsAndMessages must be implemented.');
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
