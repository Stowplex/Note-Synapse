# Note Editing & Management

The Note Synapse editor is a powerful markdown-based environment designed for both quick capture and deep writing.

## Editor Basics
*   **Cursor & Selection**: Standard text selection works as expected. You can tap to place the cursor or long-press to select text.
*   **Block Selection**: The editor understands "Blocks" (paragraphs, code blocks). You can drag blocks to reorder them (if enabled) or use the block handle interactions for complex moves.

## Inserting Content

### 1. Images
You can insert images directly into your notes.
*   **Action**: Tap the **Image Icon** in the toolbar.
*   **Source**: Choose from your device gallery or file system.
*   **Format**: Images are saved locally and inserted as standard Markdown: `![Alt Text](path/to/image.jpg)`.

### 2. Linking Notes
Connect your thoughts by linking notes together.
*   **Action**: Tap the **Link Icon** (or select "Insert Note Link").
*   **Selection**: A dialog will appear showing your note history and search. Select a note to link.
*   **Format**: Creates a clickable internal link: `[Note Title](synapseresource://note/ID)`. Tapping this link in View Mode instantly navigates to that note.

## Notes vs. Sub-notes
Note Synapse uses a hierarchy to keep your workspace clean.

| Feature | Main Note | Sub-note |
| :--- | :--- | :--- |
| **Purpose** | Core knowledge entity, detailed documentation. | Quick scratchpad, checklist item, or specific detail. |
| **Content** | **Rich**: Supports images, links, tags, and complex markdown. | **Lightweight**: Text-only (markdown supported). Fast to load. |
| **Context** | Has its own tags, relationships, and metadata. | inherits context from the Parent Note. |
| **Use Case** | Project Overview, Research Paper, Meeting Minutes. | "Action Items", "Phone Number", "Quick thoughts". |

### Managing Sub-notes
*   **Add**: Tap the "Add Sub-note" button within a main note.
*   **Edit**: Tapping a sub-note opens a focused, lightweight editor window.
*   **Reparent**: You can move sub-notes to different parent notes if they grow in scope.

## Auto-Save & Sync status
The editor saves your work automatically, but it's important to know the status to prevent data loss.

**Look at the Top Right of the screen:**
*   **Orange "Unsaved" (`edit` icon)**: You have unsaved changes. **Do not close the app.** The auto-save timer is running (usually triggering 2 seconds after you stop typing).
*   **Green "Saved" (`check` icon)**: All changes are safely written to the database. It is safe to exit.
