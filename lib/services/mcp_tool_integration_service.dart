import 'dart:convert';
import '../models/mcp_endpoint.dart';
import 'mcp_service.dart';
import 'logger_service.dart';

/// Service for integrating MCP tools with AI models
class McpToolIntegrationService {
  /// Get all available tools from selected MCP endpoints
  static Future<Map<String, List<McpTool>>> getAvailableTools(
    List<String> endpointIds,
  ) async {
    final toolsByEndpoint = <String, List<McpTool>>{};

    for (final endpointId in endpointIds) {
      final cache = await McpService.getCachedTools(endpointId);
      if (cache != null && cache.tools.isNotEmpty) {
        final endpoints = await McpService.getEndpoints();
        final endpoint = endpoints.firstWhere((e) => e.id == endpointId);
        toolsByEndpoint[endpoint.name] = cache.tools;
      }
    }

    return toolsByEndpoint;
  }

  /// Get the call_tool function definition for Gemini
  /// This is a single function that can call any MCP tool
  static Map<String, dynamic> getCallToolFunctionForGemini(
    Map<String, List<McpTool>> toolsByEndpoint,
  ) {
    // Build enum of service names
    final serviceNames = toolsByEndpoint.keys.toList();
    
    // Build detailed description with full tool information
    final toolsDescription = StringBuffer();
    toolsDescription
      ..writeln('Call an MCP tool. Available tools:\n')
      ..writeln(
          'When you call this function, include the exact parameters required by the tool.')
      ..writeln(
          'Provide them either inside the params object or as additional top-level fields.')
      ..writeln(
          'Arguments are named; order does not matter as long as you supply the correct keys.')
      ..writeln(
          'Do not wrap arguments inside an extra object named "param" or "parameters".');
    
    for (final entry in toolsByEndpoint.entries) {
      final serviceName = entry.key;
      toolsDescription.writeln('=== Endpoint: $serviceName ===');
      
      for (final tool in entry.value) {
        toolsDescription.writeln('Tool: ${tool.name}');
        
        if (tool.description != null && tool.description!.isNotEmpty) {
          toolsDescription.writeln('Description: ${tool.description}');
        }
        
        if (tool.inputSchema != null) {
          final schema = tool.inputSchema!;
          final schemaType = schema['type'] ?? 'object';
          toolsDescription.writeln('Schema Type: $schemaType');
          
          // Parse and display properties
          final properties = schema['properties'] as Map<String, dynamic>?;
          if (properties != null && properties.isNotEmpty) {
            toolsDescription.writeln('Parameters:');
            properties.forEach((paramName, paramDetails) {
              final details = paramDetails as Map<String, dynamic>;
              final paramType = details['type'] ?? 'any';
              final paramDesc = details['description'] ?? '';
              toolsDescription.writeln('  - $paramName ($paramType): $paramDesc');
              
              // Include enum values if present
              if (details.containsKey('enum')) {
                toolsDescription.writeln('    Allowed values: ${details['enum']}');
              }
            });
            
            // Show required parameters
            final required = schema['required'] as List?;
            if (required != null && required.isNotEmpty) {
              toolsDescription.writeln('Required parameters: ${required.join(", ")}');
            }
          }
        }

        if (tool.outputSchema != null) {
          final outputSchema = tool.outputSchema!;
          final outputProperties = outputSchema['properties'] as Map<String, dynamic>?;
          if (outputProperties != null && outputProperties.isNotEmpty) {
            toolsDescription.writeln('Outputs:');
            outputProperties.forEach((outputName, outputDetails) {
              final details = outputDetails as Map<String, dynamic>;
              final outputType = details['type'] ?? 'any';
              final outputDesc = details['description'] ?? '';
              toolsDescription.writeln('  - $outputName ($outputType): $outputDesc');

              if (details.containsKey('enum')) {
                toolsDescription.writeln('    Possible values: ${details['enum']}');
              }
            });
          }
        }
        
        toolsDescription.writeln('');
      }
    }

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
                'The parameters to pass to the tool. Provide each parameter as a direct field inside this object. Do not wrap values inside additional objects such as "param" or "parameters".',
          },
        },
        'required': ['service_name', 'tool_name'],
      },
    };
  }

  /// Get the call_tool function definition for OpenAI
  /// This is a single function that can call any MCP tool
  static Map<String, dynamic> getCallToolFunctionForOpenAI(
    Map<String, List<McpTool>> toolsByEndpoint,
  ) {
    // Build enum of service names
    final serviceNames = toolsByEndpoint.keys.toList();
    
    // Build detailed description with full tool information
    final toolsDescription = StringBuffer();
    toolsDescription.writeln('Call an MCP tool.');
    toolsDescription.writeln('You must provide arguments as a JSON object with this shape:');
    toolsDescription.writeln('{"service_name": "...", "tool_name": "...", "params": {"<required_param>": <value>, ...}}');
    toolsDescription.writeln('Never omit the params field. Populate every required parameter exactly as listed.');
    toolsDescription.writeln('If you do not have a value for a required parameter, ask the user for it.');
    toolsDescription.writeln('\nAvailable tools:\n');
    
    for (final entry in toolsByEndpoint.entries) {
      final serviceName = entry.key;
      toolsDescription.writeln('=== Endpoint: $serviceName ===');
      
      for (final tool in entry.value) {
        toolsDescription.writeln('Tool: ${tool.name}');
        
        if (tool.description != null && tool.description!.isNotEmpty) {
          toolsDescription.writeln('Description: ${tool.description}');
        }
        
        if (tool.inputSchema != null) {
          final schema = tool.inputSchema!;
          final schemaType = schema['type'] ?? 'object';
          toolsDescription.writeln('Schema Type: $schemaType');
          
          // Parse and display properties
          final properties = schema['properties'] as Map<String, dynamic>?;
          if (properties != null && properties.isNotEmpty) {
            toolsDescription.writeln('Parameters:');
            properties.forEach((paramName, paramDetails) {
              final details = paramDetails as Map<String, dynamic>;
              final paramType = details['type'] ?? 'any';
              final paramDesc = details['description'] ?? '';
              toolsDescription.writeln('  - $paramName ($paramType): $paramDesc');
              
              // Include enum values if present
              if (details.containsKey('enum')) {
                toolsDescription.writeln('    Allowed values: ${details['enum']}');
              }
            });
            
            // Show required parameters
            final required = schema['required'] as List?;
            if (required != null && required.isNotEmpty) {
              toolsDescription.writeln('Required parameters: ${required.join(", ")}');
            }
          }
        }

        if (tool.outputSchema != null) {
          final outputSchema = tool.outputSchema!;
          final outputProperties = outputSchema['properties'] as Map<String, dynamic>?;
          if (outputProperties != null && outputProperties.isNotEmpty) {
            toolsDescription.writeln('Outputs:');
            outputProperties.forEach((outputName, outputDetails) {
              final details = outputDetails as Map<String, dynamic>;
              final outputType = details['type'] ?? 'any';
              final outputDesc = details['description'] ?? '';
              toolsDescription.writeln('  - $outputName ($outputType): $outputDesc');

              if (details.containsKey('enum')) {
                toolsDescription.writeln('    Possible values: ${details['enum']}');
              }
            });
          }
        }
        
        toolsDescription.writeln('');
      }
    }

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
            'description': 'The parameters to pass to the tool (as a JSON object matching the tool\'s schema)',
          },
        },
        'required': ['service_name', 'tool_name', 'params'],
      },
    };
  }

  /// Build system prompt that explains available MCP tools to the AI
  /// Provides detailed tool information to help the AI understand capabilities
  static String buildMcpSystemPrompt(
    Map<String, List<McpTool>> toolsByEndpoint,
  ) {
    if (toolsByEndpoint.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();
    buffer.writeln('\n\n=== MCP TOOLS AVAILABLE ===\n');
    buffer.writeln('You have access to external tools via the call_tool function.');
    buffer.writeln('Use function calling to invoke these tools when needed.');
    buffer.writeln('When you call call_tool, always include a params object and populate every required field exactly as defined by the schema.');
    buffer.writeln('If a required value is missing, ask the user for it instead of guessing or omitting it.');
    buffer.writeln('Validate that types match the schema before calling the tool.\n');

    for (final entry in toolsByEndpoint.entries) {
      final serviceName = entry.key;
      buffer.writeln('=== Endpoint: $serviceName ===');
      
      for (final tool in entry.value) {
        buffer.writeln('Tool: ${tool.name}');
        
        if (tool.description != null && tool.description!.isNotEmpty) {
          buffer.writeln('Description: ${tool.description}');
        }
        
        if (tool.inputSchema != null) {
          final schema = tool.inputSchema!;
          final properties = schema['properties'] as Map<String, dynamic>?;
          
          if (properties != null && properties.isNotEmpty) {
            buffer.writeln('Parameters:');
            properties.forEach((paramName, paramDetails) {
              final details = paramDetails as Map<String, dynamic>;
              final paramType = details['type'] ?? 'any';
              final paramDesc = details['description'] ?? '';
              buffer.writeln('  - $paramName ($paramType): $paramDesc');
            });
            
            final required = schema['required'] as List?;
            if (required != null && required.isNotEmpty) {
              buffer.writeln('Required: ${required.join(", ")}');
            }
          }
        }
        
        buffer.writeln();
      }
    }

    return buffer.toString();
  }

  /// Parse call_tool function arguments
  /// Handles named (object) format, key/value lists, and positional fallbacks
  static Map<String, dynamic>? parseCallToolArguments(
    dynamic argumentsRaw,
  ) {
    try {
      late final Map<String, dynamic> arguments;

      if (argumentsRaw is Map) {
        arguments = argumentsRaw.map((key, value) => MapEntry(key.toString(), value));
      } else if (argumentsRaw is List) {
        final listArguments = <String, dynamic>{};
        for (final entry in argumentsRaw) {
          if (entry is Map) {
            final key = entry['name'] ?? entry['key'] ?? entry['field'] ?? entry['param'];
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
        LoggerService.error(
          'Unsupported call_tool argument format: ${argumentsRaw.runtimeType}',
        );
        return null;
      }

      if (arguments.isEmpty) {
        LoggerService.error('Empty call_tool arguments');
        return null;
      }

      final serviceName = arguments['service_name'] as String? ??
          arguments['serviceName'] as String? ??
          arguments['service'] as String?;
      final toolName = arguments['tool_name'] as String? ??
          arguments['toolName'] as String? ??
          arguments['tool'] as String?;

      if (serviceName == null || toolName == null) {
        LoggerService.error('Missing required fields: service_name or tool_name');
        return null;
      }

      // Try to get params in nested format first
      Map<String, dynamic>? params;
      final rawParams = arguments['params'];
      if (rawParams is Map) {
        params = rawParams.map((key, value) => MapEntry(key.toString(), value));
      }

      // Some Gemini responses incorrectly wrap arguments under a single
      // "param" (or "parameters") key. Unwrap that automatically.
      if (params != null && params.length == 1) {
        final soleKey = params.keys.first;
        final soleValue = params.values.first;
        if ((soleKey == 'param' || soleKey == 'params') &&
            soleValue is Map<String, dynamic>) {
          params = soleValue.map((key, value) => MapEntry(key.toString(), value));
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
              key != 'param') {
            params![key] = value;
          }
        });
      }

      // If we still don't have params, fail
      if (params.isEmpty) {
        LoggerService.error('No params found in arguments');
        return null;
      }

      return {
        'service_name': serviceName,
        'tool_name': toolName,
        'params': params,
      };
    } catch (e) {
      LoggerService.error('Error parsing call_tool arguments: $e');
      return null;
    }
  }

  /// Execute an MCP tool call
  static Future<String> executeToolCall({
    required String serviceName,
    required String toolName,
    required Map<String, dynamic> parameters,
    required List<String> enabledEndpointIds,
  }) async {
    try {
      // Find the endpoint by service name
      final endpoints = await McpService.getEndpoints();
      final endpoint = endpoints.firstWhere(
        (e) => e.name == serviceName && enabledEndpointIds.contains(e.id),
        orElse: () => throw Exception('Service not found or not enabled: $serviceName'),
      );

      LoggerService.info('Executing MCP tool call: $serviceName.$toolName');
      LoggerService.debug('Tool parameters: ${jsonEncode(parameters)}');

      // Call the tool
      final result = await McpService.callTool(
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
      if (responseData['choices'] == null || 
          responseData['choices'].isEmpty) {
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

