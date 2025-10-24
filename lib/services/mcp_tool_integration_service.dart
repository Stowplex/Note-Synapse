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
    
    // Build description with available tools
    final toolsDescription = StringBuffer();
    toolsDescription.writeln('Call an MCP tool. Available tools by service:');
    for (final entry in toolsByEndpoint.entries) {
      toolsDescription.writeln('${entry.key}:');
      for (final tool in entry.value) {
        toolsDescription.writeln('  - ${tool.name}: ${tool.description ?? "No description"}');
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
            'description': 'The parameters to pass to the tool',
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
    // Build enum of service names
    final serviceNames = toolsByEndpoint.keys.toList();
    
    // Build description with available tools
    final toolsDescription = StringBuffer();
    toolsDescription.writeln('Call an MCP tool. Available tools by service:');
    for (final entry in toolsByEndpoint.entries) {
      toolsDescription.writeln('${entry.key}:');
      for (final tool in entry.value) {
        toolsDescription.writeln('  - ${tool.name}: ${tool.description ?? "No description"}');
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
            'description': 'The parameters to pass to the tool',
          },
        },
        'required': ['service_name', 'tool_name', 'params'],
      },
    };
  }

  /// Build system prompt that explains available MCP tools to the AI
  /// When function calling is available, this is minimal since tools are in function definitions
  static String buildMcpSystemPrompt(
    Map<String, List<McpTool>> toolsByEndpoint,
  ) {
    if (toolsByEndpoint.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();
    buffer.writeln('\n\n=== MCP TOOLS AVAILABLE ===\n');
    buffer.writeln('You have access to external tools via the call_tool function.');
    buffer.writeln('Use function calling to invoke these tools when needed.\n');

    for (final entry in toolsByEndpoint.entries) {
      final serviceName = entry.key;
      buffer.writeln('Service: $serviceName');
      
      for (final tool in entry.value) {
        buffer.writeln('  - ${tool.name}: ${tool.description ?? "No description"}');
        if (tool.inputSchema != null) {
          final props = tool.inputSchema!['properties'] as Map?;
          if (props != null && props.isNotEmpty) {
            buffer.writeln('    Required params: ${props.keys.join(", ")}');
          }
        }
      }
      buffer.writeln();
    }

    return buffer.toString();
  }

  /// Parse call_tool function arguments
  static Map<String, dynamic>? parseCallToolArguments(
    Map<String, dynamic> arguments,
  ) {
    try {
      final serviceName = arguments['service_name'] as String?;
      final toolName = arguments['tool_name'] as String?;
      final params = arguments['params'] as Map<String, dynamic>?;

      if (serviceName == null || toolName == null || params == null) {
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

