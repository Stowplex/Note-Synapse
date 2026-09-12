import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';
import 'package:yaml/yaml.dart';

import '../models/app_revision.dart';
import '../models/mcp_endpoint.dart';
import '../models/note.dart';
import '../models/user_app.dart';
import '../models/generation_context.dart';
import '../providers/app_provider.dart';
import '../services/logger_service.dart';
import '../services/user_app_runtime_bridge.dart';
import '../services/user_app_service.dart';

class AiToolDefinition {
  AiToolDefinition({
    required this.toolName,
    required this.description,
    required this.parameterSchema,
    this.outputSchema,
  });

  final String toolName;
  final String description;
  final Map<String, dynamic> parameterSchema;
  final Map<String, dynamic>? outputSchema;
}

class AiToolAppBundle {
  AiToolAppBundle({
    required this.app,
    required this.revision,
    required this.serviceName,
    required this.toolDefinitions,
  });

  final UserApp app;
  final AppRevision revision;
  final String serviceName;
  final List<AiToolDefinition> toolDefinitions;

  List<McpTool> toMcpTools() {
    return toolDefinitions
        .map(
          (def) => McpTool(
            name: def.toolName,
            description: def.description,
            inputSchema: def.parameterSchema,
            outputSchema: def.outputSchema,
          ),
        )
        .toList();
  }
}

class AiToolRuntime {
  AiToolRuntime({
    required this.bundle,
    required this.appProvider,
    this.onModificationRequest,
    this.onSqlWriteApprovalRequest,
  });

  final AiToolAppBundle bundle;
  final AppProvider appProvider;

  /// Optional callback for note modification approval.
  final ModificationRequestCallback? onModificationRequest;

  /// Optional callback for SQL write approval.
  final SqlWriteApprovalCallback? onSqlWriteApprovalRequest;

  HeadlessInAppWebView? _headlessWebView;
  InAppWebViewController? _controller;
  UserAppRuntimeBridge? _bridge;
  Completer<void>? _loadCompleter;

  // Console log collection for invoke operations
  bool _isCollectingConsoleLogs = false;
  final List<String> _consoleLogBuffer = [];

  Future<void> _ensureRunning() async {
    if (!UserAppService.isWebViewSupported()) {
      throw Exception('AI tools are not supported on this platform.');
    }

    if (_headlessWebView != null) {
      final isRunning = _headlessWebView!.isRunning();
      if (isRunning) {
        return _loadCompleter?.future ?? Future.value();
      }
    }

    _loadCompleter = Completer<void>();
    _bridge = UserAppRuntimeBridge(
      app: bundle.app,
      appProvider: appProvider,
      revisionNumber: bundle.revision.revisionNumber,
      isInteractive: false,
      selectedNotes: const <Note>[],
      onModificationRequest: onModificationRequest,
      onSqlWriteApprovalRequest: onSqlWriteApprovalRequest,
    );
    _headlessWebView = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
        data: bundle.revision.appCode,
        mimeType: 'text/html',
        encoding: 'utf8',
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        resourceCustomSchemes: const ['synapse', 'synapseuser'],
        clearCache: true,
        cacheEnabled: true,
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        _bridge!.buildBootstrapScript(),
      ]),
      onWebViewCreated: (controller) {
        _controller = controller;
        _bridge!.registerJavaScriptHandlers(controller);
      },
      onLoadStart: (controller, url) {
        _bridge!.pageDidStartLoading();
      },
      onLoadStop: (controller, url) async {
        await _bridge!.pageDidFinishLoading();
        if (!(_loadCompleter?.isCompleted ?? true)) {
          _loadCompleter!.complete();
        }
      },
      onLoadError: (controller, url, code, message) {
        if (!(_loadCompleter?.isCompleted ?? true)) {
          _loadCompleter!.completeError(
            Exception(
              'Failed to load AI tool ${bundle.app.name}: $message ($code)',
            ),
          );
        }
      },
      onConsoleMessage: (controller, consoleMessage) {
        final levelLabel = consoleMessage.messageLevel
            .toString()
            .split('.')
            .last
            .toUpperCase();
        final logMessage = '[$levelLabel] ${consoleMessage.message}';

        // If we're collecting logs for an invoke operation, add to buffer
        if (_isCollectingConsoleLogs) {
          _consoleLogBuffer.add(logMessage);
        }

        LoggerService.debug('[AiTool.${bundle.app.name}] $logMessage');
      },
      onLoadResourceWithCustomScheme: (controller, request) async {
        final scheme = request.url.scheme.toLowerCase();
        if (scheme == 'synapse') {
          try {
            final assetPath = 'assets/scripts/${request.url.host}';
            final data = await rootBundle.loadString(assetPath);
            return CustomSchemeResponse(
              data: Uint8List.fromList(utf8.encode(data)),
              contentType: 'text/plain',
            );
          } catch (e) {
            LoggerService.warning(
              'Failed to load synapse asset for AI tool ${bundle.app.name}: ${request.url}',
            );
            return null;
          }
        }

        return await _bridge!.handleSynapseUserScheme(request.url);
      },
    );

    await _headlessWebView!.run();
    await _loadCompleter!.future;

    // Ensure the Synapse tool namespace is ready before allowing invocation.
    if (_controller != null) {
      await _controller!.callAsyncJavaScript(
        functionBody:
            'return !!window.Synapse && !!window.Synapse.tool && !!window.Synapse.tool.registered;',
      );
    }
  }

  Future<String> invoke(
    String toolName,
    Map<String, dynamic> params,
    GenerationContext generationContext,
  ) async {
    await _ensureRunning();
    // Republish the Space before every call. This runtime keeps its WebView
    // alive across invocations *and* across Space switches, and it is the one
    // consumer of the bridge with no subscriber to the provider — the
    // interactive `UserAppWebView` listens and forwards, a headless tool has
    // no widget tree to listen from. Without this a generated tool follows
    // half of the documented contract: it scopes its queries by `space.tags`
    // from the boot-time value and never receives `synapse:spacechanged`, so
    // it keeps scoping to a Space the user has left.
    await _bridge?.republishContextIfChanged();
    final controller = _controller;
    if (controller == null) {
      throw Exception(
        'AI tool runtime controller not available for ${bundle.app.name}',
      );
    }

    // Start collecting console logs
    _isCollectingConsoleLogs = true;
    _consoleLogBuffer.clear();
    final startTime = DateTime.now();
    final requestId = generationContext.ensureRequestId();
    final endpoint = 'AI Tool Invoke: ${bundle.app.name}.$toolName';

    try {
      final jsResult = await controller.callAsyncJavaScript(
        functionBody:
            'return window.Synapse && window.Synapse.tool && window.Synapse.tool.invoke ? window.Synapse.tool.invoke(toolName, params) : null;',
        arguments: {'toolName': toolName, 'params': params},
      );

      final value = jsResult?.value;
      final result = value == null
          ? 'null'
          : value is String
          ? value
          : (() {
              try {
                return const JsonEncoder.withIndent('  ').convert(value);
              } catch (_) {
                return value.toString();
              }
            })();

      // Stop collecting and log all console messages as one entry
      _isCollectingConsoleLogs = false;
      final duration = DateTime.now().difference(startTime);

      if (_consoleLogBuffer.isNotEmpty) {
        final concatenatedLogs = _consoleLogBuffer.join('\n');
        LoggerService.logAiConsole(
          consoleOutput: concatenatedLogs,
          endpoint: endpoint,
          requestId: requestId,
          duration: duration,
        );
      }

      _consoleLogBuffer.clear();
      return result;
    } catch (e) {
      // Stop collecting even on error
      _isCollectingConsoleLogs = false;
      final duration = DateTime.now().difference(startTime);

      // Log console messages if any were collected
      if (_consoleLogBuffer.isNotEmpty) {
        final concatenatedLogs = _consoleLogBuffer.join('\n');
        LoggerService.logAiConsole(
          consoleOutput: concatenatedLogs,
          endpoint: endpoint,
          requestId: requestId,
          duration: duration,
        );
      }

      _consoleLogBuffer.clear();
      rethrow;
    }
  }

  Future<void> dispose() async {
    try {
      if (_headlessWebView != null) {
        if (_headlessWebView!.isRunning()) {
          await _headlessWebView!.dispose();
        }
      }
    } catch (e) {
      LoggerService.warning(
        'Error disposing AI tool runtime for ${bundle.app.name}: $e',
      );
    } finally {
      _bridge?.detach();
      _headlessWebView = null;
      _controller = null;
      _bridge = null;
      _loadCompleter = null;
    }
  }
}

class AiToolService {
  static Future<AiToolAppBundle?> loadAppBundle({
    required UserApp app,
    required AppRevision revision,
  }) async {
    final html = revision.appCode;
    final toolSpecPattern = RegExp(
      r'<!\[CDATA\[\s*tool_spec(.*?)\]\]>',
      dotAll: true,
    );
    final toolSpecMatch = toolSpecPattern.firstMatch(html);
    if (toolSpecMatch == null) {
      LoggerService.warning(
        'AI tool "${app.name}" is missing CDATA tool_spec block.',
      );
      return null;
    }

    final yamlText = _dedent(toolSpecMatch.group(1)!);
    if (yamlText.isEmpty) {
      LoggerService.warning(
        'AI tool "${app.name}" CDATA tool_spec block is empty.',
      );
      return null;
    }

    if (!RegExp(r'-\s*name\s*:').hasMatch(yamlText)) {
      final errorMessage =
          'AI tool "${app.name}" tool_spec block does not contain any tool definitions.';
      LoggerService.warning(errorMessage);
      LoggerService.logAiError(
        error: errorMessage,
        endpoint: 'AI Tool Load: ${app.name}',
      );
      return null;
    }
    dynamic parsedYaml;
    try {
      parsedYaml = loadYaml(yamlText);
    } catch (e) {
      final errorMessage = 'Failed to parse YAML for AI tool "${app.name}": $e';
      LoggerService.error(errorMessage);
      LoggerService.logAiError(
        error: errorMessage,
        endpoint: 'AI Tool Load: ${app.name}',
      );
      return null;
    }

    if (parsedYaml is! YamlList) {
      final errorMessage =
          'AI tool "${app.name}" YAML header must be a list of tools.';
      LoggerService.warning(errorMessage);
      LoggerService.logAiError(
        error: errorMessage,
        endpoint: 'AI Tool Load: ${app.name}',
      );
      return null;
    }

    final toolDefinitions = <AiToolDefinition>[];

    for (final entry in parsedYaml) {
      if (entry is! YamlMap) continue;
      final toolName = entry['name']?.toString().trim();
      if (toolName == null || toolName.isEmpty) {
        continue;
      }

      final description = entry['description']?.toString().trim() ?? '';
      final parameterSchema = _buildParameterSchema(entry['input_params']);
      final outputSchema = _buildOptionalParameterSchema(
        entry['output_params'],
      );

      toolDefinitions.add(
        AiToolDefinition(
          toolName: toolName,
          description: description.isEmpty
              ? 'User-defined tool generated from ${app.name}'
              : description,
          parameterSchema: parameterSchema,
          outputSchema: outputSchema,
        ),
      );
    }

    if (toolDefinitions.isEmpty) {
      LoggerService.warning(
        'AI tool "${app.name}" did not define any callable tools.',
      );
      return null;
    }

    final serviceName = _buildServiceName(app);
    return AiToolAppBundle(
      app: app,
      revision: revision,
      serviceName: serviceName,
      toolDefinitions: toolDefinitions,
    );
  }

  static String _buildServiceName(UserApp app) {
    final slug = app.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp('_+'), '_')
        .trim();
    final suffix = app.uuid.substring(0, 8);
    final base = slug.isEmpty ? 'tool' : slug;
    return 'NS/${base}_$suffix';
  }

  static Map<String, dynamic> _buildParameterSchema(dynamic inputParams) {
    final properties = <String, dynamic>{};
    final requiredFields = <String>[];

    void addParam(
      String name,
      Map<String, dynamic> schema, {
      required bool optional,
    }) {
      properties[name] = schema;
      if (!optional) {
        requiredFields.add(name);
      }
    }

    if (inputParams is YamlList) {
      for (final paramEntry in inputParams) {
        if (paramEntry is YamlMap) {
          for (final key in paramEntry.keys) {
            final name = key.toString();
            final value = paramEntry[key];
            if (value is YamlMap) {
              final schema = _schemaFromSpec(value);
              final optional = value['optional'] == true;
              addParam(name, schema, optional: optional);
            } else {
              final schema = _schemaFromType(value?.toString() ?? 'string');
              addParam(name, schema, optional: false);
            }
          }
        }
      }
    } else if (inputParams is YamlMap) {
      for (final key in inputParams.keys) {
        final name = key.toString();
        final value = inputParams[key];
        if (value is YamlMap) {
          final schema = _schemaFromSpec(value);
          final optional = value['optional'] == true;
          addParam(name, schema, optional: optional);
        } else {
          final schema = _schemaFromType(value?.toString() ?? 'string');
          addParam(name, schema, optional: false);
        }
      }
    }

    final result = <String, dynamic>{
      'type': 'object',
      'properties': properties,
    };
    if (requiredFields.isNotEmpty) {
      result['required'] = requiredFields;
    }
    return result;
  }

  static Map<String, dynamic>? _buildOptionalParameterSchema(dynamic params) {
    if (params == null) {
      return null;
    }
    final schema = _buildParameterSchema(params);
    final properties = schema['properties'];
    if (properties is Map && properties.isNotEmpty) {
      return schema;
    }
    return null;
  }

  static Map<String, dynamic> _schemaFromSpec(dynamic spec) {
    if (spec is YamlMap) {
      return _schemaFromYamlMap(spec);
    } else if (spec is Map) {
      return _schemaFromYamlMap(YamlMap.wrap(spec));
    } else if (spec is String) {
      return _schemaFromType(spec);
    } else if (spec != null) {
      return _schemaFromType(spec.toString());
    }
    return _schemaFromType('string');
  }

  static Map<String, dynamic> _schemaFromYamlMap(YamlMap spec) {
    final typeValue = spec['type']?.toString() ?? 'string';
    final schema = _schemaFromType(typeValue);

    void copyKey(String yamlKey, {String? targetKey}) {
      if (spec.containsKey(yamlKey)) {
        final value = spec[yamlKey];
        if (value != null) {
          schema[targetKey ?? yamlKey] = value;
        }
      }
    }

    copyKey('description');
    copyKey('default');
    copyKey('title');
    copyKey('format');
    copyKey('pattern');
    copyKey('minimum');
    copyKey('maximum');
    copyKey('exclusiveMinimum');
    copyKey('exclusiveMaximum');
    copyKey('multipleOf');
    copyKey('minLength');
    copyKey('maxLength');
    copyKey('minItems');
    copyKey('maxItems');
    copyKey('uniqueItems');
    copyKey('examples');
    copyKey('const');
    copyKey('deprecated');

    final enumValue = spec['enum'];
    if (enumValue is YamlList) {
      schema['enum'] = List<dynamic>.from(enumValue);
    } else if (enumValue is List) {
      schema['enum'] = List<dynamic>.from(enumValue);
    }

    if (schema['type'] == 'array' && spec.containsKey('items')) {
      schema['items'] = _schemaFromItemsSpec(spec['items']);
    }

    if (schema['type'] == 'object') {
      final propertiesSpec = spec['properties'];
      final requiredSet = <String>{};

      if (propertiesSpec != null) {
        final nestedSchema = _buildParameterSchema(propertiesSpec);
        schema['properties'] = Map<String, dynamic>.from(
          nestedSchema['properties'] ?? <String, dynamic>{},
        );

        final nestedRequired = nestedSchema['required'];
        if (nestedRequired is List) {
          requiredSet.addAll(nestedRequired.map((e) => e.toString()));
        }
      } else {
        schema['properties'] = schema['properties'] ?? <String, dynamic>{};
      }

      final explicitRequired = spec['required'];
      if (explicitRequired is YamlList) {
        requiredSet.addAll(explicitRequired.map((e) => e.toString()));
      } else if (explicitRequired is List) {
        requiredSet.addAll(explicitRequired.map((e) => e.toString()));
      }

      if (requiredSet.isNotEmpty) {
        schema['required'] = requiredSet.toList();
      } else {
        schema.remove('required');
      }

      if (spec.containsKey('additionalProperties')) {
        final additional = spec['additionalProperties'];
        if (additional is bool || additional == null) {
          schema['additionalProperties'] = additional;
        } else if (additional is YamlMap || additional is Map) {
          schema['additionalProperties'] = _schemaFromSpec(additional);
        } else if (additional is String) {
          schema['additionalProperties'] = _schemaFromType(additional);
        }
      }
    }

    return schema;
  }

  static dynamic _schemaFromItemsSpec(dynamic items) {
    if (items is YamlMap || items is Map || items is String) {
      return _schemaFromSpec(items);
    } else if (items is YamlList) {
      return items.map((item) => _schemaFromSpec(item)).toList();
    } else if (items is List) {
      return items.map((item) => _schemaFromSpec(item)).toList();
    }
    return _schemaFromType('string');
  }

  static Map<String, dynamic> _schemaFromType(String typeName) {
    switch (typeName.toLowerCase()) {
      case 'string':
        return {'type': 'string'};
      case 'number':
        return {'type': 'number'};
      case 'integer':
        return {'type': 'integer'};
      case 'boolean':
        return {'type': 'boolean'};
      case 'array':
        return {
          'type': 'array',
          'items': {'type': 'string'},
        };
      case 'object':
        return {'type': 'object', 'properties': <String, dynamic>{}};
      default:
        return {'type': 'string'};
    }
  }

  static String _dedent(String text) {
    if (text.trim().isEmpty) return '';

    final lines = text.split('\n');
    int? minIndent;

    for (final line in lines) {
      if (line.trim().isEmpty) continue;

      int indent = 0;
      for (int i = 0; i < line.length; i++) {
        if (line[i] != ' ') break;
        indent++;
      }

      if (minIndent == null || indent < minIndent) {
        minIndent = indent;
      }
    }

    if (minIndent == null || minIndent == 0) return text.trim();

    final buffer = StringBuffer();
    for (final line in lines) {
      if (line.length >= minIndent) {
        if (line.trim().isEmpty) {
          buffer.writeln('');
        } else {
          buffer.writeln(line.substring(minIndent));
        }
      } else {
        if (line.trim().isEmpty) {
          buffer.writeln('');
        } else {
          buffer.writeln(line);
        }
      }
    }
    return buffer.toString().trim();
  }
}
