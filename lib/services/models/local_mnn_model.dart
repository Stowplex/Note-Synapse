import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:image/image.dart' as img;
import 'package:json_repair_flutter/json_repair_flutter.dart';

import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/services/logger_service.dart';
import 'package:note_synapse/services/models/ai_model.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';

class LocalMnnModel extends AIModel {
  gemma.InferenceModel? _model;
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
  String get description => 'On-device AI model via Flutter Gemma';

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

  Future<gemma.InferenceModel> _ensureModel() async {
    if (_model != null) {
      return _model!;
    }

    final preset = _preset;
    if (preset == null) {
      throw Exception('Unsupported local model preset');
    }

    final installed = await gemma.FlutterGemma.isModelInstalled(
      preset.filename,
    );
    if (!installed) {
      throw Exception('Local model is not downloaded yet.');
    }

    await gemma.FlutterGemma.installModel(
          modelType: preset.modelType,
          fileType: preset.fileType,
        )
        .fromNetwork(
          _config?.endpoint ?? preset.downloadUrl,
          foreground: preset.foregroundDownload,
        )
        .install();

    _model = await gemma.FlutterGemma.getActiveModel(
      maxTokens: _resolvedTokenWindow,
      preferredBackend: _preferredBackend,
      supportImage: preset.supportsVision,
      supportAudio: false,
      maxNumImages: _resolvedMaxNumImages,
    );
    return _model!;
  }

  int get _resolvedTokenWindow {
    final preset = _preset;
    if (preset == null) {
      return _config?.tokenWindow ?? 8192;
    }
    final requested = _config?.tokenWindow ?? preset.defaultTokenWindow;
    return requested.clamp(preset.minTokenWindow, preset.maxTokenWindow);
  }

  gemma.PreferredBackend? get _preferredBackend {
    switch (_config?.backendType) {
      case 'cpu':
        return gemma.PreferredBackend.cpu;
      case 'gpu':
        return gemma.PreferredBackend.gpu;
      default:
        return null;
    }
  }

  int? get _resolvedMaxNumImages {
    final preset = _preset;
    if (preset == null || !preset.supportsVision) {
      return null;
    }
    return preset.maxNumImages;
  }

  Future<gemma.InferenceChat> _createChat({
    required List<PromptMessage> messages,
    required List<Map<String, dynamic>> tools,
    double? temperature,
    int? topK,
    double? topP,
  }) async {
    final preset = _preset;
    if (preset == null) {
      throw Exception('Unsupported local model preset');
    }

    final model = await _ensureModel();
    final chat = await model.createChat(
      temperature: temperature ?? preset.temperature,
      randomSeed: 1,
      topK: topK ?? preset.topK,
      topP: topP ?? preset.topP,
      tokenBuffer: 256,
      supportImage: preset.supportsVision,
      supportAudio: false,
      supportsFunctionCalls: tools.isNotEmpty && preset.supportsToolCalls,
      tools: _toToolDeclarations(tools),
      toolChoice: tools.isEmpty ? gemma.ToolChoice.none : gemma.ToolChoice.auto,
      modelType: preset.modelType,
      systemInstruction: _extractSystemInstruction(messages),
    );

    await _appendConversation(chat, messages);
    return chat;
  }

  String? _extractSystemInstruction(List<PromptMessage> messages) {
    final parts = messages
        .where((message) => message.role == PromptRole.system)
        .map((message) => message.content.trim())
        .where((content) => content.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return null;
    }
    return parts.join('\n\n');
  }

  Future<void> _appendConversation(
    gemma.InferenceChat chat,
    List<PromptMessage> messages,
  ) async {
    final coalescedMessages = _coalesceMessagesForGemma(messages);
    LoggerService.info(
      'Local Gemma coalesced messages',
      error: {
        'count': coalescedMessages.length,
        'messages': coalescedMessages
            .map(
              (message) => {
                'role': message.role.name,
                'contentLength': message.content.length,
                'attachmentCount': message.attachments.length,
                'attachmentNames': message.attachments
                    .map((attachment) => attachment.name)
                    .toList(growable: false),
              },
            )
            .toList(growable: false),
      },
    );
    for (final message in coalescedMessages) {
      if (message.role == PromptRole.system) {
        continue;
      }
      final converted = await _toGemmaMessages(message);
      for (final gemmaMessage in converted) {
        await chat.addQueryChunk(gemmaMessage, message.role == PromptRole.tool);
      }
    }
  }

  @visibleForTesting
  List<PromptMessage> coalesceMessagesForGemma(List<PromptMessage> messages) {
    return _coalesceMessagesForGemma(messages);
  }

  List<PromptMessage> _coalesceMessagesForGemma(List<PromptMessage> messages) {
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

  Future<List<gemma.Message>> _toGemmaMessages(PromptMessage message) async {
    switch (message.role) {
      case PromptRole.system:
        return const [];
      case PromptRole.user:
        return _buildUserMessages(message);
      case PromptRole.assistant:
        return _buildAssistantMessages(message);
      case PromptRole.tool:
        return [_buildToolResponseMessage(message)];
    }
  }

  Future<List<gemma.Message>> _buildUserMessages(PromptMessage message) async {
    _logAttachmentDiagnostics(message);
    final images = await _readSupportedImageAttachments(message.attachments);
    var content = message.content.trim();

    if (images.isEmpty) {
      return [gemma.Message.text(text: content, isUser: true)];
    }

    final result = <gemma.Message>[
      gemma.Message.withImage(
        text: content,
        imageBytes: images.first,
        isUser: true,
      ),
    ];

    // TODO: On Android LiteRT-LM, follow-up imageOnly chunks appear to be
    // ignored or collapsed in practice for PDF-page context. Keep this path
    // raw for now so we can observe runtime behavior without workarounds.
    for (final image in images.skip(1)) {
      result.add(gemma.Message.imageOnly(imageBytes: image, isUser: true));
    }
    return result;
  }

  List<gemma.Message> _buildAssistantMessages(PromptMessage message) {
    final result = <gemma.Message>[];
    final functionCalls = message.metadata?['function_calls'];
    if (functionCalls is List && functionCalls.isNotEmpty) {
      result.add(
        gemma.Message.toolCall(
          text: jsonEncode(_toolCallEnvelope(functionCalls)),
        ),
      );
    }
    final content = message.content.trim();
    if (content.isNotEmpty) {
      result.add(gemma.Message.text(text: content, isUser: false));
    }
    return result;
  }

  gemma.Message _buildToolResponseMessage(PromptMessage message) {
    final toolName =
        message.metadata?['function_name']?.toString() ?? 'call_tool';
    final decoded = _decodeToolResponse(message.content);
    return gemma.Message.toolResponse(toolName: toolName, response: decoded);
  }

  Map<String, dynamic> _toolCallEnvelope(List<dynamic> rawCalls) {
    final calls = rawCalls.whereType<Map>().map((rawCall) {
      final call = rawCall.map((key, value) => MapEntry(key.toString(), value));
      return {
        'name': call['name'],
        'arguments': call['args'] ?? const <String, dynamic>{},
        if (call['id'] != null) 'id': call['id'],
      };
    }).toList();

    if (calls.length == 1) {
      return Map<String, dynamic>.from(calls.first);
    }
    return {'tool_calls': calls};
  }

  Map<String, dynamic> _decodeToolResponse(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      return {'result': decoded};
    } catch (_) {
      return {'result': content};
    }
  }

  List<gemma.Tool> _toToolDeclarations(List<Map<String, dynamic>> tools) {
    return tools
        .map((tool) {
          final function = tool['function'] is Map<String, dynamic>
              ? tool['function'] as Map<String, dynamic>
              : tool;
          return gemma.Tool(
            name: function['name']?.toString() ?? 'call_tool',
            description: function['description']?.toString() ?? '',
            parameters: function['parameters'] is Map<String, dynamic>
                ? function['parameters'] as Map<String, dynamic>
                : const <String, dynamic>{},
          );
        })
        .toList(growable: false);
  }

  Future<List<Uint8List>> _readSupportedImageAttachments(
    List<PlatformFile> attachments,
  ) async {
    final images = <Uint8List>[];
    for (final attachment in attachments) {
      if (!_isSupportedImageFile(attachment)) {
        continue;
      }
      if (attachment.bytes != null && attachment.bytes!.isNotEmpty) {
        images.add(attachment.bytes!);
        continue;
      }
      final path = attachment.path;
      if (path != null && path.isNotEmpty) {
        images.add(await File(path).readAsBytes());
      }
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

  void _logAttachmentDiagnostics(PromptMessage message) {
    if (message.attachments.isEmpty) {
      return;
    }

    final diagnostics = message.attachments
        .map((attachment) {
          final bytes = attachment.bytes;
          final resolvedBytesLength = bytes?.length;
          final decoded = bytes != null && bytes.isNotEmpty
              ? img.decodeImage(bytes)
              : null;
          final signature = bytes == null || bytes.isEmpty
              ? null
              : bytes
                    .take(8)
                    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
                    .join(' ');
          return {
            'name': attachment.name,
            'path': attachment.path,
            'declaredSize': attachment.size,
            'hasBytes': bytes != null,
            'resolvedBytesLength': resolvedBytesLength,
            'isSupportedImage': _isSupportedImageFile(attachment),
            'decoded': decoded != null,
            if (decoded != null) 'decodedWidth': decoded.width,
            if (decoded != null) 'decodedHeight': decoded.height,
            if (signature != null) 'signature': signature,
          };
        })
        .toList(growable: false);

    LoggerService.info(
      'Local Gemma attachment diagnostics',
      error: {
        'contentLength': message.content.length,
        'attachmentCount': message.attachments.length,
        'attachments': diagnostics,
      },
    );
  }

  Map<String, dynamic> _responseToToolResult(gemma.ModelResponse response) {
    if (response is gemma.FunctionCallResponse) {
      return {
        'text': '',
        'function_calls': [
          {'name': response.name, 'args': response.args},
        ],
        'modelUsed': name,
      };
    }

    if (response is gemma.ParallelFunctionCallResponse) {
      return {
        'text': '',
        'function_calls': response.calls
            .map((call) => {'name': call.name, 'args': call.args})
            .toList(growable: false),
        'modelUsed': name,
      };
    }

    if (response is gemma.ThinkingResponse) {
      return {
        'text': response.content,
        'function_calls': null,
        'modelUsed': name,
      };
    }

    final text = response is gemma.TextResponse ? response.token : '';
    final parsedToolCalls = _extractTaggedToolCalls(text);
    if (parsedToolCalls.calls.isNotEmpty) {
      return {
        'text': parsedToolCalls.cleanedText,
        'function_calls': parsedToolCalls.calls,
        'modelUsed': name,
      };
    }

    return {'text': text, 'function_calls': null, 'modelUsed': name};
  }

  @visibleForTesting
  ParsedToolCallText extractTaggedToolCallsForTest(String text) {
    return _extractTaggedToolCalls(text);
  }

  ParsedToolCallText _extractTaggedToolCalls(String text) {
    if (text.isEmpty) {
      return const ParsedToolCallText(cleanedText: '', calls: []);
    }

    final matches = _toolCallTagPattern
        .allMatches(text)
        .toList(growable: false);
    if (matches.isEmpty) {
      return ParsedToolCallText(cleanedText: text, calls: const []);
    }

    final calls = <Map<String, dynamic>>[];
    for (final match in matches) {
      final payload = match.group(1)?.trim();
      if (payload == null || payload.isEmpty) {
        continue;
      }

      final call = _parseTaggedToolCallPayload(payload);
      if (call != null) {
        calls.add(call);
      }
    }

    final cleanedText = text.replaceAll(_toolCallTagPattern, '').trim();
    return ParsedToolCallText(cleanedText: cleanedText, calls: calls);
  }

  Map<String, dynamic>? _parseTaggedToolCallPayload(String payload) {
    final argsStart = payload.indexOf('{');
    if (argsStart <= 0) {
      return null;
    }

    final functionName = payload.substring(0, argsStart).trim();
    if (functionName.isEmpty) {
      return null;
    }

    final argsText = _extractBalancedSegment(payload, argsStart);
    if (argsText == null) {
      return null;
    }

    final decodedArgs = _decodeLooseMap(argsText);
    if (decodedArgs == null) {
      return null;
    }

    return {'name': functionName, 'args': decodedArgs};
  }

  String? _extractBalancedSegment(String content, int startIdx) {
    int depth = 0;
    var inString = false;
    var escapeNext = false;

    for (int i = startIdx; i < content.length; i++) {
      final char = content[i];

      if (escapeNext) {
        escapeNext = false;
        continue;
      }

      if (char == '\\' && inString) {
        escapeNext = true;
        continue;
      }

      if (char == '"') {
        inString = !inString;
        continue;
      }

      if (inString) {
        continue;
      }

      if (char == '{') {
        depth++;
      } else if (char == '}') {
        depth--;
        if (depth == 0) {
          return content.substring(startIdx, i + 1);
        }
      }
    }

    return null;
  }

  Map<String, dynamic>? _decodeLooseMap(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      // Fall through to repairJson for Gemma's relaxed object syntax.
    }

    try {
      final repaired = repairJson(text);
      if (repaired is Map<String, dynamic>) {
        return repaired;
      }
      if (repaired is Map) {
        return repaired.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  Future<void> _disposeModel() async {
    final model = _model;
    _model = null;
    if (model != null) {
      await model.close();
    }
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
                    .map(
                      (file) => {
                        'name': file.name,
                        'path': file.path,
                        'size': file.size,
                        'hasBytes': file.bytes != null,
                      },
                    )
                    .toList(),
              if (message.metadata != null) 'metadata': message.metadata,
            },
          )
          .toList(),
      'tools': tools,
      'gemmaConfig': {
        'preset': _preset?.id,
        'backend': _config?.backendType ?? 'gpu',
        'tokenWindow': _resolvedTokenWindow,
      },
    };
  }

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
    final endpoint = 'local-gemma://$name';

    try {
      LoggerService.logAiRequest(
        endpoint: endpoint,
        headers: {'backend': _config?.backendType ?? 'gpu'},
        requestBody: _buildLogBody(messages, tools: const []),
        requestId: requestId,
      );

      final chat = await _createChat(
        messages: messages,
        tools: const [],
        temperature: temperature,
        topK: topK,
        topP: topP,
      );

      final response = await chat.generateChatResponse();
      final result = _responseToToolResult(response);
      final text = result['text']?.toString() ?? '';

      LoggerService.logAiResponse(
        statusCode: 200,
        headers: {'model': name},
        responseBody: result,
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
    } finally {
      await _disposeModel();
    }
  }

  @override
  List<Map<String, dynamic>> buildToolDeclarations(
    Map<String, List<McpTool>> toolsByEndpoint,
  ) {
    if (toolsByEndpoint.isEmpty) return [];
    // Individual declarations — one per tool, matching Google Gallery pattern.
    // Constrained decoding forces Gemma to output only valid tool names.
    final declarations = <Map<String, dynamic>>[];
    for (final entry in toolsByEndpoint.entries) {
      for (final tool in entry.value) {
        declarations.add({
          'name': tool.name,
          'description': tool.description ?? tool.name,
          'parameters': tool.inputSchema ?? {
            'type': 'object',
            'properties': <String, dynamic>{},
          },
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
    final endpoint = 'local-gemma://$name/tools';

    try {
      LoggerService.logAiRequest(
        endpoint: endpoint,
        headers: {'backend': _config?.backendType ?? 'gpu'},
        requestBody: _buildLogBody(messages, tools: tools),
        requestId: requestId,
      );

      final chat = await _createChat(
        messages: messages,
        tools: tools,
        temperature: temperature,
        topK: topK,
        topP: topP,
      );

      final response = await chat.generateChatResponse();
      final result = _responseToToolResult(response);

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
    } finally {
      await _disposeModel();
    }
  }

  /// Streaming generation with tool awareness. Streams text chunks via
  /// [onChunk] and returns the full result including any function calls.
  /// Combines the speed of streaming with the tool-calling path so Gemma
  /// can answer simple questions fast while still detecting tool calls.
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
    final endpoint = 'local-gemma://$name/stream-tools';

    try {
      LoggerService.logAiRequest(
        endpoint: endpoint,
        headers: {'backend': _config?.backendType ?? 'gpu'},
        requestBody: _buildLogBody(messages, tools: tools),
        requestId: requestId,
      );

      final chat = await _createChat(messages: messages, tools: tools);
      final buffer = StringBuffer();
      final functionCalls = <Map<String, dynamic>>[];

      await for (final response in chat.generateChatResponseAsync()) {
        if (response is gemma.TextResponse) {
          buffer.write(response.token);
          onChunk(response.token);
        } else if (response is gemma.FunctionCallResponse) {
          functionCalls.add({'name': response.name, 'args': response.args});
        } else if (response is gemma.ParallelFunctionCallResponse) {
          for (final call in response.calls) {
            functionCalls.add({'name': call.name, 'args': call.args});
          }
        }
      }

      final text = buffer.toString();
      // Check streamed text for tagged tool calls as fallback
      if (functionCalls.isEmpty) {
        final parsed = _extractTaggedToolCalls(text);
        if (parsed.calls.isNotEmpty) {
          final result = <String, dynamic>{
            'text': parsed.cleanedText,
            'function_calls': parsed.calls,
            'modelUsed': name,
          };
          LoggerService.logAiResponse(
            statusCode: 200,
            headers: {'model': name},
            responseBody: result,
            requestId: requestId,
            duration: DateTime.now().difference(startTime),
          );
          return result;
        }
      }

      final result = <String, dynamic>{
        'text': text,
        'function_calls': functionCalls.isNotEmpty ? functionCalls : null,
        'modelUsed': name,
      };
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
    } finally {
      await _disposeModel();
    }
  }

  Stream<String> generateStreaming(
    List<PromptMessage> messages, {
    int? maxNewTokens,
    String? requestId,
  }) async* {
    final reqId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final startTime = DateTime.now();
    final endpoint = 'local-gemma://$name/stream';

    try {
      LoggerService.logAiRequest(
        endpoint: endpoint,
        headers: {'backend': _config?.backendType ?? 'gpu'},
        requestBody: _buildLogBody(messages, tools: const []),
        requestId: reqId,
      );

      final chat = await _createChat(messages: messages, tools: const []);
      final buffer = StringBuffer();

      await for (final response in chat.generateChatResponseAsync()) {
        if (response is gemma.TextResponse) {
          buffer.write(response.token);
          yield response.token;
        }
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
    } finally {
      await _disposeModel();
    }
  }
}

@visibleForTesting
class ParsedToolCallText {
  final String cleanedText;
  final List<Map<String, dynamic>> calls;

  const ParsedToolCallText({required this.cleanedText, required this.calls});
}

final _toolCallTagPattern = RegExp(
  r'<\|tool_call\>([\s\S]*?)<tool_call\|>',
  dotAll: true,
);
