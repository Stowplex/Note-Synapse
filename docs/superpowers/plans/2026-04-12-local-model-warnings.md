# Local Model Degradation Warnings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore and extend the local model warning system so users are clearly warned when Gemma is active and they use skills, tag workflows, or MCP tools.

**Architecture:** Fix `supportsToolOrchestration = false` on the Gemma preset (re-enabling the existing MCP tool warning system), then extend the same capability flag to drive a warning badge on the skills button (plus model-aware default-off), a warning badge on the tag management Workflows tab, and an approval dialog before tag workflows run — wired via a static callback on `ContentIngestionService` registered by `WorkflowShell`.

**Tech Stack:** Flutter/Dart, Provider, GetIt, flutter_localizations (ARB), Mockito

---

## File Map

| File | Change |
|---|---|
| `lib/services/models/local_model_presets.dart` | Add `supportsToolOrchestration` field; set `false` on `gemma4E2b` |
| `lib/screens/local_model_settings_screen.dart` | Use `preset.supportsToolOrchestration` instead of `preset.supportsToolCalls` |
| `lib/screens/conversation_chat_screen.dart` | Skills badge + model-aware default-off in `initState` |
| `lib/screens/tag_management_screen.dart` | Warning badge on Workflows tab |
| `lib/widgets/local_model_workflow_warning_dialog.dart` | New: `LocalModelWorkflowApproval` enum + dialog widget |
| `lib/services/content_ingestion_service.dart` | Static callback + session flag + check in `processNote` |
| `lib/widgets/workflow_shell.dart` | Register/unregister callback handler in `initState`/`dispose` |
| `lib/l10n/app_en.arb` | 3 new strings |
| `lib/l10n/app_zh.arb` | 3 new Chinese strings |
| `test/local_model_presets_test.dart` | New: unit tests for preset capability |
| `test/content_ingestion_approval_test.dart` | New: unit tests for approval callback logic |

---

### Task 1: Add `supportsToolOrchestration` to `LocalModelPreset`

The bug: `local_model_settings_screen.dart:87` sets `supportsToolOrchestration: widget.preset.supportsToolCalls`. Tool calls (API-level) and tool orchestration (reliable multi-step agentic) are different — Gemma supports the former, not the latter. Fix by adding a dedicated field.

**Files:**
- Modify: `lib/services/models/local_model_presets.dart`
- Modify: `lib/screens/local_model_settings_screen.dart`
- Create: `test/local_model_presets_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/local_model_presets_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/models/local_model_presets.dart';

void main() {
  group('LocalModelPresets.gemma4E2b', () {
    test('supportsToolOrchestration is false', () {
      expect(LocalModelPresets.gemma4E2b.supportsToolOrchestration, isFalse);
    });

    test('supportsToolCalls remains true', () {
      expect(LocalModelPresets.gemma4E2b.supportsToolCalls, isTrue);
    });
  });

  group('LocalModelPreset default', () {
    test('supportsToolOrchestration defaults to false', () {
      // Verify any preset constructed without explicit supportsToolOrchestration
      // is safe-by-default.
      expect(LocalModelPresets.gemma4E2b.supportsToolOrchestration, isFalse);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
flutter test test/local_model_presets_test.dart
```

Expected: compile error — `supportsToolOrchestration` not defined on `LocalModelPreset`.

- [ ] **Step 3: Add `supportsToolOrchestration` to `LocalModelPreset`**

In `lib/services/models/local_model_presets.dart`, add the field to the class and constructor:

```dart
class LocalModelPreset {
  // ... existing fields ...
  final bool supportsToolOrchestration;   // ← add this line

  const LocalModelPreset({
    // ... existing named params ...
    this.supportsToolOrchestration = false,  // ← add with default false
  });
}
```

The `gemma4E2b` preset does not need to set it explicitly since the default is `false`. Leave `supportsToolCalls: true` unchanged — it means the flutter_gemma API accepts tool declarations, which is separate.

- [ ] **Step 4: Fix `local_model_settings_screen.dart`**

At line ~87, change:

```dart
supportsToolOrchestration: widget.preset.supportsToolCalls,
```

to:

```dart
supportsToolOrchestration: widget.preset.supportsToolOrchestration,
```

- [ ] **Step 5: Run tests**

```bash
flutter test test/local_model_presets_test.dart
```

Expected: all pass.

- [ ] **Step 6: Analyze**

```bash
flutter analyze
```

Expected: no new errors.

- [ ] **Step 7: Commit**

```bash
git add lib/services/models/local_model_presets.dart \
        lib/screens/local_model_settings_screen.dart \
        test/local_model_presets_test.dart
git commit -m "fix: set supportsToolOrchestration=false on Gemma preset, restoring local model warnings"
```

---

### Task 2: Skills Button — Warning Badge and Model-Aware Default

The skills `FilterChip` in the conversation tool panel needs two changes when `supportsToolOrchestration == false`: a warning badge overlay, and starting unchecked (disabled by default).

**Files:**
- Modify: `lib/screens/conversation_chat_screen.dart`

The `supportsToolOrchestration` variable is already computed in the build method at ~line 2018–2022 and reused for MCP tool badges. The skills section at ~line 2351 is in the same build method — use the same variable.

- [ ] **Step 1: Change `initState` skills initialization**

Find and replace this block in `initState` (~lines 145–156):

```dart
// BEFORE:
_skillsEnabled = widget.skillsEnabled;
if (widget.skillsEnabled) {
  _conversationService.enableSkills().then((_) {
    if (mounted)
      setState(() => _skillCount = _conversationService.skillIndex.length);
  });
} else {
  _conversationService.disableSkills();
  getIt<SkillService>().buildSkillIndex().then((index) {
    if (mounted) setState(() => _skillCount = index.length);
  });
}
```

Replace with:

```dart
// Skills start disabled; _initSkillsWithModelCheck runs after first frame
// when BuildContext is available to read the active model's capabilities.
_skillsEnabled = false;
WidgetsBinding.instance.addPostFrameCallback((_) => _initSkillsWithModelCheck());
```

- [ ] **Step 2: Add `_initSkillsWithModelCheck` method**

Add this method to `_ConversationChatScreenState` (near the other init helpers):

```dart
void _initSkillsWithModelCheck() {
  if (!mounted) return;
  final modelConfig = _selectedModel ?? context.read<AppProvider>().modelConfig;
  final supportsOrchestration =
      modelConfig?.customCapabilitiesObject?.supportsToolOrchestration ?? true;
  final enable = widget.skillsEnabled && supportsOrchestration;
  if (enable) {
    setState(() => _skillsEnabled = true);
    _conversationService.enableSkills().then((_) {
      if (mounted)
        setState(() => _skillCount = _conversationService.skillIndex.length);
    });
  } else {
    _conversationService.disableSkills();
    getIt<SkillService>().buildSkillIndex().then((index) {
      if (mounted) setState(() => _skillCount = index.length);
    });
  }
}
```

- [ ] **Step 3: Add warning badge to the skills `FilterChip`**

Find the skills `FilterChip` at ~line 2383. It is rendered inside `if (_skillCount > 0) ...`. Wrap the existing `FilterChip(...)` in a `Stack` with the badge overlay:

```dart
// BEFORE:
FilterChip(
  label: Text('$_skillCount available'),
  selected: _skillsEnabled,
  // ... rest of chip properties
),

// AFTER:
Stack(
  clipBehavior: Clip.none,
  children: [
    FilterChip(
      label: Text('$_skillCount available'),
      selected: _skillsEnabled,
      // ... rest of chip properties unchanged
    ),
    if (!supportsToolOrchestration)
      Positioned(
        right: -4,
        top: -4,
        child: Icon(
          Icons.warning_amber_rounded,
          size: 12,
          color: Colors.amber.shade700,
        ),
      ),
  ],
),
```

The `supportsToolOrchestration` variable is already in scope from ~line 2018.

- [ ] **Step 4: Analyze**

```bash
flutter analyze
```

Expected: no new errors.

- [ ] **Step 5: Commit**

```bash
git add lib/screens/conversation_chat_screen.dart
git commit -m "feat: skills button — warning badge and default-off when local model active"
```

---

### Task 3: Tag Management Screen — Workflow Tab Warning Badge

The "Workflows" tab in `tag_management_screen.dart` (line 221) needs an amber badge when `supportsToolOrchestration == false`. `AppProvider` is already imported in this file.

**Files:**
- Modify: `lib/screens/tag_management_screen.dart`

- [ ] **Step 1: Replace the static Workflows tab with a model-aware version**

Find line ~221:

```dart
const Tab(text: 'Workflows'),
```

Replace with:

```dart
Builder(
  builder: (ctx) {
    final supportsOrchestration = ctx
            .watch<AppProvider>()
            .modelConfig
            ?.customCapabilitiesObject
            ?.supportsToolOrchestration ??
        true;
    return Tab(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Text('Workflows'),
          if (!supportsOrchestration)
            Positioned(
              right: -10,
              top: -4,
              child: Icon(
                Icons.warning_amber_rounded,
                size: 10,
                color: Colors.amber.shade700,
              ),
            ),
        ],
      ),
    );
  },
),
```

The `Builder` creates a fresh context that can `watch<AppProvider>()` reactively — the badge will appear/disappear when the user switches models.

- [ ] **Step 2: Analyze**

```bash
flutter analyze
```

Expected: no new errors.

- [ ] **Step 3: Commit**

```bash
git add lib/screens/tag_management_screen.dart
git commit -m "feat: add warning badge to tag workflows tab when local model active"
```

---

### Task 4: Local Model Workflow Warning Dialog + Localization

Create the approval dialog widget and add the three new localization strings. The `LocalModelWorkflowApproval` enum is defined here since both `ContentIngestionService` (logic) and `WorkflowShell` (UI handler) need it.

**Files:**
- Create: `lib/widgets/local_model_workflow_warning_dialog.dart`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_zh.arb`

- [ ] **Step 1: Add localization strings to `app_en.arb`**

Insert after `"toolOrchestrationSwitchModel": "Switch Model",` (line ~1814):

```json
  "localModelWorkflowWarningTitle": "Local Model Performance Warning",
  "localModelWorkflowWarningBody": "This model may not deliver the best experience with tag workflows.",
  "localModelWorkflowWarningContinueNoWarn": "Continue, Don''t Warn This Session",
```

Note: ARB files use `''` for a literal single quote inside a string.

- [ ] **Step 2: Add localization strings to `app_zh.arb`**

Insert after `"toolOrchestrationSwitchModel": "切换模型",` (line ~1752):

```json
  "localModelWorkflowWarningTitle": "本地模型性能警告",
  "localModelWorkflowWarningBody": "此模型在标签工作流中可能无法提供最佳体验。",
  "localModelWorkflowWarningContinueNoWarn": "继续且本次会话不再提示",
```

- [ ] **Step 3: Regenerate localization**

```bash
flutter gen-l10n
```

Expected: `lib/l10n/app_localizations.dart` updated with the three new getters.

- [ ] **Step 4: Create the dialog widget**

Create `lib/widgets/local_model_workflow_warning_dialog.dart`:

```dart
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Result of the local model workflow warning dialog.
enum LocalModelWorkflowApproval {
  /// Proceed; show warning again next time.
  proceed,
  /// Proceed and suppress this dialog for the rest of the app session.
  proceedAndSuppress,
  /// Do not run the workflow.
  cancel,
}

/// Dialog shown before a tag workflow runs when the active model has
/// [ModelCapabilities.supportsToolOrchestration] == false.
///
/// Three actions:
/// - Continue: proceed, warn again next time
/// - Continue, Don't Warn This Session: proceed, suppress dialog for session
/// - Cancel: skip this workflow
class LocalModelWorkflowWarningDialog extends StatelessWidget {
  const LocalModelWorkflowWarningDialog({super.key});

  /// Show the dialog and return the user's decision.
  static Future<LocalModelWorkflowApproval?> show(BuildContext context) {
    return showDialog<LocalModelWorkflowApproval>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const LocalModelWorkflowWarningDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      icon: Icon(
        Icons.warning_amber_rounded,
        color: Colors.amber.shade700,
        size: 32,
      ),
      title: Text(l10n.localModelWorkflowWarningTitle),
      content: Text(l10n.localModelWorkflowWarningBody),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, LocalModelWorkflowApproval.cancel),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            LocalModelWorkflowApproval.proceedAndSuppress,
          ),
          child: Text(l10n.localModelWorkflowWarningContinueNoWarn),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.amber.shade700,
            foregroundColor: Colors.white,
          ),
          onPressed: () =>
              Navigator.pop(context, LocalModelWorkflowApproval.proceed),
          child: Text(l10n.toolOrchestrationContinue),
        ),
      ],
    );
  }
}
```

- [ ] **Step 5: Analyze**

```bash
flutter analyze
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/local_model_workflow_warning_dialog.dart \
        lib/l10n/app_en.arb \
        lib/l10n/app_zh.arb \
        lib/l10n/app_localizations.dart \
        lib/l10n/app_localizations_en.dart \
        lib/l10n/app_localizations_zh.dart
git commit -m "feat: add local model workflow warning dialog and localization strings"
```

---

### Task 5: Wire Approval Callback in `ContentIngestionService` and `WorkflowShell`

Mirror the existing `ApprovalService.fallbackApprovalRequest` pattern: `ContentIngestionService` exposes a static callback that `WorkflowShell` registers. `processNote()` calls it before each `runWorkflowTask()` when the model doesn't support orchestration.

**Files:**
- Modify: `lib/services/content_ingestion_service.dart`
- Modify: `lib/widgets/workflow_shell.dart`
- Create: `test/content_ingestion_approval_test.dart`

- [ ] **Step 1: Write failing tests**

Create `test/content_ingestion_approval_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/model_capabilities.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/workflow_binding_row.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/content_ingestion_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';
import 'package:note_synapse/widgets/local_model_workflow_warning_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'content_ingestion_approval_test.mocks.dart';

@GenerateMocks([DatabaseService, AgentService, TagWorkflowService, AppProvider])
void main() {
  late MockDatabaseService mockDb;
  late MockAgentService mockAgentService;
  late MockTagWorkflowService mockTagWorkflowService;
  late MockAppProvider mockAppProvider;
  late ContentIngestionService service;

  final testNote = Note(
    id: 1, uuid: 'note-1', title: 'Test', content: '',
    tags: ['wiki-tag'], createdAt: DateTime.now(), updatedAt: DateTime.now(),
  );

  final testBinding = ResolvedBinding(
    skillNoteId: 'skill-1',
    matchedTag: 'wiki-tag',
    pattern: 'wiki-tag',
    prompt: 'Process.',
    contentImmutable: false,
  );

  ModelConfig localModelConfig({bool supportsOrchestration = false}) =>
      ModelConfig(
        id: 'local',
        type: ModelType.localMnn,
        modelName: 'gemma4_e2b',
        isConfigured: true,
        customCapabilitiesObject: ModelCapabilities(
          supportsToolOrchestration: supportsOrchestration,
        ),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetForTesting();

    mockDb = MockDatabaseService();
    mockAgentService = MockAgentService();
    mockTagWorkflowService = MockTagWorkflowService();
    mockAppProvider = MockAppProvider();

    getIt.registerLazySingleton<AgentService>(() => mockAgentService);
    getIt.registerLazySingleton<TagWorkflowService>(() => mockTagWorkflowService);

    service = ContentIngestionService(mockDb);
    ContentIngestionService.onLocalModelApprovalRequired = null;

    when(mockTagWorkflowService.resolveBindings(any))
        .thenAnswer((_) async => [testBinding]);
    when(mockAgentService.runWorkflowTask(
      binding: anyNamed('binding'),
      note: anyNamed('note'),
    )).thenAnswer((_) async {});
    when(mockAppProvider.modelConfig)
        .thenReturn(localModelConfig(supportsOrchestration: false));
    // Stub remaining processNote paths used below the workflow section
    when(mockDb.getAllTags()).thenAnswer((_) async => []);
  });

  tearDown(() {
    ContentIngestionService.onLocalModelApprovalRequired = null;
  });

  group('processNote approval callback', () {
    test('calls callback before running workflow when orchestration unsupported',
        () async {
      var callbackCalled = false;
      ContentIngestionService.onLocalModelApprovalRequired = () async {
        callbackCalled = true;
        return LocalModelWorkflowApproval.proceed;
      };

      await service.processNote(testNote, mockAppProvider);

      expect(callbackCalled, isTrue);
      verify(mockAgentService.runWorkflowTask(
        binding: anyNamed('binding'),
        note: anyNamed('note'),
      )).called(1);
    });

    test('skips workflow when callback returns cancel', () async {
      ContentIngestionService.onLocalModelApprovalRequired =
          () async => LocalModelWorkflowApproval.cancel;

      await service.processNote(testNote, mockAppProvider);

      verifyNever(mockAgentService.runWorkflowTask(
        binding: anyNamed('binding'),
        note: anyNamed('note'),
      ));
    });

    test('runs workflow and suppresses subsequent dialogs on proceedAndSuppress',
        () async {
      // Two bindings so we can check the second one skips the dialog
      when(mockTagWorkflowService.resolveBindings(any))
          .thenAnswer((_) async => [testBinding, testBinding]);

      var callCount = 0;
      ContentIngestionService.onLocalModelApprovalRequired = () async {
        callCount++;
        return LocalModelWorkflowApproval.proceedAndSuppress;
      };

      await service.processNote(testNote, mockAppProvider);

      expect(callCount, 1); // Dialog shown once; second binding skipped it
      verify(mockAgentService.runWorkflowTask(
        binding: anyNamed('binding'),
        note: anyNamed('note'),
      )).called(2); // Both workflows ran
    });

    test('does not call callback when orchestration is supported', () async {
      when(mockAppProvider.modelConfig)
          .thenReturn(localModelConfig(supportsOrchestration: true));

      var callbackCalled = false;
      ContentIngestionService.onLocalModelApprovalRequired = () async {
        callbackCalled = true;
        return LocalModelWorkflowApproval.proceed;
      };

      await service.processNote(testNote, mockAppProvider);

      expect(callbackCalled, isFalse);
      verify(mockAgentService.runWorkflowTask(
        binding: anyNamed('binding'),
        note: anyNamed('note'),
      )).called(1);
    });

    test('does not call callback when no workflow bindings match', () async {
      when(mockTagWorkflowService.resolveBindings(any))
          .thenAnswer((_) async => []);

      var callbackCalled = false;
      ContentIngestionService.onLocalModelApprovalRequired =
          () async { callbackCalled = true; return LocalModelWorkflowApproval.proceed; };

      await service.processNote(testNote, mockAppProvider);

      expect(callbackCalled, isFalse);
    });
  });
}
```

- [ ] **Step 2: Generate mocks**

```bash
dart run build_runner build --delete-conflicting-outputs
```

Expected: `test/content_ingestion_approval_test.mocks.dart` created.

- [ ] **Step 3: Run tests to verify they fail**

```bash
flutter test test/content_ingestion_approval_test.dart
```

Expected: compile or runtime errors — `onLocalModelApprovalRequired` not defined.

- [ ] **Step 4: Update `ContentIngestionService`**

Add the import at the top of `lib/services/content_ingestion_service.dart`:

```dart
import '../widgets/local_model_workflow_warning_dialog.dart';
```

Add these two declarations inside `class ContentIngestionService`:

```dart
/// Registered by [WorkflowShell] to show the local model warning dialog.
/// Mirrors the [ApprovalService.fallbackApprovalRequest] pattern.
/// Returns null (treated as [LocalModelWorkflowApproval.cancel]) when unset.
static Future<LocalModelWorkflowApproval> Function()? onLocalModelApprovalRequired;

/// Session flag — set to true when user picks "don't warn this session".
/// Resets when a new [ContentIngestionService] instance is created (app restart).
bool _suppressLocalModelWarning = false;
```

Replace the workflow execution block in `processNote` (~lines 48–53):

```dart
// BEFORE:
if (workflowBindings.isNotEmpty) {
  for (final binding in workflowBindings) {
    onMessage?.call('Starting workflow for tag "${binding.matchedTag}"...');
    await agentService.runWorkflowTask(binding: binding, note: note);
  }
}

// AFTER:
if (workflowBindings.isNotEmpty) {
  final supportsOrchestration = appProvider.modelConfig
          ?.customCapabilitiesObject?.supportsToolOrchestration ??
      true;
  for (final binding in workflowBindings) {
    if (!supportsOrchestration &&
        !_suppressLocalModelWarning &&
        onLocalModelApprovalRequired != null) {
      final approval = await onLocalModelApprovalRequired!();
      if (approval == LocalModelWorkflowApproval.proceedAndSuppress) {
        _suppressLocalModelWarning = true;
      } else if (approval == LocalModelWorkflowApproval.cancel) {
        continue;
      }
      // LocalModelWorkflowApproval.proceed falls through.
    }
    onMessage?.call('Starting workflow for tag "${binding.matchedTag}"...');
    await agentService.runWorkflowTask(binding: binding, note: note);
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
flutter test test/content_ingestion_approval_test.dart
```

Expected: all 5 tests pass.

- [ ] **Step 6: Register callback in `WorkflowShell`**

Add imports to `lib/widgets/workflow_shell.dart`:

```dart
import '../services/content_ingestion_service.dart';
import '../widgets/local_model_workflow_warning_dialog.dart';
import '../utils/global_keys.dart'; // already imported
```

In `_WorkflowShellState.initState()`, after the existing `ApprovalService` line:

```dart
@override
void initState() {
  super.initState();
  ApprovalService.fallbackApprovalRequest = _showApprovalDialog;
  ContentIngestionService.onLocalModelApprovalRequired = _showLocalModelWorkflowDialog; // ← add
  _agentService.addListener(_onAgentStateChanged);
}
```

In `dispose()`, after the existing `ApprovalService` block:

```dart
@override
void dispose() {
  if (identical(
    ApprovalService.fallbackApprovalRequest,
    _showApprovalDialog,
  )) {
    ApprovalService.fallbackApprovalRequest = null;
  }
  // ↓ add
  if (identical(
    ContentIngestionService.onLocalModelApprovalRequired,
    _showLocalModelWorkflowDialog,
  )) {
    ContentIngestionService.onLocalModelApprovalRequired = null;
  }
  _agentService.removeListener(_onAgentStateChanged);
  super.dispose();
}
```

Add the handler method to `_WorkflowShellState`:

```dart
Future<LocalModelWorkflowApproval> _showLocalModelWorkflowDialog() async {
  if (!mounted) return LocalModelWorkflowApproval.cancel;
  final context = navigatorKey.currentContext;
  if (context == null) return LocalModelWorkflowApproval.cancel;
  final result = await LocalModelWorkflowWarningDialog.show(context);
  return result ?? LocalModelWorkflowApproval.cancel;
}
```

- [ ] **Step 7: Run all tests**

```bash
flutter test
```

Expected: all tests pass, no regressions.

- [ ] **Step 8: Analyze**

```bash
flutter analyze
```

Expected: no errors.

- [ ] **Step 9: Commit**

```bash
git add lib/services/content_ingestion_service.dart \
        lib/widgets/workflow_shell.dart \
        test/content_ingestion_approval_test.dart \
        test/content_ingestion_approval_test.mocks.dart
git commit -m "feat: wire approval dialog for tag workflows when local model active"
```

---

## Spec Coverage Check

| Spec requirement | Task |
|---|---|
| `supportsToolOrchestration = false` on Gemma preset | Task 1 |
| MCP tool badges/dialog re-enabled (existing system) | Task 1 (free — existing code reacts to flag) |
| Skills button warning badge | Task 2 |
| Skills default-off for local models | Task 2 |
| Tag workflow Workflows tab badge | Task 3 |
| Approval dialog widget + 3-button actions | Task 4 |
| Session suppression flag | Task 5 |
| WorkflowShell registers/unregisters callback | Task 5 |
| `ContentIngestionService` calls callback before `runWorkflowTask` | Task 5 |
| Localization (EN + ZH) | Task 4 |
