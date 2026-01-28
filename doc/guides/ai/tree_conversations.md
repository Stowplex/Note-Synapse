# Tree Conversations: Git for Thoughts

Don't let a bad turn ruin a good conversation. Note Synapse treats every conversation as a **Tree**, allowing you to explore multiple possibilities without losing your place.

## The "Forking" Workflow
### Problem
You are debating architecture with the AI. It made a great point 5 messages ago, but then went down a rabbit hole about database drivers. You want to go back to that great point and explore a different direction.

### Solution: Fork It
1.  Scroll back to the **Message** where the AI made the good point (or where you want to change your reply).
2.  Tap the **Fork Icon** (`call_split`) on the message bubble.
3.  **Result**: A new "Branch" is created.
    -   The old conversation is safe.
    -   You are now in a fresh timeline starting from that exact moment.
    -   The current thread is automatically highlighted in the Tree View.

> **Screenshot Placeholder:** [Image of a chat message bubble with the Fork icon highlighted.]

---

## Navigating the Tree
Tap the **Tree Icon** (`account_tree`) in the top-right of the chat screen to see the bigger picture.

### The Graph View
*   **Green Node**: Your current location.
*   **Blue Nodes**: Other branches.
*   **Edges**: Show the history flow.
*   **Tap** any node to jump instantly to that version of reality.

### Multi-Select Actions
You can manage multiple branches at once:
1.  **Long Press** a node to enter selection mode.
2.  Tap other nodes to add them to your selection.
3.  Use the top-right menu for actions:
    *   **Create Note** (`note_add`): Compile the selected conversation parts into a single permanent note. This is perfect for saving the "good parts" of a brainstorming session.
    *   **New Conversation** (`add`): Start a brand new conversation using the selected nodes as context. You can even use an **AI Transformation** to summarize them first (e.g., "Summarize these 3 branches into a requirements doc").

### Use Case: Text Adventure Game
Imagine playing an RPG with the AI.
1.  **Choice A**: You attack the dragon. -> *You die.*
2.  **Rewind**: Go back to the message before the choice.
3.  **Fork**: Choose "Choice B: Negotiate". -> *You succeed.*
4.  **Tree View**: You can now see both timelines side-by-side and effectively "save scum" your way to victory.

---

## Context Pruning
Sometimes the AI generates massive output (e.g., a 500-line log analysis tool output) that clogs up your context window and wastes tokens.

1.  Tap the **Tool Icon** (`build`) on the message with the large output.
2.  Select **"Strip Tool Output"** (or "Exclude Message").
3.  **Result**: The message remains in the visual history, but its heavy content is removed from the AI's "memory" for future turns. This keeps your conversation fast and focused.
