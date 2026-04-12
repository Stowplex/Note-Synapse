import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/mcp_endpoint.dart';
import '../models/generation_context.dart';
import 'mcp_service.dart';
import 'logger_service.dart';
import 'prompts/prompt_template_service.dart';
import 'service_locator.dart';

/// Service for integrating MCP tools with AI models
class McpToolIntegrationService {
  static const int _compactPromptThreshold = 50000;

  /// Get all available tools from selected MCP endpoints
  static Future<Map<String, List<McpTool>>> getAvailableTools(
    List<String> endpointIds,
  ) async {
    final toolsByEndpoint = <String, List<McpTool>>{};

    for (final endpointId in endpointIds) {
      final cache = await getIt<McpService>().getCachedTools(endpointId);
      if (cache != null && cache.tools.isNotEmpty) {
        final endpoints = await getIt<McpService>().getEndpoints();
        final endpoint = endpoints.firstWhere((e) => e.id == endpointId);
        toolsByEndpoint[endpoint.name] = cache.tools;
      }
    }

    return toolsByEndpoint;
  }

  /// Get the call_tool function definition for Gemini
  /// This is a single function that can call any MCP tool
  static Map<String, dynamic> getCallToolFunctionForGemini(
    Map<String, List<McpTool>> toolsByEndpoint, {
    bool compactDescription = false,
  }) {
    final serviceNames = toolsByEndpoint.keys.toList();
    final toolsDescription = compactDescription
        ? 'Call a tool. Provide service_name, tool_name, and params.'
        : _buildToolCatalogDescription(
            toolsByEndpoint,
            compact: true,
            includeWrapperIntro: true,
          );

    return {
      'name': 'call_tool',
      'description': toolsDescription.toString(),
      'parameters': {
        'type': 'object',
        'properties': {
          'service_name': {
            'type': 'string',
            'description': 'The MCP service name',
            'enum': serviceNames,
          },
          'tool_name': {
            'type': 'string',
            'description': 'The name of the tool to call within the service',
          },
          'params': {
            'type': 'object',
            'description':
                'The parameters to pass to the tool as a JSON object matching the selected tool schema.',
          },
        },
        'required': ['service_name', 'tool_name', 'params'],
      },
    };
  }

  /// Get the call_tool function definition for OpenAI
  /// This is a single function that can call any MCP tool
  static Map<String, dynamic> getCallToolFunctionForOpenAI(
    Map<String, List<McpTool>> toolsByEndpoint,
  ) {
    final serviceNames = toolsByEndpoint.keys.toList();
    final toolsDescription = _buildToolCatalogDescription(
      toolsByEndpoint,
      compact: true,
      includeWrapperIntro: true,
    );

    return {
      'name': 'call_tool',
      'description': toolsDescription.toString(),
      'parameters': {
        'type': 'object',
        'properties': {
          'service_name': {
            'type': 'string',
            'description': 'The MCP service name',
            'enum': serviceNames,
          },
          'tool_name': {
            'type': 'string',
            'description': 'The name of the tool to call within the service',
          },
          'params': {
            'type': 'object',
            'description':
                'The parameters to pass to the tool (as a JSON object matching the tool\'s schema)',
          },
        },
        'required': ['service_name', 'tool_name', 'params'],
      },
    };
  }

  /// Build system prompt that explains available MCP tools to the AI
  /// Provides detailed tool information to help the AI understand capabilities
  static String buildMcpSystemPrompt(
    Map<String, List<McpTool>> toolsByEndpoint, {
    int? maxBudgetTokens,
    bool includeWrapperIntro = true,
  }) {
    if (toolsByEndpoint.isEmpty) {
      return '';
    }
    final compact =
        maxBudgetTokens != null && maxBudgetTokens < _compactPromptThreshold;
    return _buildToolCatalogDescription(
      toolsByEndpoint,
      compact: compact,
      includeWrapperIntro: includeWrapperIntro,
      includeHeader: true,
    );
  }

  /// Parse call_tool function arguments
  /// Handles named (object) format, key/value lists, and positional fallbacks
  static Map<String, dynamic>? parseCallToolArguments(
    dynamic argumentsRaw, {
    String? fallbackServiceName,
    String? fallbackToolName,
    bool logErrors = true,
  }) {
    try {
      late final Map<String, dynamic> arguments;

      if (argumentsRaw is Map) {
        arguments = argumentsRaw.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      } else if (argumentsRaw is List) {
        final listArguments = <String, dynamic>{};
        for (final entry in argumentsRaw) {
          if (entry is Map) {
            final key =
                entry['name'] ??
                entry['key'] ??
                entry['field'] ??
                entry['param'];
            if (key != null) {
              listArguments[key.toString()] = entry.containsKey('value')
                  ? entry['value']
                  : entry.containsKey('data')
                  ? entry['data']
                  : entry['argument'];
              continue;
            }
          }

          if (entry is List && entry.length == 2) {
            listArguments[entry[0].toString()] = entry[1];
            continue;
          }

          // Fallback: treat the list as positional [serviceName, toolName, params]
          if (entry == argumentsRaw.first && argumentsRaw.length >= 3) {
            listArguments['service_name'] = argumentsRaw[0];
            listArguments['tool_name'] = argumentsRaw[1];
            listArguments['params'] = argumentsRaw[2];
            break;
          }
        }
        arguments = listArguments;
      } else {
        if (logErrors) {
          LoggerService.error(
            'Unsupported call_tool argument format: ${argumentsRaw.runtimeType}',
          );
        }
        return null;
      }

      if (arguments.isEmpty) {
        if (logErrors) {
          LoggerService.error('Empty call_tool arguments');
        }
        return null;
      }

      final serviceName =
          arguments['service_name'] as String? ??
          arguments['serviceName'] as String? ??
          arguments['service'] as String? ??
          fallbackServiceName;
      final toolName =
          arguments['tool_name'] as String? ??
          arguments['toolName'] as String? ??
          arguments['tool'] as String? ??
          fallbackToolName;

      if (serviceName == null || toolName == null) {
        if (logErrors) {
          LoggerService.error(
            'Missing required fields: service_name or tool_name',
          );
        }
        return null;
      }

      // Try to get params in nested format first
      Map<String, dynamic>? params;
      final rawParams = arguments['params'] ?? arguments['param'];
      if (rawParams is Map) {
        params = rawParams.map((key, value) => MapEntry(key.toString(), value));
      }

      // Some Gemini responses incorrectly wrap arguments under a single
      // "param" (or "parameters") key. Unwrap that automatically.
      if (params != null && params.length == 1) {
        final soleKey = params.keys.first;
        final soleValue = params.values.first;
        if ((soleKey == 'param' ||
                soleKey == 'params' ||
                soleKey == 'parameters') &&
            soleValue is Map) {
          params = soleValue.map(
            (key, value) => MapEntry(key.toString(), value),
          );
        }
      }

      // If params is not in nested format, check if all other fields are at top level
      if (params == null || params.isEmpty) {
        // Extract everything except service_name and tool_name as params
        params = <String, dynamic>{};
        arguments.forEach((key, value) {
          if (key != 'service_name' &&
              key != 'tool_name' &&
              key != 'serviceName' &&
              key != 'toolName' &&
              key != 'service' &&
              key != 'tool' &&
              key != 'params' &&
              key != 'param' &&
              key != 'parameters') {
            params![key] = value;
          }
        });
      }

      // If we still don't have params, fail
      // We allow empty params because some tools (like 'ls') take no arguments.
      // Validation of required arguments happens at the tool execution level.

      return {
        'service_name': serviceName,
        'tool_name': toolName,
        'params': params,
      };
    } catch (e) {
      if (logErrors) {
        LoggerService.error('Error parsing call_tool arguments: $e');
      }
      return null;
    }
  }

  static String _buildToolCatalogDescription(
    Map<String, List<McpTool>> toolsByEndpoint, {
    required bool compact,
    bool includeWrapperIntro = true,
    bool includeHeader = false,
  }) {
    final templateService = getIt<PromptTemplateService>();

    // Build the per-tool details in Dart (data assembly stays here)
    final detailsBuffer = StringBuffer();
    for (final entry in toolsByEndpoint.entries) {
      detailsBuffer.writeln(
        '=== Endpoint: ${entry.key} (service_name: "${entry.key}") ===',
      );
      for (final tool in entry.value) {
        final description = tool.description?.trim();
        if (compact) {
          detailsBuffer.write('- ${tool.name}');
          if (description != null && description.isNotEmpty) {
            detailsBuffer.write(': $description');
          }
          detailsBuffer.writeln();
        } else {
          detailsBuffer.writeln('Tool Name Argument: ${tool.name}');
          if (description != null && description.isNotEmpty) {
            detailsBuffer.writeln('Description: $description');
          }
        }

        if (tool.inputSchema != null) {
          final schema = tool.inputSchema!;
          final properties = schema['properties'] as Map<String, dynamic>?;
          final required = schema['required'] as List?;
          if (required != null && required.isNotEmpty) {
            detailsBuffer.writeln(
              compact
                  ? '  Required: ${required.join(", ")}'
                  : 'Required parameters: ${required.join(", ")}',
            );
          }
          if (properties != null && properties.isNotEmpty) {
            if (!compact) {
              detailsBuffer.writeln('Parameters:');
            }
            properties.forEach((paramName, paramDetails) {
              final details = paramDetails as Map<String, dynamic>;
              final paramType = details['type'] ?? 'any';
              final paramDesc = details['description'] ?? '';
              detailsBuffer.writeln('  - $paramName ($paramType): $paramDesc');
              if (!compact && details.containsKey('enum')) {
                detailsBuffer.writeln('    Allowed values: ${details['enum']}');
              }
            });
          }
        }
        detailsBuffer.writeln();
      }
    }

    // Determine example service/tool for the intro
    String exampleService = '';
    String exampleTool = '';
    if (toolsByEndpoint.isNotEmpty) {
      exampleService = toolsByEndpoint.keys.first;
      exampleTool = toolsByEndpoint.values.first.first.name;
    }

    return templateService.renderSync(
      'mcp/tool_catalog',
      {
        'includeHeader': includeHeader,
        'includeWrapperIntro': includeWrapperIntro && toolsByEndpoint.isNotEmpty,
        'exampleService': exampleService,
        'exampleTool': exampleTool,
        'toolDetails': detailsBuffer.toString(),
      },
    );
  }

  @visibleForTesting
  static String testBuildToolCatalogDescription(
    Map<String, List<McpTool>> toolsByEndpoint, {
    required bool compact,
    bool includeWrapperIntro = true,
    bool includeHeader = false,
  }) => _buildToolCatalogDescription(
        toolsByEndpoint,
        compact: compact,
        includeWrapperIntro: includeWrapperIntro,
        includeHeader: includeHeader,
      );

  /// Execute an MCP tool call
  static Future<String> executeToolCall({
    required String serviceName,
    required String toolName,
    required Map<String, dynamic> parameters,
    required List<String> enabledEndpointIds,
    required GenerationContext generationContext,
  }) async {
    try {
      // Find the endpoint by service name
      final endpoints = await getIt<McpService>().getEndpoints();
      final endpoint = endpoints.firstWhere(
        (e) => e.name == serviceName && enabledEndpointIds.contains(e.id),
        orElse: () =>
            throw Exception('Service not found or not enabled: $serviceName'),
      );

      final requestId = generationContext.ensureRequestId();
      LoggerService.info(
        'Executing MCP tool call: $serviceName.$toolName',
        error: {'requestId': requestId},
      );
      LoggerService.debug('Tool parameters: ${jsonEncode(parameters)}');

      // Call the tool
      final result = await getIt<McpService>().callTool(
        endpointId: endpoint.id,
        toolName: toolName,
        arguments: parameters,
      );

      LoggerService.info('MCP tool call completed successfully');
      return result;
    } catch (e) {
      LoggerService.error('Error executing MCP tool call: $e');
      return 'Error executing tool $serviceName.$toolName: $e';
    }
  }

  /// Parse Gemini function calls from response
  /// Gemini returns function calls in the 'functionCall' field
  static List<Map<String, dynamic>>? parseGeminiFunctionCalls(
    Map<String, dynamic> responseData,
  ) {
    try {
      if (responseData['candidates'] == null ||
          responseData['candidates'].isEmpty) {
        return null;
      }

      final candidate = responseData['candidates'][0];
      final content = candidate['content'];

      if (content == null || content['parts'] == null) {
        return null;
      }

      final functionCalls = <Map<String, dynamic>>[];

      for (final part in content['parts']) {
        if (part.containsKey('functionCall')) {
          functionCalls.add(part['functionCall'] as Map<String, dynamic>);
        }
      }

      return functionCalls.isEmpty ? null : functionCalls;
    } catch (e) {
      LoggerService.error('Error parsing Gemini function calls: $e');
      return null;
    }
  }

  /// Parse OpenAI function calls from response
  /// OpenAI returns function calls in 'function_call' field
  static Map<String, dynamic>? parseOpenAIFunctionCall(
    Map<String, dynamic> responseData,
  ) {
    try {
      if (responseData['choices'] == null || responseData['choices'].isEmpty) {
        return null;
      }

      final choice = responseData['choices'][0];
      final message = choice['message'];

      if (message == null || !message.containsKey('function_call')) {
        return null;
      }

      final functionCall = message['function_call'];
      return {
        'name': functionCall['name'],
        'arguments': jsonDecode(functionCall['arguments']),
      };
    } catch (e) {
      LoggerService.error('Error parsing OpenAI function call: $e');
      return null;
    }
  }
}
