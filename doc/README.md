# Note Synapse Documentation

## Community
-   **[Discord](https://discord.gg/DmvrAh6H7)**: Ask questions, share plugins, and chat with other users and developers.

## Getting Started
-   **[Setup Guide](guides/ai/onboarding.md)**: Setting up your first model and API keys.

## Editor & Writing
-   **[Block-Based Editing](guides/editor/block_editing.md)**: The pen-drop gesture, expanding a selection, and running apps on part of a note.
-   **[Note Editing](guides/editor/note_editing.md)**: Using the note editor.

## Organization
-   **[Tag Filter](guides/organize/tag_filter.md)**: Filter notes by combining multiple tags into hierarchies.
-   **[Tag Image](guides/organize/tag_image.md)**: Add images to visualize your tags.
-   **[Tag Manager & Dedup](guides/organize/tag_manager.md)**: Bulk delete and Merge tags (Manual & AI).
-   **[Tag Prompts](guides/ai/tag_prompts.md)**: Associate pre-defined prompts with tags.

## AI & Thinking
-   **[AI Conversations](guides/ai/ai_conversations.md)**: non-linear conversations with notes as context, forking thoughts, and pruning context.
-   **[Agent Skills](guides/ai/agent_skills.md)**: Teach the AI reusable workflows with notes, tool references, and tag-triggered automation.
-   **[Agentic Research](guides/ai/agents.md)**: Complex task planning and execution.
-   **[Immersive Reading](guides/ai/immersive_reading.md)**: Intuitively interacting with documents.
-   **[Smart Model Matching](guides/ai/smart_model_matching.md)**: Automatically switch models based on capabilities.
-   **[MCP Tools](guides/ai/mcp.md)**: Connect Note Synapse to external tools.

## Productivity
-   **[Web Clipper](guides/productivity/web_clipper.md)**: Saving knowledge from the web, including sites that need a login, and keeping track of where each clip came from.
-   **[World Capture](guides/productivity/world_capture.md)**: Turn videos, photo sequences, and screen recordings into clean page notes.
-   **[Calendar & Tasks](guides/productivity/calendar.md)**: Scheduling and task management.
-   **[Multi-Function Tab](guides/productivity/multi_function_tab.md)**: Custom default views.

## Plugins
Apps that run inside your notes. Some ship with Note Synapse; others you download and import.

-   **[Plugins Overview](guides/plugins/overview.md)**: What is bundled, what you download, and how to install one.
-   **[Formula Studio](guides/plugins/formula_studio.md)**: Edit LaTeX formulas visually and solve them offline.
-   **[Table Studio](guides/plugins/table_studio.md)**: Edit a note's markdown tables and spreadsheet attachments in a real spreadsheet.
-   **[Diagram Studio](guides/plugins/diagram_studio.md)**: Author diagrams as Mermaid, freehand drawing, ASCII art, or an AI image.
-   **[DOS Station](guides/plugins/dos_station.md)**: Run DOS programs and games from a note's attachments; downloaded separately.

## Power User / Create Your Own Tool.
Build your own apps and tools *inside* Synapse or from external editor:

-   **[Overview](power_user/overview.md)**: Global Apps vs Note Actions vs AI Tools.

## Developer
For developers modifying the Core Dart/Flutter codebase.

-   **[Architecture](developer/architecture.md)**

### Regenerating the Manual
To regenerate the `USER_MANUAL.pdf` included in the app assets, run the build script from the `doc/` directory:
```bash
cd doc
./build_manual.sh
```
This requires `npx` (Node.js) to be installed on your system.
