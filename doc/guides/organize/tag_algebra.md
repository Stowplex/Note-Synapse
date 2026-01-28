# Hands-On: Tag Algebra (Virtual Folders)

Organize your notes without ever moving a file.

## The Concept: Filters Create Hierarchy
Tags in Synapse are **flat**. `#project` and `#marketing` are just separate labels. They do **not** use file paths like `#project/marketing`.

Instead, **Hierarchy is defined by Filter Algebra**:
*   **Filter A**: Notes with `#project`.
*   **Filter B**: Notes with `#project` AND `#marketing`.
*   **Result**: Synapse sees that Filter B is a *subset* of Filter A, so it automatically nests B under A in the visual tree.

### Problem
You want to organize 50 notes about "AI Learning" into sub-topics like "LLMs" and "Vision", but you don't want to manage complex folder structures.

### Walkthrough: Creating a "Virtual" Hierarchy
1.  **Tag Freely**:
    *   Tag general notes with `#AI`.
    *   Tag specific notes with `#AI` *and* `#LLM`.
    *   Note: You do NOT need to name the tag `AI/LLM`. Just use two separate tags.
2.  **Create Parent Filter**:
    *   Create a filter named "AI" that includes tag `#AI`.
3.  **Create Child Filter**:
    *   Create a filter named "LLMs" that includes tags `#AI` *and* `#LLM`.
4.  **Result**: In the Filter Strip, "LLMs" automatically tucks inside "AI" because it is a more specific subset.

> **Screenshot Placeholder:** [Image of Filter Strip showing 'LLMs' nested under 'AI' because of tag containment.]

## Tag Filters: Your Saved Views
While you can manually select tags, **Filters** let you save complex combinations (Algebra) for one-tap access.

### 1. The Filter Strip
Located at the top of your note list, the **Filter Strip** holds all your saved views.
-   **Add (+)**: Tap the plus icon to create a new filter. You can define it by:
    -   **Tags**: Include or exclude specific tags.
    -   **Text**: Must contain specific keywords.

### 2. Hierarchy Mode (Auto-Organization)
If you have many filters, the strip can get cluttered. Use **Hierarchy Mode** to organize them automatically.
-   **Toggle**: Tap the **Tree Icon** (`account_tree`) on the far left of the strip.
-   **Full Tree View**: **Long Press** the Tree Icon to open a popup dialog showing your entire filter hierarchy as a classic file-system tree.
-   **Logic**: Synapse detects "Algebraic Parents". 
    -   If Filter A uses `#project`...
    -   And Filter B uses `#project` AND `#dev`...
    -   Then **Filter B becomes a child of Filter A**.
-   **Navigation**: Child filters are hidden to save space. Tap the **dropdown arrow** on the parent filter to reveal them.

### 3. Pinning for Speed
Keep your most-used filters accessible, even if they are deep in the hierarchy or hierarchy mode is active.
1.  **Select**: Tap a filter to activate it.
2.  **Pin**: Tap the **Pin Icon** (`push_pin`) inside the active filter chip.
3.  **Result**: The filter moves to the **far left** of the strip and stays visible at all times, bypassing the hierarchy collapse.

> **Screenshot Placeholder:** [Image of the Filter Strip showing a Pinned filter on the left, and a Parent filter with a dropdown arrow for hierarchy.]

## Automation: Associated Tag Prompts
Tags can trigger AI work for you. You can associate a specific **Prompt** with a tag, so that when you apply it, Synapse automatically transforms the note.

### Use Case: Research Papers
Imagine you save PDFs of research papers. You want to extract the same key info from every paper.
1.  **Configure**:
    -   Go to **Tag Management** (or long-press a tag in the filter list).
    -   Tap the **Brain Icon** (`psychology`) next to the `#paper` tag.
    -   Enter a Prompt: *"Summarize the key contributions, limitations, and related work of this paper."*
2.  **Apply**:
    -   Open a new note containing a paper.
    -   Add the tag `#paper`.
3.  **Result**: Synapse detects the associated prompt and automatically runs it against the note content, appending the AI-generated summary to your note.
