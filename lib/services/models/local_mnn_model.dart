import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:edge_gen/edge_gen.dart';
import 'package:image/image.dart' as img_lib;
import 'package:json_repair_flutter/json_repair_flutter.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/services/models/ai_model.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';
import 'package:note_synapse/services/logger_service.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';

class PreparedImage {
  final String path;
  final int width;
  final int height;
  const PreparedImage({required this.path, required this.width, required this.height});
}

class ToolCallParseResult {
  final String text;
  final List<Map<String, dynamic>>? functionCalls;

  const ToolCallParseResult({required this.text, this.functionCalls});
}

class LocalMnnModel extends AIModel {
  EdgeGenSession? _session;
  ModelConfig? _config;
  LocalModelPreset? _preset;
  bool _isInitialized = false;

  @override
  String get id => _config?.id ?? 'local_mnn';

  @override
  String get name => _config?.displayName ?? _preset?.displayName ?? 'Local Model';

  @override
  String get description => 'On-device AI model via MNN';

  @override
  Future<bool> isReady() async => _isInitialized;

  @override
  Future<void> initialize({ModelConfig? config}) async {
    _config = config;
    if (config?.modelName != null) {
      _preset = LocalModelPresets.findById(config!.modelName!);
    }
    _isInitialized = _preset != null;
  }

  Future<EdgeGenSession> _ensureSession() async {
    if (_session != null) return _session!;

    final configPath = _config?.endpoint;
    if (configPath == null) {
      throw Exception('Local model config path not set');
    }

    final backendType = _config?.backendType ??
        _preset?.defaultBackend[Platform.isAndroid ? 'android' : 'ios'] ??
        'cpu';

    final edgeConfig = EdgeGenConfig(
      backendType: backendType,
      maxNewTokens: _config?.maxOutputTokens ?? 8192,
      enableThinking: _config?.enableThinking ?? false,
    );

    _session = await EdgeGenController.instance.openSession(
      configPath: configPath,
      configJson: edgeConfig.toJson(),
    );
    return _session!;
  }

  /// Extracts the outermost JSON object from [text] starting at [start]
  /// using brace counting. Returns null if no balanced object is found.
  static String? _extractJsonObject(String text, int start) {
    if (start >= text.length || text[start] != '{') return null;
    int depth = 0;
    bool inString = false;
    bool escape = false;
    for (int i = start; i < text.length; i++) {
      final c = text[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (c == '\\' && inString) {
        escape = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }

  static final _toolCallHint = RegExp(r'\{\s*"name"\s*:\s*"call_tool"');

  /// Parses tool calls from model response text.
  static ToolCallParseResult parseToolCalls(String response) {
    final hint = _toolCallHint.firstMatch(response);
    if (hint == null) {
      return ToolCallParseResult(text: response);
    }

    final textBefore = response.substring(0, hint.start).trim();
    final jsonStr = _extractJsonObject(response, hint.start);

    try {
      Map<String, dynamic> parsed;
      if (jsonStr != null) {
        // Balanced braces found — try standard JSON decode first
        try {
          parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
        } catch (_) {
          final repaired = repairJson(jsonStr);
          if (repaired is! Map) {
            return ToolCallParseResult(text: response);
          }
          parsed = Map<String, dynamic>.from(repaired);
        }
      } else {
        // Unbalanced braces (malformed JSON) — try repair on raw substring
        final repaired = repairJson(response.substring(hint.start));
        if (repaired is! Map) {
          return ToolCallParseResult(text: response);
        }
        parsed = Map<String, dynamic>.from(repaired);
      }

      if (parsed['name'] == 'call_tool' && parsed.containsKey('arguments')) {
        final args = Map<String, dynamic>.from(parsed['arguments'] as Map);
        return ToolCallParseResult(
          text: textBefore,
          functionCalls: [
            {
              'name': 'call_tool',
              'args': args,
            }
          ],
        );
      }
    } catch (_) {
      // JSON repair failed — treat as plain text
    }

    return ToolCallParseResult(text: response);
  }

  /// Builds a tool schema block for injection into the system prompt.
  static String buildToolSchemaBlock(List<Map<String, dynamic>> tools) {
    const encoder = JsonEncoder.withIndent('  ');
    final toolsJson = encoder.convert(tools);
    return '''
You have access to the following tools. To use a tool, respond with a JSON object:
{"name": "call_tool", "arguments": {"service_name": "<service>", "tool_name": "<tool>", "params": {<parameters>}}}

Available tools:
$toolsJson

When you need to use a tool, output ONLY the JSON object. Do not wrap it in markdown code blocks.''';
  }

  /// Pre-processes messages by resizing image attachments and inserting
  /// `<img>` tags (with `<hw>` dimension info) into the message content
  /// so the MNN runtime can pick them up.
  static Future<List<PromptMessage>> preprocessAttachments(
    List<PromptMessage> messages,
  ) async {
    final result = <PromptMessage>[];
    for (final msg in messages) {
      if (msg.attachments.isEmpty) {
        result.add(msg);
        continue;
      }
      final prepared = <PreparedImage>[];
      for (final file in msg.attachments) {
        String? sourcePath = file.path;

        // Handle in-memory attachments (e.g. rendered PDF pages) by
        // writing bytes to a temp file first.
        if (sourcePath == null && file.bytes != null) {
          final ext = file.name.split('.').last.toLowerCase();
          if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext)) {
            final tempDir = await Directory.systemTemp.createTemp('mnn_mem_');
            sourcePath = '${tempDir.path}/${file.name}';
            await File(sourcePath).writeAsBytes(file.bytes!);
          }
        }

        if (sourcePath == null) continue;
        final ext = sourcePath.split('.').last.toLowerCase();
        if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext)) {
          final image = await resizeImageForModel(sourcePath);
          prepared.add(image);
        }
      }
      if (prepared.isNotEmpty) {
        result.add(msg.copyWith(
          content: _appendImageTags(msg.content, prepared),
        ));
      } else {
        result.add(msg);
      }
    }
    return result;
  }

  /// Builds `<img>path<hw>height,width</hw></img>` tags matching the
  /// format expected by the MNN vision runtime.
  static String _appendImageTags(String text, List<PreparedImage> images) {
    final buffer = StringBuffer(text);
    for (final img in images) {
      final hwTag = img.width > 0 && img.height > 0
          ? '<hw>${img.height},${img.width}</hw>'
          : '';
      buffer.write('\n<img>${img.path}$hwTag</img>');
    }
    return buffer.toString();
  }

  /// Converts [PromptMessage] list into structured (role, content) pairs
  /// for the MNN native session. MNN's Jinja template engine formats these
  /// into the correct ChatML for each model (Qwen 3.5, Qwen3 VL, etc.).
  ///
  /// MNN supports "system", "user", "assistant" roles. "tool" role messages
  /// are mapped to "user" with a "Tool result:" prefix since MNN silently
  /// drops unknown roles.
  static List<Map<String, String>> buildChatMessages(
    List<PromptMessage> messages, {
    String? toolSchemaBlock,
  }) {
    final result = <Map<String, String>>[];

    for (final msg in messages) {
      switch (msg.role) {
        case PromptRole.system:
          // Merge tool schema into the system message content
          final content = toolSchemaBlock != null
              ? '${msg.content}\n\n$toolSchemaBlock'
              : msg.content;
          result.add({'role': 'system', 'content': content});
          break;
        case PromptRole.user:
          result.add({'role': 'user', 'content': msg.content});
          break;
        case PromptRole.assistant:
          result.add({'role': 'assistant', 'content': msg.content});
          break;
        case PromptRole.tool:
          // MNN doesn't support "tool" role — map to "user" with prefix
          result.add({'role': 'user', 'content': 'Tool result: ${msg.content}'});
          break;
      }
    }

    // If there's a tool schema but no system message was present, inject one
    if (toolSchemaBlock != null && !messages.any((m) => m.role == PromptRole.system)) {
      result.insert(0, {'role': 'system', 'content': toolSchemaBlock});
    }

    return result;
  }

  /// Legacy plain-text prompt formatting. Kept for tests and fallback.
  static String formatPrompt(List<PromptMessage> messages, {String? toolSchemaBlock}) {
    final chatMessages = buildChatMessages(messages, toolSchemaBlock: toolSchemaBlock);
    final buffer = StringBuffer();
    for (int i = 0; i < chatMessages.length; i++) {
      final msg = chatMessages[i];
      if (i > 0) buffer.write('\n');
      final role = msg['role']!;
      final content = msg['content']!;
      if (role == 'system') {
        buffer.write(content);
      } else if (role == 'user') {
        buffer.write(content);
      } else if (role == 'assistant') {
        buffer.write('Assistant: $content');
      }
    }
    return buffer.toString();
  }

  /// Builds a summary of messages and attachments for debug logging.
  static Map<String, dynamic> _buildLogBody(
    List<PromptMessage> messages, {
    String? prompt,
    List<Map<String, dynamic>>? tools,
  }) {
    final msgSummary = messages.map((m) {
      final entry = <String, dynamic>{
        'role': m.role.name,
        'content': m.content,
      };
      if (m.attachments.isNotEmpty) {
        entry['attachments'] = m.attachments
            .map((f) => {
              'name': f.name,
              'size': f.size,
              'path': f.path,
              'hasBytes': f.bytes != null,
              'bytesLength': f.bytes?.length,
            })
            .toList();
      }
      return entry;
    }).toList();

    return {
      'messages': msgSummary,
      if (prompt != null) 'prompt': prompt,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
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
    final requestId = generationContext?.ensureRequestId() ??
        DateTime.now().millisecondsSinceEpoch.toString();
    final startTime = DateTime.now();
    final endpoint = 'local-mnn://$name';

    final session = await _ensureSession();
    await session.reset();
    final processed = await preprocessAttachments(messages);
    final chatMessages = buildChatMessages(processed);

    LoggerService.logAiRequest(
      endpoint: endpoint,
      headers: {'backend': _config?.backendType ?? 'cpu'},
      requestBody: _buildLogBody(messages, prompt: chatMessages.toString()),
      requestId: requestId,
    );

    final buffer = StringBuffer();
    await for (final chunk in session.generateWithMessages(
      messages: chatMessages,
      maxNewTokens: maxOutputTokens ?? _config?.maxOutputTokens ?? 8192,
    )) {
      buffer.write(chunk);
    }

    final responseText = buffer.toString();
    final duration = DateTime.now().difference(startTime);

    LoggerService.logAiResponse(
      statusCode: 200,
      headers: {'model': name},
      responseBody: {
        'text': responseText,
      },
      requestId: requestId,
      duration: duration,
    );

    return responseText;
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
    final requestId = generationContext?.ensureRequestId() ??
        DateTime.now().millisecondsSinceEpoch.toString();
    final startTime = DateTime.now();
    final endpoint = 'local-mnn://$name/tools';

    final session = await _ensureSession();
    await session.reset();
    final processed = await preprocessAttachments(messages);
    final toolSchemaBlock = tools.isNotEmpty ? buildToolSchemaBlock(tools) : null;
    final chatMessages = buildChatMessages(processed, toolSchemaBlock: toolSchemaBlock);

    LoggerService.logAiRequest(
      endpoint: endpoint,
      headers: {'backend': _config?.backendType ?? 'cpu'},
      requestBody: _buildLogBody(messages, prompt: chatMessages.toString(), tools: tools),
      requestId: requestId,
    );

    // Buffer full response for tool call parsing
    final buffer = StringBuffer();
    await for (final chunk in session.generateWithMessages(
      messages: chatMessages,
      maxNewTokens: maxOutputTokens ?? _config?.maxOutputTokens ?? 8192,
    )) {
      buffer.write(chunk);
    }

    final responseText = buffer.toString();
    final duration = DateTime.now().difference(startTime);
    final parsed = parseToolCalls(responseText);

    final result = {
      'text': parsed.text.isEmpty ? '' : parsed.text,
      'function_calls': parsed.functionCalls,
      'modelUsed': name,
    };

    LoggerService.logAiResponse(
      statusCode: 200,
      headers: {'model': name},
      responseBody: {
        'text': parsed.text,
        'functionCalls': parsed.functionCalls,
        'rawLength': responseText.length,
      },
      requestId: requestId,
      duration: duration,
    );

    return result;
  }

  /// Generates a streaming response for plain chat (no tool calls).
  Stream<String> generateStreaming(List<PromptMessage> messages, {
    int? maxNewTokens,
    String? requestId,
  }) async* {
    final reqId = requestId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final startTime = DateTime.now();
    final endpoint = 'local-mnn://$name/stream';

    final session = await _ensureSession();
    await session.reset();
    final processed = await preprocessAttachments(messages);
    final chatMessages = buildChatMessages(processed);

    LoggerService.logAiRequest(
      endpoint: endpoint,
      headers: {'backend': _config?.backendType ?? 'cpu'},
      requestBody: _buildLogBody(messages, prompt: chatMessages.toString()),
      requestId: reqId,
    );

    final responseBuffer = StringBuffer();
    await for (final chunk in session.generateWithMessages(
      messages: chatMessages,
      maxNewTokens: maxNewTokens ?? _config?.maxOutputTokens ?? 8192,
    )) {
      responseBuffer.write(chunk);
      yield chunk;
    }

    final responseText = responseBuffer.toString();
    final duration = DateTime.now().difference(startTime);

    LoggerService.logAiResponse(
      statusCode: 200,
      headers: {'model': name},
      responseBody: {
        'text': responseText.length > 2000
            ? '${responseText.substring(0, 2000)}...'
            : responseText,
        'textLength': responseText.length,
        'streaming': true,
      },
      requestId: reqId,
      duration: duration,
    );
  }

  /// Whether this model supports streaming responses.
  bool get supportsStreaming => true;

  Future<void> resetSession() async {
    _session = null;
  }

  Future<void> dispose() async {
    _session = null;
  }

  static const _maxImageDimension = 784;

  /// Estimates token count for an image based on its dimensions.
  /// Images are resized to min(maxDim, 784px) preserving aspect ratio.
  /// Token count = ceil(resizedWidth/28) * ceil(resizedHeight/28).
  static int estimateImageTokens(int width, int height) {
    final maxDim = width > height ? width : height;
    if (maxDim > _maxImageDimension) {
      final scale = _maxImageDimension / maxDim;
      width = (width * scale).ceil();
      height = (height * scale).ceil();
    }
    return ((width / 28).ceil()) * ((height / 28).ceil());
  }

  /// Inserts <img> tags for image paths into the text content.
  /// Prefer [_appendImageTags] which includes `<hw>` dimension info.
  static String insertImageTags(String text, List<String> imagePaths) {
    if (imagePaths.isEmpty) return text;
    final tags = imagePaths.map((p) => '<img>$p</img>').join('\n');
    return '$text\n$tags';
  }

  /// Normalizes an image for the MNN runtime: resizes to fit within 1000px
  /// on the longest side and always writes to a temp file (matching the
  /// format expected by the vision runtime).
  /// Returns a [PreparedImage] with the output path and final dimensions.
  static Future<PreparedImage> resizeImageForModel(String sourcePath) async {
    final file = File(sourcePath);
    final bytes = await file.readAsBytes();

    final image = img_lib.decodeImage(bytes);
    if (image == null) {
      return PreparedImage(path: sourcePath, width: 0, height: 0);
    }

    final longestSide = image.width > image.height ? image.width : image.height;
    final targetLongest = longestSide > _maxImageDimension
        ? _maxImageDimension
        : longestSide;

    int newWidth = image.width;
    int newHeight = image.height;
    img_lib.Image normalized = image;

    if (targetLongest < longestSide) {
      final scale = targetLongest / longestSide;
      newWidth = (image.width * scale).round();
      newHeight = (image.height * scale).round();
      normalized = img_lib.copyResize(
        image,
        width: newWidth,
        height: newHeight,
        interpolation: img_lib.Interpolation.cubic,
      );
    }

    final ext = sourcePath.split('.').last.toLowerCase();
    final tempDir = await Directory.systemTemp.createTemp('mnn_img_');
    final isPng = ext == 'png';
    final tempPath = '${tempDir.path}/prepared.${isPng ? 'png' : 'jpg'}';

    if (isPng) {
      await File(tempPath).writeAsBytes(img_lib.encodePng(normalized));
    } else {
      await File(tempPath).writeAsBytes(img_lib.encodeJpg(normalized, quality: 92));
    }

    return PreparedImage(path: tempPath, width: newWidth, height: newHeight);
  }
}
