# Building User Apps: Note Action Example

While AI Tools run in the background, **User Apps** have a UI. They can be **Global** (Dashboards) or **Note Actions** (Processors).

In this guide, we will build a **Note Summarizer** that takes selected notes and displays a compiled summary table.

## The Goal
Create an app that:
1.  Is accessible when long-pressing meaningful notes.
2.  Reads the content of those notes.
3.  Uses an LLM (via `Synapse.chatAI`) to summarize them.
4.  Displays the result in a nice HTML table.

## Step 1: Create the App
1.  **Apps** -> **+ create**.
2.  **Type**: **Note Action** (Important! This gives it access to `window.Synapse.Notes`).
3.  **Name**: `Action Summarizer`.
4.  **Prompt**:
    ```text
    Create a note action app. 
    It should read all selected notes from window.Synapse.Notes.
    For each note, call `Synapse.chatAI` to generate a 1-sentence summary.
    Display a table with columns: "Title", "Date", "Summary".
    Style it with a modern dark theme.
    ```

## Step 2: Libraries & Prompt Engineering
You can enhance your app with external JavaScript libraries (e.g., specific charting libs, PDF generators).

### Adding Libraries
In the **Advanced** tab of the App Creator:
1.  **Add Library**: e.g., `Chart.js`.
2.  **Links**: CDN link (e.g., `https://cdn.jsdelivr.net/npm/chart.js`).
3.  **Usage Instructions**: *Tell the AI how to use it.*
    *   *Example*: "Use Chart.js for all visualizations. Initialize charts on canvas elements."

> [!NOTE]
> **Global vs App Scope**
> Libraries added here are **specific to this app**. Synapse also ships with "Global Libraries" (like Markdown parsers or MathJax) that are available to all apps. You can toggle these in Settings.

## Step 3: Understanding the Code
The AI will generate something like this:

```html
<script>
async function generateSummaries() {
  const notes = window.Synapse.Notes; // Automatically populated
  const tbody = document.getElementById('summary-body');
  
  for (const note of notes) {
    // 1. Ask AI to summarize
    const aiResp = await window.Synapse.chatAI(
      `Summarize this in 1 sentence: ${note.content}`,
      { temperature: 0.3 }
    );
    
    // 2. Render Row
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td>${note.title}</td>
      <td>${new Date(note.updatedAt).toLocaleDateString()}</td>
      <td>${aiResp.response}</td>
    `;
    tbody.appendChild(tr);
  }
}
</script>
```

### Key API: `window.Synapse`
This is your bridge to the native app.

| Function | Description |
| :--- | :--- |
| `Synapse.Notes` | Array of selected notes (Note Action apps only). |
| `Synapse.chatAI(prompt, options)` | Calls the user's preferred LLM. |
| `Synapse.runQuery(sql)` | Execute SQLite queries on the database (requires user permission). |
| `Synapse.openNote(id)` | Navigates the main app to a specific note. |
| `Synapse.saveTemp(data, mime)` | Prompts user to save a generated file (e.g., CSV). |

## Step 4: Using the App
1.  Go to your **Notes List**.
2.  **Long Press** a note to enter selection mode. Select a few.
3.  Tap the **Actions** menu (Three dots or lightning bolt).
4.  Select **Action Summarizer**.
5.  Watch it run!

## Pro Tip: Prompt Tailoring
You can "Soft Code" behaviour. Instead of writing complex regex to parse text, just instruct the Javascript to ask the AI:

*   *"Extract all phone numbers from this note"*
*   *"Convert this unstructured text into JSON"*

The `Synapse.chatAI` function is your universal adapter.
