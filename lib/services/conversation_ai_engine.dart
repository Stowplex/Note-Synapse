import 'dart:async';

import '../models/mcp_endpoint.dart';
import '../models/model_type.dart';
import '../services/ai_service.dart';
import '../services/logger_service.dart';
import '../services/mcp_tool_integration_service.dart';
import '../services/model_selector.dart';
import '../services/prompts/prompt_models.dart';

class ConversationCancelledException implements Exception {
  const ConversationCancelledException([this.message = 'Request cancelled by user']);

  final String message;

  @override
  String toString() => message;
}

class ConversationAiResponse {
  const ConversationAiResponse({required this.content, this.metadata});

  final String content;
  final Map<String, dynamic>? metadata;
}

typedef ToolExecutionCallback = Future<String> Function(
  String serviceName,
  String toolName,
  Map<String, dynamic> params,
);

typedef CancellationCheck = bool Function();

class ConversationAiEngine {
  const ConversationAiEngine();

  Future<ConversationAiResponse> generate({
    required PromptRequest request,
    required Map<String, List<McpTool>> activeTools,
    required bool enableTools,
    required ToolExecutionCallback executeTool,
    required CancellationCheck isCancelled,
    String? requestId,
  }) async {
    if (isCancelled()) {
      throw const ConversationCancelledException();
    }

    if (!enableTools || activeTools.isEmpty) {
      return _generateWithoutTools(
        request,
        isCancelled,
        requestId,
      );
    }

    return _generateWithTools(
      request: request,
      activeTools: activeTools,
      executeTool: executeTool,
      isCancelled: isCancelled,
      requestId: requestId,
    );
  }

  Future<ConversationAiResponse> _generateWithoutTools(
    PromptRequest request,
    CancellationCheck isCancelled,
    String? requestId,
  ) async {
    try {
      if (isCancelled()) {
        throw const ConversationCancelledException();
      }

      final responseText = await AIService.executePrompt(
        request,
        requestId: requestId,
      );

      if (isCancelled()) {
        throw const ConversationCancelledException();
      }

      return ConversationAiResponse(content: responseText);
    } on ConversationCancelledException {
      rethrow;
    } catch (e, stackTrace) {
      LoggerService.error(
        'Error generating AI response without tools: $e',
        error: e,
        stackTrace: stackTrace,
      );
      return const ConversationAiResponse(
        content:
            'I apologize, but I encountered an error while generating a response. Please try again.',
      );
    }
  }

  Future<ConversationAiResponse> _generateWithTools({
    required PromptRequest request,
    required Map<String, List<McpTool>> activeTools,
    required ToolExecutionCallback executeTool,
    required CancellationCheck isCancelled,
    String? requestId,
  }) async {
    try {
      if (isCancelled()) {
        throw const ConversationCancelledException();
      }

      var currentMessages = <PromptMessage>[
        request.systemMessage,
        ...request.contextMessages,
        ...request.conversationMessages,
      ];

      final currentModelType = ModelSelector.instance.currentModelType;
      final callToolFunction = currentModelType == ModelType.openaiCompatible
          ? McpToolIntegrationService.getCallToolFunctionForOpenAI(activeTools)
          : McpToolIntegrationService.getCallToolFunctionForGemini(activeTools);

      LoggerService.info(
        'Starting tool-enabled conversation with ${activeTools.length} services',
        error: {
          if (requestId != null) 'requestId': requestId,
        },
      );

      const maxIterations = 10;
      final conversationParts = <String>[];
      Map<String, dynamic>? lastAssistantMetadata;

      for (int iteration = 0; iteration < maxIterations; iteration++) {
        if (isCancelled()) {
          throw const ConversationCancelledException();
        }

        LoggerService.debug('MCP iteration ${iteration + 1}/$maxIterations');

        final response = await ModelSelector.instance
            .generateWithToolsAndMessages(currentMessages, [callToolFunction]);

        if (isCancelled()) {
          throw const ConversationCancelledException();
        }

        final textResponse = response['text'] as String?;
        final functionCalls = response['function_calls'] as List?;

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

            if (functionName != 'call_tool') {
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

            final serviceName = parsedArgs['service_name'] as String;
            final toolName = parsedArgs['tool_name'] as String;
            final params = parsedArgs['params'] as Map<String, dynamic>;

            LoggerService.info('Executing: $serviceName.$toolName');
            LoggerService.debug('Tool parameters', error: params);

            try {
              final result = await executeTool(serviceName, toolName, params);
              final toolSummary =
                  'Tool: $serviceName.$toolName\nResult: $result';
              toolResults.add(toolSummary);
              conversationParts.add('[Tool executed: $serviceName.$toolName]');

              if (currentModelType == ModelType.openaiCompatible) {
                final timestamp = DateTime.now()
                    .millisecondsSinceEpoch
                    .toRadixString(36);
                final shortName = toolName.length > 10
                    ? toolName.substring(0, 10)
                    : toolName;
                final toolCallId = 't_${timestamp}_${shortName}_$i';
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

          if (toolResults.isNotEmpty) {
            final assistantMetadata = <String, dynamic>{
              'function_calls': functionCalls,
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

            if (currentModelType == ModelType.openaiCompatible) {
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
              final toolMessages = <PromptMessage>[];
              for (int i = 0; i < toolResults.length; i++) {
                final functionCall =
                    i < functionCalls.length ? functionCalls[i] : null;
                toolMessages.add(
                  PromptMessage(
                    role: PromptRole.user,
                    content: toolResults[i],
                    metadata: functionCall != null
                        ? {
                            'function_name': functionCall['name'],
                            'function_args': functionCall['args'],
                          }
                        : null,
                  ),
                );
              }

              currentMessages = [
                ...currentMessages,
                assistantMessage,
                ...toolMessages,
              ];
            }

            continue;
          }
        }

        if (textResponse != null && textResponse.isNotEmpty) {
          conversationParts.add(textResponse);
          return ConversationAiResponse(
            content: conversationParts.join('\n\n'),
            metadata: lastAssistantMetadata,
          );
        }

        LoggerService.warning('AI returned empty response after tool calls');
        return const ConversationAiResponse(
          content:
              'I was unable to generate a response. Please try again.',
        );
      }

      LoggerService.warning('MCP tool loop exceeded $maxIterations iterations');
      return const ConversationAiResponse(
        content:
            'I was unable to complete the request with the available tools. Please try again later.',
      );
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
      );
    }
  }
}

