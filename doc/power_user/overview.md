# Powering Up: Creating Apps & Tools

Note Synapse is designed to be infinitely extensible. Unlike "Contributors" who write Dart code to modify the app's core (see [Contributing](../developer/index.md)), **Power Users** can create fully functional mini-apps, tools, and workflows directly inside Synapse using HTML, CSS, and JavaScript.

This is colloquially called **"Vibe Coding"**: you supply the idea and context, and Synapse's AI handles the implementation.

## 🌟 The 3 App Types

When creating a new app (`+` -> `Create App`), you can choose from three distinct types:

| App Type | Icon | Best For | Context |
| :--- | :--- | :--- | :--- |
| **Global App** | 📱 | Dashboard, Utilities, Games | System-wide (No specific note focus) |
| **Note Action** | ⚡ | Summarizers, Formatters, exporters | Runs *on* specific selected notes |
| **AI Tool** | 🤖 | Backend capabilities (e.g., Geocoding) | Called implicitly by the LLM during chat |

### 1. Global Apps (Normal)
These are independent applications that live in your App Drawer. They have their own database tables (SQLite) and can interact with the global state.
*   **Examples**: Weather Dashboard, Habit Tracker, Flashcards, Spaced Repetition Game.
*   **Access**: Through the "Apps" tab in the bottom navigation.

### 2. Note Actions
These apps appear in the "Action" menu when you select one or more notes. They are designed to *process* content.
*   **Examples**: "Summarize Selected", "Convert to Table", "Export to CSV", "Publish to WP".
*   **Access**: Long-press a detailed note -> `Actions` -> Select your app.
*   **Context**: The app automatically receives the selected note(s) as JSON in `window.Synapse.Notes`.

### 3. AI Tools
These are "Headless" apps. They provide **functions** that the AI can call during a chat. You define the logic, and the AI decides when to use it.
*   **Examples**: "Get Lat/Long for Address" (Geocoding), "Fetch Stock Price", "Search Wikipedia".
*   **Access**: You don't "open" them. You just ask the AI: *"Where is Paris?"*, and if your Geocoding tool is active, the AI will use it.

## 🛠️ The "Vibe Coding" Workflow

You don't need to be a master programmer. Synapse includes a built-in **App Studio**.

1.  **Describe it**: "I want an app that shows a heatmap of my notes based on tags."
2.  **Add Context**: Attach screenshots of designs you like, or existing notes as data examples.
3.  **Iterate**: Use the **Playground** to test the app. If something looks wrong, just tell the AI: *"Make the header blue"* or *"Fix the sorting bug"*.
4.  **Publish**: Save the app to your library.

---

**Next Steps:**
*   **[App Development Guide](app_development.md)**: The complete API reference and workflow guide.
*   **[Build a Geocoding AI Tool](ai_tools.md)**: Teach your AI new tricks.
*   **[Build a Note Summarizer](user_apps.md)**: Process your notes with custom logic.
*   **[External Development](external_development.md)**: Coding in VS Code & Python scripts.
