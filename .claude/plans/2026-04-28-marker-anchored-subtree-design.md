# Design: Marker-anchored conversation subtree, inline branch strip, AI-emitted action chips

Date: 2026-04-28
Branch: main
Status: DRAFT (revision of /Users/liwen/.gstack/projects/kkspeed-Note-Synapse/liwen-main-design-20260426-234802.md)

## Revision Notes vs. 2026-04-26 design

This revision applies grounding corrections and one substantive feature change.

**Substantive change — skill UX hook (Section 5).** The original design used a separate concept-extraction subsystem: regex tokenizer + local-LLM call to extract noun phrases from each completed AI message, render them as chips, and tap-template into a fork prompt. That is replaced with **AI-emitted chips inside the model's reply** as a fenced ` ```chips ` block. Skills inject a `default_action` instruction into the system prompt that tells the model how to emit chips for that conversation mode.

Chips carry two fields: a short **`label`** (≤5 words, displayed) and a full **`prompt`** (long, persona-laden, sent verbatim as the new user message on tap). The label is what the user sees; the prompt is what the AI receives. Hover (desktop) / long-press (mobile) previews the full prompt before invocation. Emission format: markdown H2 headings as labels, body text under each heading as the prompt — chosen for emission reliability and trivial parsing (split on `## `).

Why the change: the prior design required a second LLM call per AI message, a regex fallback path, concurrency limits, scroll-into-view lifecycle, 2s timeout, no-cancellation discardable-cache, an LLM eval suite — all to produce text that the model itself could emit during its own turn at zero marginal latency. The model also has the conversation context naturally; the extractor didn't. The label/prompt split lets the chip stay visually compact while still carrying the rich persona/calibration instructions that make the next AI turn high-quality.

**Marker-type branching (Section 4).** Original design implied uniform replacement of the marker preview. Updated: the new ChatPanel-hosted experience is for `MarkerType.ai` markers only. `MarkerType.annotation` (scratchpad) markers preserve the existing render — they have no conversation subtree to navigate.

**Marker-sheet send box gains a model picker.** Original design cut the model picker from marker-sheet scope. Updated: the marker sheet's send box reuses `lib/widgets/model_selector_button.dart` so users get the same model-override affordance as the chat-screen and immersive-screen send boxes. Attachments remain deferred.

**Mechanical corrections.**
- SQL column casing in branch-summary query: snake_case → camelCase (`parentMessageId`, `messageId`, `conversationId` per indexes at `database_service.dart:410-413`).
- ChipTapHandler "thin call to send-message path" was hand-waved; the send path is host-orchestrated screen logic (~100 lines in `_sendMessage`). Resolved via `ChatPanel.onSendUserPrompt` host callback — see Section 1.
- `ForkService.forkFromMessage` requires `BuildContext` for context-selection dialog. Resolved via new `forkFromMessageInContext` that all four call sites unify through — see Section 2.
- Streaming flag for ChatPanel was undefined. Resolved as a host-pushed `bool isStreaming` prop — see Section 1.
- `forkCreatedStream` home was inconsistent across sections. Locked to `ForkService`.
- Premise 5 wording fix: dropped the "if it's set on the new conversation entry" qualifier (the flag is a singleton on `ConversationService`, not per-conversation entry).
- Performance Notes "cancellation must be cheap" line dropped — moot now that there is no concept-extraction call to cancel.

## Problem Statement

Note-Synapse has three powerful primitives that don't talk to each other in the way a focused reader would want:

1. **Tree-shaped conversations** — branching is supported via `forkConversation()` + the `message_parents` adjacency list, and a graphview tree screen exists.
2. **Immersive mode + in-note markers** — circling a region in a PDF or text note creates a marker pointing to a single user-message + its immediately-following AI reply.
3. **Agent skills** (shipped in #57) — markdown notes with YAML frontmatter that get prompt-injected into conversations, optionally fired by tag-workflow bindings.

The user's reading flow exposes the gap. Reading a paper, the reader circles a paragraph and asks for math background. The AI lists prerequisites: matrix multiplication, decomposition. The reader wants to dive into each — and then sub-dive — and re-enter that exploration weeks later when re-opening the paper. None of this composes today: a marker points to one turn; sub-dives create disconnected forked conversations; re-entry lands on the original turn with no visible record of the exploration that grew under it.

The right framing is **substrate, not feature**: the marker is the durable, document-anchored entry point to a *branching exploration*. Skills get to lightly customize the default interaction (e.g., a `default_action` skill makes the AI propose a structured set of follow-up "chips" the reader can tap to fork without typing). The whole experience must stay inside immersive mode — leaving immersive for tree exploration breaks the focused-reading promise.

## What Makes This Cool

The novelty isn't any single piece; it's the composition. Note-Synapse is the only place where:

- A **margin annotation grows roots** — the marker isn't a dead pointer to one Q&A, it's the entry point to a branching exploration that can deepen across reading sessions.
- **Branch navigation is inline with messages**, not a separate tree mode. The chat panel renders a small branch strip on each message that has multiple child conversations; tapping a sibling switches the active branch. The tree IS the chat.
- **Skills shape what the AI proposes next**, not just what it knows. A skill's `default_action` instruction tells the model to emit a structured chips block — "explain matrix", "explain calculus", "Explore option 1" — that the reader taps to fork. Skills go from prompt-injection to genuine UX shaping.
- **Subtree nodes can be promoted to durable notes**, and the marker badge reflects that derivation. Reading → exploration → durable note → searchable from anywhere is one continuous loop. *(Deferred to v1.1 — see Section 6.)*

NotebookLM ships an impressive auto-mindmap from sources, but it's one-shot, not document-anchored, not incrementally growable. ChatGPT/Claude have branching but no spatial grounding. Hypothes.is has spatial grounding but dead text. Heptabase has spatial maps but manual + AI-blind. Nothing combines incremental + AI-grown + document-anchored + structurally re-enterable + skill-shaped.

## Constraints

- **Stay in immersive mode.** No screen pushes during exploration. The chat panel is hosted *inside* immersive's existing chat slot. Bird's-eye tree view stays a separate destination, reachable from the app-bar button — explicitly *not* part of the in-immersive flow.
- **Reuse over reinvent.** `forkConversation()` and `forkConversationWithContext()` are the branch-creation primitives. `message_parents` is the relation. Per-conversation skill toggle is the skill scope. Graphview tree screen unchanged. Normalized-rect marker storage unchanged.
- **Visual density budget.** Branch strip lives in the message footer; small font, narrow rows, expected typical fan-out is <5. Long titles must truncate aggressively.
- **No new database tables.** All v1 additions go in existing JSON metadata columns: `notes.metadata` and `attachments.metadata` already host marker payloads. `conversation_messages.metadata` already holds per-message data (sometimes large enough to need chunked-read fallback per `database_service.dart:4093`); v1 does NOT write or read it. The `concept_hash` slot reservation for v1.1 is documentation-only — no code change in v1.

## Premises

1. The substrate is mostly integration work, not new data modeling. The novelty is composition; the pieces exist.
2. Re-entry is the whoa, not real-time exploration. Persistence and re-orientation matter more than chat polish.
3. The first user is the author, this Monday morning, reading the next paper. Monday-usable beats fully-architected.
4. Mergepoint *detection* is valuable; mergepoint *action* (semantic dedup) is not. Detection deferred to v1.1 with a non-breaking `concept_hash` slot reserved.
5. Skills are tagged notes (data), AI-loadable via the existing `load_skill` tool. `enableSkills()` on `ConversationService` is a **singleton** feature flag controlling whether the AI sees the skill index in its prompt — it is global state, not per-conversation. The chip footer activation predicate reads the *same* singleton flag plus the global skill index: `_conversationService.skillsEnabled && skillIndex.values.any((s) => s.defaultAction != null)`. No per-conversation skill state to synchronize on branch switch; no per-node metadata.

## Approaches Considered

(Original A–E preserved. The chosen path remains Approach E with the chip-mechanism change described in Section 5.)

### Approach A: Subtree-anchored markers, no skill changes
Smallest change. Marker gains a subtree-aware preview; tree exploration via the existing graphview screen. Skill API untouched. Ships in 1-2 weeks. Rejected because it doesn't validate the platform claim and offers no friction killer for the typing tax of follow-up exploration.

### Approach B: Subtree + session-skill + mergepoint detection
All of A plus: a session-scoped skill chosen at immersive entry, plus mergepoint pills via local embeddings, plus `default_action` skill frontmatter. Rejected because session-scoped skill is a category error — the same paper wants different interpretive lenses on different paragraphs in the same session.

### Approach C: Generalize tag-workflow into context-bindings
Reframe tag-workflow service as a generic "context → fire skill" primitive, with reading-session start as a new context type. Architecturally elegant but generalizes a primitive that just shipped (#57) before it has been load-tested. Wrong sequencing.

### Approach D: Stay-immersive HUD + per-node skill + note synergy
Full-screen HUD overlay for the tree inside immersive mode, per-node skill picker, note-promotion synergy. Rejected because (a) a HUD overlay still needs real estate and a tree squeezed into 50-75% of screen is unreadable, (b) per-node skill metadata duplicates the existing per-conversation skill toggle now that branches are full conversations.

### Approach E (chosen): Inline branch strip + ChatPanel + AI-emitted chips
The tree IS the chat. No separate tree visualization for navigation. Branch strip lives inside the message card; tapping a sibling switches the active conversation. Marker tap opens the same ChatPanel widget hosted in two places (immersive chat slot, marker sheet). Skills stay per-conversation in the sense that `_skillsEnabled` is set at session entry — but the `default_action` instruction is injected into the AI's system prompt and the AI emits chips inline. Skill UX hook: optional `default_action` field in skill YAML that contains the prompt-injection instruction telling the model how to emit chips for that mode.

## Recommended Approach

**Approach E.**

The composition pieces, in order of independence:

### 1. Extract a unified ChatPanel widget (scoped narrow)

Today, message rendering and the send box are intertwined inside `lib/screens/conversation_chat_screen.dart` (a 41x-touched hot path, currently 3840 lines). To keep the refactor cost bounded, **v1 extracts only the message list + branch strip + active-leaf navigation** — the send box, streaming state, attachment handling, and skill-toggle UI stay in the existing host screens.

`lib/widgets/chat_panel.dart` widget API:

```dart
class ChatPanel extends StatefulWidget {
  final String conversationId;

  /// Scroll-to anchor on mount; null = bottom (newest).
  final String? initialMessageId;

  /// Optional widget pinned at top of the message list. Used by the marker
  /// sheet to show the original snapshot context.
  final Widget? contextCard;

  /// Fired when a branch-strip tap switches branches. Host updates its
  /// own conversationId binding and reactively rebuilds ChatPanel.
  final ValueChanged<String> onActiveConversationChanged;

  /// Streaming state pushed from the host. ChatPanel reads this to disable
  /// fork affordances (branch-strip taps and chip taps) while a message
  /// in this conversation is being generated.
  final bool isStreaming;

  /// Host-provided send handler. Called when the user taps a chip; the
  /// host runs its own send orchestration (model selection warnings,
  /// agent-conflict guards, attachment validation). Returns when the
  /// send has been dispatched (not when streaming completes).
  final Future<void> Function(String conversationId, String prompt)
      onSendUserPrompt;
}
```

Hosts in v1 (TWO, not three):
- `immersive_note_screen.dart` (existing chat slot) — branch strip + chip footer ship here in v1
- `in_note_marker_preview.dart` marker sheet — embeds ChatPanel inside the existing `DraggableScrollableSheet` (see Section 4)

**Deferred to v1.1: `conversation_chat_screen.dart` host.** Verified: immersive_note_screen.dart is 6720 lines and conversation_chat_screen.dart is 3840 lines. Hosting ChatPanel in BOTH within v1 is cross-screen consolidation, not bounded widget work — out of scope.

**Mandatory TODO (post-v1): consolidate chat infrastructure.** `conversation_chat_screen` and `immersive_note_screen` were supposed to share chat infrastructure from the start; they currently duplicate message rendering, send-box logic, attachment handling, streaming state, etc. v1.1+ should consolidate them around the shared ChatPanel widget so the branch strip and chip footer are available in both contexts uniformly. This is real architectural work — separate plan, separate review cycle. Do not let v1 absorb it; do not let v1.1 forget it.

**Host scoping.** Each host owns its own ChatPanel state and cache. The marker sheet ChatPanel and the immersive chat-slot ChatPanel are **mutually exclusive** in immersive mode — opening the marker sheet **collapses** the chat slot (preserving its scroll position and any in-progress draft for restoration on sheet dismiss). Active-branch persistence is keyed by `(hostKind, conversationId)`.

**Streaming signal.** Both existing screens already track send/streaming state in screen-local fields (e.g., `_isSending` at `conversation_chat_screen.dart:974`). The host passes its existing flag in as `isStreaming`. ChatPanel does not derive streaming from the message list — that would duplicate the host's state machine.

**Send orchestration.** `onSendUserPrompt` is the only path by which ChatPanel triggers an AI reply. Today's send paths are 100+ lines of UI orchestration (attachment warnings, model-selection dialogs, tool-orchestration capability checks, agent-conflict guards). Each host wires the callback to its own existing `_sendMessage` orchestration so no guard is bypassed and no orchestration is duplicated inside ChatPanel.

**Gesture-mediation plan B**: if the in-row branch-strip tap conflicts irreparably with existing scroll/long-press gestures (spike in step 1 of Next Steps), the strip degrades to a popover triggered by a small chevron icon at the message footer instead of a full tappable row. The data model and switching behavior are unchanged. **Budget impact**: if plan B fires, add ~1 day for popover positioning and dismiss handling on mobile + desktop.

### 2. Inline branch strip on messages

A new `lib/widgets/message_branch_strip.dart` renders below a message card when `message_parents` shows the message has children belonging to >1 conversation (i.e., it's a fork-point). The strip always renders on **the message that owns the children in `message_parents`** — a single consistent rule, not branched per message-type. Each row:

- Title = the child conversation's existing auto-extracted title
- Active branch (the conversation currently displayed) is visually highlighted
- Tap a sibling row → switch active conversation in the host ChatPanel; scroll so the fork-point message is at the viewport top
- Truncate titles aggressively (one line, ellipsized); small font; thin row height — visual budget assumes typical fan-out <5
- If fan-out >5: render the first 5 + a "+N more" tappable row that expands inline (data already loaded; no extra fetch)

**Service-layer query.** `conversation_service.dart` adds:

```dart
class ConversationBranchSummary {
  final String conversationId;
  final String title;                    // child conversation's existing title
  final String forkPointMessageId;       // the parent message in message_parents
                                         // (i.e. the message rendering this strip)
  final String firstChildMessageId;      // the new conversation's first message
                                         // (used for scroll-target and dedup)
  final List<String> noteIds;            // used by document-swap warning
}

// Returns one entry per child conversation. Deduped by conversationId
// (multiple shared messages in the same child conversation collapse to
// one branch entry).
Future<List<ConversationBranchSummary>> getChildBranches(String parentMessageId);

// Batched variant — single query per ChatPanel mount returning a map
// from parentMessageId -> List<ConversationBranchSummary> for all
// fork-points in the conversation. Used to avoid N+1 queries when
// rendering a message list. Cached in ChatPanel widget state.
Future<Map<String, List<ConversationBranchSummary>>>
    getAllForkPointBranches(String conversationId);
```

SQL sketch for the batched variant (camelCase column names match the actual schema and existing indexes):

```sql
SELECT mp.parentMessageId,
       cmm.conversationId,
       c.title,
       MIN(cm.timestamp) AS first_child_ts,
       (SELECT m2.id
          FROM conversation_messages m2
          JOIN message_parents mp2 ON mp2.messageId = m2.id
          JOIN conversation_message_mapping cmm2 ON cmm2.messageId = m2.id
         WHERE mp2.parentMessageId = mp.parentMessageId
           AND cmm2.conversationId = cmm.conversationId
         ORDER BY m2.timestamp ASC
         LIMIT 1) AS first_child_message_id
  FROM message_parents mp
  JOIN conversation_message_mapping cmm ON cmm.messageId = mp.messageId
  JOIN conversations c                  ON c.id = cmm.conversationId
  JOIN conversation_messages cm         ON cm.id = mp.messageId
 WHERE mp.parentMessageId IN (
       SELECT m.id FROM conversation_messages m
        JOIN conversation_message_mapping mm ON mm.messageId = m.id
       WHERE mm.conversationId = ?  -- the active conversation
 )
 GROUP BY mp.parentMessageId, cmm.conversationId;
```

The branch-strip widget renders one row per child, marking the row matching the current `conversationId` as the active branch (bold + accent color). Users always see "I'm on branch X of N" — no hidden branch points. Per (parent, child-conversation) pair, `first_child_message_id` resolves deterministically to the *earliest-timestamped* shared child message — covering the case where multiple `message_parents` rows share a parent inside the same child conversation. Group result rows in Dart by `parentMessageId` to produce the map. Single query per mount, cached for the lifetime of the ChatPanel.

A second small batched fetch enriches each summary with `noteIds` for the document-swap warning (see below). This can be a separate `getConversationNoteIdsBulk(conversationIds)` method or folded into the same mount-time fetch — implementation detail.

The strip renders ONLY when a parent message has 2 or more children (single-child messages don't get a strip). This keeps message density low for the common linear case while always exposing the full branching structure when it exists.

**Document-swap warning on sibling tap.** Verified at `immersive_note_screen.dart:5656`: `_switchConversation` rewrites note set, note order, active attachment, and reloaded markers. Sibling branches *can* be associated with a different document. Without a guard, tapping a sibling could silently move the reader from paper.pdf to paper2.pdf mid-reading.

The branch-strip widget compares the active document's note IDs against each candidate child branch's note set (carried in `ConversationBranchSummary.noteIds`). If the candidate sibling's note set diverges from the current document, the tap shows a confirm dialog: *"This branch is associated with [other-document]. Switch document?"* The reader confirms or cancels. Same-document siblings switch silently. The dialog is shown only when divergence is detected — no friction for the common case (siblings on the same paper).

**Index requirements** (verified — no migration needed, already at `database_service.dart:410-413`):
- `idx_message_parents_parentMessageId`
- `idx_conversation_message_mapping_messageId`
- `idx_conversation_message_mapping_conversationId`
- `idx_message_parents_messageId`

Run `EXPLAIN QUERY PLAN` on the batched query during step 3; the index check is a task-3 acceptance criterion.

**Cache invalidation channel.** Note-Synapse uses GetIt + Provider with services as ChangeNotifiers in some places. For fork events, expose a broadcast `Stream<String>` on `ForkService` (`forkCreatedStream`) emitting the parent-message ID of any newly created fork. ChatPanel subscribes per-mount and clears the relevant entry from its `getAllForkPointBranches` cache. (Mandatory disposal on widget dispose; standard Flutter discipline.)

**Single fork entry point.** Today there are two: `conversation_chat_screen.dart:2631` calls `_conversationService.forkConversation` directly, and `conversation_tree_screen.dart:438` plus the new chip-tap path use `_forkService.forkFromMessage`. Step 3 includes a small refactor: the chat-screen also routes through `ForkService` via the new `forkFromMessageInContext` method (below). After this, `ForkService` is the only fork entry point and the only place the stream needs to fire from. Coordinate with step 2 (ChatPanel extraction) to avoid merge conflicts in the same hot file.

**New ForkService method — `forkFromMessageInContext`.** The existing `ForkService.forkFromMessage` requires `BuildContext` to show a context-selection dialog when a message exists in multiple conversations. For chip taps and the chat-screen direct-call refactor, the source conversation is already known — there's nothing to disambiguate. Add:

```dart
/// Forks from a message when the source conversation is already known
/// (chip taps, chat-screen direct fork, future programmatic fork callers).
/// Skips the context-selection dialog. Does NOT require BuildContext.
Future<Conversation?> forkFromMessageInContext({
  required String forkFromMessageId,
  required String sourceConversationId,
  required String suggestedTitle,
}) async {
  // Build a ConversationContext from sourceConversationId, then delegate.
  // ...
  return await _conversationService.forkConversationWithContext(
    forkFromMessageId: forkFromMessageId,
    selectedContext: builtContext,
    newTitle: suggestedTitle,
  );
}
```

`forkFromMessage`, `quickFork`, the chip-tap path, and the chat-screen call all delegate to `forkFromMessageInContext` (which in turn calls `forkConversationWithContext`). One underlying path, no duplication. `forkFromMessage` retains the dialog logic and only it owns the `BuildContext` path. After this refactor, `forkCreatedStream` fires from `forkFromMessageInContext` — guaranteed to be reached by every entry point.

### 3. Active-branch persistence per fork-point

Per marker (or, more generally, per fork-point), remember the last-viewed branch. Stored in `InNoteMarker.lastViewedConversationId` (added to the JSON marker payload, no DB migration). Default = the conversation that was active at marker creation. Re-opening the marker restores that branch — Kindle resumption semantics.

For non-marker fork-points (i.e., branches in a regular chat session), use ephemeral in-memory state in ChatPanel for the current session. No need to persist beyond the session for v1.

### 4. Marker tap = open ChatPanel scrolled to userMessageId

**Marker creation is unchanged.** Circling a region in immersive mode still creates a marker pointing to a single user-message via the existing `_saveInNoteMarker` flow. The marker's `messageId` is still the user's question; the AI reply is still the next sequential message at creation time.

What changes is **what "the subtree under a marker" means at re-entry**: it's the set of conversations transitively reachable by following `message_parents` from `marker.messageId` downward. The marker itself never has to know its subtree exists — the subtree *is* the structure that grows naturally as the user forks from messages descended from the marker. This is why the data-model cost is so small: a marker is still a pointer to one message; the tree-shape interpretation lives in the `message_parents` table and the rendering logic.

**Marker type branching — important.** Markers come in two types: `MarkerType.ai` (created by AI conversation flow, the default) and `MarkerType.annotation` (scratchpad annotations created via manual highlight/draw). The new ChatPanel-hosted experience applies **only to `MarkerType.ai` markers**. `MarkerType.annotation` markers preserve the existing render *as-is* — they have no associated conversation subtree, and their value is the captured image/text snapshot, not exploration. The marker-tap dispatcher branches on `marker.type` at the entry point of `in_note_marker_preview.dart`:

```dart
@override
Widget build(BuildContext context) {
  if (widget.marker.type == MarkerType.annotation) {
    return _buildLegacyAnnotationPreview();   // unchanged from today
  }
  return _buildAiMarkerChatPanel();           // new ChatPanel-hosted flow
}
```

For `MarkerType.ai` markers, replace the preview-render code (currently 326 lines, mostly static layout):

- **Keep** the `DraggableScrollableSheet` host shell and its dismiss/expand gesture handling
- **Delete** the static preview render (image + msg + AI reply blocks) **for AI markers only** — the annotation-preview code path stays
- **Embed** ChatPanel as the sheet's child, with:
  - `conversationId =` resolveLastViewed(marker) — see fallback rule below
  - `initialMessageId = marker.messageId`
  - `contextCard` = a small widget rendering the original snapshot image + the original user question (so the reading context isn't lost when scrolled to a deep child node)
  - `onActiveConversationChanged` = persist `marker.lastViewedConversationId = newId`
  - `isStreaming` = wired to the host's existing send-state flag
  - `onSendUserPrompt` = the marker sheet's own send orchestration (see scope below)
- The app-bar button to escape to the grand graphview tree screen stays in place

**Marker sheet host send-flow scope.** The marker sheet does not currently host send orchestration (the existing AI-marker render is read-only). v1 adds a real send box to it so users can continue the conversation in-context — this is what makes the marker sheet a "marker-anchored conversation surface" rather than a peek-only viewer. The send box includes:

- **Text input** + send button
- **Model picker** — reuses the existing `lib/widgets/model_selector_button.dart` widget. Same UI affordance as the chat-screen and immersive-screen send boxes; the user can override the conversation's default model per-message in the marker sheet just like elsewhere.
- **Tap-chip-to-fork** (the chip-tap path naturally invokes `onSendUserPrompt` against the forked conversation)
- **Attachments deferred to v1.1 in marker sheet specifically.** Most marker-anchored flows don't need new attachments mid-conversation (the paper is already a note attached at conversation creation); users who do need them can promote to the chat-screen via the existing "Open Conversation" button. Documented as Open Question #4 below.

**`lastViewedConversationId` fallback** (`resolveLastViewed`):
1. **Anchor message check first.** If `marker.messageId` no longer exists in any conversation_messages row → marker is functionally orphaned regardless of conversation existence. Show "this exploration was deleted" empty state with a "delete marker" affordance. Verified concern: without this check, `_scrollToMessage(marker.messageId)` at `conversation_chat_screen.dart:2590` silently no-ops, leaving the user at a random scroll position with no error indication.
2. If `marker.lastViewedConversationId` is set AND that conversation still exists → use it.
3. Otherwise if `marker.conversationId` exists → use it (and clear the stale `lastViewedConversationId`).
4. Otherwise (anchor message exists but both target conversations deleted) → orphan: same "deleted" empty state with delete-marker affordance.

**Marker sheet header (where derived-note count + grand-tree button live).** The marker sheet does not have a Material `AppBar`; it has a sheet header strip (already present today for the "Open Conversation" button). The existing grand-tree-screen button lives in this sheet header — *not* inside ChatPanel. ChatPanel itself remains chrome-free. *(The "📝 N notes" affordance is part of Section 6 → deferred to v1.1.)*

### 5. Skill UX hook: `default_action` (AI-emitted chips with label + prompt)

**Two-field chip model.** A chip has two fields:

- **`label`** — short tap-target text the user sees. Constraint: ≤5 words, ellipsized at render if exceeded.
- **`prompt`** — the full prompt sent to the AI when tapped. Can be long, persona-laden, calibration-aware (e.g., *"You are a university tutor in computer science. I know basic calculus and linear algebra. Explain transformers at my level, building from my base knowledge step by step."*). Never shown directly in the chip; revealed via hover/long-press preview (see Preview UX below).

The chip's tap action sends the `prompt`, not the `label`. Decoupling the two lets the model emit a concise visual affordance while still controlling the full instruction the next AI turn receives.

**Skill frontmatter.** Single optional `default_action` string field; its value is the prompt-injection text instructing the model how to emit chips for that conversation mode:

```yaml
---
name: "Knowledge Learning"
description: "Explain concepts on tap; propose follow-up explorations"
default_action: |
  After your reply, propose up to 5 follow-up explorations the reader
  might want to dive into next. Output them as a fenced code block with
  language identifier `chips`, formatted as markdown H2 headings followed
  by prompt bodies:

  ```chips
  ## explain matrix multiplication
  You are a university tutor in linear algebra. I'm a curious reader
  with basic high-school math. Explain matrix multiplication at my
  level, starting from why it's defined this way, then working up to
  what it means geometrically.

  ## explain singular value decomposition
  You are a tutor in numerical linear algebra. I understand matrix
  multiplication and basic eigenvectors. Build up SVD from there...
  ```

  Constraints:
  - Each H2 heading is the chip label — keep it ≤5 words.
  - The body text under each heading is the full prompt sent on tap.
  - Do NOT use `##` headings inside prompt bodies (parser splits on them).
  - The block is stripped from your visible reply; only the chips render.
---
```

`skill_service.dart` adds parsing for `default_action` (string field, optional, ignored if absent). The new field is added to `SkillMetadata`:

```dart
class SkillMetadata {
  // ... existing fields
  final String? defaultAction;  // prompt-injection text, null if absent
}
```

**System-prompt injection.** When `_skillsEnabled` is true on `ConversationService`, the existing skill-index prompt builder appends the `default_action` text of every loaded skill that declares one. Multiple skills' instructions concatenate (deterministic order by `skillRef`); the AI synthesizes one chips block from the combined guidance. v1 does NOT add a per-conversation "active default-action skill" picker — that's a v1.1 surface if quality demands it.

**Chips-block parser — in `block_markdown_body.dart`.** The existing block-level renderer system already handles diff/editor/embedded-app blocks. Add a new block type `chips` that:

1. Detects fenced code blocks with language identifier `chips` anywhere in the AI message body.
2. Splits the block body on lines beginning with `## ` (H2 markers). Each split produces one `Chip(label, prompt)`:
   - `label` = trim of the text after `## ` on the heading line.
   - `prompt` = trim of all body text until the next `## ` or end-of-block.
3. Filters out chips with an empty label or empty prompt (defensive against partial emissions).
4. Strips the entire chips block from the rendered markdown so the user never sees the raw fence.
5. Renders a chip footer below the message body — `Wrap` of tap-targets showing each chip's `label` text only.

If multiple `chips` blocks appear in one message (e.g., the AI got creative), concatenate their parsed chips in document order. Empty/malformed blocks → silently skip (no error UI; quiet fail).

A small in-memory `Map<messageId, List<Chip>>` cache on ChatPanel state avoids re-parsing on every rebuild.

**Streaming-time UX.** During AI streaming, raw markdown text is appended progressively. The chips block may appear partially-formed or late in the stream. To avoid jank:

- ChatPanel renders the chips footer **only on completed messages** (not streaming).
- On AI messages where the chip footer is *expected* (active conversation has `_skillsEnabled = true` AND `skillIndex` contains at least one skill with non-null `defaultAction`), render a **skeleton/shimmer placeholder strip** below the message during streaming — same aesthetic as YouTube's pre-load thumbnail blocks (subtle moving gradient). Render 4 placeholder pills of varying widths; this is a fixed visual budget, not a prediction of how many chips the AI will emit.
- On streaming completion: parse the final message text for the chips block. If found → cross-fade skeleton out, fade chips in (200ms). If no block found → cross-fade skeleton out to nothing (no error UI; quiet fail).
- **Footer order when both branch strip and chip footer render on the same message:** chips above, branch strip below. Chips are about *this* message's content (the AI's proposed next steps); the branch strip is about navigation across sibling explorations. The chips are the closer-coupled affordance and belong adjacent to the message body.

**Chip footer activation predicate.** Both the skeleton (during streaming) and the chips footer (after streaming) gate on the **same** singleton check:
```dart
_conversationService.skillsEnabled &&
    skillIndex.values.any((s) => s.defaultAction != null)
```
There is no per-conversation skill state to manage. When the user switches branches via the inline strip, the chip footer's behavior is identical in the new branch — same singleton flag, same global skill index.

**Preview UX.** A chip can carry a long, persona-laden `prompt` that the user is implicitly sending in their name. They get to see it before they invoke it:

- **Desktop (mouse hover):** hovering a chip for >300ms shows a tooltip-style popover anchored above the chip with the full `prompt` text. Popover dismisses on mouse-leave or scroll.
- **Mobile (long-press):** long-press (>400ms) on a chip shows the same popover. Tap-elsewhere or scroll dismisses. Long-press deliberately shadows long-press text-selection in the message above only when the press starts on a chip — chip taps and chip long-presses both originate inside the chip widget's hit zone, so the gesture conflict is contained.
- **Both platforms:** a short tap (no long-press) immediately invokes the chip — no preview, no confirmation. Preview is opt-in; tap is the primary action.

The popover renders the prompt as plain text (no markdown), with a max width so very long prompts wrap. If the prompt exceeds ~40 lines, the popover scrolls internally.

**Tap behavior.** Tap a chip → fires `ChipTapHandler.handle(parentMessageId, chip, sourceConversationId)` where `chip` is the parsed `Chip(label, prompt)` record. ChipTapHandler is a thin coordinator class (~50 lines, `lib/services/chip_tap_handler.dart`) that orchestrates three calls:

1. `forkService.forkFromMessageInContext(forkFromMessageId: parentMessageId, sourceConversationId: sourceConversationId, suggestedTitle: chip.label)` — creates the empty fork; the `label` becomes the new conversation's title (concise, scannable in branch strip and tree view); no `BuildContext` required, no context-selection dialog.
2. `conversationService.addUserMessage(forkedConversation.id, chip.prompt)` — adds the **full prompt** verbatim as the first new user message. The label was *display only*; the prompt is the message.
3. Invokes the host-provided `onSendUserPrompt(forkedConversation.id, chip.prompt)` callback — the host runs its own send orchestration (model-selection warnings, agent-conflict guards) so no guard is bypassed.

ChipTapHandler is testable in isolation (mock the three dependencies). The new branch appears in the source message's branch strip after `ForkService.forkCreatedStream` fires and the cache is invalidated.

**Streaming guard.** Fork affordances (manual fork buttons AND chip taps) are disabled while `ChatPanel.isStreaming` is true. The branch strip and chip footer both check this prop. Re-enabled on stream completion. This is the simplest correctness contract — no race conditions, no half-streamed parents, no queued actions to forget about.

**What's gone vs. the prior design** (deliberate — see Revision Notes at top):

- ❌ `extractConcepts` LLM call — replaced by AI-emitted chips
- ❌ Regex noun-phrase fallback tokenizer
- ❌ Concurrency cap, scroll-into-view trigger, 2s timeout, no-cancel discardable cache
- ❌ Code-side prompt templates per `default_action` enum value (`explain_concept`, `challenge_claim`, `summarize`)
- ❌ LLM eval suite for the extraction prompt
- ❌ Platform-claim degradation feature flag (degradation is automatic now: model emits no chips block → no chips render → no error)

**What stays** (validated by the architectural shift):

- ✅ `default_action` field on skill frontmatter — now a free-form string (the actual prompt-injection text) rather than an enum
- ✅ ChipTapHandler 3-step orchestration (fork + addUserMessage + send via host callback)
- ✅ Chip footer render position (below message body, composes with branch-strip footer)
- ✅ Streaming guard on chip taps and branch-strip taps
- ✅ Multiple-skill behavior: all `defaultAction` strings concatenate; AI synthesizes

**What's new in this revision** (label/prompt split):

- 🆕 Chips have two fields: `label` (display, ≤5 words) and `prompt` (full text sent on tap, can be long and persona-laden)
- 🆕 Emission format: markdown H2 heading per chip, body text under each heading is the prompt
- 🆕 Hover (desktop) / long-press (mobile) preview shows the full prompt before tap-to-invoke
- 🆕 Forked conversation title = `chip.label` (concise, scannable); first user message = `chip.prompt` (full instruction)

This is the friction killer. It validates the platform claim (skills genuinely shape the AI's interaction surface) without inventing per-node skill state, without a second LLM call, and without a brittle structured-output dependency.

### 6. Note synergy — DEFERRED TO v1.1

(Unchanged from prior design — full deferred plan retained for v1.1 reference.)

The note-promotion loop (save AI message as note, marker badge with derived-note count, deletion cascade across 7 callers, deep-link from note back into immersive at the marker) is real product value but does not help PROVE the substrate. Cutting from v1 lets the marker-re-entry + branch-strip + AI-emitted-chips primitive ship and accumulate weeks of real use.

**Removed from v1**: `note_promotion_service.dart`, `InNoteMarker.derivedNoteIds`, backlink fields on notes, badge derived-note chip, deletion cascade, all 7-caller audit work, and the corresponding tests. The `lastViewedConversationId` field on InNoteMarker STAYS (it's required for Section 4 — marker re-entry).

**v1.1 plan** (separate design when ready):

`lib/services/note_promotion_service.dart` exposes:

- `promoteMessageToNote(conversationId, messageId) → noteId` — creates a real note containing the AI message body, stamped with a backlink to its origin (see backlink representation below).
- The created noteId is appended to the originating marker's `derivedNoteIds` list.
- `pruneDerivedNoteId(noteId)` — removes a noteId from any marker's `derivedNoteIds` list. Called by every note-deletion path.

**Backlink representation.** The created note's `metadata` JSON gets:

```dart
String? sourceMarkerId;          // marker UUID, if promoted from a marker subtree
String? sourceConversationId;    // conversation ID; always set
String? sourceMessageId;          // message ID the note was promoted from; always set
```

JSON-only (no schema migration). Note-detail screen renders a backlink chip when `sourceMarkerId` is set: tap → opens source document in immersive mode, scrolls to marker, triggers marker tap.

**Enumerated note-deletion call-sites** (all must invoke `notePromotionService.pruneDerivedNoteId(noteId)`; preferred hookup is inside `DatabaseService.deleteNote` so all callers inherit it):

- `lib/services/database_service.dart` — canonical `deleteNote`
- `lib/screens/notes_screen.dart`
- `lib/screens/note_detail_screen.dart`
- `lib/services/note_annotation_service.dart`
- `lib/services/conversation_service.dart`
- `lib/services/tools/note_tools.dart`
- `lib/services/user_app_runtime_bridge.dart`

**InNoteMarker JSON additions** for v1.1 (in `lib/models/in_note_marker.dart` `toJson`/`fromJson`):

```dart
List<String> derivedNoteIds;       // default: const []
// lastViewedConversationId is ALREADY added in v1 (Section 3)
```

JSON-only; existing markers deserialize with defaults.

**Constraint confirmation**: `notes.metadata` and `attachments.metadata` are stored as JSON-encoded text and read back via `jsonDecode`. New fields are non-breaking. `concept_hash` slot reservation in Section 7 is documentation-only.

## Performance Notes (v1)

- **`getAllForkPointBranches` query.** All four required indexes already exist (verified at `database_service.dart:410-413`); EXPLAIN QUERY PLAN check during step 3 is a final acceptance gate, not a re-engineering risk.
- **`forkCreatedStream` subscriber lifecycle.** Each ChatPanel mount adds a stream subscriber. Mandatory disposal on widget dispose; otherwise rapid host-screen rebuilds leak subscribers and cause stream-listener bloat. Standard Flutter discipline.
- **Chip footer rendering.** Adds one `Wrap` widget below messages where chips are present; the chips block parsing is a single regex scan over the message text on render. Negligible cost. Streaming-time skeleton is one `AnimatedContainer` per chip-eligible message; cost is one running animation per visible AI message currently streaming.
- **No second LLM call per AI message.** This is the largest performance win vs. the prior design — concept-extraction was a per-message inference cost gated only by viewport visibility. AI-emitted chips fold the cost into the main inference (already paid).

## Forward Compatibility (v1.1, no v1 code)

**Mergepoint detection slot.** Reserve a `concept_hash` field name in `conversation_messages.metadata` for v1.1 use. v1 does not write or read it. v1.1 will run a local-embedding pass over node summaries on tree load and surface "also in branch X" pills in the branch strip rows. Documenting the slot here ensures v1.1 doesn't have to migrate.

**Per-conversation default-action skill picker.** If multi-skill concatenation produces noisy chips in practice, v1.1 adds a small picker UI to ChatPanel that lets the user select which `default_action`-bearing skill is active for the current conversation. The selection is stored in conversation metadata. v1's "all-skills-concatenate" behavior remains the default when no selection is made.

## Open Questions

1. **Active-branch persistence scope.** v1 persists last-viewed-branch per marker only; per-fork-point persistence in non-marker contexts is session-ephemeral. If users find themselves wanting Kindle-resumption everywhere (not just markers), this expands to a `user_view_state` map. Defer until usage surfaces the need.
2. **AI chip-emission compliance.** Will local models (gemma 3n in particular, given prior structured-output failures) reliably emit a fenced ` ```chips ` block when instructed? v1 ships either way: graceful degradation is automatic (no block → no chips). The skill system already shows a warning sign for gemma models on skill use; the same expectation applies to chip emission. A small task-5 spike measures emission rates on 5-10 representative messages and documents the baseline. No fallback path planned — bad emission on a model is a model-capability problem, not an architecture problem.
3. **Branch strip when fan-out exceeds 5.** UX assumption is <5. v1 ships with up-to-5 visible + "+N more" tap to expand inline. Re-evaluate from real use.
4. **Marker-sheet attachments.** v1 marker sheet does not support attachments in its send box (text + model picker only). Most reading flows don't need this; users who do can promote to chat-screen via the existing "Open Conversation" button. Re-evaluate after real use.
5. **Marker-sheet send orchestration drift.** The marker sheet now has its own `_sendMessage`-style chain (with model picker). If it drifts from the chat-screen's orchestration (e.g., new tool-orchestration warnings get added there but not here), users get inconsistent behavior across hosts. Mitigation: the v1.1 consolidation TODO explicitly unifies these.

(Removed from prior draft: the "chips activation breadth" question — it's the skill author's responsibility to write `default_action` instructions that only fire chips when chips are appropriate. A skill that says "always present 3 options" is a bad skill, not an architectural failing of v1.)

## Success Criteria

The v1 ships as one tier — the AI-emitted-chips change removed the need for a degradation tier.

**Substrate + platform-claim (must ship together):**
- Reading a paper Monday morning, the author can: circle a paragraph in immersive mode → see an AI reply in the inline ChatPanel (immersive's existing chat slot) → tap an AI-emitted chip below the reply to fork a sub-exploration with that chip's text as the prompt → close immersive mode → re-open the document a week later → tap the original marker → land in the last-viewed branch with the full subtree navigable via the inline branch strip — all without leaving the immersive screen.
- The grand-tree graphview screen still works for bird's-eye exploration, reachable from the app-bar button.
- Tapping a sibling row in the strip switches branches; if the sibling is associated with a different document, the user is warned via confirm dialog before the swap.
- Marker re-entry handles all three orphan tiers cleanly (anchor-message deleted, lastViewed-conversation deleted, both deleted).
- A user-defined skill with a `default_action` instruction makes the AI emit chips inline; chips render below AI messages after streaming completes (with skeleton placeholder during streaming); each chip displays its short `label`; hover/long-press previews the full `prompt`; tap a chip → ChipTapHandler orchestrates fork + addUserMessage(`chip.prompt`) + onSendUserPrompt → new branch appears in the source's branch strip with the `chip.label` as title.
- Quiet-failure path verified: a skill with `default_action` enabled but the model fails to emit a `chips` block → no chips render, no error UI, message renders cleanly.
- Quiet-failure path verified: a skill with `default_action` enabled and the model emits a malformed block (e.g., labels but no prompt bodies) → only well-formed chips render; bad chips are silently dropped.

**Deferred to v1.1 (DO NOT include in v1 success criteria):**
- Note synergy: save-as-note + marker derived-note badge + deletion cascade + immersive deep-link. Section 6 of this doc is the v1.1 plan.
- Chat-screen ChatPanel host: branch strip and chip footer in `conversation_chat_screen.dart`. Cross-screen consolidation is a separate plan.
- Mergepoint detection: the `concept_hash` slot reservation enables this without v1 code.
- Per-conversation default-action skill picker: enabled by demand if multi-skill concatenation is noisy.

## Distribution Plan

Note-Synapse is an existing Flutter app shipped via the standard mobile/desktop distribution channels (TestFlight / Play Store / direct macOS/Linux/web builds). This feature is an in-app feature — no new distribution channel needed. Feature ships under whatever the next version bump is for the existing release pipeline.

## Next Steps

Concrete build tasks, ordered. The order pulls the highest-risk (gesture mediation + ChatPanel extraction) work first; the chip subsystem is now low-risk and lands late.

1. **Spike: gesture mediation for inline branch strip** (1 day). Confirm the branch strip + tap-to-switch interaction doesn't conflict with existing scroll/long-press gestures in the chat list. If conflict can't be resolved, fall back to chevron-icon popover (plan B in Section 1; +1 day if fallback fires).

2. **Add `ForkService.forkFromMessageInContext` + route chat-screen call through it + add `forkCreatedStream`** (1 day). All four call sites (chat-screen, tree-screen, marker-sheet chip taps, ChatPanel programmatic) unify through the new method, which delegates to `forkConversationWithContext`. The stream fires from inside `forkFromMessageInContext`. Done before ChatPanel extraction so the cache-invalidation channel exists when the panel is built.

3. **Extract ChatPanel widget — narrow scope** (4-5 days). Move the message list + active-leaf navigation into `lib/widgets/chat_panel.dart`. Send box, streaming, attachments stay in host screens. The host screen is 3840 lines and 41x-touched; even narrow extraction pulls in scroll controllers, message-tap handlers, edit/copy menus, and streaming placeholders. Existing chat tests pass; new widget-boundary tests added. ChatPanel API includes the four props from Section 1: `conversationId`, `initialMessageId`, `contextCard`, `onActiveConversationChanged`, `isStreaming`, `onSendUserPrompt`.

4. **Implement `getAllForkPointBranches` query + branch strip widget** (3 days). Batched single-query fetch on ChatPanel mount, cached in widget state, invalidated via `ForkService.forkCreatedStream`. Verify SQLite index coverage with `EXPLAIN QUERY PLAN` (acceptance criterion). Branch strip widget + viewport-top scroll on sibling tap + document-swap confirm dialog. Test fixtures for multi-child fork-points and >5 fan-out.

5. **Skill `default_action` parsing + chips-block parser + chip preview + ChipTapHandler** (2-3 days). Frontmatter parser learns one new optional string field. Skill-index prompt builder appends each loaded skill's `default_action` instruction. `block_markdown_body.dart` learns to detect, strip, and parse the `chips` fenced block into `Chip(label, prompt)` records (split-on-`## ` parser). Chip footer with skeleton-during-streaming + cross-fade on completion. Hover-popover (desktop) and long-press-popover (mobile) for chip preview. ChipTapHandler 3-step orchestration uses `chip.label` for fork title and `chip.prompt` for the new user message. **Mid-task spike**: emit-compliance check on 5-10 representative messages with the user's primary local + cloud models — verify both `## ` heading emission AND that body prompts are non-trivial (not just label-restated). If local emission is unreliable, document as a known limit (Open Question #2) and ship — no re-architecture needed. (+0.5-1 day vs. prior estimate for the preview popover.)

6. **Marker tap hosts ChatPanel — AI markers only** (3-4 days). Branch on `marker.type` at preview entry: `MarkerType.annotation` → keep existing render unchanged (zero work, zero regression risk); `MarkerType.ai` → ChatPanel embedded in the existing DraggableScrollableSheet. Wire `lastViewedConversationId` persistence via `onActiveConversationChanged`, plus the `resolveLastViewed` fallback (anchor-message check first, then conversation existence check, then orphan state with delete-marker affordance). Context card pinned at top. The existing grand-tree-screen button stays in the sheet header. **Marker-sheet send orchestration**: text input + send button + model picker (reuses `lib/widgets/model_selector_button.dart`) + chip-tap path. Wired to `onSendUserPrompt`. Attachments deferred to v1.1 in marker sheet (Open Question #4). (+1-2 days vs. prior estimate to account for marker-type branching, send-orchestration work, and model-picker integration.)

7. **Polish + Monday-morning self-test** (2 days). Read a real paper end-to-end, fix what's broken, ship.

   *(Step 6 of the prior design — note synergy — is DEFERRED to v1.1. Section 6 of this doc retains the deferred plan.)*

8. **Test pass — explicit budget for coverage of remaining new paths** (3-4 days). Note-Synapse's stated test discipline ("100% coverage is the goal" per CLAUDE.md) demands an explicit line item.
   - **Day 1: Critical regression tests** — (a) chat-screen fork-call refactor through `forkFromMessageInContext` preserves DB state vs pre-refactor baseline; (b) `InNoteMarker` JSON deserialization of pre-v1 markers (no `lastViewedConversationId`) → defaults applied cleanly; (c) `ForkService.forkCreatedStream` emission from all entry paths.
   - **Day 2: Unit tests** — branch strip rendering (2+ children, single child, >5 fan-out, active highlighted, document-swap warning trigger), `getAllForkPointBranches` query (returns ALL children including active, dedup by conversationId, empty-conversation case), `default_action` field parsing (present/missing/empty), `ChipTapHandler.handle` 3-step orchestration (mock the three deps; verify `chip.label` reaches the fork title and `chip.prompt` reaches `addUserMessage`), chips-block parser (single chip, multiple chips, missing prompt body, missing label, multiple blocks per message, malformed fence, prompts containing `#` but not `##`, label >5 words → ellipsize at render).
   - **Day 3-4: E2E + chip-emission compliance** — `resolveLastViewed` fallback chain (anchor-deleted, conversation-deleted, both-deleted), viewport-top scroll on sibling tap, document-swap confirm dialog, chip preview popover on hover (desktop) and long-press (mobile), 4 E2E flows: marker re-entry, lastViewed-deleted fallback, fork → strip auto-appears, chip-tap → fork (verify forked conversation's first user message equals `chip.prompt`, not `chip.label`). **Compliance smoke**: 5-10 messages with `default_action` skill loaded → assert chips block emission rate AND that emitted prompts are substantive (heuristic: prompt body length > label length + 20 chars, or contains a persona phrase like "you are"). Cloud ≥90%; local — measure and document as baseline.

**Honest budget (v1):**
- Full v1: **~4 weeks** (~21–23 working days) of focused solo work, summing the step ranges above (1+1+4.5+3+2.5+3.5+2+3.5 = ~21d midpoint).
- No "substrate-only ship" tier needed — chips degrade quietly to no-chips with no architectural cost.

Delta vs. prior 3.5-week design (whose internal day-counts also added to ~21d — the prior "3.5 weeks" headline was already optimistic):
- Step 5 (formerly chip extraction subsystem, 4-5 days) → 2-3 days for the AI-emitted-chips path with label/prompt split + preview popover (-1 to -3 days)
- Step 2 added: dedicated `forkFromMessageInContext` + chat-screen routing + stream-creation (+1 day, separated from prior step 3 to make the dependency explicit)
- Step 6 (marker tap) +1-2 days vs. prior estimate: marker-type branching (annotation preserved), marker-sheet send orchestration, and model-picker integration
- Step 8 (test pass) -1 day from removing the concept-extraction LLM eval suite (offset partly by new chip-parser + preview tests)
- Net: ~4 weeks. The chip simplification mostly cancels out against the marker-sheet feature additions (send box, model picker, type branching) and the chip preview popover. The real win is risk reduction and a richer surface (label/prompt split makes high-quality follow-ups possible), not calendar time.

Tests are a non-optional line item per CLAUDE.md. The 3-4 day test pass is what makes the coverage goal achievable. This is a personal/open-source project; calendar time depends on cadence. The estimates compare scope, not deadlines.

## What I noticed about how you think (preserved from prior design)

A few things the original conversation surfaced that are worth holding onto for future design work:

- You consistently shrink scope when given the chance. Three times in a row you said "this is over-engineered" or "this might not be needed" and pruned a piece. That's a strong instinct — most designers add, you subtract. The session-scoped skill, the per-node skill metadata, and the appendChildMessage API all died because you noticed the existing primitives already covered the job.
- Your novelty claim sharpened mid-session in a useful way. You started with "tree + immersive marker fusion." A few exchanges in: *"nobody combines agent skills to a mindmap to repurpose a mind-map like structure into something else."* The second framing is the real load-bearing claim, and it pulled the design toward a substrate-not-feature shape.
- You pushed back on premises with reasoning, not dismissal. The merge-detection split (keep visibility, drop semantic dedup; reserve `concept_hash` slot) was a textbook design-keystone move.
- You demand grounding in actual code before accepting alternatives. The "None of them are rooted in reality" correction was the inflection point of the original session — and the same instinct surfaced again in this revision when you collapsed the entire concept-extraction subsystem into "let the AI emit them."
- You think about UX real estate physically — the "tree in 1/2 screen is unreadable" insight that killed two HUD-overlay approaches.
- **New observation from this revision pass**: when given a complex subsystem (regex + LLM extraction + concurrency cap + fallback + cancellation), your instinct was to ask "why is this not the model's job?" — which collapsed five layers of plumbing into one frontmatter field. This is the same scope-shrinking instinct, applied to a different abstraction layer.
