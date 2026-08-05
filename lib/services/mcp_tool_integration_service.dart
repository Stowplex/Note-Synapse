import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/mcp_endpoint.dart';
import '../models/generation_context.dart';
import 'mcp_service.dart';
import 'logger_service.dart';
import 'prompts/prompt_template_service.dart';
import 'service_locator.dart';
import 'tools/tool_outcome.dart';

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
    bool preferDirectCalls = false,
    Set<String> directlyDeclaredToolNames = const {},
  }) {
    final serviceNames = toolsByEndpoint.keys.toList();
    final toolsDescription = compactDescription
        ? 'Call a tool. Provide service_name, tool_name, and params.'
        : _buildToolCatalogDescription(
            toolsByEndpoint,
            compact: true,
            includeWrapperIntro: true,
            preferDirectCalls: preferDirectCalls,
            excludeToolNames: directlyDeclaredToolNames,
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
    Map<String, List<McpTool>> toolsByEndpoint, {
    bool preferDirectCalls = false,
    Set<String> directlyDeclaredToolNames = const {},
  }) {
    final serviceNames = toolsByEndpoint.keys.toList();
    final toolsDescription = _buildToolCatalogDescription(
      toolsByEndpoint,
      compact: true,
      includeWrapperIntro: true,
      preferDirectCalls: preferDirectCalls,
      excludeToolNames: directlyDeclaredToolNames,
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
    bool preferDirectCalls = false,
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
      preferDirectCalls: preferDirectCalls,
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

  /// Maximum nesting depth rendered for object/array parameter schemas.
  /// Top-level params are depth 1; we descend through nested objects and the
  /// element shape of object arrays. The deepest built-in shape is the batch
  /// `modify_notes`: `modifications` -> item `modification` -> `link` ->
  /// `added` -> `relation`/`target`, which is depth 5 (the batch array adds a
  /// level over the single-note `modify_note`). Capped so pathologically deep
  /// inputs can't blow up the prompt.
  static const int _maxSchemaDepth = 5;

  /// Recursively render a JSON-schema `properties` map into the textual tool
  /// catalog so the model can see nested object/array shapes (not just the
  /// top-level parameter name). Without this, an object parameter renders as
  /// only "- modification (object): The modification object." and the model
  /// has to guess the inner structure.
  static void _writeSchemaProperties(
    StringBuffer buffer,
    Map<String, dynamic> properties, {
    List<dynamic>? required,
    required bool compact,
    required int depth,
  }) {
    final requiredSet = required == null
        ? const <String>{}
        : required.map((e) => e.toString()).toSet();
    final indent = '  ' * depth;
    properties.forEach((paramName, raw) {
      if (raw is! Map<String, dynamic>) return;
      final details = raw;
      final paramType = details['type'] ?? 'any';
      final paramDesc = details['description'];
      final requiredMark = requiredSet.contains(paramName) ? ', required' : '';
      final descSuffix =
          (paramDesc is String && paramDesc.isNotEmpty) ? ': $paramDesc' : '';
      buffer.writeln('$indent- $paramName ($paramType$requiredMark)$descSuffix');

      final enumValues = details['enum'];
      if (enumValues is List && enumValues.isNotEmpty) {
        buffer.writeln('$indent  Allowed values: ${enumValues.join(", ")}');
      }

      if (depth >= _maxSchemaDepth) return;

      // Nested object: descend into its properties.
      final nestedProps = details['properties'];
      if (nestedProps is Map<String, dynamic> && nestedProps.isNotEmpty) {
        _writeSchemaProperties(
          buffer,
          nestedProps,
          required: details['required'] as List?,
          compact: compact,
          depth: depth + 1,
        );
      }

      // Array of objects: descend into the item shape so the model knows what
      // each array element looks like.
      final items = details['items'];
      if (items is Map<String, dynamic>) {
        final itemProps = items['properties'];
        if (itemProps is Map<String, dynamic> && itemProps.isNotEmpty) {
          buffer.writeln('$indent  Each array item is an object with:');
          _writeSchemaProperties(
            buffer,
            itemProps,
            required: items['required'] as List?,
            compact: compact,
            depth: depth + 1,
          );
        } else {
          final itemEnum = items['enum'];
          if (itemEnum is List && itemEnum.isNotEmpty) {
            buffer.writeln(
              '$indent  Item allowed values: ${itemEnum.join(", ")}',
            );
          }
        }
      }
    });
  }

  static String _buildToolCatalogDescription(
    Map<String, List<McpTool>> toolsByEndpoint, {
    required bool compact,
    bool includeWrapperIntro = true,
    bool includeHeader = false,
    bool preferDirectCalls = false,
    Set<String> excludeToolNames = const {},
  }) {
    final templateService = getIt<PromptTemplateService>();

    // Build the per-tool details in Dart (data assembly stays here)
    final detailsBuffer = StringBuffer();
    for (final entry in toolsByEndpoint.entries) {
      detailsBuffer.writeln(
        '=== Endpoint: ${entry.key} (service_name: "${entry.key}") ===',
      );
      // Tools with their own function declarations get one summary line
      // instead of full schema text: the declaration itself carries the
      // schema, and repeating the catalog here anchors models on the
      // call_tool wrapper (and bloats every request).
      final directlyDeclared = entry.value
          .where((tool) => excludeToolNames.contains(tool.name))
          .map((tool) => tool.name)
          .toList();
      if (directlyDeclared.isNotEmpty) {
        detailsBuffer.writeln(
          'Directly declared (call by function name, not via call_tool): '
          '${directlyDeclared.join(', ')}',
        );
      }
      for (final tool in entry.value) {
        if (excludeToolNames.contains(tool.name)) continue;
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
            _writeSchemaProperties(
              detailsBuffer,
              properties,
              required: required,
              compact: compact,
              depth: 1,
            );
          }
          // Opt-in worked example via the standard JSON-Schema `examples`
          // keyword — one line, only for tools that declare it.
          final examples = schema['examples'];
          if (examples is List && examples.isNotEmpty) {
            try {
              detailsBuffer.writeln(
                '  Example: call_tool({"service_name": "${entry.key}", '
                '"tool_name": "${tool.name}", '
                '"params": ${jsonEncode(examples.first)}})',
              );
            } catch (_) {
              // Skip unencodable examples.
            }
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
        'preferDirectCalls': preferDirectCalls,
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
  /// Upper bound on individual tool declarations per request, so a large
  /// MCP catalog cannot blow up request size; overflow tools remain callable
  /// through the `call_tool` wrapper.
  static const int maxPerToolDeclarations = 48;

  static final RegExp _validFunctionName = RegExp(r'^[a-zA-Z0-9_-]{1,64}$');

  /// Argument names [parseCallToolArguments] treats as wrapper fields. A
  /// directly-declared tool whose schema uses one of these would have its
  /// arguments corrupted by the direct-call normalization path (e.g. a
  /// `params` property being unwrapped as the nested-params slot), so such
  /// tools stay on the call_tool wrapper only.
  static const Set<String> _reservedArgumentNames = {
    'service_name',
    'serviceName',
    'service',
    'tool_name',
    'toolName',
    'tool',
    'params',
    'param',
    'parameters',
  };

  /// Individual function declarations for the active tools (cloud chat
  /// models). With a real schema per tool, constrained decoding (Gemini
  /// VALIDATED mode / OpenAI function calling) structurally rejects
  /// malformed arguments that a prose catalog cannot prevent.
  ///
  /// Only tools whose bare name is globally unique across the active set
  /// (the engine dispatches direct calls by unique name) and valid as a
  /// function name are declared. Everything else — plus all declared tools,
  /// for backward compatibility — stays callable through the `call_tool`
  /// wrapper, which callers should append after these declarations.
  static List<Map<String, dynamic>> buildPerToolDeclarations(
    Map<String, List<McpTool>> toolsByEndpoint,
  ) {
    final nameCounts = <String, int>{};
    for (final tools in toolsByEndpoint.values) {
      for (final tool in tools) {
        nameCounts[tool.name] = (nameCounts[tool.name] ?? 0) + 1;
      }
    }

    final declarations = <Map<String, dynamic>>[];
    for (final entry in toolsByEndpoint.entries) {
      for (final tool in entry.value) {
        if (declarations.length >= maxPerToolDeclarations) {
          LoggerService.warning(
            'Per-tool declaration cap ($maxPerToolDeclarations) reached; '
            'remaining tools stay on the call_tool wrapper',
          );
          return declarations;
        }
        if (nameCounts[tool.name] != 1) continue;
        if (!_validFunctionName.hasMatch(tool.name)) continue;
        if (tool.name == 'call_tool') continue;
        final topLevelProps = tool.inputSchema?['properties'];
        if (topLevelProps is Map &&
            topLevelProps.keys.any(
              (key) => _reservedArgumentNames.contains(key.toString()),
            )) {
          continue;
        }
        final description = tool.description?.trim();
        declarations.add({
          'name': tool.name,
          'description': (description == null || description.isEmpty)
              ? tool.name
              : description,
          'parameters': sanitizeSchemaForDeclaration(tool.inputSchema),
        });
      }
    }
    return declarations;
  }

  /// Deep-copies a JSON schema keeping only the structural keywords the
  /// cloud declaration formats support (an OpenAPI subset). Documentation
  /// keywords (`examples`) are dropped; schemas using unsupported structure
  /// (`$ref`, `oneOf`, type arrays, ...) fall back to a permissive object so
  /// the tool is never rejected by the API or silently dropped.
  static Map<String, dynamic> sanitizeSchemaForDeclaration(
    Map<String, dynamic>? schema,
  ) {
    final sanitized = schema == null ? null : _sanitizeSchemaNode(schema);
    return sanitized ?? {'type': 'object'};
  }

  static Map<String, dynamic>? _sanitizeSchemaNode(Map<String, dynamic> node) {
    const unsupportedKeys = {r'$ref', 'oneOf', 'anyOf', 'allOf', 'not'};
    if (node.keys.any(unsupportedKeys.contains)) return null;

    final type = node['type'];
    final hasProperties = node['properties'] is Map;
    if (type is! String && !hasProperties) return null;
    final effectiveType = type is String ? type : 'object';
    const knownTypes = {
      'object',
      'array',
      'string',
      'number',
      'integer',
      'boolean',
    };
    if (!knownTypes.contains(effectiveType)) return null;

    final sanitized = <String, dynamic>{'type': effectiveType};
    final description = node['description'];
    if (description is String && description.isNotEmpty) {
      sanitized['description'] = description;
    }

    final enumValues = node['enum'];
    if (enumValues is List &&
        enumValues.isNotEmpty &&
        enumValues.every((e) => e is String || e is num || e is bool)) {
      sanitized['enum'] = List<dynamic>.from(enumValues);
    }

    if (effectiveType == 'object') {
      final properties = node['properties'];
      if (properties is Map) {
        final sanitizedProps = <String, dynamic>{};
        for (final entry in properties.entries) {
          final value = entry.value;
          if (value is! Map) return null;
          final child = _sanitizeSchemaNode(value.cast<String, dynamic>());
          if (child == null) return null;
          sanitizedProps[entry.key.toString()] = child;
        }
        if (sanitizedProps.isNotEmpty) {
          sanitized['properties'] = sanitizedProps;
          final required = node['required'];
          if (required is List) {
            final requiredNames = required
                .whereType<String>()
                .where(sanitizedProps.containsKey)
                .toList();
            if (requiredNames.isNotEmpty) {
              sanitized['required'] = requiredNames;
            }
          }
        }
      }
    } else if (effectiveType == 'array') {
      final items = node['items'];
      if (items is Map) {
        final child = _sanitizeSchemaNode(items.cast<String, dynamic>());
        if (child == null) return null;
        sanitized['items'] = child;
      }
    }

    return sanitized;
  }

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
    } on McpToolErrorException catch (e) {
      // The server executed the tool and the tool itself failed
      // (CallToolResult.isError). Deterministic — not retryable as-is.
      LoggerService.error('MCP tool reported error: $e');
      return ToolOutcome.failure(
        code: ToolOutcome.codeToolError,
        message: 'Tool $serviceName.$toolName failed: $e',
      ).serialize();
    } catch (e) {
      // Connection/transport-level failure — eligible for retry.
      LoggerService.error('Error executing MCP tool call: $e');
      return ToolOutcome.failure(
        code: ToolOutcome.codeTransportError,
        message: 'Error executing tool $serviceName.$toolName: $e',
        retryable: true,
      ).serialize();
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
