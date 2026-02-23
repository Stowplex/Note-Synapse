# Block-Based Editing

Block-editing allows for quick operations without needing to go into the editing view.

## The Interaction Model

### 1. Initiating Block Mode (The "Pen Drop")
To start block editing, you **drag the edit button** itself.
*   **Gesture**: Long-press the **Edit Button** (pencil icon) in the top-right toolbar.
*   **Action**: Drag the floating icon and drop it onto any paragraph or element in your note.
*   **Visual**: The target block will highlight, and the floating **Action Menu** will appear.

![](../../media/editing/drag_edit.png)

### 2. Expanding Selection
Note Synapse uses a precision menu for expanding selections.
*   **Action**: Tap the **Up (`^`)** or **Down (`v`)** chevron arrows on the Block Menu.
*   **Result**: The selection highlight grows to include adjacent blocks.

![](../../media/editing/drag_edit_expand.png)


## The Block Menu
Once blocks are selected, you can perform batch operations on them:

### Actions
*   **Edit Groups**: Tapping the **Edit** (pencil) icon opens a focused editor containing *only* the selected blocks. This is perfect for rewriting a specific section without scrolling through the editor.
*   **Batch Delete**: Tapping **Delete** (trash can) removes all selected blocks at once.
