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
import 'package:note_synapse/services/prompts/prompt_models.dart';

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

  static String formatChatML(List<PromptMessage> messages, {String? toolSchemaBlock}) {
    final buffer = StringBuffer();

    for (final msg in messages) {
      if (msg.role == PromptRole.system) {
        buffer.writeln('<|im_start|>system');
        buffer.write(msg.content);
        if (toolSchemaBlock != null) {
          buffer.write('\n\n$toolSchemaBlock');
        }
        buffer.writeln('\n<|im_end|>');
      } else if (msg.role == PromptRole.user) {
        buffer.writeln('<|im_start|>user');
        buffer.writeln(msg.content);
        buffer.writeln('<|im_end|>');
      } else if (msg.role == PromptRole.assistant) {
        buffer.writeln('<|im_start|>assistant');
        buffer.writeln(msg.content);
        buffer.writeln('<|im_end|>');
      } else if (msg.role == PromptRole.tool) {
        buffer.writeln('<|im_start|>tool');
        buffer.writeln(msg.content);
        buffer.writeln('<|im_end|>');
      }
    }

    buffer.writeln('<|im_start|>assistant');
    return buffer.toString();
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
    final session = await _ensureSession();
    final prompt = formatChatML(messages);

    final buffer = StringBuffer();
    await for (final chunk in session.generate(
      prompt: prompt,
      maxNewTokens: maxOutputTokens ?? _config?.maxOutputTokens ?? 8192,
    )) {
      buffer.write(chunk);
    }

    return buffer.toString();
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
    final session = await _ensureSession();
    final toolSchemaBlock = tools.isNotEmpty ? buildToolSchemaBlock(tools) : null;
    final prompt = formatChatML(messages, toolSchemaBlock: toolSchemaBlock);

    // Buffer full response for tool call parsing
    final buffer = StringBuffer();
    await for (final chunk in session.generate(
      prompt: prompt,
      maxNewTokens: maxOutputTokens ?? _config?.maxOutputTokens ?? 8192,
    )) {
      buffer.write(chunk);
    }

    final responseText = buffer.toString();
    final parsed = parseToolCalls(responseText);

    return {
      'text': parsed.text.isEmpty ? '' : parsed.text,
      'function_calls': parsed.functionCalls,
      'modelUsed': name,
    };
  }

  /// Generates a streaming response for plain chat (no tool calls).
  Stream<String> generateStreaming(List<PromptMessage> messages, {
    int? maxNewTokens,
  }) async* {
    final session = await _ensureSession();
    final prompt = formatChatML(messages);
    yield* session.generate(
      prompt: prompt,
      maxNewTokens: maxNewTokens ?? _config?.maxOutputTokens ?? 8192,
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

  static const _maxImageDimension = 768;

  /// Estimates token count for an image based on its dimensions.
  /// Images are resized to min(maxDim, 768px) preserving aspect ratio.
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
  static String insertImageTags(String text, List<String> imagePaths) {
    if (imagePaths.isEmpty) return text;
    final tags = imagePaths.map((p) => '<img>$p</img>').join('\n');
    return '$text\n$tags';
  }

  /// Resizes an image to fit within 768px on the longest dimension.
  /// Returns the path to the resized temp file, or original path if already small enough.
  static Future<String> resizeImageForModel(String sourcePath) async {
    final file = File(sourcePath);
    final bytes = await file.readAsBytes();

    final image = img_lib.decodeImage(bytes);
    if (image == null) return sourcePath;

    final width = image.width;
    final height = image.height;
    final maxDim = width > height ? width : height;

    if (maxDim <= _maxImageDimension) {
      return sourcePath; // Already smaller than 768px, no resize needed
    }

    final scale = _maxImageDimension / maxDim;
    final newWidth = (width * scale).round();
    final newHeight = (height * scale).round();

    final resized = img_lib.copyResize(
      image,
      width: newWidth,
      height: newHeight,
      interpolation: img_lib.Interpolation.linear,
    );

    final tempDir = await Directory.systemTemp.createTemp('mnn_img_');
    final tempPath = '${tempDir.path}/resized.jpg';
    await File(tempPath).writeAsBytes(img_lib.encodeJpg(resized, quality: 85));
    return tempPath;
  }
}
