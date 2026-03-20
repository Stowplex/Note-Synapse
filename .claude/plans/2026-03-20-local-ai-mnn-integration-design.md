# Design: Local AI Integration via MNN (edge_gen)

**Date:** 2026-03-20
**Branch:** kkspeed/update_json_view
**Status:** DRAFT
**Related:**
- CEO Plan: `~/.gstack/projects/kkspeed-Note-Synapse/ceo-plans/2026-03-19-local-ai-research-wedge.md`
- Design Doc: `~/.gstack/projects/kkspeed-Note-Synapse/liwen-kkspeed-update_json_view-design-20260319-office-hours.md`
- Test Plan: `~/.gstack/projects/kkspeed-Note-Synapse/liwen-kkspeed-update_json_view-test-plan-20260319.md`

## Problem Statement

Note Synapse currently requires users to bring their own API key (Gemini or OpenAI-compatible) for AI features. This creates onboarding friction — users must obtain and configure an API key before experiencing any AI functionality. Local on-device inference via MNN removes this barrier entirely: download a model, start chatting. Zero API keys, zero cloud dependency, works offline.

## Goals

1. Integrate the `edge_gen` Flutter plugin (MNN wrapper) as a first-class AI provider alongside Gemini and OpenAI Compatible
2. Support two models: Qwen 3.5 0.8B (text + vision) and Qwen3 VL 2B (vision-language)
3. Platform-appropriate defaults: Android → Qwen 3.5 0.8B (OpenCL/GPU), iOS → Qwen3 VL 2B (Metal/GPU)
4. Streaming response UI for local models in conversation chat and immersive screens
5. Tool calling via JSON output + json_repair (BNF-constrained decoding deferred to V2)

## Non-Goals

- BNF/grammar-constrained decoding (V2, tracked in TODOS.md)
- Cloud model streaming (cloud continues using non-streaming endpoints)
- Changes to first-launch onboarding flow (local models appear as a peer option in existing model selection)
- macOS/Linux/web support for local models (Android and iOS only — MNN targets mobile)

## Architecture: Thin Adapter Pattern

```
ModelSelector
    ├── GeminiModel        (existing)
    ├── OpenaiModel         (existing)
    └── LocalMnnModel       (new — wraps EdgeGenSession)
            │
            └── edge_gen plugin
                    │
                    └── MNN (C++ via platform channels)
```

`LocalMnnModel extends AIModel` — follows the exact same pattern as `GeminiModel` and `OpenaiModel`. The adapter translates between Note-Synapse's `PromptMessage` format and edge_gen's prompt string + streaming API.

## Component Design

### 1. edge_gen Submodule

**Location:** `third_party/edge_gen/` (git submodule of `git@github.com:Stowplex/edge_gen.git`)

Contains its own MNN submodule at `third_party/edge_gen/third_party/MNN/`. Referenced as a path dependency in `pubspec.yaml`:

```yaml
dependencies:
  edge_gen:
    path: third_party/edge_gen
```

Bootstrap: `git submodule update --init --recursive` pulls both edge_gen and MNN.

### 2. ModelType Extension

**File:** `lib/models/model_type.dart`

```dart
enum ModelType {
  gemini('gemini', 'Gemini'),
  openaiCompatible('openai_compatible', 'OpenAI Compatible'),
  localMnn('local_mnn', 'Local Model'),  // new
}
```

### 3. Local Model Presets

**File:** `lib/services/models/local_model_presets.dart`

A configuration-driven registry of available local models. Each preset defines:

```dart
class LocalModelPreset {
  final String id;                        // 'qwen35_08b'
  final String displayName;               // 'Qwen 3.5 0.8B'
  final QwenModelSpec spec;               // from edge_gen — includes HuggingFace repoId + requiredFiles
  final Map<String, String> defaultBackend; // {'android': 'opencl', 'ios': 'cpu'}
  final bool supportsVision;
  final bool supportsThinking;
  final int defaultTokenWindow;           // e.g. 16384
}
```

Initial presets:

| ID | Display Name | HF Repo | Default Backend (Android) | Default Backend (iOS) | Vision | Thinking |
|----|-------------|---------|--------------------------|----------------------|--------|----------|
| `qwen35_08b` | Qwen 3.5 0.8B | `taobao-mnn/Qwen3.5-0.8B-MNN` | OpenCL (GPU) | CPU (Metal bug) | Yes | Yes |
| `qwen3_vl_2b` | Qwen3 VL 2B | `taobao-mnn/Qwen3-VL-2B-Instruct-MNN` | CPU | Metal (GPU) | Yes | Yes |

Adding a new model = adding one preset entry. No other code changes required.

### 4. LocalModelService

**File:** `lib/services/local_model_service.dart`
**GetIt registration:** Wave 2 (depends only on DatabaseService)

Responsibilities:
- **Download management:** wraps `QwenModelDownloader` from edge_gen, exposes `Stream<double>` for progress
- **Status tracking:** persists which models are downloaded via SharedPreferences (model ID → file path mapping). No database table needed — download state is lightweight metadata, not relational data.
- **Deletion:** removes model files and clears SharedPreferences entries
- **Model enumeration:** lists available presets, checks SharedPreferences + file system for download status

### 5. LocalMnnModel (AIModel Adapter)

**File:** `lib/services/models/local_mnn_model.dart`

**Lazy loading:** `initialize()` validates model files exist but does NOT load the model into memory. The `EdgeGenSession` is created on the first generation call, so configuring a local model has zero memory cost until it's actually used.

**Prompt formatting:** Converts `List<PromptMessage>` to Qwen's ChatML format:

```
<|im_start|>system
{system message}
<|im_end|>
<|im_start|>user
{user message with <img> tags for images}
<|im_end|>
<|im_start|>assistant
```

**Image handling:**
- All image sources supported (note content, PDF pages, conversation attachments, immersive reading)
- Images resized to 784px on longest dimension, preserving aspect ratio (matches Qwen's 28x28 patch tokenization)
- Resized images saved to temp directory, path inserted as `<img>/path/to/resized.jpg</img>` in prompt
- PDFs rendered as page images, each resized to 784px
- Temp files cleaned up after generation completes

**Tool calling:**
- Tool schemas injected as JSON array in system prompt with instruction to respond with `{"name": "call_tool", "arguments": {"service_name": "...", "tool_name": "...", "params": {...}}}`
- Response parsed via regex for JSON tool call objects
- `json_repair` (new dependency in `pubspec.yaml`) applied before `jsonDecode` to handle common malformations
- On parse failure: treat entire response as plain text (graceful degradation, suggest cloud model in error)

**`generateWithToolsAndMessages` return contract:**
Returns `Map<String, dynamic>` matching the format expected by `ConversationAiEngine`:
- Plain text response: `{'text': 'response text', 'modelUsed': 'Qwen 3.5 0.8B'}`
- Tool call detected: `{'text': '', 'function_calls': [{'name': 'call_tool', 'args': {'service_name': '...', 'tool_name': '...', 'params': {...}}}], 'modelUsed': 'Qwen 3.5 0.8B'}`
- Mixed (text + tool call): `{'text': 'reasoning text', 'function_calls': [...], 'modelUsed': '...'}`

The adapter parses the buffered response, extracts any JSON tool call blocks, and returns everything else as `text`. This matches how `GeminiModel` and `OpenaiModel` structure their returns.

**`generateWithAttachments`:** Uses the default `AIModel` base implementation which delegates to `generateWithMessages` via `PromptRequest`. Image attachments are handled by the prompt formatter (resize + `<img>` tag insertion), so no special override needed.

**Streaming behavior:**
- Plain chat: chunks streamed directly to UI as they arrive from `EdgeGenSession.generate()`
- Tool-enabled turns: buffer full response before parsing for tool call JSON

**Session lifecycle:**
- Session created lazily on first generation call
- Session reset between conversations (clears KV cache + history)
- Session disposed when user switches away from local model
- Only one local session active at a time
- On model switch: dispose previous session before creating new one

### 6. ModelConfig Additions

**File:** `lib/models/model_config.dart`

New fields for `ModelType.localMnn`:
- `tokenWindow: int` — user-configurable, 4096–32768
- `enableThinking: bool` — Qwen thinking mode toggle
- `backendType: String` — defaults from preset, user-overridable (options: 'cpu', 'opencl', 'metal')

No `apiKey` or `endpoint` needed for local models.

### 7. Constraint Checking & Smart Routing

**Location:** `lib/services/model_selector.dart` (extends existing capability matching)

Before generation with a local model:

1. **Token estimation:** reuse existing `TokenEstimator.estimateTokens()` from `lib/utils/token_estimator.dart` (handles CJK characters correctly); add ~784 tokens per image (28x28 patches). Sum compared against configured `tokenWindow`.
2. **Over-limit warning:** If estimated tokens exceed token window, show dialog: "This input is ~{N}K tokens, exceeding your local model's {W}K window. Switch to [cloud model]?" Options: Switch / Send Anyway / Cancel.
3. **Existing capability matching:** `ModelCapabilities` flags (supports images, video, etc.) set correctly in local model presets. No new capability logic needed.
4. **Tool call failure fallback:** If local model fails to produce valid JSON after repair, error message suggests switching to cloud model.

### 8. Streaming UI

**Affected screens:** Conversation chat screen, immersive reading screen.

Current cloud models return complete responses (non-streaming endpoints). Local models stream token-by-token. Changes:

- `ConversationAiEngine` gains a streaming code path that yields partial responses via a `Stream`
- Chat screen: response bubble progressively renders text as chunks arrive
- Immersive screen: same progressive rendering
- Other AI callers (note transform, app generation, etc.) continue using buffered responses
- Cloud models are unaffected — they continue using non-streaming endpoints

### 9. UI Screens

**Model Selection Screen (existing, updated):**
- Three options: Local Models / Gemini / OpenAI Compatible
- Local Models is a peer option, not a special onboarding path

**Local Model Picker Screen (new):**
- Lists all presets with status: Not Downloaded / Downloading (%) / Ready
- Download button per model → progress bar during download
- On failure: error message + Retry / Back buttons
- Tapping a downloaded model navigates to settings

**Local Model Settings Screen (new):**
- Model status + file size display
- Backend selector dropdown (options depend on platform + model, defaults from preset)
- Enable Thinking toggle (on/off, default off)
- Token Window slider (4096–32768)
- Delete Model button

## File Summary

| Component | File | Purpose |
|-----------|------|---------|
| edge_gen submodule | `third_party/edge_gen/` | MNN Flutter bridge |
| ModelType extension | `lib/models/model_type.dart` | New `localMnn` enum value |
| Local model presets | `lib/services/models/local_model_presets.dart` | Config-driven model registry with HF URLs |
| LocalModelService | `lib/services/local_model_service.dart` | Download, delete, status management |
| LocalMnnModel | `lib/services/models/local_mnn_model.dart` | AIModel adapter wrapping EdgeGenSession |
| ModelConfig additions | `lib/models/model_config.dart` | tokenWindow, enableThinking, backendType |
| Constraint checking | `lib/services/model_selector.dart` | Token window warning, cloud suggestions |
| Streaming UI | Chat screen + immersive screen | Progressive text rendering for local models |
| Local model picker | `lib/screens/local_model_picker_screen.dart` | Download and select local models |
| Local model settings | `lib/screens/local_model_settings_screen.dart` | Configure backend, thinking, token window |

## Testing Strategy

Per the test plan:
- **Unit tests:** LocalMnnModel prompt formatting, token estimation, tool call parsing + json_repair, image resizing logic, preset loading
- **Integration tests:** Download flow (mock HF), session lifecycle (create/reset/dispose), model switching (local → cloud → local)
- **Edge cases:** Corrupted model → checksum validation + re-download, storage full → clear error, input exceeds token window → warning, malformed tool call JSON → graceful fallback
- **Platform tests:** Correct backend defaults per platform + model combination

## Future Work (V2)

- BNF/grammar-constrained decoding for reliable tool call JSON (TODOS.md)
- Cloud model streaming (reuse local model streaming UI plumbing)
- Additional local models (add presets, no architecture changes)
- Download resume on network interruption (restart from beginning for V1)
