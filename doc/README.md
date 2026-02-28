# Note Synapse Documentation

## Getting Started
-   **[Setup Guide](guides/ai/onboarding.md)**: Setting up your first model and API keys.

## Editor & Writing
-   **[Block-Based Editing](guides/editor/block_editing.md)**: The gesture, reordering, and block types.
-   **[Note Editing](guides/editor/note_editing.md)**: Using the note editor.

## Organization
-   **[Tag Filter](guides/organize/tag_filter.md)**: Filter notes by combining multiple tags into hierarchies.
-   **[Tag Image](guides/organize/tag_image.md)**: Add images to visualize your tags.
-   **[Tag Manager & Dedup](guides/organize/tag_manager.md)**: Bulk delete and Merge tags (Manual & AI).
-   **[Tag Prompts](guides/ai/tag_prompts.md)**: Associate pre-defined prompts with tags.

## AI & Thinking
-   **[AI Conversations](guides/ai/ai_conversations.md)**: non-linear conversations with notes as context, forking throughts, and pruning context.
-   **[Agentic Research](guides/ai/agents.md)**: Complex task planning and execution.
-   **[Immersive Reading](guides/ai/immersive_reading.md)**: Intuitively interacting with documents.
-   **[Smart Model Matching](guides/ai/smart_model_matching.md)**: Automatically switch models based on capabilities.
-   **[MCP Tools](guides/ai/mcp.md)**: Connect Note Synapse to external tools.

## Productivity
-   **[Web Clipper](guides/productivity/web_clipper.md)**: Saving knowledge from the web.
-   **[Calendar & Tasks](guides/productivity/calendar.md)**: Scheduling and task management.
-   **[Multi-Function Tab](guides/productivity/multi_function_tab.md)**: Custom default views.

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
