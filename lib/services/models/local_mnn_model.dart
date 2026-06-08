import 'dart:async';
import 'dart:io';

import 'package:edge_gen/edge_gen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/services/attachment_preprocessor.dart';
import 'package:note_synapse/services/logger_service.dart';
import 'package:note_synapse/services/models/ai_model.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';
import 'package:note_synapse/services/models/local_model_tool_templates/function_call_parser.dart';
import 'package:note_synapse/services/models/local_model_tool_templates/local_model_type.dart';
import 'package:note_synapse/services/models/local_model_tool_templates/model_response.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';

/// On-device model runtime backed by MNN via the edge_gen bridge.
///
/// Text generation uses the chat-message path (model chat template applied
/// natively); tool calls are requested via the structured path and parsed out
/// of the model's text stream with the family-specific [FunctionCallParser]
/// (edge_gen emits plain text, not typed tool-call objects).
class LocalMnnModel extends AIModel {
  LocalMnnModel({QwenModelDownloader? downloader, EdgeGenController? controller})
    : _downloader = downloader ?? QwenModelDownloader(),
      _controllerOverride = controller;

  final QwenModelDownloader _downloader;
  final EdgeGenController? _controllerOverride;

  // Resolved lazily so constructing the model (e.g. for buildToolDeclarations
  // in unit tests) doesn't touch the platform-channel-backed singleton.
  EdgeGenController get _controller =>
      _controllerOverride ?? EdgeGenController.instance;

  EdgeGenSession? _session;
  ModelConfig? _config;
  LocalModelPreset? _preset;
  bool _isInitialized = false;

  @override
  bool get supportsStreaming => true;

  @override
  bool get usesNativeToolDeclarations => true;

  @override
  String get id => _config?.id ?? 'local_mnn';

  @override
  String get name =>
      _config?.displayName ?? _preset?.displayName ?? 'Local Model';

  @override
  String get description => 'On-device AI model via MNN';

  @override
  Future<bool> isReady() async => _isInitialized;

  @override
  Future<void> initialize({ModelConfig? config}) async {
    _config = config;
    _preset = config?.modelName != null
        ? LocalModelPresets.findById(config!.modelName!)
        : null;
    _isInitialized = _preset != null;
  }

  // ---------------------------------------------------------------------------
  // Session lifecycle
  // ---------------------------------------------------------------------------

  Future<EdgeGenSession> _ensureSession() async {
    final existing = _session;
    if (existing != null) return existing;

    final preset = _preset;
    if (preset == null) {
      throw Exception('Unsupported local model preset');
    }

    final downloaded = await _downloader.isDownloaded(preset.mnnSpec);
    if (!downloaded) {
      throw Exception('Local model is not downloaded yet.');
    }

    final configPath = _config?.endpoint?.isNotEmpty == true
        ? _config!.endpoint!
        : await _downloader.resolveConfigPath(preset.mnnSpec);

    final session = await _controller.openSession(
      configPath: configPath,
      configJson: _buildConfig().toJson(),
    );
    _session = session;
    return session;
  }

  EdgeGenConfig _buildConfig() {
    final preset = _preset;
    return EdgeGenConfig(
      backendType: _resolvedBackend,
      precision: 'low',
      memory: 'low',
      useMmap: true,
      reuseKv: true,
      maxNewTokens: _resolvedTokenWindow,
      temperature: preset?.temperature ?? 0.7,
      topK: preset?.topK ?? 40,
      topP: preset?.topP ?? 0.9,
      attentionMode: _resolvedAttentionMode,
      enableThinking:
          (preset?.supportsThinking ?? false) && (_config?.enableThinking ?? false),
    );
  }

  String get _resolvedBackend {
    final configured = _config?.backendType;
    if (configured != null && configured.isNotEmpty) {
      return configured;
    }
    final platformKey = Platform.isIOS ? 'ios' : 'android';
    return _preset?.defaultBackend[platformKey] ?? 'cpu';
  }

  /// KV-cache quantization + flash attention bitmask. 12 = TQ4 K+V + flash
  /// attention, which slashes KV/attention memory for long (multimodal)
  /// prefills — but flash attention is CPU-only on MNN, so only enable it on the
  /// CPU backend. GPU backends keep the unquantized default (0).
  int get _resolvedAttentionMode => _resolvedBackend == 'cpu' ? 12 : 0;

  int get _resolvedTokenWindow {
    final preset = _preset;
    if (preset == null) {
      return _config?.tokenWindow ?? 8192;
    }
    final requested = _config?.tokenWindow ?? preset.defaultTokenWindow;
    return requested.clamp(preset.minTokenWindow, preset.maxTokenWindow);
  }

  LocalModelFamily get _family => _preset?.family ?? LocalModelFamily.qwen;

  @override
  Future<void> dispose() async {
    final session = _session;
    _session = null;
    if (session != null) {
      await session.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Message + tool + image conversion
  // ---------------------------------------------------------------------------

  /// Convert prompt messages into edge_gen's structured message maps. System,
  /// user, assistant (with any prior tool calls) and tool-result roles are all
  /// rendered by the model chat template on the native side.
  List<Map<String, dynamic>> _toEdgeGenMessages(List<PromptMessage> messages) {
    final result = <Map<String, dynamic>>[];
    for (final message in messages) {
      switch (message.role) {
        case PromptRole.system:
          if (message.content.trim().isNotEmpty) {
            result.add({'role': 'system', 'content': message.content});
          }
          break;
        case PromptRole.user:
          result.add({'role': 'user', 'content': message.content});
          break;
        case PromptRole.assistant:
          final map = <String, dynamic>{
            'role': 'assistant',
            'content': message.content,
          };
          final functionCalls = message.metadata?['function_calls'];
          if (functionCalls is List && functionCalls.isNotEmpty) {
            map['tool_calls'] = _toToolCallList(functionCalls);
          }
          result.add(map);
          break;
        case PromptRole.tool:
          result.add({
            'role': 'tool',
            'name': message.metadata?['function_name']?.toString() ?? 'call_tool',
            'content': message.content,
          });
          break;
      }
    }
    return result;
  }

  List<Map<String, dynamic>> _toToolCallList(List<dynamic> rawCalls) {
    return rawCalls.whereType<Map>().map((rawCall) {
      final call = rawCall.map((key, value) => MapEntry(key.toString(), value));
      return {
        'type': 'function',
        'function': {
          'name': call['name'],
          'arguments': call['args'] ?? const <String, dynamic>{},
        },
      };
    }).toList(growable: false);
  }

  /// Wrap MCP tool declarations in the OpenAI-style function schema the chat
  /// templates expect.
  List<Map<String, dynamic>> _toEdgeGenTools(List<Map<String, dynamic>> tools) {
    return tools.map((tool) {
      final function = tool['function'] is Map<String, dynamic>
          ? tool['function'] as Map<String, dynamic>
          : tool;
      return {
        'type': 'function',
        'function': {
          'name': function['name']?.toString() ?? 'call_tool',
          'description': function['description']?.toString() ?? '',
          'parameters': function['parameters'] is Map<String, dynamic>
              ? function['parameters'] as Map<String, dynamic>
              : const <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
        },
      };
    }).toList(growable: false);
  }

  Future<List<Uint8List>> _collectImages(List<PromptMessage> messages) async {
    if (!(_preset?.supportsVision ?? false)) return const [];
    final images = <Uint8List>[];
    for (final message in messages) {
      if (message.role != PromptRole.user) continue;
      images.addAll(await _readSupportedImageAttachments(message.attachments));
    }
    // Cap the number of images — each one adds a block of vision tokens, so an
    // unbounded count can exhaust memory during prefill.
    final maxImages = _preset?.maxNumImages;
    if (maxImages != null && images.length > maxImages) {
      LoggerService.info(
        'Local MNN truncating images to maxNumImages',
        error: {'count': images.length, 'maxNumImages': maxImages},
      );
      return images.sublist(0, maxImages);
    }
    return images;
  }

  // ---------------------------------------------------------------------------
  // Generation
  // ---------------------------------------------------------------------------

  @override
  Future<String> generateWithMessages(
    List<PromptMessage> messages, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) async {
    final requestId =
        generationContext?.ensureRequestId() ??
        DateTime.now().millisecondsSinceEpoch.toString();
    final startTime = DateTime.now();
    final endpoint = 'local-mnn://$name';

    try {
      final sanitized = await _sanitizeMessages(messages, requestId);
      final coalesced = _coalesceUserMessages(sanitized);
      LoggerService.logAiRequest(
        endpoint: endpoint,
        headers: {'backend': _resolvedBackend},
        requestBody: _buildLogBody(coalesced, tools: const []),
        requestId: requestId,
      );

      final session = await _ensureSession();
      final images = await _collectImages(coalesced);
      final buffer = StringBuffer();
      await for (final chunk in session.generateWithMessages(
        messages: _toRoleContent(coalesced),
        images: images.isEmpty ? null : images,
        maxNewTokens: maxOutputTokens,
      )) {
        buffer.write(chunk);
      }
      final text = buffer.toString();

      LoggerService.logAiResponse(
        statusCode: 200,
        headers: {'model': name},
        responseBody: {'text': text},
        requestId: requestId,
        duration: DateTime.now().difference(startTime),
      );
      return text;
    } catch (e) {
      LoggerService.logAiError(
        error: e.toString(),
        endpoint: endpoint,
        requestId: requestId,
        duration: DateTime.now().difference(startTime),
      );
      rethrow;
    }
  }

  /// edge_gen's plain message path takes role/content strings.
  List<Map<String, String>> _toRoleContent(List<PromptMessage> messages) {
    return _toEdgeGenMessages(messages)
        .map(
          (m) => <String, String>{
            'role': m['role'].toString(),
            'content': m['content']?.toString() ?? '',
          },
        )
        .toList(growable: false);
  }

  @override
  List<Map<String, dynamic>> buildToolDeclarations(
    Map<String, List<McpTool>> toolsByEndpoint,
  ) {
    if (toolsByEndpoint.isEmpty) return [];
    final declarations = <Map<String, dynamic>>[];
    for (final entry in toolsByEndpoint.entries) {
      for (final tool in entry.value) {
        declarations.add({
          'name': tool.name,
          'description': tool.description ?? tool.name,
          'parameters':
              tool.inputSchema ??
              {'type': 'object', 'properties': <String, dynamic>{}},
        });
      }
    }
    return declarations;
  }

  @override
  Future<Map<String, dynamic>> generateWithToolsAndMessages(
    List<PromptMessage> messages,
    List<Map<String, dynamic>> tools, {
    double? temperature,
    int? topK,
    double? topP,
    int? maxOutputTokens,
    GenerationContext? generationContext,
  }) async {
    final requestId =
        generationContext?.ensureRequestId() ??
        DateTime.now().millisecondsSinceEpoch.toString();
    final startTime = DateTime.now();
    final endpoint = 'local-mnn://$name/tools';

    try {
      final sanitized = await _sanitizeMessages(messages, requestId);
      final coalesced = _coalesceUserMessages(sanitized);
      LoggerService.logAiRequest(
        endpoint: endpoint,
        headers: {'backend': _resolvedBackend},
        requestBody: _buildLogBody(coalesced, tools: tools),
        requestId: requestId,
      );

      final fullText = await _runStructured(
        coalesced,
        tools,
        maxOutputTokens,
        onChunk: null,
      );
      final result = _parseToolResult(fullText);

      LoggerService.logAiResponse(
        statusCode: 200,
        headers: {'model': name},
        responseBody: result,
        requestId: requestId,
        duration: DateTime.now().difference(startTime),
      );
      return result;
    } catch (e) {
      LoggerService.logAiError(
        error: e.toString(),
        endpoint: endpoint,
        requestId: requestId,
        duration: DateTime.now().difference(startTime),
      );
      rethrow;
    }
  }

  /// Streaming generation with tool awareness. Streams plain-text chunks via
  /// [onChunk] (suppressing any tool-call markup) and returns the full result
  /// including parsed function calls.
  Future<Map<String, dynamic>> generateStreamingWithTools(
    List<PromptMessage> messages,
    List<Map<String, dynamic>> tools, {
    required void Function(String chunk) onChunk,
    GenerationContext? generationContext,
  }) async {
    final requestId =
        generationContext?.ensureRequestId() ??
        DateTime.now().millisecondsSinceEpoch.toString();
    final startTime = DateTime.now();
    final endpoint = 'local-mnn://$name/stream-tools';

    try {
      LoggerService.logAiRequest(
        endpoint: endpoint,
        headers: {'backend': _resolvedBackend},
        requestBody: _buildLogBody(messages, tools: tools),
        requestId: requestId,
      );

      final fullText = await _runStructured(
        messages,
        tools,
        null,
        onChunk: onChunk,
      );
      final result = _parseToolResult(fullText);

      LoggerService.logAiResponse(
        statusCode: 200,
        headers: {'model': name},
        responseBody: result,
        requestId: requestId,
        duration: DateTime.now().difference(startTime),
      );
      return result;
    } catch (e) {
      LoggerService.logAiError(
        error: e.toString(),
        endpoint: endpoint,
        requestId: requestId,
        duration: DateTime.now().difference(startTime),
      );
      rethrow;
    }
  }

  /// Run the structured (tool-aware) generation path, optionally forwarding
  /// confirmed plain-text chunks to [onChunk] while holding back tool-call
  /// markup. Returns the full accumulated text for parsing.
  Future<String> _runStructured(
    List<PromptMessage> messages,
    List<Map<String, dynamic>> tools,
    int? maxOutputTokens, {
    required void Function(String chunk)? onChunk,
  }) async {
    final session = await _ensureSession();
    final images = await _collectImages(messages);
    final format = FunctionCallParser.formatFor(_family);
    final buffer = StringBuffer();
    var holding = false;

    await for (final chunk in session.generateStructured(
      messages: _toEdgeGenMessages(messages),
      tools: tools.isEmpty ? null : _toEdgeGenTools(tools),
      images: images.isEmpty ? null : images,
      maxNewTokens: maxOutputTokens,
    )) {
      buffer.write(chunk);
      if (onChunk != null) {
        if (!holding && format.isFunctionCallStart(buffer.toString())) {
          holding = true; // tool-call markup begins — stop forwarding text.
        }
        if (!holding) {
          onChunk(chunk);
        }
      }
    }
    return buffer.toString();
  }

  Map<String, dynamic> _parseToolResult(String fullText) {
    final calls = FunctionCallParser.parseAll(fullText, family: _family);
    if (calls.isNotEmpty) {
      return {
        'text': '',
        'function_calls': calls
            .map((c) => {'name': c.name, 'args': c.args})
            .toList(growable: false),
        'modelUsed': name,
      };
    }
    return {'text': fullText, 'function_calls': null, 'modelUsed': name};
  }

  Stream<String> generateStreaming(
    List<PromptMessage> messages, {
    int? maxNewTokens,
    String? requestId,
  }) async* {
    final reqId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final startTime = DateTime.now();
    final endpoint = 'local-mnn://$name/stream';

    try {
      final sanitized = await _sanitizeMessages(messages, reqId);
      final coalesced = _coalesceUserMessages(sanitized);
      LoggerService.logAiRequest(
        endpoint: endpoint,
        headers: {'backend': _resolvedBackend},
        requestBody: _buildLogBody(coalesced, tools: const []),
        requestId: reqId,
      );

      final session = await _ensureSession();
      final images = await _collectImages(coalesced);
      final buffer = StringBuffer();
      await for (final chunk in session.generateWithMessages(
        messages: _toRoleContent(coalesced),
        images: images.isEmpty ? null : images,
        maxNewTokens: maxNewTokens,
      )) {
        buffer.write(chunk);
        yield chunk;
      }

      LoggerService.logAiResponse(
        statusCode: 200,
        headers: {'model': name},
        responseBody: {'text': buffer.toString()},
        requestId: reqId,
        duration: DateTime.now().difference(startTime),
      );
    } catch (e) {
      LoggerService.logAiError(
        error: e.toString(),
        endpoint: endpoint,
        requestId: reqId,
        duration: DateTime.now().difference(startTime),
      );
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Reusable helpers (preserved from the previous runtime)
  // ---------------------------------------------------------------------------

  @visibleForTesting
  List<PromptMessage> coalesceMessagesForGemma(List<PromptMessage> messages) {
    return _coalesceUserMessages(messages);
  }

  /// Merge consecutive user messages into a single turn (some chat templates
  /// reject two user turns in a row).
  List<PromptMessage> _coalesceUserMessages(List<PromptMessage> messages) {
    if (messages.isEmpty) {
      return const [];
    }

    final coalesced = <PromptMessage>[];
    PromptMessage? pendingUserMessage;

    void flushPendingUserMessage() {
      if (pendingUserMessage == null) {
        return;
      }
      coalesced.add(pendingUserMessage!);
      pendingUserMessage = null;
    }

    for (final message in messages) {
      if (message.role != PromptRole.user) {
        flushPendingUserMessage();
        coalesced.add(message);
        continue;
      }

      if (pendingUserMessage == null) {
        pendingUserMessage = message;
        continue;
      }

      final mergedContent = [
        pendingUserMessage!.content.trim(),
        message.content.trim(),
      ].where((part) => part.isNotEmpty).join('\n\n');

      final mergedAttachments = <PlatformFile>[
        ...pendingUserMessage!.attachments,
        ...message.attachments,
      ];

      pendingUserMessage = PromptMessage(
        role: PromptRole.user,
        content: mergedContent,
        attachments: mergedAttachments,
        metadata:
            {...?pendingUserMessage!.metadata, ...?message.metadata}.isEmpty
            ? null
            : {...?pendingUserMessage!.metadata, ...?message.metadata},
        isContext: pendingUserMessage!.isContext && message.isContext,
      );
    }

    flushPendingUserMessage();
    return coalesced;
  }

  // Longest-edge budget for images sent to the vision encoder. Vision-token
  // count (and prefill memory) scales with pixel area, so cap aggressively.
  static const int _maxImageEdgePx = 800;

  Future<List<Uint8List>> _readSupportedImageAttachments(
    List<PlatformFile> attachments,
  ) async {
    final images = <Uint8List>[];
    for (final attachment in attachments) {
      if (!_isSupportedImageFile(attachment)) {
        continue;
      }
      Uint8List? bytes;
      if (attachment.bytes != null && attachment.bytes!.isNotEmpty) {
        bytes = attachment.bytes!;
      } else {
        final path = attachment.path;
        if (path != null && path.isNotEmpty) {
          bytes = await File(path).readAsBytes();
        }
      }
      if (bytes == null) continue;
      // Decode/resize off the UI isolate — full-res photos are slow to decode
      // and would otherwise jank the app.
      images.add(
        await compute(
          _capImageLongEdge,
          _ImageCapRequest(bytes, _maxImageEdgePx),
        ),
      );
    }
    return images;
  }

  bool _isSupportedImageFile(PlatformFile file) {
    final name = file.name.toLowerCase();
    return name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.webp');
  }

  Map<String, dynamic> _buildLogBody(
    List<PromptMessage> messages, {
    required List<Map<String, dynamic>> tools,
  }) {
    return {
      'messages': messages
          .map(
            (message) => {
              'role': message.role.name,
              'content': message.content,
              if (message.attachments.isNotEmpty)
                'attachments': message.attachments
                    .map((file) => {'name': file.name, 'size': file.size})
                    .toList(),
              if (message.metadata != null) 'metadata': message.metadata,
            },
          )
          .toList(),
      'tools': tools,
      'mnnConfig': {
        'preset': _preset?.id,
        'family': _family.name,
        'backend': _resolvedBackend,
        'tokenWindow': _resolvedTokenWindow,
      },
    };
  }

  Future<List<PromptMessage>> _sanitizeMessages(
    List<PromptMessage> messages,
    String requestId,
  ) async {
    if (messages.isEmpty) {
      return messages;
    }

    final outcome = await AttachmentPreprocessor.sanitizeMessages(
      messages,
      config: _config,
    );

    AttachmentPreprocessor.logIgnoredAttachments(
      outcome.ignored,
      endpoint: '$name attachment_filter',
      requestId: requestId,
    );

    return outcome.messages;
  }

  @visibleForTesting
  List<FunctionCallResponse> parseToolCallsForTest(String text) {
    return FunctionCallParser.parseAll(text, family: _family);
  }

  // Retained so existing JSON-tool-call tests keep a stable entry point; now
  // delegates to the family-aware parser.
  @visibleForTesting
  Map<String, dynamic>? parseInjectedJsonToolCallForTest(String text) {
    final calls = FunctionCallParser.parseAll(
      text,
      family: LocalModelFamily.gemma,
    );
    if (calls.isEmpty) return null;
    return {'name': calls.first.name, 'args': calls.first.args};
  }
}

class _ImageCapRequest {
  const _ImageCapRequest(this.bytes, this.maxEdge);
  final Uint8List bytes;
  final int maxEdge;
}

/// Downscale [req.bytes] so its longest edge is <= [_ImageCapRequest.maxEdge]
/// pixels. Returns the original bytes if already within budget or undecodable.
/// Top-level so it can run in a background isolate via `compute`.
Uint8List _capImageLongEdge(_ImageCapRequest req) {
  final decoded = img.decodeImage(req.bytes);
  if (decoded == null) return req.bytes;
  final longest =
      decoded.width >= decoded.height ? decoded.width : decoded.height;
  if (longest <= req.maxEdge) return req.bytes;
  final resized = decoded.width >= decoded.height
      ? img.copyResize(decoded, width: req.maxEdge)
      : img.copyResize(decoded, height: req.maxEdge);
  return Uint8List.fromList(img.encodeJpg(resized, quality: 90));
}
