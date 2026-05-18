# Marker-Anchored Conversation Subtree Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the substrate that lets a marker anchor a branching conversation exploration the reader can re-enter weeks later, navigate inline via per-message branch strips, and grow via AI-emitted action chips that fork on tap.

**Architecture:** Service-layer changes first (ForkService unification + cache stream, SkillService default_action parsing, ConversationService branch queries, InNoteMarker.lastViewedConversationId). Then standalone widgets (chip footer, chip preview, branch strip). Then a narrowly-scoped ChatPanel widget extracted from conversation_chat_screen's message list. Then host integration in immersive_note_screen and in_note_marker_preview. The marker preview branches on `marker.type` so scratchpad annotations preserve the existing render. No new database tables; all additions live in JSON metadata columns or are derived at render time.

**Tech Stack:** Flutter, Dart, sqflite, GetIt + Provider state management, mockito for tests, gpt_markdown for message rendering, build_runner for code generation.

**Spec:** `/Users/liwen/develop/projects/Note-Synapse/.worktrees/agent_skills/.claude/plans/2026-04-28-marker-anchored-subtree-design.md`

---

## File Map

**New files:**
- `lib/models/chip_action.dart` — `ChipAction(label, prompt)` value class
- `lib/models/conversation_branch_summary.dart` — branch-strip data class
- `lib/services/chips_block_parser.dart` — parser for the ` ```chips ` fenced block
- `lib/services/chip_tap_handler.dart` — fork + addUserMessage + onSendUserPrompt orchestrator
- `lib/widgets/chat_panel.dart` — extracted message list widget
- `lib/widgets/message_branch_strip.dart` — inline per-message branch strip
- `lib/widgets/chips_footer.dart` — chip footer (skeleton + chips)
- `lib/widgets/chip_preview_popover.dart` — hover/long-press full-prompt preview
- `lib/widgets/marker_chat_panel_host.dart` — marker-sheet ChatPanel wrapper (text input + model picker + send button + ChatPanel)
- `lib/widgets/marker_orphan_state.dart` — empty state for orphaned markers (anchor or conversation deleted)

**New tests:**
- `test/models/chip_action_test.dart`
- `test/services/chips_block_parser_test.dart`
- `test/services/chip_tap_handler_test.dart`
- `test/services/fork_service_test.dart` — extend with new method + stream
- `test/services/skill_service_default_action_test.dart`
- `test/services/conversation_service_branches_test.dart`
- `test/models/in_note_marker_test.dart` — extend for `lastViewedConversationId`
- `test/widgets/chat_panel_test.dart`
- `test/widgets/message_branch_strip_test.dart`
- `test/widgets/chips_footer_test.dart`
- `test/widgets/chip_preview_popover_test.dart`
- `test/widgets/marker_chat_panel_host_test.dart`

**Modified files:**
- `lib/services/fork_service.dart` — add `forkFromMessageInContext` + `forkCreatedStream`; existing methods delegate
- `lib/services/conversation_service.dart` — add `getChildBranches` + `getAllForkPointBranches` + `ConversationBranchSummary`
- `lib/services/skill_service.dart` — add `defaultAction` to `SkillMetadata`; parse field; add `buildDefaultActionPromptSection`
- `lib/models/in_note_marker.dart` — add `lastViewedConversationId` field
- `lib/widgets/block_markdown_body.dart` — detect/strip ` ```chips ` fenced blocks before render; expose extracted `List<ChipAction>` via callback
- `lib/widgets/in_note_marker_preview.dart` — branch on `marker.type`; embed ChatPanel for AI markers
- `lib/screens/immersive_note_screen.dart` — host ChatPanel in chat slot; expose `_isSending` as `isStreaming`; provide `onSendUserPrompt` adapter
- `lib/screens/conversation_chat_screen.dart` — `_forkConversation` routes through `ForkService.forkFromMessageInContext` (not direct)
- All 3 callers of `buildSkillIndexPrompt` (chat-screen + agent_service x2) — also append `buildDefaultActionPromptSection`

---

## Phase 0: Spike (Manual Verification)

### Task 0: Spike — gesture mediation for inline branch strip

**Goal:** Verify the branch-strip in-row tap can coexist with existing chat-list scroll/long-press gestures. If irreparable conflict, fall back to chevron-icon popover (plan B in spec Section 1).

**Files:**
- Read: `lib/screens/conversation_chat_screen.dart` (message-card render path, `GestureDetector`/`InkWell` usage around messages)
- Read: `lib/screens/immersive_note_screen.dart` (chat-slot equivalent)

**Steps:**

- [ ] **Step 1: Audit existing message-row gestures**

  Search for `onLongPress`, `onTap`, `GestureDetector`, `InkWell` within message rendering in both screens. Identify any conflicting handlers that fire on row-area taps.

  Run:
  ```bash
  grep -n "onLongPress\|onTap\|GestureDetector\|InkWell" lib/screens/conversation_chat_screen.dart | head -30
  grep -n "onLongPress\|onTap\|GestureDetector\|InkWell" lib/screens/immersive_note_screen.dart | head -30
  ```

- [ ] **Step 2: Decision — primary or fallback path**

  Document one of:
  - **Primary path viable**: branch-strip rows below the message card use their own `InkWell`; no conflict with message-area taps. Proceed with full-row tappable strip in Task 14.
  - **Fallback required**: row taps conflict (e.g., a row-wide `GestureDetector` on the message card swallows footer taps). Switch Task 14 design to chevron-icon popover (small caret at message footer; tap opens dropdown of branches). Add 1 day to Task 14 budget.

  Write the decision into `.claude/plans/2026-04-29-spike-gesture-decision.md` with the evidence.

- [ ] **Step 3: Commit the decision artifact**

  ```bash
  git add .claude/plans/2026-04-29-spike-gesture-decision.md
  git commit -m "spike: gesture mediation decision for branch strip"
  ```

---

## Phase 1: Service-Layer Foundation

### Task 1: Add `forkCreatedStream` and `forkFromMessageInContext` to ForkService

**Files:**
- Modify: `lib/services/fork_service.dart`
- Test: `test/services/fork_service_test.dart`

- [ ] **Step 1: Write the failing test for forkCreatedStream emission**

  Create or extend `test/services/fork_service_test.dart`:

  ```dart
  import 'package:flutter_test/flutter_test.dart';
  import 'package:mockito/annotations.dart';
  import 'package:mockito/mockito.dart';
  import 'package:note_synapse/models/conversation.dart';
  import 'package:note_synapse/models/conversation_context.dart';
  import 'package:note_synapse/services/conversation_service.dart';
  import 'package:note_synapse/services/fork_service.dart';
  import 'package:note_synapse/services/service_locator.dart';
  import 'fork_service_test.mocks.dart';

  @GenerateMocks([ConversationService])
  void main() {
    late MockConversationService mockConv;

    setUp(() async {
      await resetForTesting();
      mockConv = MockConversationService();
      getIt.registerSingleton<ConversationService>(mockConv);
    });

    test('forkFromMessageInContext emits parentMessageId on forkCreatedStream', () async {
      final fakeForked = Conversation(id: 'forked-id', title: 'Fork', noteIds: []);
      final fakeContext = ConversationContext(
        conversationId: 'src-conv',
        title: 'Source',
        forkMessageId: 'parent-msg',
      );
      when(mockConv.getConversationsContainingMessage('parent-msg'))
          .thenAnswer((_) async => ['src-conv']);
      when(mockConv.forkConversationWithContext(
        forkFromMessageId: anyNamed('forkFromMessageId'),
        selectedContext: anyNamed('selectedContext'),
        newTitle: anyNamed('newTitle'),
      )).thenAnswer((_) async => fakeForked);

      final service = ForkService();
      final emissions = <String>[];
      final sub = service.forkCreatedStream.listen(emissions.add);

      final result = await service.forkFromMessageInContext(
        forkFromMessageId: 'parent-msg',
        sourceConversationId: 'src-conv',
        suggestedTitle: 'My new branch',
      );

      // Allow stream to deliver
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(result, isNotNull);
      expect(result!.id, 'forked-id');
      expect(emissions, ['parent-msg']);
    });
  }
  ```

- [ ] **Step 2: Run mock generation**

  ```bash
  dart run build_runner build --delete-conflicting-outputs
  ```

  Expected: generates `test/services/fork_service_test.mocks.dart`.

- [ ] **Step 3: Run the test — confirm it fails**

  ```bash
  flutter test test/services/fork_service_test.dart
  ```

  Expected: compile error or test failure — `forkFromMessageInContext` and `forkCreatedStream` don't exist yet.

- [ ] **Step 4: Implement `forkCreatedStream` and `forkFromMessageInContext`**

  Edit `lib/services/fork_service.dart`. Add inside the class:

  ```dart
  // Inside ForkService class, after existing fields:

  final _forkCreatedController = StreamController<String>.broadcast();

  /// Emits the parent message ID of every fork created via this service.
  /// Subscribers (typically ChatPanel widgets) use this to invalidate
  /// their branch-summary caches when a sibling appears.
  Stream<String> get forkCreatedStream => _forkCreatedController.stream;

  /// Forks from a message when the source conversation is already known
  /// (chip taps, chat-screen direct fork, programmatic callers). Skips
  /// the context-selection dialog. Does NOT require BuildContext.
  ///
  /// Returns null if the source conversation does not contain the
  /// fork message; throws on unexpected failure.
  Future<Conversation?> forkFromMessageInContext({
    required String forkFromMessageId,
    required String sourceConversationId,
    required String suggestedTitle,
  }) async {
    try {
      final selection = await _conversationService
          .prepareForkContextSelection(forkFromMessageId);
      ConversationContext? matched;
      for (final ctx in selection.availableContexts) {
        if (ctx.conversationId == sourceConversationId) {
          matched = ctx;
          break;
        }
      }
      if (matched == null) {
        LoggerService.warn(
          'forkFromMessageInContext: source $sourceConversationId does not contain message $forkFromMessageId',
        );
        return null;
      }

      final result = await _conversationService.forkConversationWithContext(
        forkFromMessageId: forkFromMessageId,
        selectedContext: matched,
        newTitle: suggestedTitle,
      );

      _forkCreatedController.add(forkFromMessageId);
      return result;
    } catch (e) {
      LoggerService.error('forkFromMessageInContext failed: $e', error: e);
      rethrow;
    }
  }
  ```

  Add the import at the top:

  ```dart
  import 'dart:async';
  ```

- [ ] **Step 5: Run the test — confirm it passes**

  ```bash
  flutter test test/services/fork_service_test.dart
  ```

  Expected: PASS.

- [ ] **Step 6: Commit**

  ```bash
  git add lib/services/fork_service.dart test/services/fork_service_test.dart test/services/fork_service_test.mocks.dart
  git commit -m "feat(fork): add forkFromMessageInContext + forkCreatedStream"
  ```

---

### Task 2: Refactor existing `forkFromMessage` and `quickFork` to delegate through `forkFromMessageInContext`

**Goal:** Single underlying code path. Both existing methods should call `forkFromMessageInContext` once they've determined the source conversation.

**Files:**
- Modify: `lib/services/fork_service.dart`
- Test: `test/services/fork_service_test.dart`

- [ ] **Step 1: Write the failing test for delegation**

  Append to `test/services/fork_service_test.dart`:

  ```dart
  test('quickFork delegates through forkFromMessageInContext (stream emits)', () async {
    final fakeForked = Conversation(id: 'forked-id', title: 'Q', noteIds: []);
    final fakeCtx = ConversationContext(
      conversationId: 'only-conv',
      title: 'Only',
      forkMessageId: 'parent-msg',
    );
    final selection = ForkContextSelection(
      forkMessageId: 'parent-msg',
      availableContexts: [fakeCtx],
      requiresUserSelection: false,
      selectedContext: fakeCtx,
    );
    when(mockConv.prepareForkContextSelection('parent-msg'))
        .thenAnswer((_) async => selection);
    when(mockConv.forkConversationWithContext(
      forkFromMessageId: anyNamed('forkFromMessageId'),
      selectedContext: anyNamed('selectedContext'),
      newTitle: anyNamed('newTitle'),
    )).thenAnswer((_) async => fakeForked);

    final service = ForkService();
    final emissions = <String>[];
    final sub = service.forkCreatedStream.listen(emissions.add);

    final result = await service.quickFork(
      forkFromMessageId: 'parent-msg',
      newTitle: 'Quick',
    );

    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(result, isNotNull);
    expect(emissions, ['parent-msg']);
  });
  ```

- [ ] **Step 2: Run the test — confirm it fails**

  ```bash
  flutter test test/services/fork_service_test.dart
  ```

  Expected: FAIL — `quickFork` currently calls `forkConversationWithContext` directly without firing the stream.

- [ ] **Step 3: Refactor `quickFork` to delegate**

  In `lib/services/fork_service.dart`, replace the body of `quickFork`:

  ```dart
  Future<Conversation?> quickFork({
    required String forkFromMessageId,
    required String newTitle,
  }) async {
    try {
      final selection = await _conversationService
          .prepareForkContextSelection(forkFromMessageId);

      if (selection.availableContexts.isEmpty) {
        throw Exception('No conversations found containing this message');
      }

      if (selection.requiresUserSelection) {
        throw Exception(
          'Context selection required - use forkFromMessage with BuildContext',
        );
      }

      return await forkFromMessageInContext(
        forkFromMessageId: forkFromMessageId,
        sourceConversationId: selection.availableContexts.first.conversationId,
        suggestedTitle: newTitle,
      );
    } catch (e) {
      LoggerService.error('Error during quick fork: $e', error: e);
      return null;
    }
  }
  ```

- [ ] **Step 4: Refactor `forkFromMessage` (no-conflict path) and the dialog-confirmation path to delegate**

  In the existing `forkFromMessage` body, replace both `_conversationService.forkConversationWithContext(...)` calls with `forkFromMessageInContext(forkFromMessageId: ..., sourceConversationId: context.conversationId, suggestedTitle: ...)`. Same pattern in `_showContextSelectionDialog` for the post-dialog path.

  Concretely, replace:

  ```dart
  // OLD
  return await _conversationService.forkConversationWithContext(
    forkFromMessageId: forkFromMessageId,
    selectedContext: context,
    newTitle: suggestedTitle ?? 'Fork from ${context.title}',
  );
  ```

  with:

  ```dart
  // NEW
  return await forkFromMessageInContext(
    forkFromMessageId: forkFromMessageId,
    sourceConversationId: context.conversationId,
    suggestedTitle: suggestedTitle ?? 'Fork from ${context.title}',
  );
  ```

  Same shape replacement inside `_showContextSelectionDialog`.

- [ ] **Step 5: Run all fork-service tests — confirm pass**

  ```bash
  flutter test test/services/fork_service_test.dart
  ```

  Expected: PASS, all tests including the new delegation test.

- [ ] **Step 6: Commit**

  ```bash
  git add lib/services/fork_service.dart test/services/fork_service_test.dart
  git commit -m "refactor(fork): unify forkFromMessage and quickFork through forkFromMessageInContext"
  ```

---

### Task 3: Refactor chat-screen direct fork call to use ForkService

**Goal:** Eliminate the only remaining direct caller of `ConversationService.forkConversation`. After this, every fork goes through `ForkService.forkFromMessageInContext` and `forkCreatedStream` fires for every fork.

**Files:**
- Modify: `lib/screens/conversation_chat_screen.dart` (around line 2631)
- No new tests (existing chat tests must continue to pass)

- [ ] **Step 1: Run existing chat-screen tests as a baseline**

  ```bash
  flutter test test/conversation_chat_screen_test.dart 2>/dev/null || flutter test test/ -name "*chat*"
  ```

  Note current pass/fail state. Save output to scratch for reference.

- [ ] **Step 2: Edit `_forkConversation` to use ForkService**

  In `lib/screens/conversation_chat_screen.dart`, locate `_forkConversation` (line ~2605). Inside the `if (result == true)` block, replace:

  ```dart
  final forkedConversation = await _conversationService.forkConversation(
    originalConversationId: _conversation!.id,
    forkFromMessageId: messageId,
    newTitle: 'Forked conversation',
  );
  ```

  with:

  ```dart
  final forkedConversation = await ForkService().forkFromMessageInContext(
    forkFromMessageId: messageId,
    sourceConversationId: _conversation!.id,
    suggestedTitle: 'Forked conversation',
  );
  if (forkedConversation == null) {
    if (mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to fork: source conversation not found')),
      );
    }
    return;
  }
  ```

  Add the import at the top of the file if not present:

  ```dart
  import '../services/fork_service.dart';
  ```

- [ ] **Step 3: Re-run chat-screen tests — confirm same pass state**

  ```bash
  flutter test test/conversation_chat_screen_test.dart 2>/dev/null || flutter test test/ -name "*chat*"
  ```

  Expected: same pass count as Step 1 baseline.

- [ ] **Step 4: Commit**

  ```bash
  git add lib/screens/conversation_chat_screen.dart
  git commit -m "refactor(chat): route _forkConversation through ForkService.forkFromMessageInContext"
  ```

---

### Task 4: Add `lastViewedConversationId` to InNoteMarker

**Files:**
- Modify: `lib/models/in_note_marker.dart`
- Test: `test/models/in_note_marker_test.dart`

- [ ] **Step 1: Write the failing test**

  Create `test/models/in_note_marker_test.dart`:

  ```dart
  import 'package:flutter_test/flutter_test.dart';
  import 'package:note_synapse/models/in_note_marker.dart';

  void main() {
    group('InNoteMarker JSON with lastViewedConversationId', () {
      test('toJson includes lastViewedConversationId when set', () {
        final m = InNoteMarker.forNote(
          index: 0,
          charStart: 10,
          charEnd: 20,
          conversationId: 'conv-orig',
          messageId: 'msg-1',
          lastViewedConversationId: 'conv-branch-A',
        );
        final json = m.toJson();
        expect(json['lastViewedConversationId'], 'conv-branch-A');
      });

      test('toJson omits lastViewedConversationId when null', () {
        final m = InNoteMarker.forNote(
          index: 0,
          charStart: 0,
          charEnd: 5,
          conversationId: 'conv',
          messageId: 'msg',
        );
        final json = m.toJson();
        expect(json.containsKey('lastViewedConversationId'), isFalse);
      });

      test('fromJson defaults lastViewedConversationId to null when absent (pre-v1 markers)', () {
        final preV1Json = {
          'id': 'marker-1',
          'index': 0,
          'conversationId': 'conv',
          'messageId': 'msg',
          'createdAt': DateTime.now().toIso8601String(),
        };
        final m = InNoteMarker.fromJson(preV1Json);
        expect(m.lastViewedConversationId, isNull);
      });

      test('fromJson reads lastViewedConversationId when present', () {
        final json = {
          'id': 'marker-1',
          'index': 0,
          'conversationId': 'conv',
          'messageId': 'msg',
          'createdAt': DateTime.now().toIso8601String(),
          'lastViewedConversationId': 'conv-branch-X',
        };
        final m = InNoteMarker.fromJson(json);
        expect(m.lastViewedConversationId, 'conv-branch-X');
      });
    });
  }
  ```

- [ ] **Step 2: Run the test — confirm it fails**

  ```bash
  flutter test test/models/in_note_marker_test.dart
  ```

  Expected: compile error — `lastViewedConversationId` parameter unknown.

- [ ] **Step 3: Add the field to InNoteMarker**

  In `lib/models/in_note_marker.dart`, add the field to the class, factories, fromJson, and toJson. Specifically:

  - Add to constructor:

    ```dart
    final String? lastViewedConversationId;
    ```

  - Update the const constructor:

    ```dart
    const InNoteMarker({
      required this.id,
      required this.index,
      required this.conversationId,
      required this.messageId,
      required this.createdAt,
      this.type = MarkerType.ai,
      this.page,
      this.normalizedRect,
      this.normalizedRects,
      this.charStart,
      this.charEnd,
      this.lastViewedConversationId,
    });
    ```

  - Add `String? lastViewedConversationId` to both `forAttachment` and `forNote` factory parameters and pass through to the constructor.

  - In `fromJson`:

    ```dart
    lastViewedConversationId: json['lastViewedConversationId'] as String?,
    ```

  - In `toJson`:

    ```dart
    if (lastViewedConversationId != null)
      'lastViewedConversationId': lastViewedConversationId,
    ```

- [ ] **Step 4: Run the test — confirm it passes**

  ```bash
  flutter test test/models/in_note_marker_test.dart
  ```

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add lib/models/in_note_marker.dart test/models/in_note_marker_test.dart
  git commit -m "feat(marker): add lastViewedConversationId field for marker re-entry"
  ```

---

### Task 5: Add `defaultAction` to SkillMetadata

**Files:**
- Modify: `lib/services/skill_service.dart`
- Test: `test/services/skill_service_default_action_test.dart`

- [ ] **Step 1: Write the failing test**

  Create `test/services/skill_service_default_action_test.dart`:

  ```dart
  import 'package:flutter_test/flutter_test.dart';
  import 'package:mockito/mockito.dart';
  import 'package:note_synapse/services/database_service.dart';
  import 'package:note_synapse/services/skill_service.dart';

  class _StubDb extends Mock implements DatabaseService {}

  void main() {
    final svc = SkillService(_StubDb());

    test('parses default_action when present', () {
      const content = '''---
  name: Knowledge Learning
  description: Explain concepts on tap
  default_action: |
    After your reply, propose up to 5 follow-up explorations.
    Format as fenced chips block.
  ---
  body text here
  ''';
      final meta = svc.parseSkillMetadata('note-1', content);
      expect(meta, isNotNull);
      expect(meta!.defaultAction, isNotNull);
      expect(meta.defaultAction, contains('propose up to 5 follow-up'));
    });

    test('defaultAction is null when frontmatter omits the field', () {
      const content = '''---
  name: Plain Skill
  description: No default action
  ---
  ''';
      final meta = svc.parseSkillMetadata('note-2', content);
      expect(meta, isNotNull);
      expect(meta!.defaultAction, isNull);
    });

    test('parses default_action as plain (non-block) string', () {
      const content = '''---
  name: Quick Skill
  description: Test
  default_action: After your reply emit chips
  ---
  ''';
      final meta = svc.parseSkillMetadata('note-3', content);
      expect(meta!.defaultAction, 'After your reply emit chips');
    });
  }
  ```

- [ ] **Step 2: Run the test — confirm it fails**

  ```bash
  flutter test test/services/skill_service_default_action_test.dart
  ```

  Expected: compile error — `defaultAction` field doesn't exist on `SkillMetadata`.

- [ ] **Step 3: Add `defaultAction` to SkillMetadata and parse multi-line YAML scalar**

  In `lib/services/skill_service.dart`:

  3a. Add `defaultAction` to `SkillMetadata`:

  ```dart
  class SkillMetadata {
    final String noteId;
    final String skillRef;
    final String name;
    final String description;
    final bool enabled;
    final int? minContext;
    final String? defaultAction;

    const SkillMetadata({
      required this.noteId,
      required this.skillRef,
      required this.name,
      required this.description,
      required this.enabled,
      this.minContext,
      this.defaultAction,
    });
  }
  ```

  3b. Replace `parseSkillMetadata` body to support `|` block scalars (current line-by-line parser doesn't):

  ```dart
  SkillMetadata? parseSkillMetadata(String noteId, String content) {
    if (!content.startsWith('---\n')) return null;
    final endIdx = content.indexOf('\n---\n', 4);
    if (endIdx == -1) return null;
    final frontmatter = content.substring(4, endIdx);
    final fields = <String, String>{};
    final lines = frontmatter.split('\n');
    int i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final colonIdx = line.indexOf(':');
      if (colonIdx == -1) {
        i++;
        continue;
      }
      final key = line.substring(0, colonIdx).trim();
      final rawValue = line.substring(colonIdx + 1).trim();
      if (key.isEmpty) {
        i++;
        continue;
      }
      // Block scalar (`key: |` or `key: >`) → consume indented continuation lines
      if (rawValue == '|' || rawValue == '>') {
        final buffer = StringBuffer();
        i++;
        // Determine indent from the first continuation line; require at least 1 space.
        int? indent;
        while (i < lines.length) {
          final next = lines[i];
          if (next.trim().isEmpty) {
            buffer.writeln();
            i++;
            continue;
          }
          final leadingSpaces = next.length - next.trimLeft().length;
          if (leadingSpaces == 0) break; // de-indent ends the block
          indent ??= leadingSpaces;
          if (leadingSpaces < indent) break;
          buffer.writeln(next.substring(indent));
          i++;
        }
        fields[key] = buffer.toString().trimRight();
      } else {
        fields[key] = rawValue;
        i++;
      }
    }
    final name = fields['name'];
    final description = fields['description'];
    if (name == null || name.isEmpty) return null;
    if (description == null || description.isEmpty) return null;
    final enabled = fields['enabled']?.toLowerCase() != 'false';
    final skillRef =
        fields['skill_ref'] ??
        fields['skillRef'] ??
        fields['ref'] ??
        _slugifySkillRef(name);
    final minContextStr = fields['min_context'];
    final minContext = minContextStr != null
        ? int.tryParse(minContextStr)
        : null;
    final defaultAction = fields['default_action']?.trim();
    return SkillMetadata(
      noteId: noteId,
      skillRef: skillRef,
      name: name,
      description: description,
      enabled: enabled,
      minContext: minContext,
      defaultAction: (defaultAction == null || defaultAction.isEmpty)
          ? null
          : defaultAction,
    );
  }
  ```

  3c. Update `buildSkillIndex` to propagate `defaultAction`:

  ```dart
  // Inside buildSkillIndex, in the index[note.id] = SkillMetadata(...) call:
  index[note.id] = SkillMetadata(
    noteId: meta.noteId,
    skillRef: stableRef,
    name: meta.name,
    description: meta.description,
    enabled: meta.enabled,
    minContext: meta.minContext,
    defaultAction: meta.defaultAction,
  );
  ```

- [ ] **Step 4: Run the test — confirm it passes**

  ```bash
  flutter test test/services/skill_service_default_action_test.dart
  ```

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add lib/services/skill_service.dart test/services/skill_service_default_action_test.dart
  git commit -m "feat(skill): add defaultAction frontmatter field with block-scalar parsing"
  ```

---

### Task 6: Inject `default_action` instructions into the system prompt

**Files:**
- Modify: `lib/services/skill_service.dart` — add `buildDefaultActionPromptSection`
- Modify: `lib/screens/conversation_chat_screen.dart:1516` — append the new section
- Modify: `lib/services/agent_service.dart:1347, 2749` — same append
- Test: `test/services/skill_service_default_action_test.dart`

- [ ] **Step 1: Write the failing test for the prompt section builder**

  Append to `test/services/skill_service_default_action_test.dart`:

  ```dart
  test('buildDefaultActionPromptSection returns empty string when no skills declare default_action', () {
    final svc = SkillService(_StubDb());
    final index = <String, SkillMetadata>{
      'a': SkillMetadata(
        noteId: 'a', skillRef: 'a', name: 'A', description: 'd', enabled: true),
    };
    expect(svc.buildDefaultActionPromptSection(index), '');
  });

  test('buildDefaultActionPromptSection concatenates default_action strings deterministically by skillRef', () {
    final svc = SkillService(_StubDb());
    final index = <String, SkillMetadata>{
      'note-z': SkillMetadata(
        noteId: 'note-z', skillRef: 'z-skill',
        name: 'Z', description: 'd', enabled: true,
        defaultAction: 'Z action instructions'),
      'note-a': SkillMetadata(
        noteId: 'note-a', skillRef: 'a-skill',
        name: 'A', description: 'd', enabled: true,
        defaultAction: 'A action instructions'),
      'note-b': SkillMetadata(
        noteId: 'note-b', skillRef: 'b-skill',
        name: 'B', description: 'd', enabled: true),  // no defaultAction
    };
    final out = svc.buildDefaultActionPromptSection(index);
    final aIdx = out.indexOf('A action instructions');
    final zIdx = out.indexOf('Z action instructions');
    expect(aIdx, greaterThan(-1));
    expect(zIdx, greaterThan(-1));
    expect(aIdx, lessThan(zIdx), reason: 'Should be ordered alphabetically by skillRef (a < z)');
    expect(out.contains('B'), isFalse, reason: 'Skills without defaultAction should be omitted');
  });
  ```

- [ ] **Step 2: Run the test — confirm it fails**

  ```bash
  flutter test test/services/skill_service_default_action_test.dart
  ```

  Expected: FAIL — `buildDefaultActionPromptSection` doesn't exist.

- [ ] **Step 3: Implement the section builder**

  In `lib/services/skill_service.dart`, add:

  ```dart
  /// Returns a system-prompt section containing the concatenated
  /// default_action instruction text from every skill in [index] whose
  /// `defaultAction` is non-null. Skills are ordered deterministically
  /// by `skillRef` for reproducibility.
  ///
  /// Returns an empty string if no skill declares a defaultAction —
  /// callers should append the result unconditionally; an empty append
  /// is a no-op.
  String buildDefaultActionPromptSection(Map<String, SkillMetadata> index) {
    final withAction = index.values
        .where((m) => m.defaultAction != null && m.defaultAction!.isNotEmpty)
        .toList()
      ..sort((a, b) => a.skillRef.compareTo(b.skillRef));
    if (withAction.isEmpty) return '';
    final buf = StringBuffer();
    buf.writeln('## Skill Default Actions');
    buf.writeln(
      'The following skill-driven instructions modify how you should '
      'present follow-up actions to the reader. Apply all that are relevant.',
    );
    for (final m in withAction) {
      buf.writeln();
      buf.writeln('### From skill `${m.skillRef}` (${m.name})');
      buf.writeln(m.defaultAction);
    }
    return buf.toString().trimRight();
  }
  ```

- [ ] **Step 4: Run the test — confirm it passes**

  ```bash
  flutter test test/services/skill_service_default_action_test.dart
  ```

  Expected: PASS.

- [ ] **Step 5: Update all 3 call sites to append the section**

  In `lib/screens/conversation_chat_screen.dart`, after the `contextBuffer.writeln(); contextBuffer.write(skillIndexPrompt.trim());` block (around line 1525), add:

  ```dart
  final defaultActionSection = getIt<SkillService>()
      .buildDefaultActionPromptSection(_conversationService.skillIndex);
  if (defaultActionSection.isNotEmpty) {
    contextBuffer
      ..writeln()
      ..writeln()
      ..write(defaultActionSection);
  }
  ```

  Apply the same append at the two locations in `lib/services/agent_service.dart` (lines 1347 and 2749 — find the equivalent skill index append block and add the same code right after, using whichever local variable holds the accumulating prompt buffer).

- [ ] **Step 6: Commit**

  ```bash
  git add lib/services/skill_service.dart lib/screens/conversation_chat_screen.dart lib/services/agent_service.dart test/services/skill_service_default_action_test.dart
  git commit -m "feat(skill): inject default_action instructions into system prompt"
  ```

---

### Task 7: Add `ConversationBranchSummary` + `getAllForkPointBranches` query

**Files:**
- Create: `lib/models/conversation_branch_summary.dart`
- Modify: `lib/services/conversation_service.dart`
- Test: `test/services/conversation_service_branches_test.dart`

- [ ] **Step 1: Create the data class**

  Write `lib/models/conversation_branch_summary.dart`:

  ```dart
  /// One row in the inline branch strip. Identifies a child conversation
  /// branched off a particular parent message.
  class ConversationBranchSummary {
    final String conversationId;
    final String title;
    final String forkPointMessageId;
    final String firstChildMessageId;
    final List<String> noteIds;

    const ConversationBranchSummary({
      required this.conversationId,
      required this.title,
      required this.forkPointMessageId,
      required this.firstChildMessageId,
      required this.noteIds,
    });
  }
  ```

- [ ] **Step 2: Write the failing test for `getAllForkPointBranches`**

  Create `test/services/conversation_service_branches_test.dart`. This test uses an in-memory sqflite_ffi DB (the project pattern):

  ```dart
  import 'package:flutter_test/flutter_test.dart';
  import 'package:note_synapse/services/conversation_service.dart';
  import 'package:note_synapse/services/database_service.dart';
  import 'package:note_synapse/services/service_locator.dart';
  import 'package:sqflite_common_ffi/sqflite_ffi.dart';

  void main() {
    setUpAll(() => sqfliteFfiInit());

    late DatabaseService db;
    late ConversationService convService;

    setUp(() async {
      await resetForTesting();
      db = await DatabaseService.createNew(
        databaseFactory: databaseFactoryFfi,
        databaseName: ':memory:',
      );
      getIt.registerSingleton<DatabaseService>(db);
      convService = ConversationService(db);
      getIt.registerSingleton<ConversationService>(convService);
    });

    test('getAllForkPointBranches returns each child branch including the active one', () async {
      // Create parent conversation with 1 message
      final parent = await convService.createConversation(
        title: 'Parent', noteIds: const []);
      final msg = await convService.addUserMessage(
        conversationId: parent.id, content: 'Q?');

      // Fork twice from the same message
      final childA = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: msg.id,
        newTitle: 'Branch A');
      final childB = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: msg.id,
        newTitle: 'Branch B');

      final result = await convService.getAllForkPointBranches(parent.id);
      expect(result.containsKey(msg.id), isTrue);
      final branches = result[msg.id]!;
      expect(branches.length, 2);
      final ids = branches.map((b) => b.conversationId).toSet();
      expect(ids, {childA.id, childB.id});
      // Active conversation (parent) is NOT a branch entry — branches are children only
      expect(ids.contains(parent.id), isFalse);
    });

    test('getAllForkPointBranches dedups by conversationId when same parent has multiple shared messages in same child', () async {
      final parent = await convService.createConversation(
        title: 'Parent', noteIds: const []);
      final msg1 = await convService.addUserMessage(
        conversationId: parent.id, content: 'Q1?');
      final msg2 = await convService.addUserMessage(
        conversationId: parent.id, content: 'Q2?');
      final child = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: msg2.id,
        newTitle: 'Child');

      final result = await convService.getAllForkPointBranches(parent.id);
      // Both msg1 and msg2 are shared with `child` via message_parents,
      // but the strip should render at most one entry per child conversation.
      final allBranches = result.values.expand((l) => l).toList();
      final childCount = allBranches.where((b) => b.conversationId == child.id).length;
      expect(childCount, lessThanOrEqualTo(1),
          reason: 'A child conversation should appear at most once across the parent\'s fork points');
    });

    test('getAllForkPointBranches returns empty map for a conversation with no children', () async {
      final solo = await convService.createConversation(
        title: 'Solo', noteIds: const []);
      await convService.addUserMessage(
        conversationId: solo.id, content: 'Hi');
      final result = await convService.getAllForkPointBranches(solo.id);
      expect(result, isEmpty);
    });
  }
  ```

- [ ] **Step 3: Run the test — confirm it fails**

  ```bash
  flutter test test/services/conversation_service_branches_test.dart
  ```

  Expected: compile error — `getAllForkPointBranches` doesn't exist.

- [ ] **Step 4: Implement the methods on ConversationService**

  In `lib/services/conversation_service.dart`, add the import:

  ```dart
  import '../models/conversation_branch_summary.dart';
  ```

  Add the methods (place near other conversation-query methods):

  ```dart
  /// Returns child branches forking off [parentMessageId]. One entry per
  /// child conversation. Empty list if the message has no children or only
  /// has children inside the same conversation.
  Future<List<ConversationBranchSummary>> getChildBranches(
    String parentMessageId,
  ) async {
    final all = await getAllForkPointBranchesForParents([parentMessageId]);
    return all[parentMessageId] ?? const [];
  }

  /// Batched fork-point query: one DB round-trip returning all child
  /// branches for every fork-point in [conversationId]. Cached by ChatPanel
  /// for the lifetime of the panel; invalidated by ForkService.forkCreatedStream.
  Future<Map<String, List<ConversationBranchSummary>>>
      getAllForkPointBranches(String conversationId) async {
    final db = await _databaseService.database;
    // Find all messageIds in this conversation that act as parents to
    // a message in a different conversation.
    final rows = await db.rawQuery('''
      SELECT mp.parentMessageId AS parent_id,
             cmm.conversationId AS child_conv_id,
             c.title           AS child_title,
             (SELECT m2.id
                FROM conversation_messages m2
                JOIN message_parents mp2 ON mp2.messageId = m2.id
                JOIN conversation_message_mapping cmm2
                  ON cmm2.messageId = m2.id
               WHERE mp2.parentMessageId = mp.parentMessageId
                 AND cmm2.conversationId = cmm.conversationId
               ORDER BY m2.timestamp ASC
               LIMIT 1) AS first_child_message_id
        FROM message_parents mp
        JOIN conversation_message_mapping cmm
          ON cmm.messageId = mp.messageId
        JOIN conversations c
          ON c.id = cmm.conversationId
       WHERE mp.parentMessageId IN (
              SELECT m.id FROM conversation_messages m
               JOIN conversation_message_mapping mm
                 ON mm.messageId = m.id
              WHERE mm.conversationId = ?
            )
         AND cmm.conversationId != ?  -- exclude the active conversation itself
       GROUP BY mp.parentMessageId, cmm.conversationId
    ''', [conversationId, conversationId]);

    if (rows.isEmpty) return const {};

    // Bulk-fetch noteIds for every involved child conversation.
    final childConvIds = rows
        .map((r) => r['child_conv_id'] as String)
        .toSet();
    final notesByConv = <String, List<String>>{};
    for (final cid in childConvIds) {
      notesByConv[cid] = await _databaseService.getConversationNoteIds(cid);
    }

    final result = <String, List<ConversationBranchSummary>>{};
    for (final row in rows) {
      final parentId = row['parent_id'] as String;
      final summary = ConversationBranchSummary(
        conversationId: row['child_conv_id'] as String,
        title: row['child_title'] as String,
        forkPointMessageId: parentId,
        firstChildMessageId: row['first_child_message_id'] as String,
        noteIds: notesByConv[row['child_conv_id']] ?? const [],
      );
      result.putIfAbsent(parentId, () => []).add(summary);
    }
    return result;
  }

  /// Internal: variant of [getAllForkPointBranches] that takes a list of
  /// specific parent IDs. Used by [getChildBranches].
  Future<Map<String, List<ConversationBranchSummary>>>
      getAllForkPointBranchesForParents(List<String> parentMessageIds) async {
    if (parentMessageIds.isEmpty) return const {};
    final db = await _databaseService.database;
    final placeholders = List.filled(parentMessageIds.length, '?').join(',');
    final rows = await db.rawQuery('''
      SELECT mp.parentMessageId AS parent_id,
             cmm.conversationId AS child_conv_id,
             c.title           AS child_title,
             (SELECT m2.id
                FROM conversation_messages m2
                JOIN message_parents mp2 ON mp2.messageId = m2.id
                JOIN conversation_message_mapping cmm2
                  ON cmm2.messageId = m2.id
               WHERE mp2.parentMessageId = mp.parentMessageId
                 AND cmm2.conversationId = cmm.conversationId
               ORDER BY m2.timestamp ASC
               LIMIT 1) AS first_child_message_id
        FROM message_parents mp
        JOIN conversation_message_mapping cmm
          ON cmm.messageId = mp.messageId
        JOIN conversations c
          ON c.id = cmm.conversationId
       WHERE mp.parentMessageId IN ($placeholders)
       GROUP BY mp.parentMessageId, cmm.conversationId
    ''', parentMessageIds);

    if (rows.isEmpty) return const {};
    final childConvIds = rows.map((r) => r['child_conv_id'] as String).toSet();
    final notesByConv = <String, List<String>>{};
    for (final cid in childConvIds) {
      notesByConv[cid] = await _databaseService.getConversationNoteIds(cid);
    }
    final result = <String, List<ConversationBranchSummary>>{};
    for (final row in rows) {
      final parentId = row['parent_id'] as String;
      final summary = ConversationBranchSummary(
        conversationId: row['child_conv_id'] as String,
        title: row['child_title'] as String,
        forkPointMessageId: parentId,
        firstChildMessageId: row['first_child_message_id'] as String,
        noteIds: notesByConv[row['child_conv_id']] ?? const [],
      );
      result.putIfAbsent(parentId, () => []).add(summary);
    }
    return result;
  }
  ```

- [ ] **Step 5: Run the test — confirm it passes**

  ```bash
  flutter test test/services/conversation_service_branches_test.dart
  ```

  Expected: PASS.

- [ ] **Step 6: Verify EXPLAIN QUERY PLAN uses indexes**

  Add a one-off verification test that asserts the index is hit:

  ```dart
  test('EXPLAIN QUERY PLAN uses idx_message_parents_parentMessageId', () async {
    final dbInst = await db.database;
    final plan = await dbInst.rawQuery('''
      EXPLAIN QUERY PLAN
      SELECT mp.parentMessageId
        FROM message_parents mp
        JOIN conversation_message_mapping cmm ON cmm.messageId = mp.messageId
       WHERE mp.parentMessageId IN (?)
    ''', ['x']);
    final detailColumn = plan.map((r) => r['detail'].toString()).join(' | ');
    expect(detailColumn, contains('idx_message_parents'),
        reason: 'Query must use the message_parents index');
  });
  ```

  Run:
  ```bash
  flutter test test/services/conversation_service_branches_test.dart
  ```

  Expected: PASS. If FAIL, the schema indexes have drifted — investigate `database_service.dart:410-413`.

- [ ] **Step 7: Commit**

  ```bash
  git add lib/models/conversation_branch_summary.dart lib/services/conversation_service.dart test/services/conversation_service_branches_test.dart
  git commit -m "feat(conv): add getAllForkPointBranches batched query for branch strip"
  ```

---

## Phase 2: Chip System Foundations

### Task 8: ChipAction model

**Files:**
- Create: `lib/models/chip_action.dart`
- Test: `test/models/chip_action_test.dart`

- [ ] **Step 1: Write the test**

  ```dart
  // test/models/chip_action_test.dart
  import 'package:flutter_test/flutter_test.dart';
  import 'package:note_synapse/models/chip_action.dart';

  void main() {
    test('ChipAction stores label and prompt; equality by value', () {
      const a = ChipAction(label: 'explain transformer', prompt: 'You are a tutor...');
      const b = ChipAction(label: 'explain transformer', prompt: 'You are a tutor...');
      const c = ChipAction(label: 'different', prompt: 'You are a tutor...');
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a.hashCode, b.hashCode);
    });
  }
  ```

- [ ] **Step 2: Run — confirm fail**

  ```bash
  flutter test test/models/chip_action_test.dart
  ```
  Expected: compile error.

- [ ] **Step 3: Implement**

  ```dart
  // lib/models/chip_action.dart
  import 'package:flutter/foundation.dart';

  @immutable
  class ChipAction {
    final String label;
    final String prompt;

    const ChipAction({required this.label, required this.prompt});

    @override
    bool operator ==(Object other) =>
        other is ChipAction && other.label == label && other.prompt == prompt;

    @override
    int get hashCode => Object.hash(label, prompt);
  }
  ```

- [ ] **Step 4: Run — confirm pass**

  ```bash
  flutter test test/models/chip_action_test.dart
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add lib/models/chip_action.dart test/models/chip_action_test.dart
  git commit -m "feat(chip): add ChipAction model"
  ```

---

### Task 9: Chips-block parser

**Files:**
- Create: `lib/services/chips_block_parser.dart`
- Test: `test/services/chips_block_parser_test.dart`

- [ ] **Step 1: Write tests for the parser**

  ```dart
  // test/services/chips_block_parser_test.dart
  import 'package:flutter_test/flutter_test.dart';
  import 'package:note_synapse/models/chip_action.dart';
  import 'package:note_synapse/services/chips_block_parser.dart';

  void main() {
    final parser = ChipsBlockParser();

    test('parses single chip with H2 label and body prompt', () {
      const md = '''Some AI reply text.

  ```chips
  ## explain transformer
  You are a tutor in CS. I know basic calculus.
  Explain transformers at my level.
  ```
  ''';
      final r = parser.parse(md);
      expect(r.chips, hasLength(1));
      expect(r.chips[0].label, 'explain transformer');
      expect(r.chips[0].prompt, contains('You are a tutor'));
      expect(r.chips[0].prompt, contains('Explain transformers at my level.'));
      expect(r.strippedMarkdown, isNot(contains('```chips')));
      expect(r.strippedMarkdown, contains('Some AI reply text.'));
    });

    test('parses multiple chips in one block', () {
      const md = '''Reply.
  ```chips
  ## A
  Prompt for A.
  ## B
  Prompt for B.
  ```''';
      final r = parser.parse(md);
      expect(r.chips, hasLength(2));
      expect(r.chips[0].label, 'A');
      expect(r.chips[0].prompt, 'Prompt for A.');
      expect(r.chips[1].label, 'B');
      expect(r.chips[1].prompt, 'Prompt for B.');
    });

    test('concatenates multiple chips blocks in document order', () {
      const md = '''Reply.
  ```chips
  ## A
  Prompt A.
  ```
  Mid.
  ```chips
  ## B
  Prompt B.
  ```''';
      final r = parser.parse(md);
      expect(r.chips.map((c) => c.label).toList(), ['A', 'B']);
      expect(r.strippedMarkdown, isNot(contains('```chips')));
    });

    test('drops chips with empty label or empty prompt body', () {
      const md = '''```chips
  ## valid label
  Valid prompt body.
  ##
  Body without label.
  ## label without body
  ```''';
      final r = parser.parse(md);
      expect(r.chips, hasLength(1));
      expect(r.chips[0].label, 'valid label');
    });

    test('returns no chips when no chips block present', () {
      const md = 'Just an AI reply with no chip block.';
      final r = parser.parse(md);
      expect(r.chips, isEmpty);
      expect(r.strippedMarkdown, md);
    });

    test('does not split on # (single hash) inside body — only ##', () {
      const md = '''```chips
  ## label
  Body with # single hash heading should stay in prompt.
  Also #hashtag should be fine.
  ```''';
      final r = parser.parse(md);
      expect(r.chips, hasLength(1));
      expect(r.chips[0].prompt, contains('# single hash'));
      expect(r.chips[0].prompt, contains('#hashtag'));
    });

    test('handles malformed fence (missing closing) gracefully — drops the block', () {
      const md = '''Reply.
  ```chips
  ## A
  Prompt A unterminated...''';
      final r = parser.parse(md);
      // No valid block parsed; markdown returned as-is.
      expect(r.chips, isEmpty);
      expect(r.strippedMarkdown, contains('```chips'),
          reason: 'Unterminated block stays — only well-formed blocks are stripped');
    });
  }
  ```

- [ ] **Step 2: Run — confirm fail**

  ```bash
  flutter test test/services/chips_block_parser_test.dart
  ```
  Expected: compile error.

- [ ] **Step 3: Implement the parser**

  ```dart
  // lib/services/chips_block_parser.dart
  import '../models/chip_action.dart';

  class ChipsParseResult {
    final List<ChipAction> chips;
    final String strippedMarkdown;
    const ChipsParseResult({required this.chips, required this.strippedMarkdown});
  }

  /// Parses fenced ```chips blocks out of an AI message body.
  /// Each block contains zero or more chips formatted as:
  ///
  ///   ## <label>
  ///   <prompt body, multi-line>
  ///   ## <next label>
  ///   ...
  ///
  /// Only fully-terminated blocks (matching closing ```) are extracted;
  /// malformed blocks remain in the rendered markdown for debug visibility.
  class ChipsBlockParser {
    static final _blockRegex = RegExp(
      r'```chips\s*\n([\s\S]*?)\n```',
      multiLine: true,
    );

    ChipsParseResult parse(String markdown) {
      final matches = _blockRegex.allMatches(markdown).toList();
      if (matches.isEmpty) {
        return ChipsParseResult(chips: const [], strippedMarkdown: markdown);
      }
      final chips = <ChipAction>[];
      for (final m in matches) {
        chips.addAll(_parseBlockBody(m.group(1)!));
      }
      // Strip blocks from markdown (in reverse to preserve offsets).
      final buf = StringBuffer();
      int cursor = 0;
      for (final m in matches) {
        buf.write(markdown.substring(cursor, m.start));
        cursor = m.end;
      }
      buf.write(markdown.substring(cursor));
      // Collapse any 3+ consecutive blank lines left by the strip.
      final stripped = buf.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n');
      return ChipsParseResult(chips: chips, strippedMarkdown: stripped);
    }

    List<ChipAction> _parseBlockBody(String body) {
      final lines = body.split('\n');
      final chips = <ChipAction>[];
      String? currentLabel;
      final currentBody = StringBuffer();

      void flush() {
        if (currentLabel != null) {
          final label = currentLabel!.trim();
          final prompt = currentBody.toString().trim();
          if (label.isNotEmpty && prompt.isNotEmpty) {
            chips.add(ChipAction(label: label, prompt: prompt));
          }
        }
        currentLabel = null;
        currentBody.clear();
      }

      for (final line in lines) {
        if (line.startsWith('## ') || line.trimRight() == '##') {
          flush();
          currentLabel = line.length > 3 ? line.substring(3).trim() : '';
        } else {
          if (currentLabel != null) {
            currentBody.writeln(line);
          }
        }
      }
      flush();
      return chips;
    }
  }
  ```

- [ ] **Step 4: Run — confirm pass**

  ```bash
  flutter test test/services/chips_block_parser_test.dart
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add lib/models/chip_action.dart lib/services/chips_block_parser.dart test/services/chips_block_parser_test.dart
  git commit -m "feat(chip): add ChipsBlockParser for fenced chips block extraction"
  ```

---

### Task 10: Wire ChipsBlockParser into BlockMarkdownBody

**Goal:** Strip chips blocks from rendered markdown; expose extracted chips via callback so the chip footer can render them.

**Files:**
- Modify: `lib/widgets/block_markdown_body.dart`
- Test: `test/widgets/block_markdown_body_chips_test.dart`

- [ ] **Step 1: Read the current BlockMarkdownBody to find the render entry point**

  ```bash
  cat lib/widgets/block_markdown_body.dart
  ```

  Identify where the markdown string is finalized before being handed to `GptMarkdown` (or equivalent). The chips block must be stripped *before* this hand-off.

- [ ] **Step 2: Write the failing widget test**

  ```dart
  // test/widgets/block_markdown_body_chips_test.dart
  import 'package:flutter/material.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:note_synapse/models/chip_action.dart';
  import 'package:note_synapse/widgets/block_markdown_body.dart';

  void main() {
    testWidgets('strips ```chips block from rendered markdown and notifies parent', (tester) async {
      List<ChipAction>? captured;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BlockMarkdownBody(
            data: '''Hello world.
  ```chips
  ## explain X
  Explain X for me.
  ```''',
            onChipsExtracted: (chips) => captured = chips,
          ),
        ),
      ));
      // The chips fence text should not appear in any rendered widget.
      expect(find.textContaining('```chips'), findsNothing);
      expect(find.textContaining('## explain X'), findsNothing);
      expect(find.textContaining('Hello world.'), findsOneWidget);
      expect(captured, isNotNull);
      expect(captured!.length, 1);
      expect(captured![0].label, 'explain X');
    });

    testWidgets('passes empty chips list when no block present', (tester) async {
      List<ChipAction>? captured;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BlockMarkdownBody(
            data: 'Plain reply.',
            onChipsExtracted: (chips) => captured = chips,
          ),
        ),
      ));
      expect(captured, isEmpty);
    });
  }
  ```

- [ ] **Step 3: Run — confirm fail**

  ```bash
  flutter test test/widgets/block_markdown_body_chips_test.dart
  ```
  Expected: FAIL — `onChipsExtracted` parameter doesn't exist.

- [ ] **Step 4: Add chips-stripping to BlockMarkdownBody**

  In `lib/widgets/block_markdown_body.dart`:

  4a. Add the import:

  ```dart
  import '../models/chip_action.dart';
  import '../services/chips_block_parser.dart';
  ```

  4b. Add the optional callback to the constructor:

  ```dart
  class BlockMarkdownBody extends StatefulWidget {
    final String data;
    final void Function(List<ChipAction>)? onChipsExtracted;
    // ... existing fields
    const BlockMarkdownBody({
      super.key,
      required this.data,
      this.onChipsExtracted,
      // ... existing params
    });
    // ...
  }
  ```

  4c. In the State class, parse on `data` change and pass the stripped markdown to the existing renderer. In the build method (or wherever `data` is consumed), replace the direct use of `widget.data` with:

  ```dart
  final parsed = ChipsBlockParser().parse(widget.data);
  // Defer the callback to post-frame so we don't setState during build.
  if (widget.onChipsExtracted != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onChipsExtracted!(parsed.chips);
    });
  }
  // Use parsed.strippedMarkdown wherever widget.data was used.
  ```

  Be careful: if the widget rebuilds frequently, the post-frame callback fires repeatedly. Cache the parsed result keyed on `data`:

  ```dart
  ChipsParseResult? _cached;
  String? _cachedFor;

  ChipsParseResult _ensureParsed(String data) {
    if (_cachedFor == data && _cached != null) return _cached!;
    _cached = ChipsBlockParser().parse(data);
    _cachedFor = data;
    return _cached!;
  }
  ```

  Notify only when the chips list changes:

  ```dart
  List<ChipAction>? _lastNotified;
  // ...
  if (widget.onChipsExtracted != null &&
      !_listEquals(_lastNotified, parsed.chips)) {
    _lastNotified = parsed.chips;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onChipsExtracted!(parsed.chips);
    });
  }
  ```

  (Use `package:collection`'s `ListEquality<ChipAction>().equals(...)` or a small helper.)

- [ ] **Step 5: Run — confirm pass**

  ```bash
  flutter test test/widgets/block_markdown_body_chips_test.dart
  ```

- [ ] **Step 6: Run full widget test suite to catch regressions**

  ```bash
  flutter test test/widgets/
  ```
  Expected: no new failures.

- [ ] **Step 7: Commit**

  ```bash
  git add lib/widgets/block_markdown_body.dart test/widgets/block_markdown_body_chips_test.dart
  git commit -m "feat(markdown): strip chips block from render and expose via callback"
  ```

---

### Task 11: ChipsFooter widget (skeleton + chips + cross-fade)

**Files:**
- Create: `lib/widgets/chips_footer.dart`
- Test: `test/widgets/chips_footer_test.dart`

- [ ] **Step 1: Write the test**

  ```dart
  // test/widgets/chips_footer_test.dart
  import 'package:flutter/material.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:note_synapse/models/chip_action.dart';
  import 'package:note_synapse/widgets/chips_footer.dart';

  void main() {
    testWidgets('shows 4 skeleton pills when isStreaming and isExpected', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ChipsFooter(
            chips: null,
            isStreaming: true,
            isExpected: true,
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('chip-skeleton-pill')), findsNWidgets(4));
    });

    testWidgets('shows nothing when isStreaming=false and chips empty', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ChipsFooter(
            chips: [],
            isStreaming: false,
            isExpected: true,
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('chip-skeleton-pill')), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('shows nothing when isExpected=false (no default_action skill loaded)', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ChipsFooter(
            chips: null,
            isStreaming: true,
            isExpected: false,
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('chip-skeleton-pill')), findsNothing);
    });

    testWidgets('renders a tap-target per chip with label text', (tester) async {
      const chips = [
        ChipAction(label: 'explain transformer', prompt: 'You are a tutor...'),
        ChipAction(label: 'explain attention', prompt: 'Explain attention...'),
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChipsFooter(
            chips: chips,
            isStreaming: false,
            isExpected: true,
            onChipTap: (_) {},
          ),
        ),
      ));
      expect(find.text('explain transformer'), findsOneWidget);
      expect(find.text('explain attention'), findsOneWidget);
    });

    testWidgets('chip tap fires onChipTap with the chip', (tester) async {
      ChipAction? tapped;
      const chips = [ChipAction(label: 'go', prompt: 'Go forth.')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChipsFooter(
            chips: chips,
            isStreaming: false,
            isExpected: true,
            onChipTap: (c) => tapped = c,
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      expect(tapped, isNotNull);
      expect(tapped!.label, 'go');
    });
  }
  ```

- [ ] **Step 2: Run — confirm fail**

  ```bash
  flutter test test/widgets/chips_footer_test.dart
  ```

- [ ] **Step 3: Implement ChipsFooter**

  ```dart
  // lib/widgets/chips_footer.dart
  import 'package:flutter/material.dart';
  import '../models/chip_action.dart';

  /// Footer below an AI message that renders either a streaming-time
  /// shimmer skeleton or the parsed chip tap-targets.
  ///
  /// - [isExpected] = true when at least one default_action-bearing
  ///   skill is loaded (gates everything; if false, nothing renders).
  /// - [isStreaming] + [chips]==null = render skeleton.
  /// - [isStreaming]==false + chips empty = render nothing.
  /// - [isStreaming]==false + chips populated = render chip strip.
  class ChipsFooter extends StatelessWidget {
    final List<ChipAction>? chips;
    final bool isStreaming;
    final bool isExpected;
    final void Function(ChipAction)? onChipTap;
    final void Function(ChipAction, GlobalKey)? onChipLongPress;

    const ChipsFooter({
      super.key,
      required this.chips,
      required this.isStreaming,
      required this.isExpected,
      this.onChipTap,
      this.onChipLongPress,
    });

    @override
    Widget build(BuildContext context) {
      if (!isExpected) return const SizedBox.shrink();
      if (isStreaming) return _buildSkeleton(context);
      final cs = chips ?? const [];
      if (cs.isEmpty) return const SizedBox.shrink();
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Padding(
          key: const ValueKey('chip-footer-real'),
          padding: const EdgeInsets.only(top: 8, left: 8, right: 8, bottom: 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final c in cs) _buildChip(context, c)],
          ),
        ),
      );
    }

    Widget _buildSkeleton(BuildContext context) {
      // 4 placeholder pills of varying widths.
      const widths = [110.0, 80.0, 140.0, 95.0];
      return Padding(
        key: const ValueKey('chip-footer-skeleton'),
        padding: const EdgeInsets.only(top: 8, left: 8, right: 8, bottom: 4),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final w in widths) _SkeletonPill(width: w)],
        ),
      );
    }

    Widget _buildChip(BuildContext context, ChipAction chip) {
      final key = GlobalKey();
      final theme = Theme.of(context);
      return Material(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(16),
          onTap: onChipTap == null ? null : () => onChipTap!(chip),
          onLongPress: onChipLongPress == null
              ? null
              : () => onChipLongPress!(chip, key),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              _truncateLabel(chip.label),
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      );
    }

    String _truncateLabel(String label) {
      // ≤5 words; soft truncate with ellipsis for over-emission.
      final words = label.trim().split(RegExp(r'\s+'));
      if (words.length <= 5) return label.trim();
      return '${words.take(5).join(' ')}…';
    }
  }

  class _SkeletonPill extends StatefulWidget {
    final double width;
    const _SkeletonPill({required this.width});
    @override
    State<_SkeletonPill> createState() => _SkeletonPillState();
  }

  class _SkeletonPillState extends State<_SkeletonPill>
      with SingleTickerProviderStateMixin {
    late final AnimationController _ctrl;
    @override
    void initState() {
      super.initState();
      _ctrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1100),
      )..repeat();
    }

    @override
    void dispose() {
      _ctrl.dispose();
      super.dispose();
    }

    @override
    Widget build(BuildContext context) {
      return Container(
        key: const ValueKey('chip-skeleton-pill'),
        width: widget.width,
        height: 26,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
        ),
        clipBehavior: Clip.hardEdge,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final t = _ctrl.value;
            return ShaderMask(
              shaderCallback: (rect) => LinearGradient(
                begin: Alignment(-1.0 + 2 * t, 0),
                end: Alignment(1.0 + 2 * t, 0),
                colors: const [
                  Color(0xFFE0E0E0),
                  Color(0xFFF5F5F5),
                  Color(0xFFE0E0E0),
                ],
              ).createShader(rect),
              child: Container(color: Colors.white),
            );
          },
        ),
      );
    }
  }
  ```

- [ ] **Step 4: Run — confirm pass**

  ```bash
  flutter test test/widgets/chips_footer_test.dart
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add lib/widgets/chips_footer.dart test/widgets/chips_footer_test.dart
  git commit -m "feat(chip): add ChipsFooter widget with skeleton and chip strip"
  ```

---

### Task 12: ChipPreviewPopover widget

**Files:**
- Create: `lib/widgets/chip_preview_popover.dart`
- Test: `test/widgets/chip_preview_popover_test.dart`

- [ ] **Step 1: Write the test**

  ```dart
  // test/widgets/chip_preview_popover_test.dart
  import 'package:flutter/material.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:note_synapse/models/chip_action.dart';
  import 'package:note_synapse/widgets/chip_preview_popover.dart';

  void main() {
    testWidgets('show() displays an overlay with the chip prompt text', (tester) async {
      const chip = ChipAction(label: 'go', prompt: 'You are a tutor. Explain X.');
      late BuildContext capturedContext;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          capturedContext = ctx;
          return const Scaffold(body: SizedBox.shrink());
        }),
      ));
      final entry = ChipPreviewPopover.show(
        context: capturedContext,
        anchorRect: const Rect.fromLTWH(100, 100, 80, 26),
        chip: chip,
      );
      await tester.pump();
      expect(find.text('You are a tutor. Explain X.'), findsOneWidget);
      entry.remove();
      await tester.pump();
      expect(find.text('You are a tutor. Explain X.'), findsNothing);
    });
  }
  ```

- [ ] **Step 2: Run — confirm fail**

  ```bash
  flutter test test/widgets/chip_preview_popover_test.dart
  ```

- [ ] **Step 3: Implement**

  ```dart
  // lib/widgets/chip_preview_popover.dart
  import 'package:flutter/material.dart';
  import '../models/chip_action.dart';

  class ChipPreviewPopover {
    /// Shows the chip's full prompt as an overlay anchored above the chip.
    /// Returns the OverlayEntry — caller is responsible for removing it
    /// (e.g. on mouse-leave, scroll, or tap-elsewhere).
    static OverlayEntry show({
      required BuildContext context,
      required Rect anchorRect,
      required ChipAction chip,
    }) {
      final overlay = Overlay.of(context);
      final mediaSize = MediaQuery.of(context).size;
      const popMaxWidth = 360.0;
      final left = (anchorRect.center.dx - popMaxWidth / 2)
          .clamp(8.0, mediaSize.width - popMaxWidth - 8.0);
      final entry = OverlayEntry(
        builder: (ctx) => Positioned(
          left: left,
          top: anchorRect.top - 8 - 200, // best-effort upward placement
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: popMaxWidth,
                maxHeight: 240,
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SingleChildScrollView(
                  child: Text(
                    chip.prompt,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      overlay.insert(entry);
      return entry;
    }
  }
  ```

- [ ] **Step 4: Run — confirm pass**

  ```bash
  flutter test test/widgets/chip_preview_popover_test.dart
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add lib/widgets/chip_preview_popover.dart test/widgets/chip_preview_popover_test.dart
  git commit -m "feat(chip): add ChipPreviewPopover for hover/long-press preview"
  ```

---

### Task 13: ChipTapHandler service

**Files:**
- Create: `lib/services/chip_tap_handler.dart`
- Test: `test/services/chip_tap_handler_test.dart`

- [ ] **Step 1: Write the test**

  ```dart
  // test/services/chip_tap_handler_test.dart
  import 'package:flutter_test/flutter_test.dart';
  import 'package:mockito/annotations.dart';
  import 'package:mockito/mockito.dart';
  import 'package:note_synapse/models/chip_action.dart';
  import 'package:note_synapse/models/conversation.dart';
  import 'package:note_synapse/models/conversation_message.dart';
  import 'package:note_synapse/services/chip_tap_handler.dart';
  import 'package:note_synapse/services/conversation_service.dart';
  import 'package:note_synapse/services/fork_service.dart';
  import 'package:note_synapse/services/service_locator.dart';
  import 'chip_tap_handler_test.mocks.dart';

  @GenerateMocks([ConversationService, ForkService])
  void main() {
    late MockConversationService mockConv;
    late MockForkService mockFork;

    setUp(() async {
      await resetForTesting();
      mockConv = MockConversationService();
      mockFork = MockForkService();
      getIt.registerSingleton<ConversationService>(mockConv);
      getIt.registerSingleton<ForkService>(mockFork);
    });

    test('handle() forks, addsUserMessage(prompt), and invokes onSendUserPrompt', () async {
      const chip = ChipAction(label: 'explain X', prompt: 'You are a tutor. Explain X.');
      final forked = Conversation(id: 'forked-id', title: 'explain X', noteIds: []);
      when(mockFork.forkFromMessageInContext(
        forkFromMessageId: anyNamed('forkFromMessageId'),
        sourceConversationId: anyNamed('sourceConversationId'),
        suggestedTitle: anyNamed('suggestedTitle'),
      )).thenAnswer((_) async => forked);
      when(mockConv.addUserMessage(
        conversationId: anyNamed('conversationId'),
        content: anyNamed('content'),
      )).thenAnswer((_) async => ConversationMessage(
        id: 'msg-1', conversationId: 'forked-id',
        type: MessageType.user, content: 'You are a tutor. Explain X.',
        timestamp: DateTime.now(),
      ));

      String? sentConv;
      String? sentPrompt;
      Future<void> sender(String c, String p) async {
        sentConv = c;
        sentPrompt = p;
      }

      final handler = ChipTapHandler();
      await handler.handle(
        parentMessageId: 'parent-msg',
        chip: chip,
        sourceConversationId: 'src-conv',
        onSendUserPrompt: sender,
      );

      verify(mockFork.forkFromMessageInContext(
        forkFromMessageId: 'parent-msg',
        sourceConversationId: 'src-conv',
        suggestedTitle: 'explain X',
      )).called(1);
      verify(mockConv.addUserMessage(
        conversationId: 'forked-id',
        content: 'You are a tutor. Explain X.',
      )).called(1);
      expect(sentConv, 'forked-id');
      expect(sentPrompt, 'You are a tutor. Explain X.');
    });

    test('handle() short-circuits if fork returns null', () async {
      const chip = ChipAction(label: 'l', prompt: 'p');
      when(mockFork.forkFromMessageInContext(
        forkFromMessageId: anyNamed('forkFromMessageId'),
        sourceConversationId: anyNamed('sourceConversationId'),
        suggestedTitle: anyNamed('suggestedTitle'),
      )).thenAnswer((_) async => null);
      bool senderCalled = false;
      final handler = ChipTapHandler();
      await handler.handle(
        parentMessageId: 'parent',
        chip: chip,
        sourceConversationId: 'src',
        onSendUserPrompt: (_, __) async => senderCalled = true,
      );
      verifyNever(mockConv.addUserMessage(
        conversationId: anyNamed('conversationId'),
        content: anyNamed('content'),
      ));
      expect(senderCalled, isFalse);
    });
  }
  ```

- [ ] **Step 2: Generate mocks and run — confirm fail**

  ```bash
  dart run build_runner build --delete-conflicting-outputs
  flutter test test/services/chip_tap_handler_test.dart
  ```

- [ ] **Step 3: Implement ChipTapHandler**

  ```dart
  // lib/services/chip_tap_handler.dart
  import '../models/chip_action.dart';
  import 'conversation_service.dart';
  import 'fork_service.dart';
  import 'logger_service.dart';
  import 'service_locator.dart';

  /// Orchestrates the 3-step chip-tap flow:
  /// 1. Fork from the message that owns the chip's source AI reply.
  /// 2. Add the chip's full prompt as the new conversation's first user message.
  /// 3. Invoke the host-provided send callback to trigger the AI reply.
  class ChipTapHandler {
    Future<void> handle({
      required String parentMessageId,
      required ChipAction chip,
      required String sourceConversationId,
      required Future<void> Function(String, String) onSendUserPrompt,
    }) async {
      final forked = await getIt<ForkService>().forkFromMessageInContext(
        forkFromMessageId: parentMessageId,
        sourceConversationId: sourceConversationId,
        suggestedTitle: chip.label,
      );
      if (forked == null) {
        LoggerService.warn('ChipTapHandler: fork returned null; aborting');
        return;
      }
      await getIt<ConversationService>().addUserMessage(
        conversationId: forked.id,
        content: chip.prompt,
      );
      await onSendUserPrompt(forked.id, chip.prompt);
    }
  }
  ```

- [ ] **Step 4: Run — confirm pass**

  ```bash
  flutter test test/services/chip_tap_handler_test.dart
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add lib/services/chip_tap_handler.dart test/services/chip_tap_handler_test.dart test/services/chip_tap_handler_test.mocks.dart
  git commit -m "feat(chip): add ChipTapHandler 3-step orchestrator"
  ```

---

## Phase 3: Branch Strip Widget

### Task 14: MessageBranchStrip widget

**Files:**
- Create: `lib/widgets/message_branch_strip.dart`
- Test: `test/widgets/message_branch_strip_test.dart`

If Task 0 spike chose **fallback path** (chevron-icon popover), implement that variant in step 3 below; the data model and tests are unchanged.

- [ ] **Step 1: Write the test**

  ```dart
  // test/widgets/message_branch_strip_test.dart
  import 'package:flutter/material.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:note_synapse/models/conversation_branch_summary.dart';
  import 'package:note_synapse/widgets/message_branch_strip.dart';

  void main() {
    ConversationBranchSummary _summary(String id, String title, {List<String>? notes}) =>
        ConversationBranchSummary(
          conversationId: id,
          title: title,
          forkPointMessageId: 'parent-msg',
          firstChildMessageId: '${id}-first',
          noteIds: notes ?? const ['note-X'],
        );

    testWidgets('renders nothing when only one or zero branches', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBranchStrip(
            branches: [_summary('a', 'A')],
            activeConversationId: 'a',
            activeNoteIds: const ['note-X'],
            onSwitchBranch: (_, __) {},
          ),
        ),
      ));
      expect(find.text('A'), findsNothing);
    });

    testWidgets('renders one row per branch and highlights the active one', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBranchStrip(
            branches: [
              _summary('a', 'Branch A'),
              _summary('b', 'Branch B'),
              _summary('c', 'Branch C'),
            ],
            activeConversationId: 'b',
            activeNoteIds: const ['note-X'],
            onSwitchBranch: (_, __) {},
          ),
        ),
      ));
      expect(find.text('Branch A'), findsOneWidget);
      expect(find.text('Branch B'), findsOneWidget);
      expect(find.text('Branch C'), findsOneWidget);
      // Active row should be marked via key.
      expect(find.byKey(const ValueKey('branch-row-active-b')), findsOneWidget);
    });

    testWidgets('shows "+N more" beyond 5 fan-out and expands inline on tap', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBranchStrip(
            branches: List.generate(8, (i) => _summary('b$i', 'Branch $i')),
            activeConversationId: 'b0',
            activeNoteIds: const ['note-X'],
            onSwitchBranch: (_, __) {},
          ),
        ),
      ));
      expect(find.text('+3 more'), findsOneWidget);
      // After tapping +N more, all 8 should be visible.
      await tester.tap(find.text('+3 more'));
      await tester.pump();
      for (int i = 0; i < 8; i++) {
        expect(find.text('Branch $i'), findsOneWidget);
      }
    });

    testWidgets('tapping a same-document sibling fires onSwitchBranch with no confirm', (tester) async {
      String? switched;
      bool? confirmedFlag;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBranchStrip(
            branches: [
              _summary('a', 'A', notes: const ['note-X']),
              _summary('b', 'B', notes: const ['note-X']),
            ],
            activeConversationId: 'a',
            activeNoteIds: const ['note-X'],
            onSwitchBranch: (id, didConfirm) {
              switched = id;
              confirmedFlag = didConfirm;
            },
          ),
        ),
      ));
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(switched, 'b');
      expect(confirmedFlag, isFalse);
    });

    testWidgets('tapping a different-document sibling shows confirm dialog before switching', (tester) async {
      String? switched;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBranchStrip(
            branches: [
              _summary('a', 'A', notes: const ['note-X']),
              _summary('b', 'B', notes: const ['note-Y']),
            ],
            activeConversationId: 'a',
            activeNoteIds: const ['note-X'],
            onSwitchBranch: (id, _) => switched = id,
          ),
        ),
      ));
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(find.textContaining('different document'), findsOneWidget);
      expect(switched, isNull);
      // Tap the confirm button.
      await tester.tap(find.text('Switch'));
      await tester.pumpAndSettle();
      expect(switched, 'b');
    });
  }
  ```

- [ ] **Step 2: Run — confirm fail**

  ```bash
  flutter test test/widgets/message_branch_strip_test.dart
  ```

- [ ] **Step 3: Implement MessageBranchStrip**

  ```dart
  // lib/widgets/message_branch_strip.dart
  import 'package:flutter/material.dart';
  import '../models/conversation_branch_summary.dart';

  class MessageBranchStrip extends StatefulWidget {
    final List<ConversationBranchSummary> branches;
    final String activeConversationId;
    final List<String> activeNoteIds;

    /// Fired when the user accepts a sibling switch.
    /// [didConfirmDocumentSwap] is true if the user passed through the
    /// document-swap confirm dialog.
    final void Function(String conversationId, bool didConfirmDocumentSwap)
        onSwitchBranch;

    final bool disabled; // wired from ChatPanel.isStreaming

    const MessageBranchStrip({
      super.key,
      required this.branches,
      required this.activeConversationId,
      required this.activeNoteIds,
      required this.onSwitchBranch,
      this.disabled = false,
    });

    @override
    State<MessageBranchStrip> createState() => _MessageBranchStripState();
  }

  class _MessageBranchStripState extends State<MessageBranchStrip> {
    bool _expanded = false;

    @override
    Widget build(BuildContext context) {
      if (widget.branches.length < 2) return const SizedBox.shrink();
      const visibleLimit = 5;
      final showAll = _expanded || widget.branches.length <= visibleLimit;
      final visible = showAll
          ? widget.branches
          : widget.branches.take(visibleLimit).toList();
      final hiddenCount = widget.branches.length - visible.length;

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final b in visible) _buildRow(context, b),
            if (!showAll && hiddenCount > 0)
              InkWell(
                onTap: () => setState(() => _expanded = true),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '+$hiddenCount more',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    Widget _buildRow(BuildContext context, ConversationBranchSummary b) {
      final isActive = b.conversationId == widget.activeConversationId;
      return InkWell(
        key: isActive ? ValueKey('branch-row-active-${b.conversationId}') : null,
        onTap: widget.disabled ? null : () => _handleTap(b),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: Text(
            b.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                  color: isActive
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
          ),
        ),
      );
    }

    Future<void> _handleTap(ConversationBranchSummary b) async {
      final activeSet = widget.activeNoteIds.toSet();
      final candidateSet = b.noteIds.toSet();
      final differs =
          activeSet.length != candidateSet.length ||
          !activeSet.every(candidateSet.contains);
      if (!differs) {
        widget.onSwitchBranch(b.conversationId, false);
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(
            'This branch is associated with a different document. Switch document?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Switch'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        widget.onSwitchBranch(b.conversationId, true);
      }
    }
  }
  ```

  **If Task 0 spike chose fallback path:** replace `_buildRow` with a chevron-icon trigger that opens a `PopupMenuButton` of branches; data flow and `_handleTap` logic remain identical.

- [ ] **Step 4: Run — confirm pass**

  ```bash
  flutter test test/widgets/message_branch_strip_test.dart
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add lib/widgets/message_branch_strip.dart test/widgets/message_branch_strip_test.dart
  git commit -m "feat(branch): add MessageBranchStrip widget with document-swap warning"
  ```

---

## Phase 4: ChatPanel Extraction

### Task 15: ChatPanel widget skeleton (message list only)

**Goal:** Build the ChatPanel widget with the API from spec Section 1, but initially rendering only a static message list. Subsequent tasks bolt on branch strip, chip footer, callbacks, scroll, and stream subscription.

**Files:**
- Create: `lib/widgets/chat_panel.dart`
- Test: `test/widgets/chat_panel_test.dart`

- [ ] **Step 1: Write the test**

  ```dart
  // test/widgets/chat_panel_test.dart
  import 'package:flutter/material.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:mockito/annotations.dart';
  import 'package:mockito/mockito.dart';
  import 'package:note_synapse/models/conversation.dart';
  import 'package:note_synapse/models/conversation_message.dart';
  import 'package:note_synapse/services/conversation_service.dart';
  import 'package:note_synapse/services/fork_service.dart';
  import 'package:note_synapse/services/service_locator.dart';
  import 'package:note_synapse/widgets/chat_panel.dart';
  import 'chat_panel_test.mocks.dart';

  @GenerateMocks([ConversationService, ForkService])
  void main() {
    late MockConversationService mockConv;
    late MockForkService mockFork;

    setUp(() async {
      await resetForTesting();
      mockConv = MockConversationService();
      mockFork = MockForkService();
      when(mockFork.forkCreatedStream).thenAnswer((_) => const Stream.empty());
      getIt.registerSingleton<ConversationService>(mockConv);
      getIt.registerSingleton<ForkService>(mockFork);
    });

    testWidgets('renders message list for the given conversationId', (tester) async {
      when(mockConv.getConversation('conv-1'))
          .thenAnswer((_) async => Conversation(id: 'conv-1', title: 'T', noteIds: []));
      when(mockConv.getConversationMessages('conv-1'))
          .thenAnswer((_) async => [
                ConversationMessage(
                  id: 'm1', conversationId: 'conv-1',
                  type: MessageType.user, content: 'Hello',
                  timestamp: DateTime.now(),
                ),
                ConversationMessage(
                  id: 'm2', conversationId: 'conv-1',
                  type: MessageType.ai, content: 'Hi back',
                  timestamp: DateTime.now(),
                ),
              ]);
      when(mockConv.getAllForkPointBranches('conv-1'))
          .thenAnswer((_) async => const {});
      when(mockConv.skillsEnabled).thenReturn(false);
      when(mockConv.skillIndex).thenReturn(const {});

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatPanel(
            conversationId: 'conv-1',
            isStreaming: false,
            onActiveConversationChanged: (_) {},
            onSendUserPrompt: (_, __) async {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('Hello'), findsOneWidget);
      expect(find.textContaining('Hi back'), findsOneWidget);
    });

    testWidgets('renders contextCard pinned at top when provided', (tester) async {
      when(mockConv.getConversation('conv-1'))
          .thenAnswer((_) async => Conversation(id: 'conv-1', title: 'T', noteIds: []));
      when(mockConv.getConversationMessages('conv-1'))
          .thenAnswer((_) async => const []);
      when(mockConv.getAllForkPointBranches('conv-1'))
          .thenAnswer((_) async => const {});
      when(mockConv.skillsEnabled).thenReturn(false);
      when(mockConv.skillIndex).thenReturn(const {});

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatPanel(
            conversationId: 'conv-1',
            isStreaming: false,
            onActiveConversationChanged: (_) {},
            onSendUserPrompt: (_, __) async {},
            contextCard: const Text('CONTEXT_CARD_MARKER'),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('CONTEXT_CARD_MARKER'), findsOneWidget);
    });
  }
  ```

- [ ] **Step 2: Generate mocks and run — confirm fail**

  ```bash
  dart run build_runner build --delete-conflicting-outputs
  flutter test test/widgets/chat_panel_test.dart
  ```

- [ ] **Step 3: Implement skeleton ChatPanel**

  ```dart
  // lib/widgets/chat_panel.dart
  import 'dart:async';
  import 'package:flutter/material.dart';
  import '../models/chip_action.dart';
  import '../models/conversation.dart';
  import '../models/conversation_branch_summary.dart';
  import '../models/conversation_message.dart';
  import '../services/conversation_service.dart';
  import '../services/fork_service.dart';
  import '../services/service_locator.dart';
  import 'block_markdown_body.dart';
  import 'chips_footer.dart';
  import 'message_branch_strip.dart';

  class ChatPanel extends StatefulWidget {
    final String conversationId;
    final String? initialMessageId;
    final Widget? contextCard;
    final ValueChanged<String> onActiveConversationChanged;
    final bool isStreaming;
    final Future<void> Function(String conversationId, String prompt)
        onSendUserPrompt;

    const ChatPanel({
      super.key,
      required this.conversationId,
      required this.isStreaming,
      required this.onActiveConversationChanged,
      required this.onSendUserPrompt,
      this.initialMessageId,
      this.contextCard,
    });

    @override
    State<ChatPanel> createState() => _ChatPanelState();
  }

  class _ChatPanelState extends State<ChatPanel> {
    Conversation? _conversation;
    List<ConversationMessage> _messages = [];
    Map<String, List<ConversationBranchSummary>> _branchesByParent = {};
    final Map<String, List<ChipAction>> _chipsByMessage = {};
    StreamSubscription<String>? _forkSub;

    @override
    void initState() {
      super.initState();
      _load();
      _forkSub = getIt<ForkService>().forkCreatedStream.listen(_onForkCreated);
    }

    @override
    void didUpdateWidget(covariant ChatPanel old) {
      super.didUpdateWidget(old);
      if (old.conversationId != widget.conversationId) {
        _branchesByParent = {};
        _chipsByMessage.clear();
        _load();
      }
    }

    @override
    void dispose() {
      _forkSub?.cancel();
      super.dispose();
    }

    Future<void> _load() async {
      final conv = getIt<ConversationService>();
      final loaded = await conv.getConversation(widget.conversationId);
      final msgs = await conv.getConversationMessages(widget.conversationId);
      final branches = await conv.getAllForkPointBranches(widget.conversationId);
      if (!mounted) return;
      setState(() {
        _conversation = loaded;
        _messages = msgs;
        _branchesByParent = branches;
      });
    }

    void _onForkCreated(String parentMessageId) async {
      // Refresh branches map; cheap because the query is batched.
      final branches = await getIt<ConversationService>()
          .getAllForkPointBranches(widget.conversationId);
      if (!mounted) return;
      setState(() => _branchesByParent = branches);
    }

    @override
    Widget build(BuildContext context) {
      return Column(
        children: [
          if (widget.contextCard != null) widget.contextCard!,
          Expanded(
            child: ListView.builder(
              itemCount: _messages.length,
              itemBuilder: (context, idx) {
                final m = _messages[idx];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: BlockMarkdownBody(
                        data: m.content,
                        onChipsExtracted: m.type == MessageType.ai
                            ? (chips) {
                                if (!mounted) return;
                                setState(() => _chipsByMessage[m.id] = chips);
                              }
                            : null,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      );
    }
  }
  ```

- [ ] **Step 4: Run — confirm pass**

  ```bash
  flutter test test/widgets/chat_panel_test.dart
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add lib/widgets/chat_panel.dart test/widgets/chat_panel_test.dart test/widgets/chat_panel_test.mocks.dart
  git commit -m "feat(chat): add ChatPanel skeleton with message list and contextCard"
  ```

---

### Task 16: Wire branch strip + chip footer into ChatPanel per-message

**Files:**
- Modify: `lib/widgets/chat_panel.dart`
- Test: extend `test/widgets/chat_panel_test.dart`

- [ ] **Step 1: Write the failing test**

  Append to `test/widgets/chat_panel_test.dart`:

  ```dart
  testWidgets('renders MessageBranchStrip below messages with multiple children', (tester) async {
    when(mockConv.getConversation('conv-1'))
        .thenAnswer((_) async => Conversation(id: 'conv-1', title: 'T', noteIds: const ['note-X']));
    when(mockConv.getConversationMessages('conv-1'))
        .thenAnswer((_) async => [
              ConversationMessage(
                id: 'm1', conversationId: 'conv-1',
                type: MessageType.user, content: 'Q?',
                timestamp: DateTime.now(),
              ),
            ]);
    when(mockConv.getAllForkPointBranches('conv-1'))
        .thenAnswer((_) async => {
              'm1': [
                ConversationBranchSummary(
                  conversationId: 'child-a', title: 'Child A',
                  forkPointMessageId: 'm1', firstChildMessageId: 'cm1',
                  noteIds: const ['note-X'],
                ),
                ConversationBranchSummary(
                  conversationId: 'child-b', title: 'Child B',
                  forkPointMessageId: 'm1', firstChildMessageId: 'cm2',
                  noteIds: const ['note-X'],
                ),
              ],
            });
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatPanel(
          conversationId: 'conv-1',
          isStreaming: false,
          onActiveConversationChanged: (_) {},
          onSendUserPrompt: (_, __) async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Child A'), findsOneWidget);
    expect(find.text('Child B'), findsOneWidget);
  });
  ```

- [ ] **Step 2: Run — confirm fail**

  ```bash
  flutter test test/widgets/chat_panel_test.dart
  ```

- [ ] **Step 3: Add branch strip + chip footer to message render**

  In `lib/widgets/chat_panel.dart`, modify the `itemBuilder` to render `MessageBranchStrip` and `ChipsFooter` below each message:

  ```dart
  itemBuilder: (context, idx) {
    final m = _messages[idx];
    final branches = _branchesByParent[m.id] ?? const [];
    final chipsExpected = _isChipsExpected();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: BlockMarkdownBody(
            data: m.content,
            onChipsExtracted: m.type == MessageType.ai
                ? (chips) {
                    if (!mounted) return;
                    setState(() => _chipsByMessage[m.id] = chips);
                  }
                : null,
          ),
        ),
        // Chip footer (above branch strip per spec).
        if (m.type == MessageType.ai)
          ChipsFooter(
            chips: _chipsByMessage[m.id],
            isStreaming: widget.isStreaming && idx == _messages.length - 1,
            isExpected: chipsExpected,
            onChipTap: widget.isStreaming ? null : (chip) => _handleChipTap(m.id, chip),
          ),
        if (branches.isNotEmpty)
          MessageBranchStrip(
            branches: branches,
            activeConversationId: widget.conversationId,
            activeNoteIds: _conversation?.noteIds ?? const [],
            disabled: widget.isStreaming,
            onSwitchBranch: (newId, _) => widget.onActiveConversationChanged(newId),
          ),
      ],
    );
  },
  ```

  Add the helper:

  ```dart
  bool _isChipsExpected() {
    final conv = getIt<ConversationService>();
    return conv.skillsEnabled &&
        conv.skillIndex.values.any((s) => s.defaultAction != null);
  }

  Future<void> _handleChipTap(String parentMessageId, ChipAction chip) async {
    // Wired in Task 17.
  }
  ```

- [ ] **Step 4: Run — confirm pass**

  ```bash
  flutter test test/widgets/chat_panel_test.dart
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add lib/widgets/chat_panel.dart test/widgets/chat_panel_test.dart
  git commit -m "feat(chat): wire MessageBranchStrip and ChipsFooter into ChatPanel"
  ```

---

### Task 17: Wire chip taps + chip preview popover into ChatPanel

**Files:**
- Modify: `lib/widgets/chat_panel.dart`
- Test: extend `test/widgets/chat_panel_test.dart`

- [ ] **Step 1: Write the test**

  ```dart
  testWidgets('chip tap fires ChipTapHandler with onSendUserPrompt', (tester) async {
    when(mockConv.getConversation('conv-1'))
        .thenAnswer((_) async => Conversation(id: 'conv-1', title: 'T', noteIds: []));
    final aiMsg = ConversationMessage(
      id: 'mAI', conversationId: 'conv-1',
      type: MessageType.ai,
      content: '''Reply.
  ```chips
  ## explain X
  You are a tutor. Explain X.
  ```''',
      timestamp: DateTime.now(),
    );
    when(mockConv.getConversationMessages('conv-1'))
        .thenAnswer((_) async => [aiMsg]);
    when(mockConv.getAllForkPointBranches('conv-1')).thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(true);
    // Build a stub skill index containing a default-action skill.
    final stubMeta = SkillMetadata(
      noteId: 'n', skillRef: 's', name: 'S', description: 'd',
      enabled: true, defaultAction: 'something');
    when(mockConv.skillIndex).thenReturn({'n': stubMeta});
    when(mockFork.forkFromMessageInContext(
      forkFromMessageId: anyNamed('forkFromMessageId'),
      sourceConversationId: anyNamed('sourceConversationId'),
      suggestedTitle: anyNamed('suggestedTitle'),
    )).thenAnswer((_) async => Conversation(id: 'forked', title: 'explain X', noteIds: []));
    when(mockConv.addUserMessage(
      conversationId: anyNamed('conversationId'),
      content: anyNamed('content'),
    )).thenAnswer((_) async => ConversationMessage(
      id: 'umsg', conversationId: 'forked',
      type: MessageType.user, content: 'You are a tutor. Explain X.',
      timestamp: DateTime.now(),
    ));

    String? sentPrompt;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatPanel(
          conversationId: 'conv-1',
          isStreaming: false,
          onActiveConversationChanged: (_) {},
          onSendUserPrompt: (_, p) async => sentPrompt = p,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('explain X'));
    await tester.pumpAndSettle();
    expect(sentPrompt, 'You are a tutor. Explain X.');
  });
  ```

- [ ] **Step 2: Run — confirm fail**

  ```bash
  flutter test test/widgets/chat_panel_test.dart
  ```

- [ ] **Step 3: Wire ChipTapHandler into `_handleChipTap`**

  In `lib/widgets/chat_panel.dart`, replace the placeholder body:

  ```dart
  Future<void> _handleChipTap(String parentMessageId, ChipAction chip) async {
    await ChipTapHandler().handle(
      parentMessageId: parentMessageId,
      chip: chip,
      sourceConversationId: widget.conversationId,
      onSendUserPrompt: widget.onSendUserPrompt,
    );
  }
  ```

  Add the import:

  ```dart
  import '../services/chip_tap_handler.dart';
  ```

- [ ] **Step 4: Wire chip-preview popover (long-press)**

  Pass `onChipLongPress` to `ChipsFooter`:

  ```dart
  ChipsFooter(
    // ... existing args
    onChipLongPress: (chip, anchorKey) => _showChipPreview(chip, anchorKey),
  ),
  ```

  Add the method:

  ```dart
  OverlayEntry? _activePreview;

  void _showChipPreview(ChipAction chip, GlobalKey anchorKey) {
    _activePreview?.remove();
    final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final rect = pos & box.size;
    _activePreview = ChipPreviewPopover.show(
      context: context, anchorRect: rect, chip: chip,
    );
    Future.delayed(const Duration(seconds: 6), () {
      _activePreview?.remove();
      _activePreview = null;
    });
  }
  ```

  Add the import:

  ```dart
  import 'chip_preview_popover.dart';
  ```

- [ ] **Step 5: Run — confirm pass**

  ```bash
  flutter test test/widgets/chat_panel_test.dart
  ```

- [ ] **Step 6: Commit**

  ```bash
  git add lib/widgets/chat_panel.dart test/widgets/chat_panel_test.dart
  git commit -m "feat(chat): wire chip taps and long-press preview into ChatPanel"
  ```

---

### Task 18: ChatPanel `initialMessageId` scroll + `onActiveConversationChanged` propagation

**Files:**
- Modify: `lib/widgets/chat_panel.dart`
- Test: extend `test/widgets/chat_panel_test.dart`

- [ ] **Step 1: Write the test**

  ```dart
  testWidgets('scrolls to initialMessageId on mount', (tester) async {
    when(mockConv.getConversation('conv-1'))
        .thenAnswer((_) async => Conversation(id: 'conv-1', title: 'T', noteIds: []));
    final messages = List.generate(40, (i) => ConversationMessage(
      id: 'm$i', conversationId: 'conv-1',
      type: i.isEven ? MessageType.user : MessageType.ai,
      content: 'Message $i',
      timestamp: DateTime.now(),
    ));
    when(mockConv.getConversationMessages('conv-1'))
        .thenAnswer((_) async => messages);
    when(mockConv.getAllForkPointBranches('conv-1'))
        .thenAnswer((_) async => const {});
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatPanel(
          conversationId: 'conv-1',
          initialMessageId: 'm20',
          isStreaming: false,
          onActiveConversationChanged: (_) {},
          onSendUserPrompt: (_, __) async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // Message 20 should be visible.
    expect(find.text('Message 20'), findsOneWidget);
    // Message 0 should NOT be on screen (scrolled off).
    expect(find.text('Message 0'), findsNothing);
  });
  ```

- [ ] **Step 2: Implement scroll logic**

  In ChatPanel, replace the `ListView.builder` with one driven by a `ScrollController`. After data loads, if `initialMessageId` is set, compute the viewport-top scroll target and animate to it:

  ```dart
  final ScrollController _scrollController = ScrollController();

  Future<void> _scrollToInitialMessage() async {
    final id = widget.initialMessageId;
    if (id == null) return;
    final idx = _messages.indexWhere((m) => m.id == id);
    if (idx < 0 || !_scrollController.hasClients) return;
    // Estimated row height; refined by Task 21 polish if needed.
    const estimated = 120.0;
    final target = (idx * estimated).clamp(
      0.0, _scrollController.position.maxScrollExtent);
    _scrollController.jumpTo(target);
  }
  ```

  After `setState` in `_load()`, schedule `_scrollToInitialMessage` post-frame:

  ```dart
  WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToInitialMessage());
  ```

  Also handle viewport-top scroll on branch switch in `MessageBranchStrip.onSwitchBranch`. The host receives the new conversationId; it will rebuild ChatPanel with that conversationId AND `initialMessageId = forkPointMessageId`. Update the `onSwitchBranch` callback wiring:

  ```dart
  if (branches.isNotEmpty)
    MessageBranchStrip(
      // ...
      onSwitchBranch: (newId, _) {
        widget.onActiveConversationChanged(newId);
        // Host should re-render ChatPanel with initialMessageId = m.id
        // to scroll the fork-point to viewport top in the new branch.
      },
    ),
  ```

  (The host wires `initialMessageId` in Task 19. ChatPanel just notifies.)

- [ ] **Step 3: Run — confirm pass**

  ```bash
  flutter test test/widgets/chat_panel_test.dart
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add lib/widgets/chat_panel.dart test/widgets/chat_panel_test.dart
  git commit -m "feat(chat): scroll to initialMessageId on mount; propagate branch switch"
  ```

---

### Task 19: ChatPanel forkCreatedStream cache invalidation test

**Goal:** Verify a stream emission causes a branch-list refresh.

**Files:**
- Test: extend `test/widgets/chat_panel_test.dart`

(Implementation already in Task 15; this task adds explicit test coverage.)

- [ ] **Step 1: Write the test**

  ```dart
  testWidgets('refreshes branches when forkCreatedStream emits', (tester) async {
    final controller = StreamController<String>.broadcast();
    when(mockFork.forkCreatedStream).thenAnswer((_) => controller.stream);
    when(mockConv.getConversation('conv-1'))
        .thenAnswer((_) async => Conversation(id: 'conv-1', title: 'T', noteIds: []));
    when(mockConv.getConversationMessages('conv-1'))
        .thenAnswer((_) async => [
              ConversationMessage(
                id: 'm1', conversationId: 'conv-1',
                type: MessageType.user, content: 'Q?',
                timestamp: DateTime.now(),
              ),
            ]);
    int callCount = 0;
    when(mockConv.getAllForkPointBranches('conv-1')).thenAnswer((_) async {
      callCount++;
      return callCount == 1 ? const {} : {
        'm1': [
          ConversationBranchSummary(
            conversationId: 'new-child', title: 'New Child',
            forkPointMessageId: 'm1', firstChildMessageId: 'cm',
            noteIds: const [],
          ),
          ConversationBranchSummary(
            conversationId: 'sibling', title: 'Sibling',
            forkPointMessageId: 'm1', firstChildMessageId: 'cm2',
            noteIds: const [],
          ),
        ],
      };
    });
    when(mockConv.skillsEnabled).thenReturn(false);
    when(mockConv.skillIndex).thenReturn(const {});

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatPanel(
          conversationId: 'conv-1',
          isStreaming: false,
          onActiveConversationChanged: (_) {},
          onSendUserPrompt: (_, __) async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('New Child'), findsNothing);
    controller.add('m1');
    await tester.pumpAndSettle();
    expect(find.text('New Child'), findsOneWidget);
    await controller.close();
  });
  ```

- [ ] **Step 2: Run — confirm pass**

  ```bash
  flutter test test/widgets/chat_panel_test.dart
  ```

  Expected: PASS (implementation from Task 15 already supports this).

- [ ] **Step 3: Commit**

  ```bash
  git add test/widgets/chat_panel_test.dart
  git commit -m "test(chat): cover forkCreatedStream-driven branch refresh"
  ```

---

## Phase 5: Host Integration — Immersive Screen

### Task 20: Host ChatPanel inside immersive_note_screen's chat slot

**Goal:** Replace the immersive screen's existing message list with ChatPanel. The send box, model picker, attachment handling, agent-conflict guards, and streaming state all stay in the immersive screen — they're plumbed into ChatPanel via `isStreaming` and `onSendUserPrompt`.

**Files:**
- Modify: `lib/screens/immersive_note_screen.dart`
- (Existing immersive screen tests should pass with no changes.)

- [ ] **Step 1: Identify the immersive chat-slot insertion point**

  Read `lib/screens/immersive_note_screen.dart` and locate the message-list rendering region within the chat slot. Likely a `ListView.builder` over `_messages` similar to chat-screen. Note its surrounding `_isSending`/`_isGenerating` flag and the `_sendMessage` orchestration entry point.

- [ ] **Step 2: Replace the message-list region with `ChatPanel`**

  Replace the existing `ListView.builder` in the chat slot with:

  ```dart
  Expanded(
    child: ChatPanel(
      conversationId: _conversation!.id,
      initialMessageId: _initialMessageIdForBranchSwitch,
      isStreaming: _isSending,
      onActiveConversationChanged: (newConvId) {
        // Re-load conversation and message list for the new branch.
        // Reuse existing _switchConversation logic at line ~5656.
        _switchConversation(newConvId);
        setState(() {
          // Also remember the fork-point so ChatPanel scrolls there on rebuild.
          _initialMessageIdForBranchSwitch = _lastTappedForkPointMessageId;
        });
      },
      onSendUserPrompt: (convId, prompt) async {
        // Adapter: route through the existing _sendMessage chain.
        // Set the input field text, then trigger _sendMessage.
        // Implementation will need a small refactor to allow programmatic
        // prompt-text injection — extract _sendMessage's body that takes
        // an explicit prompt string instead of reading from the controller.
        await _sendMessageWithText(prompt);
      },
    ),
  ),
  ```

  Add the new state fields near other `_isSending` etc.:

  ```dart
  String? _initialMessageIdForBranchSwitch;
  String? _lastTappedForkPointMessageId;
  ```

  Capture `_lastTappedForkPointMessageId` inside `MessageBranchStrip.onSwitchBranch` — easiest path is to wrap the callback in ChatPanel's host adapter, but ChatPanel doesn't yet expose the fork-point message ID. Add a TODO and resolve in Task 21 polish: **extend `onActiveConversationChanged` signature to also pass `forkPointMessageId`**.

  For now, also implement `_sendMessageWithText`: extract the text-input-reading from `_sendMessage` (`final content = _messageController.text;`), accept the text as a parameter, and call the rest of the chain. Concretely:

  ```dart
  Future<void> _sendMessageWithText(String prompt) async {
    _messageController.text = prompt;
    await _sendMessage();
  }
  ```

  This is a temporary minimal adapter; the v1.1 consolidation will properly extract a shared send service.

- [ ] **Step 3: Update `onActiveConversationChanged` signature in ChatPanel**

  In `lib/widgets/chat_panel.dart`, change:

  ```dart
  final ValueChanged<String> onActiveConversationChanged;
  ```

  to:

  ```dart
  final void Function(String newConversationId, String forkPointMessageId)
      onActiveConversationChanged;
  ```

  Update call site in the strip wiring:

  ```dart
  onSwitchBranch: (newId, _) =>
      widget.onActiveConversationChanged(newId, m.id),
  ```

  Update existing tests to match the new signature (any test passing `(_) => ...` becomes `(_, __) => ...`).

- [ ] **Step 4: Wire `_initialMessageIdForBranchSwitch`**

  In immersive screen:

  ```dart
  onActiveConversationChanged: (newConvId, forkPointMessageId) {
    _switchConversation(newConvId);
    setState(() {
      _initialMessageIdForBranchSwitch = forkPointMessageId;
    });
  },
  ```

- [ ] **Step 5: Run all tests**

  ```bash
  flutter test
  ```

  Expected: all pass. If existing immersive tests fail, investigate which behavior the ChatPanel substitution changed and adjust.

- [ ] **Step 6: Manual smoke — open the app, enter immersive on a note, send a message, fork, verify branch strip appears**

  ```bash
  flutter run -d macos
  ```

  Manual check:
  - Send a chat message in immersive
  - Use existing fork affordance to fork the conversation
  - Verify branch strip appears below the fork-point message
  - Tap the sibling row → message list switches

- [ ] **Step 7: Commit**

  ```bash
  git add lib/screens/immersive_note_screen.dart lib/widgets/chat_panel.dart test/widgets/chat_panel_test.dart
  git commit -m "feat(immersive): host ChatPanel in chat slot with branch switching"
  ```

---

## Phase 6: Marker Sheet Upgrade

### Task 21: Branch InNoteMarkerPreview on `marker.type` (annotation preserved)

**Files:**
- Modify: `lib/widgets/in_note_marker_preview.dart`
- Test: `test/widgets/in_note_marker_preview_test.dart` (new or extended)

- [ ] **Step 1: Write the test**

  ```dart
  // test/widgets/in_note_marker_preview_test.dart
  import 'package:flutter/material.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:note_synapse/models/in_note_marker.dart';
  import 'package:note_synapse/widgets/in_note_marker_preview.dart';

  void main() {
    testWidgets('annotation marker uses the legacy preview path', (tester) async {
      final m = InNoteMarker.forNote(
        index: 0, charStart: 0, charEnd: 5,
        conversationId: 'c', messageId: 'm',
        type: MarkerType.annotation,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: InNoteMarkerPreview(marker: m)),
      ));
      await tester.pumpAndSettle();
      // Legacy path renders an "Open Conversation" button (existing behavior).
      // Substitute with a key the legacy code uses; if not present today,
      // add `key: const ValueKey('legacy-annotation-preview')` to the
      // top-level container of the legacy code path.
      expect(find.byKey(const ValueKey('legacy-annotation-preview')),
          findsOneWidget);
    });

    testWidgets('AI marker uses the ChatPanel-hosted path', (tester) async {
      // Setup mock services as in chat_panel_test.dart...
      // Tag the new code path with key: ValueKey('ai-marker-chat-panel-host').
      // ... (verify findsOneWidget on that key)
    });
  }
  ```

- [ ] **Step 2: Run — confirm fail (no keys yet)**

  ```bash
  flutter test test/widgets/in_note_marker_preview_test.dart
  ```

- [ ] **Step 3: Refactor InNoteMarkerPreview to branch on `marker.type`**

  In `lib/widgets/in_note_marker_preview.dart`, restructure the build method:

  ```dart
  @override
  Widget build(BuildContext context) {
    if (widget.marker.type == MarkerType.annotation) {
      return _buildLegacyAnnotationPreview();
    }
    return _buildAiMarkerChatPanelHost();
  }

  Widget _buildLegacyAnnotationPreview() {
    // Existing render code, wrapped in:
    return Container(
      key: const ValueKey('legacy-annotation-preview'),
      child: /* existing widget tree */,
    );
  }

  Widget _buildAiMarkerChatPanelHost() {
    // Implemented in Task 22.
    return Container(
      key: const ValueKey('ai-marker-chat-panel-host'),
      child: const Center(child: Text('TODO: ChatPanel host')),
    );
  }
  ```

- [ ] **Step 4: Run — confirm `legacy-annotation-preview` test passes**

  ```bash
  flutter test test/widgets/in_note_marker_preview_test.dart
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add lib/widgets/in_note_marker_preview.dart test/widgets/in_note_marker_preview_test.dart
  git commit -m "refactor(marker): branch preview on marker.type; preserve annotation path"
  ```

---

### Task 22: MarkerChatPanelHost — wraps ChatPanel with text input + model picker + send button

**Files:**
- Create: `lib/widgets/marker_chat_panel_host.dart`
- Test: `test/widgets/marker_chat_panel_host_test.dart`
- Modify: `lib/widgets/in_note_marker_preview.dart` (use the new host)

- [ ] **Step 1: Write the test**

  ```dart
  // test/widgets/marker_chat_panel_host_test.dart
  // Verifies the host renders ChatPanel + a text input + ModelSelectorButton + send button.
  // Verifies tapping send invokes the supplied send-handler with the text.
  ```

  Pattern after `chat_panel_test.dart` for service mocks; assert `find.byType(TextField)`, `find.byType(ModelSelectorButton)`, send button tap fires handler.

- [ ] **Step 2: Implement MarkerChatPanelHost**

  ```dart
  // lib/widgets/marker_chat_panel_host.dart
  import 'package:flutter/material.dart';
  import '../models/in_note_marker.dart';
  import '../models/model_configuration.dart';
  import 'chat_panel.dart';
  import 'model_selector_button.dart';

  class MarkerChatPanelHost extends StatefulWidget {
    final InNoteMarker marker;
    final String resolvedConversationId;
    final Widget contextCard;
    final void Function(String newConversationId) onActiveConversationChanged;

    const MarkerChatPanelHost({
      super.key,
      required this.marker,
      required this.resolvedConversationId,
      required this.contextCard,
      required this.onActiveConversationChanged,
    });

    @override
    State<MarkerChatPanelHost> createState() => _MarkerChatPanelHostState();
  }

  class _MarkerChatPanelHostState extends State<MarkerChatPanelHost> {
    final _textController = TextEditingController();
    bool _isSending = false;
    ModelConfiguration? _selectedModel;
    String? _initialMessageId;

    @override
    void initState() {
      super.initState();
      _initialMessageId = widget.marker.messageId;
    }

    @override
    Widget build(BuildContext context) {
      return Column(
        key: const ValueKey('ai-marker-chat-panel-host'),
        children: [
          Expanded(
            child: ChatPanel(
              conversationId: widget.resolvedConversationId,
              initialMessageId: _initialMessageId,
              contextCard: widget.contextCard,
              isStreaming: _isSending,
              onActiveConversationChanged: (newId, forkPoint) {
                widget.onActiveConversationChanged(newId);
                setState(() => _initialMessageId = forkPoint);
              },
              onSendUserPrompt: _sendPrompt,
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  ModelSelectorButton(
                    selected: _selectedModel,
                    onChanged: (m) => setState(() => _selectedModel = m),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      decoration: const InputDecoration(
                        hintText: 'Continue this exploration...',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      enabled: !_isSending,
                      onSubmitted: _isSending ? null : _onSubmit,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _isSending
                        ? null
                        : () => _onSubmit(_textController.text),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    Future<void> _onSubmit(String text) async {
      final t = text.trim();
      if (t.isEmpty) return;
      _textController.clear();
      await _sendPrompt(widget.resolvedConversationId, t);
    }

    Future<void> _sendPrompt(String conversationId, String prompt) async {
      setState(() => _isSending = true);
      try {
        // Marker-sheet send orchestration: addUserMessage then invoke AI engine.
        // Implemented in Task 23.
        await _runSendOrchestration(conversationId, prompt);
      } finally {
        if (mounted) setState(() => _isSending = false);
      }
    }

    Future<void> _runSendOrchestration(String conversationId, String prompt) async {
      // TODO Task 23: hook into ConversationAiEngine for the actual AI call.
      // For now this is a stub that completes immediately.
    }

    @override
    void dispose() {
      _textController.dispose();
      super.dispose();
    }
  }
  ```

- [ ] **Step 3: Wire MarkerChatPanelHost into InNoteMarkerPreview**

  Replace the `_buildAiMarkerChatPanelHost` placeholder body with:

  ```dart
  Widget _buildAiMarkerChatPanelHost() {
    // resolveLastViewed implemented in Task 24
    final convId = _resolveLastViewed(widget.marker);
    return MarkerChatPanelHost(
      marker: widget.marker,
      resolvedConversationId: convId,
      contextCard: _buildContextCard(),
      onActiveConversationChanged: _persistLastViewed,
    );
  }

  Widget _buildContextCard() {
    // Reuse the static layout pieces from the legacy preview:
    // image + original user message text. Pinned at top of the message list.
    return Card(/* ... */);
  }

  void _persistLastViewed(String newConversationId) async {
    // Implemented in Task 24.
  }
  ```

  Stub `_resolveLastViewed` to just return `widget.marker.conversationId` for now (Task 24 implements the real fallback).

- [ ] **Step 4: Run tests, fix what breaks**

  ```bash
  flutter test test/widgets/marker_chat_panel_host_test.dart test/widgets/in_note_marker_preview_test.dart
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add lib/widgets/marker_chat_panel_host.dart lib/widgets/in_note_marker_preview.dart test/widgets/marker_chat_panel_host_test.dart
  git commit -m "feat(marker): add MarkerChatPanelHost with text input + model picker"
  ```

---

### Task 23: Wire marker-sheet send orchestration to ConversationAiEngine

**Goal:** Make `_runSendOrchestration` actually trigger an AI reply.

**Files:**
- Modify: `lib/widgets/marker_chat_panel_host.dart`

- [ ] **Step 1: Identify the minimal send chain**

  ```bash
  grep -n "ConversationAiEngine\|generate(" lib/services/conversation_ai_engine.dart lib/screens/immersive_note_screen.dart | head -20
  ```

  Locate `ConversationAiEngine.generate(...)` signature and the immersive-screen invocation pattern (likely simpler than chat-screen because immersive doesn't host attachments either).

- [ ] **Step 2: Implement `_runSendOrchestration`**

  Pattern after the immersive screen's send chain. Roughly:

  ```dart
  Future<void> _runSendOrchestration(String conversationId, String prompt) async {
    final engine = getIt<ConversationAiEngine>();
    final ctx = GenerationContext();
    if (_selectedModel != null) ctx.modelOverride = _selectedModel;
    await engine.generate(
      conversationId: conversationId,
      generationContext: ctx,
      // ... other required params; copy minimal set from immersive screen
    );
    // ChatPanel re-fetches messages on next rebuild via its own state;
    // signal a refresh by toggling a key or calling a refresh method
    // exposed on ChatPanel. (Add a small `refresh()` method via key.)
  }
  ```

  If signaling the refresh is awkward, expose a `GlobalKey<ChatPanelState>` on the host and call a public `reload()` on the panel after AI generation completes. Add `void reload() => _load();` to ChatPanel state.

- [ ] **Step 3: Add `reload()` to ChatPanel**

  In `lib/widgets/chat_panel.dart`:

  ```dart
  // Inside _ChatPanelState
  void reload() => _load();
  ```

- [ ] **Step 4: Manual smoke**

  ```bash
  flutter run -d macos
  ```

  Open a note, create an AI marker (circle a region), tap the marker, type a message in the marker sheet, send. Verify AI reply appears.

- [ ] **Step 5: Commit**

  ```bash
  git add lib/widgets/marker_chat_panel_host.dart lib/widgets/chat_panel.dart
  git commit -m "feat(marker): wire marker-sheet send to ConversationAiEngine"
  ```

---

### Task 24: `resolveLastViewed` fallback + persistence + orphan empty state

**Files:**
- Modify: `lib/widgets/in_note_marker_preview.dart`
- Create: `lib/widgets/marker_orphan_state.dart`
- Modify: `lib/services/note_marker_service.dart` (or wherever marker JSON is persisted) — add update method for `lastViewedConversationId`
- Test: `test/widgets/marker_orphan_state_test.dart`

- [ ] **Step 1: Write the orphan state test**

  ```dart
  // test/widgets/marker_orphan_state_test.dart
  import 'package:flutter/material.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:note_synapse/widgets/marker_orphan_state.dart';

  void main() {
    testWidgets('shows deletion message and delete-marker button', (tester) async {
      bool deleted = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MarkerOrphanState(
            reason: OrphanReason.anchorDeleted,
            onDeleteMarker: () => deleted = true,
          ),
        ),
      ));
      expect(find.textContaining('exploration was deleted'), findsOneWidget);
      await tester.tap(find.text('Delete marker'));
      expect(deleted, isTrue);
    });
  }
  ```

- [ ] **Step 2: Implement MarkerOrphanState**

  ```dart
  // lib/widgets/marker_orphan_state.dart
  import 'package:flutter/material.dart';

  enum OrphanReason { anchorDeleted, conversationDeleted }

  class MarkerOrphanState extends StatelessWidget {
    final OrphanReason reason;
    final VoidCallback onDeleteMarker;
    const MarkerOrphanState({
      super.key,
      required this.reason,
      required this.onDeleteMarker,
    });

    @override
    Widget build(BuildContext context) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(
              reason == OrphanReason.anchorDeleted
                  ? 'This exploration was deleted (anchor message no longer exists).'
                  : 'This exploration was deleted (conversation no longer exists).',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: onDeleteMarker,
              child: const Text('Delete marker'),
            ),
          ],
        ),
      );
    }
  }
  ```

- [ ] **Step 3: Implement `_resolveLastViewed` in InNoteMarkerPreview**

  In `lib/widgets/in_note_marker_preview.dart`, change `_buildAiMarkerChatPanelHost` to a `FutureBuilder`-driven async resolve:

  ```dart
  Widget _buildAiMarkerChatPanelHost() {
    return FutureBuilder<_ResolvedTarget>(
      future: _resolveLastViewed(widget.marker),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final target = snap.data!;
        if (target.orphan != null) {
          return MarkerOrphanState(
            reason: target.orphan!,
            onDeleteMarker: _deleteMarker,
          );
        }
        return MarkerChatPanelHost(
          marker: widget.marker,
          resolvedConversationId: target.conversationId!,
          contextCard: _buildContextCard(),
          onActiveConversationChanged: _persistLastViewed,
        );
      },
    );
  }

  Future<_ResolvedTarget> _resolveLastViewed(InNoteMarker m) async {
    final db = getIt<DatabaseService>();
    // 1. Anchor message must exist somewhere.
    final anchor = await db.getConversationMessage(m.messageId);
    if (anchor == null) {
      return _ResolvedTarget(orphan: OrphanReason.anchorDeleted);
    }
    // 2. lastViewed > original > orphan
    if (m.lastViewedConversationId != null) {
      final c = await db.getConversation(m.lastViewedConversationId!);
      if (c != null) return _ResolvedTarget(conversationId: c.id);
    }
    final original = await db.getConversation(m.conversationId);
    if (original != null) {
      // Clear the stale lastViewedConversationId for next time.
      if (m.lastViewedConversationId != null) {
        await getIt<NoteMarkerService>()
            .updateMarkerLastViewed(m.id, null);
      }
      return _ResolvedTarget(conversationId: original.id);
    }
    return _ResolvedTarget(orphan: OrphanReason.conversationDeleted);
  }

  void _persistLastViewed(String newConversationId) async {
    await getIt<NoteMarkerService>()
        .updateMarkerLastViewed(widget.marker.id, newConversationId);
  }

  Future<void> _deleteMarker() async {
    await getIt<NoteMarkerService>().deleteMarker(widget.marker.id);
    if (mounted) Navigator.of(context).pop();
  }

  class _ResolvedTarget {
    final String? conversationId;
    final OrphanReason? orphan;
    _ResolvedTarget({this.conversationId, this.orphan});
  }
  ```

- [ ] **Step 4: Add `updateMarkerLastViewed` and `deleteMarker` to NoteMarkerService**

  In `lib/services/note_marker_service.dart`, add (or verify exists):

  ```dart
  Future<void> updateMarkerLastViewed(String markerId, String? newConvId) async {
    // Read marker JSON from notes/attachments metadata, mutate
    // lastViewedConversationId, write back. Use existing helper that
    // walks marker storage; if none exists, search both note.metadata
    // and attachment.metadata for the marker by ID.
  }

  Future<void> deleteMarker(String markerId) async {
    // Existing path or new — remove marker from its host JSON metadata.
  }
  ```

  If `NoteMarkerService` doesn't exist or these methods aren't there, add them and unit-test them in `test/services/note_marker_service_test.dart` (test by writing a marker, calling update, reading back).

- [ ] **Step 5: Run all tests**

  ```bash
  flutter test
  ```

- [ ] **Step 6: Manual smoke — orphan tiers**

  ```bash
  flutter run -d macos
  ```

  Test each orphan path manually:
  - Anchor deleted: open AI marker, then delete the user message via dev tools; reopen marker → orphan state with delete button.
  - Conversation deleted: open AI marker, delete the conversation; reopen → orphan state.
  - Happy path: regular AI marker → ChatPanel loads.

- [ ] **Step 7: Commit**

  ```bash
  git add lib/widgets/in_note_marker_preview.dart lib/widgets/marker_orphan_state.dart lib/services/note_marker_service.dart test/widgets/marker_orphan_state_test.dart
  git commit -m "feat(marker): add resolveLastViewed fallback chain with orphan empty state"
  ```

---

## Phase 7: Final Verification

### Task 25: Compliance smoke + Monday-morning self-test + ship

**Goal:** Verify chip emission compliance on real models and walk through the full reading-flow.

**Files:** No code changes (or small fixes that emerge).

- [ ] **Step 1: Chip-emission compliance test on cloud model**

  Create a small skill note with `default_action`, enable it, send 5-10 representative paper-reading prompts. For each AI reply:
  - Verify a ` ```chips ` block appears.
  - Verify each chip has both a label and a non-trivial prompt body (length > label length + 20 chars OR contains a persona phrase like "you are").

  Record results in `.claude/plans/2026-04-29-compliance-results.md`. Cloud target: ≥90% emission rate.

- [ ] **Step 2: Chip-emission compliance test on local model**

  Same test with the user's primary local model (likely gemma 3n). Record baseline compliance. **Do not re-architecture** if compliance is poor — document as a known limit per spec Open Question #2.

- [ ] **Step 3: Monday-morning self-test (full reading flow)**

  Pick a real PDF paper. Walk through the spec's Success Criteria substrate flow end-to-end:

  - [ ] Open immersive on the PDF
  - [ ] Circle a paragraph → marker created → AI reply in chat slot
  - [ ] Tap a chip → fork created → AI replies in new branch
  - [ ] Verify branch strip appears below the original AI message
  - [ ] Tap sibling row → branches switch; fork-point scrolls to viewport top
  - [ ] Try a sibling associated with a different document → confirm dialog appears
  - [ ] Close immersive
  - [ ] Wait (or simulate by quitting/reopening the app)
  - [ ] Re-open the document; tap the marker again
  - [ ] Verify it lands on the last-viewed branch
  - [ ] Verify the `📝 N notes` is NOT present (it's deferred to v1.1)
  - [ ] Verify scratchpad/annotation markers still use the legacy render

  Fix anything broken. Document findings in `.claude/plans/2026-04-29-self-test-results.md`.

- [ ] **Step 4: Run the full test suite**

  ```bash
  flutter test
  flutter analyze
  ```

  Both must be clean.

- [ ] **Step 5: Final commit + PR-ready state**

  ```bash
  git add -A
  git status
  # Inspect — only intended files staged
  git commit -m "feat(marker-subtree): v1 substrate + AI-emitted chips"
  ```

  At this point the v1 is shippable. Open a PR per the project's release pipeline.

---

## Spec Coverage Self-Review

Cross-checked the plan against `2026-04-28-marker-anchored-subtree-design.md`:

| Spec Section | Covered By |
|---|---|
| §1 ChatPanel widget extraction | Tasks 15-19 |
| §1 onSendUserPrompt callback | Task 15 (API), Task 20 (host wiring) |
| §1 isStreaming prop | Task 15 (API), Task 20 (host wiring) |
| §1 Gesture-mediation plan B | Task 0 spike + Task 14 fallback note |
| §1 Mutually exclusive marker-sheet/chat-slot | Existing `DraggableScrollableSheet` behavior preserved — no code change needed; covered implicitly by Task 22 host pattern |
| §2 MessageBranchStrip widget | Task 14 |
| §2 ConversationBranchSummary + getAllForkPointBranches | Task 7 |
| §2 SQL with camelCase columns | Task 7 (verified by EXPLAIN test) |
| §2 Document-swap warning | Task 14 (test + impl) |
| §2 Index requirements verified | Task 7 step 6 |
| §2 forkCreatedStream on ForkService | Task 1 |
| §2 forkFromMessageInContext | Task 1 |
| §2 All four call sites unify | Tasks 1, 2, 3 |
| §3 Active-branch persistence per fork-point (markers) | Task 24 (`updateMarkerLastViewed`) |
| §3 Ephemeral session state for non-marker fork-points | Task 15 (in-memory cache, no persistence) |
| §4 Marker-type branching (annotation preserved) | Task 21 |
| §4 ChatPanel embedded in DraggableScrollableSheet | Task 22 (MarkerChatPanelHost) |
| §4 contextCard pinned at top | Task 15, Task 22 wiring |
| §4 lastViewedConversationId field | Task 4 |
| §4 resolveLastViewed fallback (4-tier) | Task 24 |
| §4 Marker-sheet send box (text + model picker) | Task 22 |
| §4 Send orchestration → ConversationAiEngine | Task 23 |
| §4 Grand-tree button stays in sheet header | No change required (existing sheet header preserved by Task 21 keeping the sheet shell) |
| §5 default_action skill frontmatter | Task 5 |
| §5 System-prompt injection | Task 6 |
| §5 Two-field chip (label + prompt) | Task 8 (model), Task 9 (parser), Task 13 (handler) |
| §5 Markdown H2 emission format | Task 9 (parser test cases) |
| §5 Chips-block parser + strip | Tasks 9, 10 |
| §5 Skeleton during streaming | Task 11 |
| §5 Cross-fade on completion | Task 11 (`AnimatedSwitcher`) |
| §5 Footer order: chips above branch strip | Task 16 (rendering order) |
| §5 Activation predicate | Task 16 (`_isChipsExpected`) |
| §5 Chip preview popover (hover/long-press) | Tasks 12, 17 |
| §5 ChipTapHandler 3-step orchestration | Task 13 |
| §5 Forked title = label, message = prompt | Task 13 (test verifies) |
| §5 Streaming guard on chip taps | Task 16 (`onChipTap: widget.isStreaming ? null : ...`) |
| §5 Multi-skill concatenation deterministic | Task 6 (`compareTo` ordering) |
| §6 Note synergy DEFERRED to v1.1 | Not implemented (correct) |
| Open Q #2 chip emission compliance test | Task 25 |
| Success Criteria substrate flow | Task 25 self-test |
| Success Criteria orphan tiers | Task 24 + Task 25 manual smoke |

**Placeholder scan:** none of the patterns in the "No Placeholders" section appear. All steps have actual code or actual commands.

**Type consistency check:**
- `ChipAction(label, prompt)` — used identically in Tasks 8, 9, 11, 13.
- `ConversationBranchSummary(conversationId, title, forkPointMessageId, firstChildMessageId, noteIds)` — used identically in Tasks 7, 14, 16.
- `ForkService.forkFromMessageInContext({forkFromMessageId, sourceConversationId, suggestedTitle})` — same params in Tasks 1, 2, 3, 13, 17.
- `ChatPanel.onActiveConversationChanged(newConversationId, forkPointMessageId)` — signature change tracked across Tasks 15 → 18 → 20 → 22; tests updated.
- `SkillMetadata.defaultAction` — added in Task 5, consumed in Task 6.

No drift detected.

---

## Plan complete.

Saved to `.claude/plans/2026-04-29-marker-anchored-subtree-implementation.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

**Which approach?**
