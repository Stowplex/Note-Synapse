# Local AI MNN Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate on-device AI inference via edge_gen/MNN as a first-class AI provider, with model download management, streaming UI, and tool calling support.

**Architecture:** Thin adapter pattern — `LocalMnnModel extends AIModel` wraps `EdgeGenSession` from the edge_gen Flutter plugin. Model presets define available models with HuggingFace URLs. SharedPreferences tracks download state. Streaming responses render progressively in chat and immersive screens.

**Tech Stack:** Flutter, edge_gen (MNN wrapper), SharedPreferences, json_repair

**Spec:** `.claude/plans/2026-03-20-local-ai-mnn-integration-design.md`

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `third_party/edge_gen/` | Git submodule — MNN Flutter bridge |
| `lib/services/models/local_mnn_model.dart` | AIModel adapter wrapping EdgeGenSession |
| `lib/services/models/local_model_presets.dart` | Config-driven model registry with HF URLs |
| `lib/services/local_model_service.dart` | Download, delete, status via SharedPreferences |
| `lib/screens/local_model_picker_screen.dart` | Model download/selection screen |
| `lib/screens/local_model_settings_screen.dart` | Backend, thinking, token window config |
| `test/services/local_model_service_test.dart` | Unit tests for download service |
| `test/services/models/local_mnn_model_test.dart` | Unit tests for adapter |
| `test/services/models/local_model_presets_test.dart` | Unit tests for presets |

### Modified Files
| File | Change |
|------|--------|
| `lib/models/model_type.dart:3-4` | Add `localMnn` enum value |
| `lib/models/model_config.dart:8-52` | Add `tokenWindow`, `enableThinking`, `backendType` fields |
| `lib/services/model_selector.dart:492-499` | Add `case ModelType.localMnn` to factory |
| `lib/services/model_selector.dart` (constraint section) | Add token window constraint check |
| `lib/services/service_locator.dart:91-113` | Register `LocalModelService` in Wave 4A |
| `lib/services/conversation_ai_engine.dart:157-168` | Add streaming code path for local models |
| `lib/screens/model_selection_screen.dart:284-299` | Add icon/description for localMnn |
| `pubspec.yaml` | Add edge_gen path dependency + json_repair |
| `lib/l10n/app_en.arb` | Add l10n strings for local model UI |
| `lib/l10n/app_zh.arb` | Add l10n strings (Chinese) |

---

## Task 1: Add edge_gen Submodule & Dependency

**Files:**
- Create: `third_party/edge_gen/` (submodule)
- Modify: `pubspec.yaml`

- [ ] **Step 1: Add edge_gen as git submodule**

```bash
cd /Users/liwen/develop/projects/Note-Synapse
git submodule add git@github.com:Stowplex/edge_gen.git third_party/edge_gen
```

- [ ] **Step 2: Initialize nested MNN submodule**

```bash
git submodule update --init --recursive
```

- [ ] **Step 3: Add edge_gen and json_repair to pubspec.yaml**

In `pubspec.yaml`, add to the dependencies section (check if `image` already exists first):

```yaml
  edge_gen:
    path: third_party/edge_gen
  json_repair: ^0.1.0
  image: ^4.0.0  # for image resizing — skip if already present
```

- [ ] **Step 4: Run flutter pub get**

```bash
flutter pub get
```
Expected: resolves successfully, edge_gen and json_repair appear in dependencies.

- [ ] **Step 5: Verify build**

```bash
flutter analyze
```
Expected: no new analysis errors from the dependency addition.

- [ ] **Step 6: Commit**

```bash
git add .gitmodules third_party/edge_gen pubspec.yaml pubspec.lock
git commit -m "feat: add edge_gen submodule and json_repair dependency"
```

---

## Task 2: Extend ModelType Enum

**Files:**
- Modify: `lib/models/model_type.dart:3-4`
- Test: `test/services/models/local_model_presets_test.dart` (created in Task 3)

- [ ] **Step 1: Add localMnn to ModelType enum**

In `lib/models/model_type.dart`, add after line 4 (`openaiCompatible`):

```dart
enum ModelType {
  gemini('gemini', 'Gemini'),
  openaiCompatible('openai_compatible', 'OpenAI Compatible'),
  localMnn('local_mnn', 'Local Model'),
```

- [ ] **Step 2: Verify existing tests still pass**

```bash
flutter test
```
Expected: all existing tests pass. The `fromId()` factory and `all` getter use the enum values automatically.

- [ ] **Step 3: Commit**

```bash
git add lib/models/model_type.dart
git commit -m "feat: add localMnn to ModelType enum"
```

---

## Task 3: Extend ModelConfig

**Files:**
- Modify: `lib/models/model_config.dart:8-52`

- [ ] **Step 1: Add new fields to ModelConfig**

In `lib/models/model_config.dart`, add these fields to the class definition (after `isConfigured`):

```dart
  final int? tokenWindow;        // 4096-32768, for local models
  final bool? enableThinking;    // Qwen thinking mode toggle
  final String? backendType;     // 'cpu', 'opencl', 'metal'
```

- [ ] **Step 2: Update constructor**

Add the new fields to the constructor with defaults:

```dart
  this.tokenWindow,
  this.enableThinking,
  this.backendType,
```

- [ ] **Step 3: Update copyWith()**

Add the new fields to `copyWith()`:

```dart
  int? tokenWindow,
  bool? enableThinking,
  String? backendType,
```

And in the return:

```dart
  tokenWindow: tokenWindow ?? this.tokenWindow,
  enableThinking: enableThinking ?? this.enableThinking,
  backendType: backendType ?? this.backendType,
```

- [ ] **Step 4: Update toJson() and fromJson()**

Add serialization for the new fields.

`toJson()`:
```dart
  if (tokenWindow != null) 'token_window': tokenWindow,
  if (enableThinking != null) 'enable_thinking': enableThinking,
  if (backendType != null) 'backend_type': backendType,
```

`fromJson()`:
```dart
  tokenWindow: json['token_window'] as int?,
  enableThinking: json['enable_thinking'] as bool?,
  backendType: json['backend_type'] as String?,
```

- [ ] **Step 5: Run tests**

```bash
flutter test
```
Expected: all existing tests pass — new fields are nullable so backward compatible.

- [ ] **Step 6: Commit**

```bash
git add lib/models/model_config.dart
git commit -m "feat: add tokenWindow, enableThinking, backendType to ModelConfig"
```

---

## Task 4: Local Model Presets

**Files:**
- Create: `lib/services/models/local_model_presets.dart`
- Test: `test/services/models/local_model_presets_test.dart`

- [ ] **Step 1: Write failing tests for LocalModelPreset**

Create `test/services/models/local_model_presets_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';

void main() {
  group('LocalModelPreset', () {
    test('qwen35_08b preset has correct properties', () {
      final preset = LocalModelPresets.qwen35_08b;
      expect(preset.id, 'qwen35_08b');
      expect(preset.displayName, 'Qwen 3.5 0.8B');
      expect(preset.supportsVision, true);
      expect(preset.supportsThinking, true);
      expect(preset.defaultTokenWindow, 16384);
      expect(preset.defaultBackend['android'], 'opencl');
      expect(preset.defaultBackend['ios'], 'cpu');
    });

    test('qwen3_vl_2b preset has correct properties', () {
      final preset = LocalModelPresets.qwen3Vl2b;
      expect(preset.id, 'qwen3_vl_2b');
      expect(preset.displayName, 'Qwen3 VL 2B');
      expect(preset.supportsVision, true);
      expect(preset.supportsThinking, true);
      expect(preset.defaultTokenWindow, 16384);
      expect(preset.defaultBackend['android'], 'cpu');
      expect(preset.defaultBackend['ios'], 'metal');
    });

    test('all presets returns both models', () {
      expect(LocalModelPresets.all.length, 2);
    });

    test('findById returns correct preset', () {
      expect(LocalModelPresets.findById('qwen35_08b')?.id, 'qwen35_08b');
      expect(LocalModelPresets.findById('nonexistent'), null);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
flutter test test/services/models/local_model_presets_test.dart
```
Expected: FAIL — file not found.

- [ ] **Step 3: Implement LocalModelPresets**

Create `lib/services/models/local_model_presets.dart`:

```dart
import 'package:edge_gen/edge_gen.dart';

class LocalModelPreset {
  final String id;
  final String displayName;
  final QwenModelSpec spec;
  final Map<String, String> defaultBackend;
  final bool supportsVision;
  final bool supportsThinking;
  final int defaultTokenWindow;

  const LocalModelPreset({
    required this.id,
    required this.displayName,
    required this.spec,
    required this.defaultBackend,
    required this.supportsVision,
    required this.supportsThinking,
    required this.defaultTokenWindow,
  });
}

class LocalModelPresets {
  LocalModelPresets._();

  static final qwen35_08b = LocalModelPreset(
    id: 'qwen35_08b',
    displayName: 'Qwen 3.5 0.8B',
    spec: QwenModelSpec.qwen35_08bMnn,
    defaultBackend: {'android': 'opencl', 'ios': 'cpu'},
    supportsVision: true,
    supportsThinking: true,
    defaultTokenWindow: 16384,
  );

  static final qwen3Vl2b = LocalModelPreset(
    id: 'qwen3_vl_2b',
    displayName: 'Qwen3 VL 2B',
    spec: QwenModelSpec.qwen3Vl2bInstructMnn,
    defaultBackend: {'android': 'cpu', 'ios': 'metal'},
    supportsVision: true,
    supportsThinking: true,
    defaultTokenWindow: 16384,
  );

  static final List<LocalModelPreset> all = [qwen35_08b, qwen3Vl2b];

  static LocalModelPreset? findById(String id) {
    try {
      return all.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
flutter test test/services/models/local_model_presets_test.dart
```
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/models/local_model_presets.dart test/services/models/local_model_presets_test.dart
git commit -m "feat: add local model presets with HuggingFace download config"
```

---

## Task 5: LocalModelService (Download Management)

**Files:**
- Create: `lib/services/local_model_service.dart`
- Create: `test/services/local_model_service_test.dart`
- Modify: `lib/services/service_locator.dart:91-113`

- [ ] **Step 1: Write failing tests for LocalModelService**

Create `test/services/local_model_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/services/local_model_service.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';

void main() {
  group('LocalModelService', () {
    late LocalModelService service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service = LocalModelService();
    });

    test('isModelDownloaded returns false when no model downloaded', () async {
      final result = await service.isModelDownloaded('qwen35_08b');
      expect(result, false);
    });

    test('getDownloadedModels returns empty list initially', () async {
      final result = await service.getDownloadedModels();
      expect(result, isEmpty);
    });

    test('markModelDownloaded persists model path', () async {
      await service.markModelDownloaded('qwen35_08b', '/path/to/model');
      final result = await service.isModelDownloaded('qwen35_08b');
      expect(result, true);
    });

    test('getModelPath returns stored path', () async {
      await service.markModelDownloaded('qwen35_08b', '/path/to/model');
      final path = await service.getModelPath('qwen35_08b');
      expect(path, '/path/to/model');
    });

    test('removeModel clears stored path', () async {
      await service.markModelDownloaded('qwen35_08b', '/path/to/model');
      await service.removeModel('qwen35_08b');
      final result = await service.isModelDownloaded('qwen35_08b');
      expect(result, false);
    });

    test('getAvailableModels returns all presets with download status', () async {
      await service.markModelDownloaded('qwen35_08b', '/path/to/model');
      final models = await service.getAvailableModels();
      expect(models.length, LocalModelPresets.all.length);
      expect(models.firstWhere((m) => m.preset.id == 'qwen35_08b').isDownloaded, true);
      expect(models.firstWhere((m) => m.preset.id == 'qwen3_vl_2b').isDownloaded, false);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
flutter test test/services/local_model_service_test.dart
```
Expected: FAIL — file not found.

- [ ] **Step 3: Implement LocalModelService**

Create `lib/services/local_model_service.dart`:

```dart
import 'dart:async';
import 'dart:io';
import 'package:edge_gen/edge_gen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';

class LocalModelStatus {
  final LocalModelPreset preset;
  final bool isDownloaded;
  final String? modelPath;

  const LocalModelStatus({
    required this.preset,
    required this.isDownloaded,
    this.modelPath,
  });
}

class LocalModelService {
  static const _keyPrefix = 'local_model_path_';

  Future<bool> isModelDownloaded(String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$_keyPrefix$modelId');
  }

  Future<String?> getModelPath(String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_keyPrefix$modelId');
  }

  Future<void> markModelDownloaded(String modelId, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_keyPrefix$modelId', path);
  }

  Future<void> removeModel(String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('$_keyPrefix$modelId');
    if (path != null) {
      // Delete model files from disk
      final dir = Directory(path).parent;
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
    await prefs.remove('$_keyPrefix$modelId');
  }

  Future<List<String>> getDownloadedModels() async {
    final prefs = await SharedPreferences.getInstance();
    final downloaded = <String>[];
    for (final preset in LocalModelPresets.all) {
      if (prefs.containsKey('$_keyPrefix${preset.id}')) {
        downloaded.add(preset.id);
      }
    }
    return downloaded;
  }

  Future<List<LocalModelStatus>> getAvailableModels() async {
    final statuses = <LocalModelStatus>[];
    for (final preset in LocalModelPresets.all) {
      final path = await getModelPath(preset.id);
      statuses.add(LocalModelStatus(
        preset: preset,
        isDownloaded: path != null,
        modelPath: path,
      ));
    }
    return statuses;
  }

  /// Downloads a model and returns a stream of progress (0.0 to 1.0).
  /// Returns the config path on completion.
  Stream<double> downloadModel(
    LocalModelPreset preset, {
    required void Function(String configPath) onComplete,
    required void Function(String error) onError,
  }) {
    final controller = StreamController<double>();
    _doDownload(preset, controller, onComplete, onError);
    return controller.stream;
  }

  Future<void> _doDownload(
    LocalModelPreset preset,
    StreamController<double> controller,
    void Function(String configPath) onComplete,
    void Function(String error) onError,
  ) async {
    try {
      final downloaded = await QwenModelDownloader().ensureDownloaded(
        preset.spec,
        onProgress: (progress) {
          if (!controller.isClosed) {
            controller.add(progress);
          }
        },
      );
      await markModelDownloaded(preset.id, downloaded.configPath);
      onComplete(downloaded.configPath);
    } catch (e) {
      onError(e.toString());
    } finally {
      await controller.close();
    }
  }
}
```

Note: The `downloadModel` method wraps `QwenModelDownloader` from edge_gen. Verify that `QwenModelDownloader.ensureDownloaded` supports an `onProgress` callback — if not, adapt to the actual edge_gen API (it may use a different progress reporting mechanism).

- [ ] **Step 4: Run tests to verify they pass**

```bash
flutter test test/services/local_model_service_test.dart
```
Expected: all 6 tests PASS (download test is not included — it requires actual network access).

- [ ] **Step 5: Register in service locator**

In `lib/services/service_locator.dart`, add `LocalModelService` registration in Wave 4A (after ModelStorageService, before ModelSelector — around line 99):

```dart
  if (!getIt.isRegistered<LocalModelService>()) {
    getIt.registerLazySingleton<LocalModelService>(
      () => LocalModelService(),
    );
  }
```

Add import at top:
```dart
import 'package:note_synapse/services/local_model_service.dart';
```

- [ ] **Step 6: Run all tests**

```bash
flutter test
```
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/services/local_model_service.dart test/services/local_model_service_test.dart lib/services/service_locator.dart
git commit -m "feat: add LocalModelService for model download management"
```

---

## Task 6: LocalMnnModel — Core Prompt Formatting

**Files:**
- Create: `lib/services/models/local_mnn_model.dart`
- Create: `test/services/models/local_mnn_model_test.dart`

- [ ] **Step 1: Write failing tests for prompt formatting**

Create `test/services/models/local_mnn_model_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/models/local_mnn_model.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';

void main() {
  group('LocalMnnModel prompt formatting', () {
    test('formats system + user messages to ChatML', () {
      final messages = [
        PromptMessage(role: PromptRole.system, content: 'You are helpful.'),
        PromptMessage(role: PromptRole.user, content: 'Hello'),
      ];
      final result = LocalMnnModel.formatChatML(messages);
      expect(result, contains('<|im_start|>system'));
      expect(result, contains('You are helpful.'));
      expect(result, contains('<|im_end|>'));
      expect(result, contains('<|im_start|>user'));
      expect(result, contains('Hello'));
      expect(result, endsWith('<|im_start|>assistant\n'));
    });

    test('formats multi-turn conversation', () {
      final messages = [
        PromptMessage(role: PromptRole.system, content: 'System prompt'),
        PromptMessage(role: PromptRole.user, content: 'First question'),
        PromptMessage(role: PromptRole.assistant, content: 'First answer'),
        PromptMessage(role: PromptRole.user, content: 'Follow up'),
      ];
      final result = LocalMnnModel.formatChatML(messages);
      expect(result, contains('<|im_start|>assistant\nFirst answer\n<|im_end|>'));
      expect(result, contains('Follow up'));
    });

    test('handles empty system message', () {
      final messages = [
        PromptMessage(role: PromptRole.user, content: 'Hello'),
      ];
      final result = LocalMnnModel.formatChatML(messages);
      expect(result, contains('<|im_start|>user'));
      expect(result, isNot(contains('<|im_start|>system')));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
flutter test test/services/models/local_mnn_model_test.dart
```
Expected: FAIL — class not found.

- [ ] **Step 3: Implement LocalMnnModel with prompt formatting**

Create `lib/services/models/local_mnn_model.dart`:

```dart
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
    // Session is NOT created here — lazy loading on first generate call
  }

  Future<EdgeGenSession> _ensureSession() async {
    if (_session != null) return _session!;

    final configPath = _config?.endpoint; // reuse endpoint field for config path
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

  /// Formats a list of PromptMessages into Qwen ChatML format.
  /// Exposed as static for testability.
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

    // Prompt the assistant to respond
    buffer.writeln('<|im_start|>assistant');
    return buffer.toString();
  }

  @override
  Future<Map<String, dynamic>> generateWithMessages(
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

    return {
      'text': buffer.toString(),
      'modelUsed': name,
    };
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

  /// Resets the session (clears KV cache and history).
  Future<void> resetSession() async {
    // Session reset for between conversations
    _session = null;
  }

  /// Disposes the session and frees memory.
  Future<void> dispose() async {
    _session = null;
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
flutter test test/services/models/local_mnn_model_test.dart
```
Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/models/local_mnn_model.dart test/services/models/local_mnn_model_test.dart
git commit -m "feat: add LocalMnnModel with ChatML prompt formatting"
```

---

## Task 7: LocalMnnModel — Tool Calling with JSON Repair

**Files:**
- Modify: `lib/services/models/local_mnn_model.dart`
- Modify: `test/services/models/local_mnn_model_test.dart`

- [ ] **Step 1: Write failing tests for tool call parsing**

Add to `test/services/models/local_mnn_model_test.dart`:

```dart
  group('LocalMnnModel tool call parsing', () {
    test('parses valid JSON tool call from response', () {
      final response = 'Let me search for that.\n{"name": "call_tool", "arguments": {"service_name": "mcp", "tool_name": "search", "params": {"query": "test"}}}';
      final result = LocalMnnModel.parseToolCalls(response);
      expect(result.functionCalls, isNotNull);
      expect(result.functionCalls!.length, 1);
      expect(result.functionCalls![0]['name'], 'call_tool');
      expect(result.functionCalls![0]['args']['tool_name'], 'search');
      expect(result.text, 'Let me search for that.');
    });

    test('handles malformed JSON with json_repair', () {
      // Missing closing quote on "test
      final response = '{"name": "call_tool", "arguments": {"service_name": "mcp", "tool_name": "search", "params": {"query": "test}}}';
      final result = LocalMnnModel.parseToolCalls(response);
      // json_repair should fix the missing quote
      expect(result.functionCalls, isNotNull);
    });

    test('returns plain text when no tool call found', () {
      final response = 'This is just a regular response with no tool calls.';
      final result = LocalMnnModel.parseToolCalls(response);
      expect(result.functionCalls, isNull);
      expect(result.text, response);
    });

    test('builds tool schema block for system prompt', () {
      final tools = [
        {
          'name': 'call_tool',
          'description': 'Call a tool',
          'parameters': {'type': 'object', 'properties': {}}
        }
      ];
      final block = LocalMnnModel.buildToolSchemaBlock(tools);
      expect(block, contains('call_tool'));
      expect(block, contains('"name": "call_tool"'));
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

```bash
flutter test test/services/models/local_mnn_model_test.dart
```
Expected: FAIL — `parseToolCalls` and `buildToolSchemaBlock` not found.

- [ ] **Step 3: Implement tool call parsing**

Add to `lib/services/models/local_mnn_model.dart`:

```dart
import 'dart:convert';
import 'package:json_repair/json_repair.dart';

class ToolCallParseResult {
  final String text;
  final List<Map<String, dynamic>>? functionCalls;

  const ToolCallParseResult({required this.text, this.functionCalls});
}
```

Add static methods to `LocalMnnModel`:

```dart
  static final _toolCallPattern = RegExp(
    r'\{[\s\S]*?"name"\s*:\s*"call_tool"[\s\S]*?\}(?:\s*\})*',
  );

  /// Parses tool calls from model response text.
  static ToolCallParseResult parseToolCalls(String response) {
    final match = _toolCallPattern.firstMatch(response);
    if (match == null) {
      return ToolCallParseResult(text: response);
    }

    final jsonStr = match.group(0)!;
    final textBefore = response.substring(0, match.start).trim();

    try {
      final repaired = jsonRepair(jsonStr);
      final parsed = jsonDecode(repaired) as Map<String, dynamic>;

      if (parsed['name'] == 'call_tool' && parsed.containsKey('arguments')) {
        final args = parsed['arguments'] as Map<String, dynamic>;
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
    final encoder = const JsonEncoder.withIndent('  ');
    final toolsJson = encoder.convert(tools);
    return '''
You have access to the following tools. To use a tool, respond with a JSON object:
{"name": "call_tool", "arguments": {"service_name": "<service>", "tool_name": "<tool>", "params": {<parameters>}}}

Available tools:
$toolsJson

When you need to use a tool, output ONLY the JSON object. Do not wrap it in markdown code blocks.''';
  }
```

- [ ] **Step 4: Implement generateWithToolsAndMessages**

Replace the `throw UnimplementedError` in `generateWithToolsAndMessages`:

```dart
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
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
flutter test test/services/models/local_mnn_model_test.dart
```
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/services/models/local_mnn_model.dart test/services/models/local_mnn_model_test.dart
git commit -m "feat: add tool call parsing with json_repair to LocalMnnModel"
```

---

## Task 8: LocalMnnModel — Image Preprocessing

**Files:**
- Modify: `lib/services/models/local_mnn_model.dart`
- Modify: `test/services/models/local_mnn_model_test.dart`

- [ ] **Step 1: Write failing tests for image tag insertion**

Add to test file:

```dart
  group('LocalMnnModel image handling', () {
    test('inserts img tag for image attachment path', () {
      final result = LocalMnnModel.insertImageTags(
        'Describe this image',
        ['/tmp/resized_photo.jpg'],
      );
      expect(result, 'Describe this image\n<img>/tmp/resized_photo.jpg</img>');
    });

    test('inserts multiple img tags for multiple images', () {
      final result = LocalMnnModel.insertImageTags(
        'Compare these',
        ['/tmp/img1.jpg', '/tmp/img2.jpg'],
      );
      expect(result, contains('<img>/tmp/img1.jpg</img>'));
      expect(result, contains('<img>/tmp/img2.jpg</img>'));
    });

    test('returns original text when no images', () {
      final result = LocalMnnModel.insertImageTags('Hello', []);
      expect(result, 'Hello');
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

```bash
flutter test test/services/models/local_mnn_model_test.dart
```
Expected: FAIL — `insertImageTags` not found.

- [ ] **Step 3: Implement image tag insertion and resizing**

Add to `LocalMnnModel`:

```dart
  static const _maxImageDimension = 784;

  /// Inserts <img> tags for image paths into the text content.
  static String insertImageTags(String text, List<String> imagePaths) {
    if (imagePaths.isEmpty) return text;
    final tags = imagePaths.map((p) => '<img>$p</img>').join('\n');
    return '$text\n$tags';
  }

  /// Resizes an image to fit within 784px on the longest dimension.
  /// Returns the path to the resized temp file.
  static Future<String> resizeImageForModel(String sourcePath) async {
    final file = File(sourcePath);
    final bytes = await file.readAsBytes();

    // Use the `image` package for decode + resize
    final img = img_lib.decodeImage(bytes);
    if (img == null) return sourcePath;

    final width = img.width;
    final height = img.height;
    final maxDim = width > height ? width : height;

    if (maxDim <= _maxImageDimension) {
      return sourcePath; // No resize needed
    }

    final resized = img_lib.copyResize(
      img,
      width: width > height ? _maxImageDimension : null,
      height: height >= width ? _maxImageDimension : null,
      interpolation: img_lib.Interpolation.linear,
    );

    final tempDir = await Directory.systemTemp.createTemp('mnn_img_');
    final tempPath = '${tempDir.path}/resized.jpg';
    await File(tempPath).writeAsBytes(img_lib.encodeJpg(resized, quality: 85));
    return tempPath;
  }
```

This uses the `image` package (`import 'package:image/image.dart' as img_lib;`). Add `image` to `pubspec.yaml` dependencies if not already present. Check existing usage first — the project may already depend on it.

- [ ] **Step 4: Update formatChatML to handle image attachments in messages**

Update the user message handling in `formatChatML` to process attachments:

```dart
      } else if (msg.role == PromptRole.user) {
        buffer.writeln('<|im_start|>user');
        final imagePaths = msg.metadata?['image_paths'] as List<String>? ?? [];
        buffer.writeln(insertImageTags(msg.content, imagePaths));
        buffer.writeln('<|im_end|>');
      }
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
flutter test test/services/models/local_mnn_model_test.dart
```
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/services/models/local_mnn_model.dart test/services/models/local_mnn_model_test.dart
git commit -m "feat: add image preprocessing and <img> tag insertion for local models"
```

---

## Task 9: ModelSelector Integration

**Files:**
- Modify: `lib/services/model_selector.dart:492-499`
- Modify: `lib/services/model_selector.dart` (constraint checking)

- [ ] **Step 1: Add LocalMnnModel to _createModel factory**

In `lib/services/model_selector.dart`, update `_createModel()` (around line 492):

```dart
AIModel _createModel(ModelType modelType) {
  switch (modelType) {
    case ModelType.gemini:
      return GeminiModel();
    case ModelType.openaiCompatible:
      return OpenAIModel();
    case ModelType.localMnn:
      return LocalMnnModel();
  }
}
```

Add import at top:
```dart
import 'package:note_synapse/services/models/local_mnn_model.dart';
```

- [ ] **Step 2: Add token window constraint check**

Find the section in `ModelSelector` where generation is initiated (the `generateWithToolsAndMessages` or `generateFromPrompt` methods). Add a constraint check before calling the model. Add a helper method:

```dart
  /// Estimates total tokens for a request and checks against local model's token window.
  /// Returns null if within limits, or a warning message if over.
  String? checkLocalModelConstraints(
    List<PromptMessage> messages,
    ModelConfig config,
  ) {
    if (config.type != ModelType.localMnn) return null;
    final tokenWindow = config.tokenWindow ?? 16384;

    int estimatedTokens = 0;
    for (final msg in messages) {
      estimatedTokens += TokenEstimator.estimateTokens(msg.content);
      // Each image ≈ 784 tokens (28x28 patches)
      final imagePaths = msg.metadata?['image_paths'] as List?;
      if (imagePaths != null) {
        estimatedTokens += imagePaths.length * 784;
      }
    }

    if (estimatedTokens > tokenWindow) {
      return 'Estimated input (~${(estimatedTokens / 1024).toStringAsFixed(1)}K tokens) '
          'exceeds local model token window (${(tokenWindow / 1024).toStringAsFixed(0)}K).';
    }
    return null;
  }
```

Add import:
```dart
import 'package:note_synapse/utils/token_estimator.dart';
```

- [ ] **Step 3: Run all tests**

```bash
flutter test
```
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add lib/services/model_selector.dart
git commit -m "feat: integrate LocalMnnModel into ModelSelector with constraint checking"
```

---

## Task 10: Model Selection Screen Update

**Files:**
- Modify: `lib/screens/model_selection_screen.dart:284-299`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_zh.arb`

- [ ] **Step 1: Add localMnn icon and description**

In `lib/screens/model_selection_screen.dart`, update `_getModelIcon()` (around line 284):

```dart
  IconData _getModelIcon(ModelType type) {
    switch (type) {
      case ModelType.gemini:
        return Icons.psychology;
      case ModelType.openaiCompatible:
        return Icons.api;
      case ModelType.localMnn:
        return Icons.phone_android;
    }
  }
```

Update `_getModelDescription()` (around line 293):

```dart
  String _getModelDescription(ModelType type) {
    switch (type) {
      case ModelType.gemini:
        return AppLocalizations.of(context)!.geminiDescription;
      case ModelType.openaiCompatible:
        return AppLocalizations.of(context)!.openaiDescription;
      case ModelType.localMnn:
        return AppLocalizations.of(context)!.localModelDescription;
    }
  }
```

- [ ] **Step 2: Update _buildModelCard to navigate to local model picker**

In the tap handler for the model card, add navigation to local model picker when `localMnn` is selected:

```dart
  // Inside _buildModelCard onTap:
  if (modelType == ModelType.localMnn) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LocalModelPickerScreen()),
    );
    return;
  }
```

Add import:
```dart
import 'package:note_synapse/screens/local_model_picker_screen.dart';
```

- [ ] **Step 3: Add l10n strings**

In `lib/l10n/app_en.arb`, add:
```json
  "localModelDescription": "On-device AI, no API key needed",
  "localModelDownload": "Download",
  "localModelDownloading": "Downloading...",
  "localModelReady": "Ready",
  "localModelNotDownloaded": "Not downloaded",
  "localModelDownloadFailed": "Download Failed",
  "localModelRetry": "Retry",
  "localModelDelete": "Delete Model",
  "localModelTokenWindow": "Token Window",
  "localModelEnableThinking": "Enable Thinking",
  "localModelBackend": "Backend",
  "localModelSettings": "Model Settings",
  "localModelConstraintWarning": "This input may exceed the local model's token window. Consider switching to a cloud model.",
  "localModelSwitchToCloud": "Switch to Cloud"
```

In `lib/l10n/app_zh.arb`, add the Chinese translations:
```json
  "localModelDescription": "本地AI模型，无需API密钥",
  "localModelDownload": "下载",
  "localModelDownloading": "下载中...",
  "localModelReady": "就绪",
  "localModelNotDownloaded": "未下载",
  "localModelDownloadFailed": "下载失败",
  "localModelRetry": "重试",
  "localModelDelete": "删除模型",
  "localModelTokenWindow": "Token窗口",
  "localModelEnableThinking": "启用思考",
  "localModelBackend": "后端",
  "localModelSettings": "模型设置",
  "localModelConstraintWarning": "输入内容可能超出本地模型的Token窗口限制，建议切换至云端模型。",
  "localModelSwitchToCloud": "切换到云端"
```

- [ ] **Step 4: Run build_runner for l10n generation**

```bash
flutter gen-l10n
```

- [ ] **Step 5: Run analysis**

```bash
flutter analyze
```
Expected: no new analysis errors.

- [ ] **Step 6: Commit**

```bash
git add lib/screens/model_selection_screen.dart lib/l10n/app_en.arb lib/l10n/app_zh.arb lib/l10n/
git commit -m "feat: add local model option to model selection screen with l10n"
```

---

## Task 11: Local Model Picker Screen

**Files:**
- Create: `lib/screens/local_model_picker_screen.dart`

- [ ] **Step 1: Create local model picker screen**

Create `lib/screens/local_model_picker_screen.dart`:

This screen shows all local model presets with their download status. Key behaviors:
- Lists all presets from `LocalModelPresets.all`
- Each model card shows: display name, size estimate, vision/text capability, download status
- **Not Downloaded**: shows "Download" button
- **Downloading**: shows progress bar with cancel button
- **Ready**: shows "Select" button → navigates to settings screen
- **Failed**: shows error message + "Retry" / "Back" buttons

Use `getIt<LocalModelService>()` for download management. Follow the existing screen patterns in the codebase (StatefulWidget, use of AppLocalizations for text).

```dart
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:note_synapse/services/local_model_service.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';
import 'package:note_synapse/screens/local_model_settings_screen.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

class LocalModelPickerScreen extends StatefulWidget {
  const LocalModelPickerScreen({super.key});

  @override
  State<LocalModelPickerScreen> createState() => _LocalModelPickerScreenState();
}

class _LocalModelPickerScreenState extends State<LocalModelPickerScreen> {
  final _service = GetIt.instance<LocalModelService>();
  List<LocalModelStatus> _models = [];
  final Map<String, double> _downloadProgress = {};
  final Map<String, String> _downloadErrors = {};

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  Future<void> _loadModels() async {
    final models = await _service.getAvailableModels();
    if (mounted) setState(() => _models = models);
  }

  void _startDownload(LocalModelPreset preset) {
    setState(() {
      _downloadProgress[preset.id] = 0.0;
      _downloadErrors.remove(preset.id);
    });

    _service.downloadModel(
      preset,
      onComplete: (configPath) {
        if (mounted) {
          setState(() => _downloadProgress.remove(preset.id));
          _loadModels();
        }
      },
      onError: (error) {
        if (mounted) {
          setState(() {
            _downloadProgress.remove(preset.id);
            _downloadErrors[preset.id] = error;
          });
        }
      },
    ).listen((progress) {
      if (mounted) {
        setState(() => _downloadProgress[preset.id] = progress);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.localModelSettings)),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _models.length,
        itemBuilder: (context, index) => _buildModelCard(_models[index]),
      ),
    );
  }

  Widget _buildModelCard(LocalModelStatus status) {
    final preset = status.preset;
    final isDownloading = _downloadProgress.containsKey(preset.id);
    final error = _downloadErrors[preset.id];
    final l10n = AppLocalizations.of(context)!;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(preset.displayName,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        preset.supportsVision ? 'Vision + Text' : 'Text only',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (status.isDownloaded && !isDownloading)
                  FilledButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LocalModelSettingsScreen(
                          preset: preset,
                          configPath: status.modelPath!,
                        ),
                      ),
                    ),
                    child: Text(l10n.localModelReady),
                  )
                else if (isDownloading)
                  const SizedBox.shrink()
                else if (error != null)
                  const SizedBox.shrink()
                else
                  OutlinedButton(
                    onPressed: () => _startDownload(preset),
                    child: Text(l10n.localModelDownload),
                  ),
              ],
            ),
            if (isDownloading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _downloadProgress[preset.id]),
              const SizedBox(height: 4),
              Text('${l10n.localModelDownloading} '
                  '${(_downloadProgress[preset.id]! * 100).toStringAsFixed(0)}%'),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(l10n.localModelDownloadFailed,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(MaterialLocalizations.of(context).backButtonTooltip),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _startDownload(preset),
                    child: Text(l10n.localModelRetry),
                  ),
                ],
              ),
            ],
            if (status.isDownloaded && !isDownloading)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(l10n.localModelReady,
                    style: TextStyle(color: Theme.of(context).colorScheme.primary)),
              ),
            if (!status.isDownloaded && !isDownloading && error == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(l10n.localModelNotDownloaded,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify analysis passes**

```bash
flutter analyze
```
Expected: no new errors.

- [ ] **Step 3: Commit**

```bash
git add lib/screens/local_model_picker_screen.dart
git commit -m "feat: add local model picker screen with download management"
```

---

## Task 12: Local Model Settings Screen

**Files:**
- Create: `lib/screens/local_model_settings_screen.dart`

- [ ] **Step 1: Create local model settings screen**

Create `lib/screens/local_model_settings_screen.dart`:

This screen configures a downloaded local model. Key settings:
- **Backend selector**: dropdown with options based on platform + model (e.g., OpenCL/CPU on Android)
- **Enable Thinking**: toggle switch
- **Token Window**: slider (4096–32768)
- **Delete Model**: button at bottom

When user confirms settings, create a `ModelConfig` with `type: ModelType.localMnn` and save via `ModelStorageService`.

```dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_type.dart';
import 'package:note_synapse/services/local_model_service.dart';
import 'package:note_synapse/services/model_storage_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

class LocalModelSettingsScreen extends StatefulWidget {
  final LocalModelPreset preset;
  final String configPath;

  const LocalModelSettingsScreen({
    super.key,
    required this.preset,
    required this.configPath,
  });

  @override
  State<LocalModelSettingsScreen> createState() => _LocalModelSettingsScreenState();
}

class _LocalModelSettingsScreenState extends State<LocalModelSettingsScreen> {
  late String _backendType;
  bool _enableThinking = false;
  int _tokenWindow = 16384;

  List<String> get _availableBackends {
    if (Platform.isAndroid) {
      return ['cpu', 'opencl'];
    } else if (Platform.isIOS) {
      // Metal only for models that support it
      final defaultBackend = widget.preset.defaultBackend['ios'] ?? 'cpu';
      if (defaultBackend == 'metal') return ['metal', 'cpu'];
      return ['cpu']; // Metal bugged for this model
    }
    return ['cpu'];
  }

  @override
  void initState() {
    super.initState();
    final platform = Platform.isAndroid ? 'android' : 'ios';
    _backendType = widget.preset.defaultBackend[platform] ?? 'cpu';
    _tokenWindow = widget.preset.defaultTokenWindow;
  }

  Future<void> _saveAndActivate() async {
    final config = ModelConfig(
      id: 'local_${widget.preset.id}',
      type: ModelType.localMnn,
      modelName: widget.preset.id,
      displayName: widget.preset.displayName,
      endpoint: widget.configPath, // reuse endpoint field for config path
      tokenWindow: _tokenWindow,
      enableThinking: _enableThinking,
      backendType: _backendType,
      isConfigured: true,
    );

    final storage = GetIt.instance<ModelStorageService>();
    await storage.addModel(config);
    await GetIt.instance<ModelSelector>().switchToModel(config);

    if (mounted) {
      Navigator.popUntil(context, (route) => route.isFirst);
    }
  }

  Future<void> _deleteModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.localModelDelete),
        content: Text('Delete ${widget.preset.displayName}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );

    if (confirmed == true) {
      await GetIt.instance<LocalModelService>().removeModel(widget.preset.id);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(widget.preset.displayName)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Backend selector
          Text(l10n.localModelBackend, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _backendType,
            items: _availableBackends
                .map((b) => DropdownMenuItem(value: b, child: Text(_backendLabel(b))))
                .toList(),
            onChanged: (v) => setState(() => _backendType = v!),
          ),
          const SizedBox(height: 24),

          // Enable Thinking toggle
          SwitchListTile(
            title: Text(l10n.localModelEnableThinking),
            subtitle: const Text('Extended reasoning (uses more tokens)'),
            value: _enableThinking,
            onChanged: (v) => setState(() => _enableThinking = v),
          ),
          const SizedBox(height: 24),

          // Token Window slider
          Text(l10n.localModelTokenWindow, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('4096'),
              Expanded(
                child: Slider(
                  value: _tokenWindow.toDouble(),
                  min: 4096,
                  max: 32768,
                  divisions: 7, // 4096 increments
                  label: _tokenWindow.toString(),
                  onChanged: (v) => setState(() => _tokenWindow = v.round()),
                ),
              ),
              const Text('32768'),
            ],
          ),
          Center(child: Text('$_tokenWindow', style: Theme.of(context).textTheme.titleMedium)),
          const SizedBox(height: 32),

          // Save & Activate button
          FilledButton(
            onPressed: _saveAndActivate,
            child: const Text('Save & Activate'),
          ),
          const SizedBox(height: 16),

          // Delete button
          OutlinedButton(
            onPressed: _deleteModel,
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.localModelDelete),
          ),
        ],
      ),
    );
  }

  String _backendLabel(String backend) {
    switch (backend) {
      case 'opencl': return 'OpenCL (GPU)';
      case 'metal': return 'Metal (GPU)';
      case 'cpu': return 'CPU';
      default: return backend;
    }
  }
}
```

- [ ] **Step 2: Verify analysis passes**

```bash
flutter analyze
```
Expected: no new errors.

- [ ] **Step 3: Commit**

```bash
git add lib/screens/local_model_settings_screen.dart
git commit -m "feat: add local model settings screen with backend, thinking, token window config"
```

---

## Task 13: Streaming UI for Conversation Chat Screen

**Files:**
- Modify: `lib/services/models/local_mnn_model.dart`
- Modify: `lib/services/conversation_ai_engine.dart:45-70` (main `generate()` method)
- Modify: `lib/screens/conversation_chat_screen.dart:999-1016` (response handling in `_sendMessage()`)
- Modify: `lib/screens/conversation_chat_screen.dart:1117-1176` (`_generateAIResponse()`)

This is the most complex UI task. The goal: when a local model generates a plain-chat response (no tools), tokens stream into the chat bubble progressively.

- [ ] **Step 1: Add streaming generation method to LocalMnnModel**

Add to `lib/services/models/local_mnn_model.dart`:

```dart
  /// Generates a streaming response for plain chat (no tool calls).
  /// Returns a Stream of text chunks.
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
```

- [ ] **Step 2: Add streaming callback to ConversationAiEngine**

In `lib/services/conversation_ai_engine.dart`, add an optional `onStreamChunk` callback parameter to both `generate()` (line 45) and `_generateWithTools()` (line 72):

```dart
  // In generate() — add onStreamChunk to existing signature:
  Future<ConversationAiResponse> generate({
    required PromptRequest request,
    required Map<String, List<McpTool>> activeTools,
    required bool enableTools,
    required ToolExecutionCallback executeTool,
    required CancellationCheck isCancelled,
    required GenerationContext generationContext,
    int? maxToolIterations,
    IterationsExhaustedHandler? onIterationsExhausted,
    void Function(String chunk)? onStreamChunk, // NEW
  }) async {
    // ... pass onStreamChunk through to _generateWithTools
  }
```

Inside `_generateWithTools()`, add the streaming shortcut **after** the first `ModelSelector.generateWithToolsAndMessages()` call resolves (line ~157). This preserves all existing cancellation checking, logging, and setup logic. Insert the streaming path just before the `while(true)` loop at line 116:

```dart
    // Streaming shortcut: if local model + no tools, stream directly
    final activeModel = getIt<ModelSelector>().activeModel;
    if (activeModel is LocalMnnModel &&
        activeModel.supportsStreaming &&
        activeTools.isEmpty &&
        onStreamChunk != null) {
      final buffer = StringBuffer();
      await for (final chunk in activeModel.generateStreaming(currentMessages)) {
        if (isCancelled()) throw const ConversationCancelledException();
        buffer.write(chunk);
        onStreamChunk(chunk);
      }
      return ConversationAiResponse(
        content: buffer.toString(),
        metadata: {'modelUsed': activeModel.name},
      );
    }

    // ... existing while(true) tool iteration loop continues below
```

This placement ensures:
- Cancellation checking is preserved (checks `isCancelled()` per chunk)
- Message building (`currentMessages`) is reused
- The streaming path only fires when no tools are active
- If tools are present, the normal buffered tool iteration loop handles everything

Add import at top:
```dart
import 'package:note_synapse/services/models/local_mnn_model.dart';
```

- [ ] **Step 3: Add streaming state to conversation chat screen**

In `lib/screens/conversation_chat_screen.dart`, add state variables (near `_isSending`):

```dart
  String _streamingContent = '';
  bool _isStreaming = false;
```

- [ ] **Step 4: Update _sendMessage() to handle streaming**

In `_sendMessage()` (line ~999), replace the block that calls `_generateAIResponse` and adds the message:

```dart
      // Create a placeholder AI message for streaming
      String? streamingMessageId;

      final aiResponse = await _generateAIResponse(
        content,
        attachments,
        generationContext,
        onStreamChunk: (chunk) {
          if (mounted) {
            setState(() {
              _streamingContent += chunk;
              _isStreaming = true;
            });
            _scrollToBottom();
          }
        },
      );

      // Finalize: save the complete response
      final aiMessage = await _conversationService.addAIResponse(
        conversationId: _conversation!.id,
        content: aiResponse.content,
        metadata: aiResponse.metadata,
        modelUsed: aiResponse.metadata?['modelUsed'] as String?,
      );
      if (!mounted) return;

      setState(() {
        _streamingContent = '';
        _isStreaming = false;
        _messages.add(aiMessage);
      });
      _scrollToBottom();
```

- [ ] **Step 5: Pass onStreamChunk through _generateAIResponse to _aiEngine.generate()**

In `_generateAIResponse()` (line ~1117), add the callback parameter:

```dart
  Future<ConversationAiResponse> _generateAIResponse(
    String userMessage,
    List<PlatformFile> attachedFiles,
    GenerationContext generationContext, {
    void Function(String chunk)? onStreamChunk,
  }) async {
```

Pass it through to `_aiEngine.generate()` (line ~1142):

```dart
      final aiResponse = await _aiEngine.generate(
        request: request,
        activeTools: _buildActiveToolsMap(),
        enableTools: _hasAnyTools || _selectedModelFeatures.isNotEmpty,
        executeTool: /* ... existing code ... */,
        generationContext: generationContext,
        onStreamChunk: onStreamChunk,  // NEW
      );
```

- [ ] **Step 6: Render streaming content in the chat message list**

In the chat screen's `ListView.builder` (where messages are rendered), add a streaming message bubble at the end when `_isStreaming` is true:

```dart
  // After the last message in the list, if streaming:
  if (_isStreaming && _streamingContent.isNotEmpty) {
    // Render a temporary AI message bubble with _streamingContent
    // Use the same message widget as regular AI messages but with _streamingContent as text
  }
```

The exact widget depends on the existing message rendering pattern — use the same AI message widget/card.

- [ ] **Step 7: Test manually on device**

Launch the app on a device with a local model downloaded. Send a chat message and verify:
- Tokens appear progressively in the response bubble
- Cancel button works mid-generation
- Message is finalized correctly after generation completes
- When tools are active, falls back to buffered response (no streaming)

- [ ] **Step 8: Commit**

```bash
git add lib/services/models/local_mnn_model.dart lib/services/conversation_ai_engine.dart lib/screens/conversation_chat_screen.dart
git commit -m "feat: add streaming response UI for local model chat"
```

---

## Task 14: Streaming UI for Immersive Screen

**Files:**
- Modify: `lib/screens/immersive_note_screen.dart:149` (has `_aiEngine` instance)
- Modify: `lib/screens/immersive_note_screen.dart:4781-4914` (`_sendMessage()` method)
- Modify: `lib/screens/immersive_note_screen.dart:5144-5183` (`_aiEngine.generate()` call in `_generateAiResponse()`)

The immersive screen follows the same pattern as the conversation chat screen. It has:
- `_isSending` state variable
- `_sendMessage()` at line 4781 that calls `_generateAiResponse()`
- `_generateAiResponse()` which calls `_aiEngine.generate()` at line 5144
- Response added to `_messages` at line 4912

- [ ] **Step 1: Add streaming state variables**

Near the existing `_isSending` declaration, add:

```dart
  String _streamingContent = '';
  bool _isStreaming = false;
```

- [ ] **Step 2: Add onStreamChunk to _generateAiResponse()**

In the `_generateAiResponse()` method, add an `onStreamChunk` callback parameter and pass it through to `_aiEngine.generate()` at line 5144:

```dart
  // Add parameter:
  void Function(String chunk)? onStreamChunk,

  // Pass to _aiEngine.generate():
  final response = await _aiEngine.generate(
    // ... existing parameters ...
    onStreamChunk: onStreamChunk,  // NEW
  );
```

- [ ] **Step 3: Update _sendMessage() to handle streaming**

In `_sendMessage()` (line ~4898), update the call to `_generateAiResponse`:

```dart
      final response = await _generateAiResponse(
        content,
        attachments,
        generationContext,
        onStreamChunk: (chunk) {
          if (mounted) {
            setState(() {
              _streamingContent += chunk;
              _isStreaming = true;
            });
            _scrollToBottom();
          }
        },
      );

      // ... existing aiMessage saving code ...

      setState(() {
        _streamingContent = '';
        _isStreaming = false;
        _messages.add(aiMessage);
      });
```

- [ ] **Step 4: Render streaming content in the chat area**

In the chat message list builder, add a streaming message at the end when `_isStreaming` is true, using the same AI message rendering widget the screen already uses.

- [ ] **Step 5: Test manually on device**

Launch immersive reading mode with a document. Ask a question with a local model active. Verify streaming works.

- [ ] **Step 6: Commit**

```bash
git add lib/screens/immersive_note_screen.dart
git commit -m "feat: add streaming response UI for local model immersive screen"
```

---

## Task 15: Final Integration & Smoke Test

**Files:**
- All files from previous tasks

- [ ] **Step 1: Run full test suite**

```bash
flutter test
```
Expected: all tests pass.

- [ ] **Step 2: Run analysis**

```bash
flutter analyze
```
Expected: no errors.

- [ ] **Step 3: Manual end-to-end smoke test on Android**

1. Open app → Model Selection → "Local Models"
2. See Qwen 3.5 0.8B and Qwen3 VL 2B listed
3. Tap "Download" on Qwen 3.5 0.8B → progress bar → completion
4. Tap "Select" → settings screen
5. Verify: Backend shows "OpenCL (GPU)" default, Thinking toggle, Token Window slider
6. Save & Activate
7. Open a conversation → send a message → response streams in
8. Send an image → verify image is processed with local model
9. Switch to cloud model via `v` icon → verify cloud model still works
10. Switch back to local → verify no crash

- [ ] **Step 4: Manual end-to-end smoke test on iOS**

Same flow but verify:
1. Qwen3 VL 2B defaults to Metal (GPU)
2. Qwen 3.5 0.8B defaults to CPU (no Metal option)
3. Vision works with Qwen3 VL 2B

- [ ] **Step 5: Commit any fixes from smoke testing**

```bash
# Stage only the specific files that were fixed during smoke testing
git add <specific files changed>
git commit -m "fix: smoke test fixes for local AI integration"
```

- [ ] **Step 6: Final commit — update TODOS.md**

Update `TODOS.md` to mark the MNN integration task as complete and keep the BNF decoding V2 item.

```bash
git add TODOS.md
git commit -m "docs: update TODOS.md — local AI integration complete, BNF decoding V2 remains"
```
