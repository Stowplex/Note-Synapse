import 'dart:async';

import '../models/mcp_endpoint.dart';
import '../models/model_type.dart';
import '../models/generation_context.dart';
import '../services/logger_service.dart';
import '../services/mcp_tool_integration_service.dart';
import '../services/model_selector.dart';
import '../services/service_locator.dart';
import '../services/prompts/prompt_models.dart';
import 'conversation_settings_service.dart';

class ConversationCancelledException implements Exception {
  const ConversationCancelledException([
    this.message = 'Request cancelled by user',
  ]);

  final String message;

  @override
  String toString() => message;
}

class ConversationAiResponse {
  const ConversationAiResponse({required this.content, this.metadata});

  final String content;
  final Map<String, dynamic>? metadata;
}

typedef ToolExecutionCallback =
    Future<String> Function(
      String serviceName,
      String toolName,
      Map<String, dynamic> params,
      GenerationContext generationContext,
    );

typedef CancellationCheck = bool Function();
typedef IterationsExhaustedHandler = Future<int?> Function(int exhaustedLimit);

class ConversationAiEngine {
  const ConversationAiEngine();

  Future<ConversationAiResponse> generate({
    required PromptRequest request,
    required Map<String, List<McpTool>> activeTools,
    required bool enableTools,
    required ToolExecutionCallback executeTool,
    required CancellationCheck isCancelled,
    required GenerationContext generationContext,
    int? maxToolIterations,
    IterationsExhaustedHandler? onIterationsExhausted,
  }) async {
    if (isCancelled()) {
      throw const ConversationCancelledException();
    }

    // Always use the tool-enabled path to ensure consistent handling of parts_history
    // and other metadata, even if no tools are active.
    return _generateWithTools(
      request: request,
      activeTools: activeTools,
      executeTool: executeTool,
      isCancelled: isCancelled,
      generationContext: generationContext,
      maxToolIterations: maxToolIterations,
      onIterationsExhausted: onIterationsExhausted,
    );
  }

  Future<ConversationAiResponse> _generateWithTools({
    required PromptRequest request,
    required Map<String, List<McpTool>> activeTools,
    required ToolExecutionCallback executeTool,
    required CancellationCheck isCancelled,
    required GenerationContext generationContext,
    int? maxToolIterations,
    IterationsExhaustedHandler? onIterationsExhausted,
  }) async {
    try {
      final requestId = generationContext.ensureRequestId();
      if (isCancelled()) {
        throw const ConversationCancelledException();
      }

      var currentMessages = <PromptMessage>[
        request.systemMessage,
        ...request.contextMessages,
        ...request.conversationMessages,
      ];

      final modelType = getIt<ModelSelector>().currentModelConfig?.type;
      final callToolFunction = modelType == ModelType.openaiCompatible
          ? McpToolIntegrationService.getCallToolFunctionForOpenAI(activeTools)
          : McpToolIntegrationService.getCallToolFunctionForGemini(activeTools);

      LoggerService.info(
        'Starting conversation with ${activeTools.length} tools',
        error: {'requestId': requestId},
      );

      int iterationLimit =
          maxToolIterations ??
          ConversationSettingsService.defaultMaxToolIterations;
      iterationLimit =
          iterationLimit < ConversationSettingsService.minToolIterations
          ? ConversationSettingsService.minToolIterations
          : (iterationLimit > ConversationSettingsService.maxToolIterationsCap
                ? ConversationSettingsService.maxToolIterationsCap
                : iterationLimit);
      var iteration = 0;
      final conversationParts = <String>[];
      Map<String, dynamic>? lastAssistantMetadata;

      while (true) {
        if (iteration >= iterationLimit) {
          if (onIterationsExhausted != null) {
            final nextLimit = await onIterationsExhausted(iterationLimit);
            if (nextLimit == null) {
              throw const ConversationCancelledException(
                'Tool iteration limit reached and user aborted.',
              );
            }
            final sanitizedNext =
                nextLimit < ConversationSettingsService.minToolIterations
                ? ConversationSettingsService.minToolIterations
                : (nextLimit > ConversationSettingsService.maxToolIterationsCap
                      ? ConversationSettingsService.maxToolIterationsCap
                      : nextLimit);
            if (sanitizedNext <= iterationLimit) {
              LoggerService.warning(
                'Rejected iteration limit $nextLimit (must be greater than $iterationLimit)',
              );
              continue;
            }
            iterationLimit = sanitizedNext;
            continue;
          }

          LoggerService.warning(
            'MCP tool loop exceeded $iterationLimit iterations',
          );
          return const ConversationAiResponse(
            content:
                'I was unable to complete the request with the available tools. Please try again later.',
            metadata: {'isSynthesized': true},
          );
        }

        if (isCancelled()) {
          throw const ConversationCancelledException();
        }

        LoggerService.debug('MCP iteration ${iteration + 1}/$iterationLimit');

        final response = await getIt<ModelSelector>()
            .generateWithToolsAndMessages(currentMessages, [
              if (activeTools.isNotEmpty) callToolFunction,
            ], generationContext: generationContext);

        if (isCancelled()) {
          throw const ConversationCancelledException();
        }

        final textResponse = response['text'] as String?;
        final functionCalls = response['function_calls'] as List?;
        final partsHistory = response['parts_history'] as List?;

        if (functionCalls != null && functionCalls.isNotEmpty) {
          LoggerService.info(
            'AI requested ${functionCalls.length} tool call(s)',
          );

          final toolResults = <String>[];
          final toolCallsWithResults = <Map<String, dynamic>>[];

          for (int i = 0; i < functionCalls.length; i++) {
            if (isCancelled()) {
              throw const ConversationCancelledException();
            }

            final functionCall = functionCalls[i] as Map<String, dynamic>;
            final functionName = functionCall['name'] as String;
            final rawArgs = functionCall['args'];

            LoggerService.debug(
              'Processing function call',
              error: {'functionName': functionName, 'args': rawArgs},
            );

            String? serviceName;
            String? toolName;
            Map<String, dynamic>? params;

            if (functionName != 'call_tool') {
              // Model called a tool directly by name instead of using call_tool wrapper
              // Return an error with helpful guidance (like "command not found" helper)
              final errorMessage = _buildUnknownToolErrorMessage(
                functionName,
                rawArgs,
                activeTools,
              );

              LoggerService.warning(
                'Unknown function call: $functionName, returning error to LLM',
              );

              final errorResult = 'Error: $errorMessage';
              toolResults.add(errorResult);
              conversationParts.add(
                '[Tool error: Unknown function "$functionName"]',
              );

              // Build proper tool error message based on model type
              if (getIt<ModelSelector>().currentModelConfig?.type ==
                  ModelType.openaiCompatible) {
                // OpenAI: Use the original tool_call_id from the API response
                final toolCallId =
                    functionCall['id'] as String? ??
                    't_err_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}_$i';
                toolCallsWithResults.add({
                  'id': toolCallId,
                  'function_call': functionCall,
                  'result': errorResult,
                });
              } else {
                // Gemini: Store with function metadata for proper functionResponse format
                toolCallsWithResults.add({
                  'function_name': functionName,
                  'function_args': rawArgs,
                  'result': errorResult,
                  // Preserve thought_signature for Gemini 3+ models
                  if (functionCall.containsKey('thoughtSignature'))
                    'thought_signature': functionCall['thoughtSignature'],
                });
              }

              continue;
            }

            final parsedArgs = McpToolIntegrationService.parseCallToolArguments(
              rawArgs,
            );
            if (parsedArgs == null) {
              LoggerService.error(
                'Failed to parse call_tool arguments',
                error: {'args': rawArgs},
              );
              continue;
            }

            serviceName = parsedArgs['service_name'] as String;
            toolName = parsedArgs['tool_name'] as String;
            params = parsedArgs['params'] as Map<String, dynamic>;

            LoggerService.info('Executing: $serviceName.$toolName');
            LoggerService.debug('Tool parameters', error: params);

            try {
              final result = await executeTool(
                serviceName,
                toolName,
                params,
                generationContext,
              );
              final toolSummary =
                  'Tool: $serviceName.$toolName\nResult: $result';
              toolResults.add(toolSummary);
              conversationParts.add('[Tool executed: $serviceName.$toolName]');

              if (getIt<ModelSelector>().currentModelConfig?.type ==
                  ModelType.openaiCompatible) {
                // Use the original tool_call_id from the API response if available
                final toolCallId =
                    functionCall['id'] as String? ??
                    't_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}_${toolName.length > 10 ? toolName.substring(0, 10) : toolName}_$i';
                toolCallsWithResults.add({
                  'id': toolCallId,
                  'function_call': functionCall,
                  'result': toolSummary,
                });
              }
            } catch (e, stackTrace) {
              LoggerService.error(
                'Tool execution failed: $e',
                error: e,
                stackTrace: stackTrace,
              );
              toolResults.add('Tool: $serviceName.$toolName\nError: $e');
            }
          }

          // Accumulate parts history
          if (partsHistory != null) {
            // If this is not the first iteration, we need to append to the existing history
            // However, the model returns the full history of the *current* turn's generation
            // We need to inject the tool results into this history for the next iteration
            // But here, we are preparing the final metadata for the ConversationMessage.

            // For the final message, we want the COMPLETE history of this interaction:
            // 1. Initial thought + tool call (from first iteration)
            // 2. Tool result (from execution)
            // 3. Subsequent thought + response (from next iteration)

            // Currently, 'partsHistory' only contains the parts from the *last* model response.
            // We need to maintain a running list of parts across iterations.
          }

          // Initialize running parts history if needed
          final runningPartsHistory =
              lastAssistantMetadata?['parts_history'] as List? ?? [];
          if (partsHistory != null) {
            runningPartsHistory.addAll(partsHistory);
          }

          // Inject tool results into the running history
          for (int i = 0; i < toolResults.length; i++) {
            runningPartsHistory.add({
              'type': 'tool_result',
              'text': toolResults[i],
              'is_included': true,
              // Link to the corresponding tool call if possible?
              // For now, just adding the result is enough for the UI to show it.
            });
          }

          if (toolResults.isNotEmpty) {
            final assistantMetadata = <String, dynamic>{
              'function_calls': functionCalls, // Keep for legacy
              'parts_history': runningPartsHistory, // Updated history
              'modelUsed':
                  response?['modelUsed'] ??
                  getIt<ModelSelector>().currentModelConfig?.id,
            };

            if (toolCallsWithResults.isNotEmpty) {
              assistantMetadata['tool_calls_with_results'] =
                  toolCallsWithResults;
            }

            final assistantMessage = PromptMessage(
              role: PromptRole.assistant,
              content: textResponse ?? '',
              metadata: assistantMetadata,
            );
            lastAssistantMetadata = assistantMetadata;
            final currentModelConfig =
                generationContext.modelOverride ??
                getIt<ModelSelector>().currentModelConfig;
            if (currentModelConfig?.type == ModelType.openaiCompatible) {
              final toolMessages = toolCallsWithResults
                  .map(
                    (toolCall) => PromptMessage(
                      role: PromptRole.tool,
                      content: toolCall['result'] as String,
                      metadata: {'tool_call_id': toolCall['id']},
                    ),
                  )
                  .toList();

              currentMessages = [
                ...currentMessages,
                assistantMessage,
                ...toolMessages,
              ];
            } else {
              // Gemini: Use PromptRole.tool with function metadata for proper functionResponse format
              final toolMessages = <PromptMessage>[];
              for (int i = 0; i < toolResults.length; i++) {
                final functionCall = i < functionCalls.length
                    ? functionCalls[i]
                    : null;
                final toolCallResult = i < toolCallsWithResults.length
                    ? toolCallsWithResults[i]
                    : null;

                // Build metadata with function info and thought_signature
                final metadata = <String, dynamic>{};
                if (functionCall != null) {
                  metadata['function_name'] = functionCall['name'];
                  metadata['function_args'] = functionCall['args'];
                  // Preserve thought_signature for Gemini 3+ models
                  if (functionCall.containsKey('thoughtSignature')) {
                    metadata['thought_signature'] =
                        functionCall['thoughtSignature'];
                  }
                }
                // Also check toolCallResult for thought_signature (for error cases)
                if (toolCallResult != null &&
                    toolCallResult.containsKey('thought_signature')) {
                  metadata['thought_signature'] =
                      toolCallResult['thought_signature'];
                }

                toolMessages.add(
                  PromptMessage(
                    role: PromptRole.tool,
                    content: toolResults[i],
                    metadata: metadata.isNotEmpty ? metadata : null,
                  ),
                );
              }

              currentMessages = [
                ...currentMessages,
                assistantMessage,
                ...toolMessages,
              ];
            }

            iteration++;
            continue;
          }
        }

        if (textResponse != null ||
            (partsHistory != null && partsHistory.isNotEmpty)) {
          if (textResponse != null && textResponse.isNotEmpty) {
            conversationParts.add(textResponse);
          }

          // Use the accumulated history
          final finalPartsHistory =
              lastAssistantMetadata?['parts_history'] as List? ?? [];
          if (partsHistory != null) {
            // If this was the final response (no more tools), add its parts
            finalPartsHistory.addAll(partsHistory);
          }

          final finalMetadata = <String, dynamic>{
            if (lastAssistantMetadata != null) ...lastAssistantMetadata,
            if (functionCalls != null) 'function_calls': functionCalls,
            'parts_history': finalPartsHistory,
            'modelUsed': textResponse != null || partsHistory != null
                ? (response?['modelUsed'] ??
                      getIt<ModelSelector>().currentModelConfig?.id)
                : getIt<ModelSelector>().currentModelConfig?.id,
          };

          return ConversationAiResponse(
            content: conversationParts.join('\n\n'),
            metadata: finalMetadata,
          );
        }

        LoggerService.warning('AI returned empty response after tool calls');
        return const ConversationAiResponse(
          content: 'I was unable to generate a response. Please try again.',
        );
      }
    } on ConversationCancelledException {
      rethrow;
    } catch (e, stackTrace) {
      LoggerService.error(
        'Error during MCP tool execution: $e',
        error: e,
        stackTrace: stackTrace,
      );
      return const ConversationAiResponse(
        content:
            'I encountered an error while coordinating tools for this request. Please try again.',
        metadata: {'is_client_synthetic': true},
      );
    }
  }

  /// Build a helpful error message for unrecognized tool calls.
  /// Similar to Linux's "command not found" helper that suggests similar commands.
  String _buildUnknownToolErrorMessage(
    String functionName,
    dynamic rawArgs,
    Map<String, List<McpTool>> activeTools,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('ERROR: Unrecognized function "$functionName"');
    buffer.writeln();
    buffer.writeln(
      'You must call tools through the "call_tool" function with:',
    );
    buffer.writeln('  - service_name: The endpoint/service name');
    buffer.writeln('  - tool_name: The tool name within the service');
    buffer.writeln('  - params: Object containing the tool parameters');
    buffer.writeln();

    // Search for matching tools (command not found helper)
    final matches = <MapEntry<String, String>>[]; // (tool_name, service_name)
    for (final entry in activeTools.entries) {
      final serviceName = entry.key;
      for (final tool in entry.value) {
        if (tool.name == functionName ||
            tool.name.toLowerCase().contains(functionName.toLowerCase()) ||
            functionName.toLowerCase().contains(tool.name.toLowerCase())) {
          matches.add(MapEntry(tool.name, serviceName));
        }
      }
    }

    if (matches.isNotEmpty) {
      buffer.writeln('Did you mean to call one of these?');
      for (final match in matches) {
        buffer.writeln(
          '  call_tool(service_name="${match.value}", tool_name="${match.key}", params={...})',
        );
      }
    } else if (activeTools.isNotEmpty) {
      buffer.writeln('Available services: ${activeTools.keys.join(", ")}');
    }

    return buffer.toString();
  }
}
