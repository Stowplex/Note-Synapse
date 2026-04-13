# Local Model Degradation Warnings

## Problem Statement

When Gemma (the local on-device model) is active, two feature areas — skills and tag workflows — deliver a significantly degraded experience compared to cloud models. Both features depend on the model correctly routing and orchestrating multi-step agentic tasks, which Gemma struggles with reliably.

The app previously showed warning badges on agentic tools when MNN local models were active. The migration to `flutter_gemma` removed this: `LocalMnnModel` reports `usesNativeToolDeclarations = true` (tool calls work at the API level), and the Gemma preset omits `supportsToolOrchestration: false`, so the entire existing warning system never fires. Skills and tag workflows were also built after the warning system, so they never carried warning badges at all.

Users have no signal that they are in a degraded configuration.

## Design

Four targeted changes using the existing `supportsToolOrchestration` capability flag as the single shared mechanism.

### Change 1: Gemma Preset — Restore Capability Flag

Set `supportsToolOrchestration: false` in `LocalModelPresets.gemma4E2b` (and any future local model presets).

This single change re-enables the existing warning system for free:
- Amber badge overlays on MCP tool icons in the conversation tool panel
- Warning row beneath the MCP tools section
- Pre-send `ToolOrchestrationWarningDialog` when tools are selected

No new code required for MCP tool warnings — they already exist and respond to this flag.

**File:** `lib/services/models/local_model_presets.dart`

### Change 2: Skills Button — Badge and Default State

The "X skills" toggle in the conversation chat screen tool panel gets two changes when `supportsToolOrchestration == false`:

1. **Warning badge** — same amber overlay icon (`Icons.warning_amber_rounded`, 12px, `Colors.amber.shade700`) positioned top-right of the skills button, consistent with MCP tool icon badges.

2. **Default deactivated** — skills start unchecked when the active model has `supportsToolOrchestration == false`. Currently skills are always activated by default. The default becomes model-aware: opt-in for local models, opt-out for cloud models. Users can still manually enable skills if they choose.

The badge and default state react to model changes mid-conversation (if the user switches models, the badge appears/disappears and the default applies to the new state).

**File:** `lib/screens/conversation_chat_screen.dart`

### Change 3: Tag Management Screen — Workflow Tab Badge

The tag workflow tab in the tag management screen displays an amber warning badge when `supportsToolOrchestration == false` on the active model. This is a proactive, static signal — users see the warning when browsing or editing workflow bindings, before applying any tags.

Badge placement: top-right corner of the tab label, same visual treatment as tool icon badges.

**File:** `lib/screens/tag_management_screen.dart`

### Change 4: Tag Workflow Trigger — Approval Dialog

When a tag is applied to a note and a workflow binding is matched, the workflow currently begins immediately with a progress snackbar. When `supportsToolOrchestration == false`, an approval dialog is shown first:

> **"This model may not deliver the best experience with tag workflows."**
>
> [Continue] [Continue and do not warn this session] [Cancel]

- **Continue** — proceeds with the workflow; dialog will appear again next time a workflow triggers.
- **Continue and do not warn this session** — proceeds and sets an in-memory session flag that suppresses this dialog for the remainder of the app session. Flag resets on app restart; no persistence.
- **Cancel** — workflow does not run.

The dialog follows the visual pattern of `ToolOrchestrationWarningDialog` for consistency. The session suppression flag lives on the service that initiates tag workflow execution (e.g., `TagWorkflowService` or `AgentService`).

If the session flag is set, workflow triggers proceed directly to the progress snackbar with no dialog.

**Implementation note:** The dialog cannot live inside `ContentIngestionService.processNote()` (a service). The approval check must be added at the UI call site(s) that invoke `processNote` — before calling the method, the UI checks the active model's `supportsToolOrchestration` flag and shows the dialog if needed. The session suppression flag lives on the call site's widget state or a thin wrapper (e.g., injected via a new `onApprovalRequired` callback on `processNote`, resolved by the calling screen/widget).

**Files:** `lib/services/content_ingestion_service.dart` (add optional `onApprovalRequired` callback to `processNote`); call sites that invoke `processNote` in the UI layer.

## Warning Surface Summary

| Surface | Type | Trigger | Files |
|---|---|---|---|
| MCP tool icons | Badge (existing, re-enabled) | `supportsToolOrchestration == false` | existing |
| MCP tools section | Warning row (existing, re-enabled) | `supportsToolOrchestration == false` | existing |
| Pre-send with tools | Dialog (existing, re-enabled) | `supportsToolOrchestration == false` | existing |
| Skills button | Badge + default off | `supportsToolOrchestration == false` | `conversation_chat_screen.dart` |
| Tag workflow tab | Badge | `supportsToolOrchestration == false` | `tag_management_screen.dart` |
| Tag workflow trigger | Approval dialog | `supportsToolOrchestration == false` (+ no session flag) | tag workflow trigger site |

## Capability Flag Propagation

The `supportsToolOrchestration` flag is read from `modelConfig?.customCapabilitiesObject?.supportsToolOrchestration ?? true`. All warning surfaces use this same expression. No new capability flags are introduced.

The session suppression flag for the approval dialog is the only new state, and it is ephemeral (in-memory only).

## Out of Scope

- Persistent "do not warn" preference (per-model or global) — session suppression is sufficient
- Warnings for other local model limitations (token window, vision) — handled by existing systems
- Changing Gemma's actual capability to handle tool orchestration
