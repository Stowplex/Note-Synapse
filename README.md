# Note Synapse
> **Extensible study companion for Android and iOS.**

Note Synapse is a local-first, open-source note-taking app built for developers, researchers, and power users who want to **program their thoughts**.

### Download

**Debug build available for free on Github**

[Download Nightly Debug Build APK (Dev Key)](https://github.com/kkspeed/Note-Synapse/releases)

**You can also get the release build from Google Play**

<a href="https://play.google.com/store/apps/details?id=com.github.kkspeed.note_synapse.note_synapse">
  <img src="https://raw.githubusercontent.com/pioug/google-play-badges/refs/heads/main/svg/en.svg" alt="Get it on Google Play" width="200"/>
</a>


---

## Features

### Expansive Thought Processing
Thoughts are expansive, and your chat interface should reflect that. Note Synapse features **tree-structured AI conversations**, allowing you to branch logic paths and explore alternatives without losing the original thread.

[Demo](https://stowplex.github.io/Note-Synapse-Site/index.html#philosophy)

### Immersive Focus
Facilitate deep reading in an era of "AI summaries." Note Synapse's **Immersive Mode** enables in-context conversation with AI directly alongside your content. Use **Circle-to-Ask** to instantly query specific text or formulas without breaking flow.

[Demo](https://stowplex.github.io/Note-Synapse-Site/index.html#focus)

### Precise Context Management
Master your AI's attention with granular context control.
- **Context Composition**: Select specific conversation turns to branch new dialogues or extract key insights, keeping your workspace clean and focused.
- **Token Economy**: Manually exclude verbose tool outputs or intermediate thought chains to optimize context windows.
- **Attachment Targeting**: Selectively include or exclude note attachments. For PDFs, precisely target the full document, current reading window, bookmarked pages, or specific chapters.

[Demo](https://stowplex.github.io/Note-Synapse-Site/index.html#focus)

### Natural Language Extensibility
Create and refine powerful **Mini Apps and AI Tools** within the app using natural language.
- **Educational Tools**: Generate pop quizzes, flashcards, and guided learning apps.
- **Custom Interfaces**: Build bespoke dashboards and knowledge graph visualizations.
- **Interactive Media**: Embed custom tools, from data analyzers to NES emulators, directly into your notes.

[Demo](https://stowplex.github.io/Note-Synapse-Site/index.html#extensibility)

### Hierarchical Tagging
Enjoy the best of both worlds with a system that merges the flexibility of tags with the structure of folders. Tag sets naturally form a hierarchy, organizing your knowledge base intuitively.

[Demo](https://stowplex.github.io/Note-Synapse-Site/index.html#organization)

### Agentic Core & MCP Support
AI tasks execution with user-selectable tools and external MCPs. Built-in agent mode to carry out complex tasks that require multiple steps.

[Demo](https://stowplex.github.io/Note-Synapse-Site/index.html#agency)

### Sovereign Data Architecture
- **Local-First Storage**: All data is stored locally with flexible export options. (Encrypted cloud sync on roadmap).
- **BYOK Privacy**: Bring Your Own Key (BYOK) model ensures zero data collection and zero telemetry. You retain full control over your data and AI provider choices.

### Intuitive Interactions
- **Focus Mode Editing**: Drag the edit icon to any paragraph to edit just that block—perfect for quick corrections.
- **Gestural Calendar**: Fluid task editing with a drag and pinch.

[Demo](https://stowplex.github.io/Note-Synapse-Site/index.html#interaction)

---

## Quick Start

### Prerequisites
- Flutter SDK 3.x, Android SDK / NDK, XCode
- A Google Gemini API Key (or OpenAI Compatible Key)
- Rust toolchain -- recommend installation with rustup

### Build from Source
```bash
git clone --recursive https://github.com/kkspeed/Note-Synapse.git
cd Note-Synapse
flutter pub get
flutter build apk --debug
```

## Documentation

Read the full documentation at **[doc/README.md](doc/README.md)**.

## License
Dual license: AGPL v3 & Proprietary. See [LICENSE](LICENSE) for details.
