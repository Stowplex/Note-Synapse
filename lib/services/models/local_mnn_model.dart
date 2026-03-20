import 'dart:async';
import 'dart:io';
import 'package:edge_gen/edge_gen.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/services/models/ai_model.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';

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
    // Implemented in Task 7
    throw UnimplementedError('Tool calling not yet implemented');
  }

  Future<void> resetSession() async {
    _session = null;
  }

  Future<void> dispose() async {
    _session = null;
  }
}
