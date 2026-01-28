# Hands-On: Tag Algebra (Virtual Folders)

Organize your notes without ever moving a file.

## The Concept: Inclusion = Child
If you tag a note `Project` and `Project/Design`, the second tag is automatically treated as a child of the first because it *contains* the string.

### Problem
You want to organize 50 notes about "AI Learning" into sub-topics like "LLMs" and "Vision", but you don't want to lose the ability to see them all at once.

### Walkthrough: Creating a Hierarchy
1.  **Tag the Parent**: Open a generic note and add the tag `AI`.
2.  **Tag the Child**: Open a specific note about GPT-4 and add the tag `AI/LLM`.
    -   *Tip*: Note Synapse treats `/` or space-separated inclusion as hierarchy.
3.  **Browse**:
    -   Tap the **Tag Filter** icon in the main list.
    -   Select `AI`. You see ALL notes (including the LLM one).
    -   Select `AI/LLM`. You see ONLY the GPT-4 note.

> **Screenshot Placeholder:** [Image of the Tag Filter Bar showing 'AI' selected, with 'AI/LLM' appearing as a refined option next to it.]

## Hands-On: Creating an "Active Filter"
Stop searching for the same things every day.

1.  Open the **Filter Dialog** (Funnel icon).
2.  Select Tags: `AI` + `Learn`.
3.  Scroll down to **"Save as Active Filter"**.
4.  Name it: "Study Queue".
5.  **Result**: A new chip appears at the top of your home screen. Tapping "Study Queue" instantly applies this complex logic.
