# Plugins

Plugins are HTML/JS apps that run inside Note Synapse and talk to your notes through the Synapse API. Some are installed with the app; others you add yourself.

## Where an App Comes From

**Bundled starter apps** are installed with Note Synapse and need no setup. Formula Studio, Table Studio and Diagram Studio are the ones documented here; Mindmap, Note Quiz, Knowledge Graph, Language Learner and Interactive Learning are in the note actions menu too. File Browser, RSS feed, Webscraper and Mermaid also ship, as global apps and AI tools.

**Downloaded plugins** are a single `.yaml` file you import. They are not part of any release or app store build, so you go and fetch one when you want it.

| Plugin | Type | Availability |
| :--- | :--- | :--- |
| **[Formula Studio](formula_studio.md)** | Note Action | Bundled |
| **[Table Studio](table_studio.md)** | Note Action | Bundled |
| **[Diagram Studio](diagram_studio.md)** | Note Action | Bundled |
| **[DOS Station](dos_station.md)** | Note Action | Download |
| **Neon Cartridge** | Note Action | Download |
| **NotebookLM Manager** | AI Tool | Download |
| **YTFetcher** | AI Tool | Download |

*Note Action* apps run on the notes you select; *AI Tools* are called by the assistant during a conversation. See **[Overview](../../power_user/overview.md)** for the difference.

The three without a page of their own:

-   **Neon Cartridge** (in the `nes-arcade` folder) plays a `.nes` ROM attached to a note, with touch controls, turbo A/B, quick saves, and annotated screenshots saved back to the note. It makes no network requests.
-   **NotebookLM Manager** syncs notes into Google NotebookLM as sources, answers questions grounded in a notebook, and generates podcasts and slides. It signs in to your Google account inside the app.
-   **YTFetcher** adds one AI tool that pulls a YouTube video's transcript (English and Chinese) into a conversation.

## Installing a Downloaded Plugin

1.  Get the plugin's `.yaml` from the project repository, under `contrib/<plugin>/plugins/`.
2.  Open or share that file into Note Synapse. It is imported as a user app and appears in the note actions menu (or in the AI tool picker, for an AI Tool).
3.  If the plugin ships a skill in `contrib/<plugin>/skills/`, create a skill in Note Synapse from that Markdown file so the assistant knows how to drive the app. See **[Agent Skills](../ai/agent_skills.md)**.

Each plugin carries its own license. Check the plugin's own README and the `license` field of its `.yaml` before redistributing.

## Running One on Part of a Note

A Note Action app normally receives whole notes. It can also receive a single block: drop the edit pen on a block and tap the grid button in the block menu. The app then sees only those blocks. See **[Block-Based Editing](../editor/block_editing.md)**.

## Writing Your Own

Plugins are ordinary HTML and JavaScript against the Synapse API, and the AI can generate one for you. See **[Overview](../../power_user/overview.md)**.
