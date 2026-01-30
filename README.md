# Note Synapse
> **The Hackable, Agentic Second Brain.**

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE)
[![Build Status](https://img.shields.io/badge/build-passing-brightgreen.svg)]()

Note Synapse is a local-first, open-source note-taking app built for developers, researchers, and power users who want to **program their thoughts**. It is not just a container for text; it is a runtime for your intelligence.

### 📥 [Download Nightly Build (Dev Key)](https://github.com/active-stack/Note-Synapse/releases)

---

## ⚡ The "Synapse 14" (Why this is different)

### 1. "Vibe Code" Your Tools
Don't wait for a feature. **Description-to-App** generation is built-in.
1. Clip an API doc using the Web Clipper.
2. Tell Synapse: "Make me a dashboard using this API."
3. Result: A fully functional HTML/JS app running inside your notes with full SQL & AI access.
[Read Developer Docs](doc/developer/user_apps.md)

### 2. Tag Algebra (Virtual Folders)
Stop moving files. Use math.
- Logic: `Tag A` + `Tag B` = `Tag B` is a sub-folder of `A`.
- Result: Fluid, self-organizing hierarchy. `AI Learn/LLM` is automatically created just by using tags.

### 3. Git for Chat (Tree Conversations)
LLMs hallucinate. Don't let a bad turn ruin a good chat.
- **Forking**: Branch any conversation at any message.
- **Pruning**: Mute verbose tool outputs (like SQL dumps) to save context tokens while keeping the reasoning.

### 4. Agentic Core
- **Background Agents**: Run deep research tasks on Android as Foreground Services. They work while you sleep.
- **MCP Support**: Use standard **Model Context Protocol** tools used by Claude/Cursor.
- **Github Exploration**: Agents can clone, read, and analyze repos to answer your questions.

### 5. Immersive Study
- **Circle-to-Ask**: Reading a PDF? Circle a formula with your finger and ask the AI to explain it.
- **Context Handling**: Pinpoint control. "Include read position +/- 5 pages."

### 6. Hackable Architecture
- **Direct SQL Access**: User Apps can run `window.Synapse.runQuery('SELECT * FROM notes')`.
- **HTTP/3 Stack**: Custom Rust-based networking layer for bulletproof inference on flaky 5G.
- **Local First**: SQLite database. Plain files. **No Cloud. No Tracking.**

---

## 🚀 Quick Start

### Prerequisites
- Flutter SDK 3.x
- A Google Gemini API Key (or OpenAI Compatible Key)

### Build from Source
```bash
git clone https://github.com/kkspeed/Note-Synapse.git
cd Note-Synapse
flutter pub get
flutter run
```

## 📚 Documentation

- **[Core Concepts](doc/guides/core_concepts.md)**: Tag Algebra, Block Editing, Privacy.
- **[Productivity Guide](doc/guides/productivity.md)**: Web Clipper, Calendar, Immersive Reading.
- **[AI Power User](doc/guides/ai_conversations.md)**: Tree Chats, Agentic Mode, Prompt Engineering.
- **[Developer API](doc/developer/user_apps.md)**: `window.Synapse` reference, Vibe Coding workflows.
- **[Architecture](doc/developer/architecture.md)**: How the HTTP/3 stack works.

## License
AGPL v3 + Private Commons.
See [LICENSE](LICENSE) for details.
