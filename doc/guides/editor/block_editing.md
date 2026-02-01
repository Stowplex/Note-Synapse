# Block-Based Editing

Note Synapse treats your markdown as a series of logical "Blocks" (paragraphs, headers, code blocks, lists). This allows for quick operations without needing to go into the editing view.

## The Interaction Model

### 1. Initiating Block Mode (The "Pen Drop")
To start block editing, you **drag the edit button** itself.
*   **Gesture**: Long-press the **Edit Button** (pencil icon) in the top-right toolbar.
*   **Action**: Drag the floating icon and drop it onto any paragraph or element in your note.
*   **Visual**: The target block will highlight, and the floating **Action Menu** will appear.

> ![Screenshot: User dragging the pencil icon from the toolbar onto a paragraph text block](placeholder_images/block_drag_initiation.png)

### 2. Expanding Selection
Note Synapse uses a precision menu for expanding selections.
*   **Action**: Tap the **Up (`^`)** or **Down (`v`)** chevron arrows on the Block Menu.
*   **Result**: The selection highlight grows to include adjacent blocks.

> ![Screenshot: The Block Action Menu showing the chevron, edit, and delete buttons](placeholder_images/block_menu_actions.png)

## The Block Menu
Once blocks are selected, you can perform batch operations on them:

### Actions
*   **Edit Groups**: Tapping the **Edit** (pencil) icon opens a focused editor containing *only* the selected blocks. This is perfect for rewriting a specific section without distractions.
*   **Batch Delete**: Tapping **Delete** (trash can) removes all selected blocks at once.

> ![Screenshot: The focused editor view showing only the selected blocks](placeholder_images/block_focused_editor.png)
