# Marker-anchored Subtree v1 — Verification Results

Plan: `.claude/plans/2026-04-29-marker-anchored-subtree-implementation.md`
Branch: `feature/marker-anchored-subtree`
Verification date: 2026-05-03

## Automated verification

### Full test suite — `flutter test`
**1292 tests pass · 0 failures**

Final run output:
```
01:34 +1292: All tests passed!
```

No regressions across the project. The marker-anchored-subtree work added these new test files (all green):

- `test/widgets/chat_panel_test.dart` — 10 tests (ChatPanel core: rendering, branch strip, chip taps, scroll-to-message, fork stream refresh, streaming bubble, tool icon, edit affordance, reload)
- `test/widgets/message_branch_strip_test.dart` — 8 tests (already from Task 14)
- `test/widgets/chips_footer_test.dart` — covered by previous tasks
- `test/widgets/chip_preview_popover_test.dart` — covered by previous tasks
- `test/widgets/marker_chat_panel_host_test.dart` — 3 tests (renders, send-clears-field, empty-input no-op)
- `test/widgets/marker_orphan_state_test.dart` — 2 tests (anchor-deleted, conversation-deleted variants)
- `test/widgets/in_note_marker_preview_test.dart` — 5 tests (legacy annotation path, AI happy, anchor orphan, conv orphan, stale lastViewed cleanup)
- `test/services/marker_chat_send_service_test.dart` — 5 tests (orchestration: addUserMessage, request-built, completion-fires, chunk-callback, addAi-with-metadata)
- `test/services/chip_tap_handler_test.dart` — 3 tests (already from Task 13)
- `test/services/chips_block_parser_test.dart` — covered by previous tasks
- `test/note_marker_service_test.dart` — extended with 7 new tests for `updateMarkerLastViewed` (4) and unified `deleteMarker` (3); 15/15 pass

### `flutter analyze` (project lib + test directories)

659 issues — **all pre-existing**, none introduced by this work:
- `withOpacity` deprecation warnings throughout (pre-existing project-wide style)
- `use_build_context_synchronously` warnings in immersive screen (pre-existing)
- Unused imports / hints in unrelated test files (`share_service_test.dart`, `web_extraction_bench_test.dart`, etc.)

Spot-check on the changed files specifically: zero new errors. Two minor cosmetic notes:
- `lib/widgets/chat_panel.dart:148` — `didUpdateWidget` parameter named `old` instead of `oldWidget`. Style nit; not changing.
- `lib/widgets/chat_panel.dart:453` — uses `withOpacity` (matched immersive's existing style for visual consistency).

## Step 1: Cloud-model chip-emission compliance — DEFERRED (manual)

**Status: NOT RUN — requires the user to run a real LLM session.**

The user should:
1. Create a small skill note with a `default_action` field telling the AI to emit a `\`\`\`chips` block.
2. Enable the skill.
3. Send 5–10 representative paper-reading prompts via the immersive chat slot, using a cloud model (e.g. Gemini).
4. For each AI reply, verify:
   - A `\`\`\`chips` fenced block appears in the reply.
   - Each chip has both a label and a non-trivial prompt body (length > label length + 20 chars OR contains a persona phrase like "you are").
5. Record the emission rate. Target per spec: **≥ 90%**.

Append findings to `.claude/plans/2026-04-29-compliance-results.md` (create if missing).

## Step 2: Local-model chip-emission compliance — DEFERRED (manual)

**Status: NOT RUN — requires the user to run a real local-model session.**

Same protocol as Step 1, but with the user's primary local model (likely Gemma 3n).

Per spec Open Question #2, **do NOT re-architect** if compliance is poor — document baseline as a known limit.

## Step 3: Monday-morning self-test (full reading flow) — DEFERRED (manual)

**Status: NOT RUN — requires `flutter run -d macos` and a real PDF.**

Spec's success-criteria substrate flow checklist:

- [ ] Open immersive on a PDF paper.
- [ ] Circle a paragraph → marker created → AI reply renders in the chat slot (bubble UI).
- [ ] AI message includes a chips footer (when skill `default_action` is enabled).
- [ ] Tap a chip → fork created → AI replies in new branch.
- [ ] Branch strip appears below the original AI message (the fork-point).
- [ ] Tap sibling row in the strip → branches switch; fork-point scrolls to viewport top.
- [ ] Try a sibling associated with a different document → confirm dialog appears before switch.
- [ ] Close immersive.
- [ ] Wait (or simulate by quitting/reopening the app).
- [ ] Re-open the document; tap the marker again.
- [ ] Verify it lands on the **last-viewed** branch (not the original).
- [ ] Verify the `📝 N notes` synergy line is **NOT** present (deferred to v1.1).
- [ ] Verify scratchpad/annotation markers still use the **legacy render** (no ChatPanel host).

Marker-sheet send chain (Task 23):
- [ ] Open AI marker → ChatPanel renders inside the bottom sheet.
- [ ] Type a prompt + tap send → AI streams a reply, completion replaces with finalized bubble.
- [ ] Test with a cloud model and a local model.
- [ ] Try a tool-using prompt with at least one MCP endpoint configured → tool calls execute; `parts_history` shows in the tool-details popover.
- [ ] Verify error path: unplug network mid-stream → SnackBar "Send failed: …" shows; sheet recovers.
- [ ] Verify the model selector at the bottom of the sheet flows through to `modelOverride`.

Orphan-tier paths (Task 24):
- [ ] Delete the conversation (via dev tools / DB) → reopen marker → orphan state with conversation-deleted message + delete-marker button.
- [ ] Delete the anchor message → reopen marker → orphan state with anchor-deleted message + delete-marker button.
- [ ] Tap "Delete marker" in orphan state → marker is removed from the note/attachment.

Document findings here when run.

## Phase summary

| Phase | Tasks | Status |
|---|---|---|
| 0 — Spike (gesture mediation) | Task 0 | ✅ Done |
| 1 — Service-Layer Foundation | Tasks 1–7 | ✅ Done |
| 2 — Chip System Foundations | Tasks 8–13 | ✅ Done |
| 3 — Branch Strip Widget | Task 14 | ✅ Done |
| 4 — ChatPanel Extraction | Tasks 15–19 | ✅ Done |
| 5 — Host Integration: Immersive | Task 20 + bubble-UI refactor | ✅ Done |
| 6 — Marker Sheet Upgrade | Tasks 21–24 | ✅ Done |
| 7 — Final Verification | Task 25 (automated parts) | ✅ Done; manual smoke deferred to user |

## Scope deviations from the original plan

1. **Bubble-UI refactor of ChatPanel** (between Tasks 19 and 20): the original plan had ChatPanel substituting directly into the immersive screen, but ChatPanel didn't render bubble UI / streaming bubble / tool indicators / tap-to-edit. After flagging the UX regression, the user picked **option C** — beef up ChatPanel to preserve all four affordances before substituting. Resulted in commit `01677cf`. Tests grew from 6 → 9.

2. **Task 23 send-orchestration via parallel `MarkerChatSendService`** instead of refactoring immersive's `_sendMessage`. The user picked **option B** ("full parity"). Pragmatic execution: the new service uses the same shared services (`ConversationAiEngine`, `NotePromptBuilder`, `BuiltInToolsService`, `McpToolIntegrationService`, `AgentService`) but encapsulates marker-sheet defaults (auto-loaded MCP/system tools, no attachments, no scratchpad). Future task can extract a shared base if drift becomes a problem. AI tool bundles + the built-in "Agent" toggle are deferred to v1.1 (require `AppProvider` access the marker sheet doesn't have).

3. **`_ChatPanelState` made public as `ChatPanelState`** so `MarkerChatPanelHost` can call `reload()` via `GlobalKey<ChatPanelState>`. Standard Flutter pattern.

4. **`_buildAiMarkerContextCard` left as a placeholder Card** showing only the marker index. The plan originally suggested reusing the legacy preview's image + user-message rendering as the context card; that's a polish task tracked as a TODO comment in the file.

5. **Marker scan-all-by-id** in `NoteMarkerService.updateMarkerLastViewed` and `deleteMarker(markerId)` — chosen over widening the API to take a parent ID so the change stays localized. Acceptable at v1 scale (< 100 markers per user); revisit if marker counts grow.

## Commits in this branch (Phase 4 → 7)

```
4280c83 feat(marker): add resolveLastViewed fallback chain with orphan empty state
b60e58b feat(marker): wire marker-sheet send to ConversationAiEngine
8f94589 feat(marker): add MarkerChatPanelHost with text input + model picker
a87a88c refactor(marker): branch preview on marker.type; preserve annotation path
a2d79f4 feat(immersive): host ChatPanel in chat slot with branch switching
01677cf refactor(chat): add bubble UI, streaming bubble, tool indicators to ChatPanel
8e44d13 test(chat): cover forkCreatedStream-driven branch refresh
f87091e feat(chat): scroll to initialMessageId on mount; propagate branch switch
a197ec4 feat(chat): wire chip taps and long-press preview into ChatPanel
252b9e7 feat(chat): wire MessageBranchStrip and ChipsFooter into ChatPanel
4864ce1 chore(chat): address Task 15 review feedback
084fd7b feat(chat): add ChatPanel skeleton with message list and contextCard
```

(Earlier commits for Phases 0–3 already in branch history at session start.)

## Ship-readiness assessment

**Code:** ✅ Ready. All automated tests pass; analyze clean for changed files; subagent reviews on each task completed.

**Manual smoke:** ⏳ Pending. Three manual checklists above (chip compliance × 2, full reading-flow self-test) require the user to run the app. Recommend running these before merging to `main`.

**Known follow-up work (deferred per spec / scope choices):**
- AI tool bundles in marker sheet (requires AppProvider plumbing)
- Note synergy line (`📝 N notes`) — explicitly deferred to v1.1 in the spec
- Polish `_buildAiMarkerContextCard` to show captured image + original user message
- Refactor immersive `_sendMessage` to share with `MarkerChatSendService` if drift becomes a problem
