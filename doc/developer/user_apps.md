# User Apps & "Vibe Coding"

Turn your notes into software. User Apps are HTML/JS applications that run *inside* Note Synapse with privileged access to your data and AI.

## The "Vibe Coding" Workflow
You don't need to write code to build a tool. You just need the *docs*.

### Tutorial: "Build a Weather Dashboard"
1.  **Clip**: Use the Web Clipper to save the `OpenWeatherMap API` documentation page.
2.  **Context**: Open a new Chat. Add the "OpenWeatherMap API" note as context.
3.  **Prompt**:
    > "Create a User App called 'Weather Dash'. It should use `window.Synapse.proxyFetch` to call the API. Ask the user for a city, then display the current temp and icon. Use the API key provided in the system prompt."
4.  **Result**: Note Synapse generates a fully functional HTML/JS app. Click "Run" to test it instantly.

> **Screenshot Placeholder:** [Image showing the 'Create User App' dialog with the API documentation attached as context.]

## `window.Synapse` API Reference

### 1. Database Access (SQL)
Directly query your `note_synapse.db` SQLite database.
```javascript
// Get tasks due today
const today = new Date().toISOString().split('T')[0];
const tasks = await window.Synapse.runQuery(
  `SELECT * FROM notes 
   WHERE type = 'task' 
   AND json_extract(content, '$.dueDate') LIKE '${today}%'`
);
```

### 2. State Management
Apps can persist state between sessions.
```javascript
// Save preferences
await window.Synapse.storeAppState({ theme: 'dark', lastCity: 'London' });

// Load preferences
const state = await window.Synapse.loadAppState();
console.log(state.lastCity); // 'London'
```

### 3. AI Integration (Multi-Part)
```javascript
const response = await window.Synapse.chatAI(
  "Analyze this data...",
  { 
    temperature: 0.7,
    model_hint: ['gemini-pro'] 
  }
);
```


### 3. Network Proxy
Bypass CORS (Cross-Origin Resource Sharing) restrictions.
```javascript
// Fetch data from any API, even if it doesn't support CORS
const data = await window.Synapse.proxyFetch(
  "https://api.example.com/data"
);
```

### 4. Note Manipulation
```javascript
// Save a new note
await window.Synapse.saveNotes([
  { title: "Report", content: "..." }
]);

// Open a note in the editor
await window.Synapse.openNote("note-id-123");
```

## Security Model
- **Read-Only by Default**: Apps can read DB/Notes by default.
- **Modification Approval**: The first time an app tries to `deleteNotes` or run a `Write` SQL query, the user is prompted to approve the session.
