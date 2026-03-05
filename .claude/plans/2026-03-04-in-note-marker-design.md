# In-Note Marker Design

**Date:** 2026-03-04
**Branch:** `kkspeed/in-note-marker`
**Status:** Approved

## Overview

When a user draws a rectangle in immersive mode and sends it to AI (or adds to scratchpad), a persistent numbered badge marker is left at that location on the document. Tapping the badge shows a preview popup of the captured annotation image, the user's message, and the AI's response, with a button to open the full conversation.

## Scope

Applies to all content types in immersive mode:
- PDF attachments
- Image attachments
- Text notes

---

## Data Model

### Storage Strategy

Markers are stored in the existing `metadata` JSON field — no new database tables, no schema migration for attachments. Text notes require a new `metadata TEXT` column added to the `notes` table (DB version bump required).

Mirrors the existing `bookmarks` pattern on attachments.

### Attachment Marker (PDF / Image)

```json
{
  "markers": [
    {
      "id": "uuid",
      "index": 1,
      "page": 3,
      "normalizedRect": { "x": 0.12, "y": 0.35, "w": 0.40, "h": 0.10 },
      "conversationId": "...",
      "messageId": "...",
      "createdAt": "2026-03-04T10:00:00Z"
    }
  ]
}
```

- `normalizedRect`: coordinates in 0.0–1.0 relative to page/image dimensions (zoom/pan invariant)
- `page`: 1-indexed PDF page number (matches existing `lastViewedPage` convention)
- `capturedImagePath` is **not stored** — retrieved at display time from `conversation_attachments` via `messageId`

### Text Note Marker

```json
{
  "markers": [
    {
      "id": "uuid",
      "index": 1,
      "charStart": 120,
      "charEnd": 250,
      "conversationId": "...",
      "messageId": "...",
      "createdAt": "2026-03-04T10:00:00Z"
    }
  ]
}
```

- `charStart`/`charEnd`: character offsets in note content derived at draw time via `RenderParagraph.getPositionForOffset()`

---

## Capture Flow

### Coordinate Capture (at draw confirmation)

Before `_captureDrawing()` saves the PNG:

1. Compute document-space position from the drawn screen rect:
   - **PDF/image**: inverse-transform screen rect using viewer's current zoom/pan matrix → `normalizedRect`
   - **Text note**: hit-test rect corners against `RenderParagraph` → `charStart`/`charEnd`

2. Stash as `_pendingMarkerPosition` in `ImmersiveNoteScreen` state alongside existing `_pendingAttachments`

### Marker Persistence (after message sent)

After the message is sent and `conversationId` + `messageId` are known:

1. Call `NoteMarkerService.saveMarker(targetId, isNote, marker)`
2. Service reads current metadata, appends marker with auto-incremented `index`, writes back via `DatabaseService`
3. Clear `_pendingMarkerPosition` from state

### NoteMarkerService API

```dart
class NoteMarkerService {
  Future<void> saveMarker(String targetId, bool isNote, InNoteMarker marker);
  Future<List<InNoteMarker>> getMarkers(String targetId, bool isNote);
  Future<void> deleteMarker(String targetId, bool isNote, String markerId);
}
```

---

## Rendering

### PDF / Image

- `ImmersiveNoteScreen` adds a `MarkerOverlayWidget` layer to the existing `Stack` over the viewer
- Filters markers to current page
- Transforms `normalizedRect` → screen coordinates using viewer's zoom/pan matrix
- Renders badge at top-left corner of the rect
- Re-renders on page change and zoom/pan change

### Text Note

- Post-frame callback resolves `charStart` → screen position via `RenderParagraph.getOffsetForCaret()`
- Badges positioned absolutely within a `Stack` over the note content

### Badge Appearance

- Small filled circle, ~20px diameter, blue
- White bold number inside (1, 2, 3, ...)
- Subtle drop shadow for readability over varied backgrounds
- **Default opacity**: ~60% (text beneath remains readable)
- **On tap**: fades to 100% opacity; returns to 60% after popup is dismissed

---

## Preview Popup

Triggered by tapping a badge. Displayed as a `showModalBottomSheet`.

### Content (top to bottom)

1. **Captured annotation image** — loaded from `ConversationAttachment` via `messageId`, thumbnail ~150px height
2. **User's message** — text content, truncated to ~3 lines
3. **AI's response** — next message in conversation after `messageId`, truncated to ~4 lines with trailing fade
4. **"Open Conversation" button** — navigates to `ConversationChatScreen` scrolled to the specific message

### Edge Cases

- Missing AI response: show "No response yet"
- Missing annotation image: show placeholder icon
- Dismissible by swipe-down or tap-outside

---

## Model: `InNoteMarker`

```dart
class InNoteMarker {
  final String id;
  final int index;
  final String conversationId;
  final String messageId;
  final DateTime createdAt;

  // PDF/image only
  final int? page;
  final NormalizedRect? normalizedRect;

  // Text note only
  final int? charStart;
  final int? charEnd;
}

class NormalizedRect {
  final double x, y, w, h;
}
```

---

## Database Changes

- **`notes` table**: add `metadata TEXT` column (JSON), DB version bump
- **`attachments` table**: no change (metadata column already exists)
- **Recovery screen**: update to handle `notes.metadata` column

---

## Out of Scope

- Markers on scratchpad content (scratchpad is ephemeral)
- Global "all markers" view across the library
- Editing/renaming marker labels
- Marker sync (can be added later via existing sync infrastructure)
