# Diagram Studio

Diagram Studio is a drawing surface for the blocks in a note. Whichever tab you use, the note keeps an editable source and a rendered image beside it.

Launch **Diagram Studio** from the note actions menu. It replaces the older Mermaid Block Renderer.

## The Tabs

| Tab | What the note keeps | How you edit it |
| :--- | :--- | :--- |
| **Mermaid** | a ` ```mermaid ` fence | a text editor with a live preview as you type |
| **Draw** | the exported SVG attachment, which *is* the source | freehand on a touch canvas |
| **ASCII** | the art itself, in whatever fence or paragraph it already lives in | a character-grid editor with a live render |
| **AI** | an ` ```ai-diagram ` fence holding the prompt | describe the diagram, then refine it by conversation |

You choose SVG, PNG or JPG for the rendered image at each save, and whether it goes above or below its source. Re-rendering replaces the previous image. Drawings are always saved as SVG so they stay editable, and AI images arrive as PNG.

On the Draw tab the canvas fills the screen between the tabs and the save bar. The tool row scrolls sideways; at its end is a bin that clears the drawing (undo brings it back). While you type — a text box on the canvas, or any editor — the save bar steps out of the way of the keyboard and returns when the keyboard goes.

## Running It

**On a whole note**, the studio scans for diagram-like blocks and lists them, with a tap to jump between them. When you create a diagram it asks which existing block to insert before or after.

**On a selected block**, drop the edit pen on the block and choose Diagram Studio from the block menu (see **[Block-Based Editing](../editor/block_editing.md)**). The studio then works on that block alone.

An empty or non-diagram block is a fine place to start: pick a tab and type.

ASCII art is detected wherever it lives, and you can always override the tab the studio guessed.

## Known Limitation

Whether the AI tab refines a diagram by editing the previous image depends on the AI backend honouring an attached image. This has not been verified on a device. When it is not honoured, each generation still builds on the accumulated instructions, and the tab says so.
