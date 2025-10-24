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

  /// Format tools for Gemini function calling
  /// Gemini uses the function calling format in the API
  static List<Map<String, dynamic>> formatToolsForGemini(
    Map<String, List<McpTool>> toolsByEndpoint,
  ) {
    final tools = <Map<String, dynamic>>[];

    for (final entry in toolsByEndpoint.entries) {
      final serviceName = entry.key;
      for (final tool in entry.value) {
        tools.add({
          'name': '${serviceName}__${tool.name}',
          'description': tool.description ?? 'No description available',
          'parameters': tool.inputSchema ?? {
            'type': 'object',
            'properties': {},
          },
        });
      }
    }

    return tools;
  }

  /// Format tools for OpenAI function calling
  /// OpenAI uses the 'functions' array in the API
  static List<Map<String, dynamic>> formatToolsForOpenAI(
    Map<String, List<McpTool>> toolsByEndpoint,
  ) {
    final functions = <Map<String, dynamic>>[];

    for (final entry in toolsByEndpoint.entries) {
      final serviceName = entry.key;
      for (final tool in entry.value) {
        functions.add({
          'name': '${serviceName}__${tool.name}',
          'description': tool.description ?? 'No description available',
          'parameters': tool.inputSchema ?? {
            'type': 'object',
            'properties': {},
          },
        });
      }
    }

    return functions;
  }

  /// Build system prompt that explains available MCP tools to the AI
  static String buildMcpSystemPrompt(
    Map<String, List<McpTool>> toolsByEndpoint,
  ) {
    if (toolsByEndpoint.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();
    buffer.writeln('\n\n=== AVAILABLE MCP TOOLS ===\n');
    buffer.writeln('You have access to the following external tools via Model Context Protocol (MCP):');
    buffer.writeln();

    for (final entry in toolsByEndpoint.entries) {
      final serviceName = entry.key;
      buffer.writeln('Service: $serviceName');
      
      for (final tool in entry.value) {
        buffer.writeln('  - ${tool.name}');
        if (tool.description != null && tool.description!.isNotEmpty) {
          buffer.writeln('    Description: ${tool.description}');
        }
        if (tool.inputSchema != null) {
          buffer.writeln('    Parameters: ${jsonEncode(tool.inputSchema)}');
        }
      }
      buffer.writeln();
    }

    buffer.writeln('To call a tool, use function calling with the format: {serviceName}__{toolName}');
    buffer.writeln('Example: weather__get_forecast with parameters {"location": "San Francisco"}');
    buffer.writeln();

    return buffer.toString();
  }

  /// Parse tool call from function call name
  /// Format: {serviceName}__{toolName}
  static Map<String, String>? parseToolCall(String functionName) {
    final parts = functionName.split('__');
    if (parts.length != 2) {
      return null;
    }

    return {
      'serviceName': parts[0],
      'toolName': parts[1],
    };
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

