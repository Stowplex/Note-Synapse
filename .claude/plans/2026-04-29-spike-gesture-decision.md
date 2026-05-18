# Spike: Gesture Mediation Decision for Branch Strip

Date: 2026-04-30
Spike for: Task 14 (MessageBranchStrip) of `2026-04-29-marker-anchored-subtree-implementation.md`

## Decision

**PRIMARY PATH viable.** Implement `MessageBranchStrip` as an in-row tappable strip placed below the message card. No fallback needed.

## Evidence

### Chat screen — `lib/screens/conversation_chat_screen.dart`

`_buildMessageCard` (line 3415) renders the message as:

```
Card (no onTap)
  Padding
    Column
      Row (header — sender icon + actions)
      Markdown body (BlockMarkdownBody)
      Optional attachment chips (_buildMessageAttachmentChips)
```

No top-level `GestureDetector` or `InkWell` wraps the card. Audit of all `onTap`/`onLongPress`/`GestureDetector`/`InkWell` occurrences in the file (45+ hits across the file) confirms gestures are scoped to specific sub-elements (attachment thumbnails, sender icon menus, copy buttons), not the message-row area as a whole.

### Immersive screen — `lib/screens/immersive_note_screen.dart`

`_buildMessageCard` (line 3447, similar shape) follows the same pattern: `Card` with no `onTap`, child `Column` of header + body + attachments. Marker-tap regions (`_handleMarkerTap` at lines 3994, 4067) are anchored to the PDF/note overlay layer, not the chat-list message rows — independent gesture surface.

### Conclusion

A new widget appended below `_buildMessageCard` (i.e., as a sibling in the parent `ListView` `itemBuilder`) gets a clean tap surface. The strip's own `InkWell` rows will handle taps without competing with any card-level handler.

## What This Means for Task 14

- Implement `MessageBranchStrip` with full-row `InkWell` tap rows per the spec.
- No chevron-icon popover variant needed.
- No +1 day budget impact.

## What If This Is Wrong

If, during integration in Task 16, in-row taps somehow swallow scroll gestures on a specific platform (mobile especially), revisit by:
1. Adding a `behavior: HitTestBehavior.opaque` on the strip's GestureDetector.
2. Failing that, switching to the chevron-popover variant per the spec's plan B.

The data model and `MessageBranchStrip` API are unchanged in either path.
