# Building Synapse Apps

Note Synapse allows developers to build powerful local-first extensions using standard HTML, CSS, and JavaScript. These apps run directly within the Synapse runtime and have access to native capabilities via the `window.Synapse` bridge.

## App Types

There are three types of Synapse Apps:

1.  **Global Apps**: Standalone tools accessed via the App Drawer. Examples: Dashboards, or Utilities.
2.  **Note Actions**: Scripts that run on specific selected notes. Examples: Summarizers, Formatters.
3.  **AI Tools**: Headless functions that the AI can call during conversations. Examples: Geocoding, Search.

## The Synapse API (`window.Synapse`)

Your app communicates with the host via the global `window.Synapse` object. All methods are asynchronous and return Promises.

### Core AI & Data
| Method | Description |
| :--- | :--- |
| `chatAI(prompt, options)` | Calls the configured LLM. `options` can include `temperature`, `model_hint`, `response_type` ('string' or 'multi_part'). |
| `runQuery(sql)` | Executes a SQLite query on the local database. Returns `{success, data, error}`. **Requires user approval for writes.** |
| `proxyFetch(url, options)` | Performs an HTTP request through the native app, bypassing CORS. Supports `method`, `headers`, `body`, `json`. |
| `fetchWebPage(url)` | Fetches a URL and returns parsed content, including a Markdown conversion. |

### Note Management
| Method | Description |
| :--- | :--- |
| `openNote(noteId, replaceWindow)` | Navigates the main app to the specified note. |
| `saveNotes(notes)` | Creates or updates notes. `notes` is an array of note objects. |
| `updateNotes(notes)` | Updates existing notes. |
| `deleteNotes(noteIds)` | Deletes notes by ID. **Requires user approval.** |
| `Notes` | (Property) In **Note Action** apps, this array contains the notes selected by the user. |

### State & Files
| Method | Description |
| :--- | :--- |
| `storeAppState(state)` | Persists a JSON object for your app. |
| `loadAppState()` | Retrieves the persisted state. |
| `saveTemp(data, mimeType)` | Prompts the user to save generated data (e.g., CSV, JSON) to a file. |
| `readAttachment(path)` | Reads the content of a local attachment. |

---

## Developing Externally

While you can write apps inside Synapse (with natural language), it is also possible to use your favorite IDE (VS Code, etc.) for complex projects.

### The Bundle
Synapse Apps are distributed as YAML files with a specific structure.

**Manifest Structure (`my_app.yaml`):**
```yaml
name: My Epic App
uuid: 1234-5678-90ab-cdef  # Unique ID
app_type: normal           # normal, note_action, or ai_tool
description: A clear description of what this app does.
author: Your Name
license: MIT
libraries:                 # Optional: External JS libraries
  - name: Chart.js
    instructions: "Use for plotting data."
    dependencies:
      - link: https://cdn.jsdelivr.net/npm/chart.js
code:PCFET0...             # Base64 encoded HTML string
```

### Packaging Workflow
1.  Develop your app as a standard `index.html` file.
2.  Create a `manifest.yaml` with your metadata.
3.  Use a script to bundle them into a `.yaml` file.

**Bundler Script (`bundle.py`):**
```python
import yaml, base64, sys, uuid

if len(sys.argv) < 3:
    print("Usage: python bundle.py <manifest.yaml> <index.html> [output.yaml]")
    sys.exit(1)

manifest_path, html_path = sys.argv[1], sys.argv[2]
output_path = sys.argv[3] if len(sys.argv) > 3 else "dist_app.yaml"

with open(manifest_path, 'r') as f: manifest = yaml.safe_load(f)
with open(html_path, 'r', encoding='utf-8') as f:
    manifest['code'] = base64.b64encode(f.read().encode('utf-8')).decode('utf-8')

if 'uuid' not in manifest: manifest['uuid'] = str(uuid.uuid4())

with open(output_path, 'w') as f: yaml.dump(manifest, f, sort_keys=False)
print(f"✅ App bundled to {output_path}")
```

---

## Examples

### 1. Simple Note Summarizer (Note Action)
**manifest.yaml**:
```yaml
name: Quick Summarizer
app_type: note_action
description: Summarizes selected notes using AI.
```

**index.html**:
```html
<!DOCTYPE html>
<html>
<head>
<style>
  body { font-family: system-ui; background: #111; color: #eee; padding: 20px; }
  .card { background: #222; padding: 15px; margin-bottom: 15px; border-radius: 8px; }
  h3 { margin-top: 0; color: #4af; }
</style>
</head>
<body>
  <h1>Summaries</h1>
  <div id="container">Loading...</div>

  <script>
    async function run() {
      const container = document.getElementById('container');
      const notes = window.Synapse.Notes;
      
      if (!notes || notes.length === 0) {
        container.innerHTML = "No notes selected.";
        return;
      }

      container.innerHTML = "";
      
      for (const note of notes) {
        const div = document.createElement('div');
        div.className = 'card';
        div.innerHTML = `<h3>${note.title}</h3><p>Generating...</p>`;
        container.appendChild(div);

        // Call AI
        const response = await window.Synapse.chatAI(
          `Summarize this note in one sentence:\n\n${note.content}`
        );
        
        div.querySelector('p').innerText = response.response;
      }
    }
    run();
  </script>
</body>
</html>
```

### 2. AI Tool Definition
AI Tools are "headless" but defined in HTML. They use a special CDATA block to tell the planner their capabilities.

**index.html**:
```html
<!DOCTYPE html>
<!-- 
  AI Tools require a tool_spec definition in YAML format inside a CDATA block.
  This tells the AI planner how to use your tool.
-->
<script>
<![CDATA[tool_spec:
  - name: weather_lookup
    description: Gets the current weather for a city.
    input_params:
      city:
        type: string
        description: The city name.
    output_params:
      temperature:
        type: number
      condition:
        type: string
]]>
</script>
<script>
  // Implement the logic
  window.Synapse.tool = {};
  window.Synapse.tool.registered = {
    weather_lookup: async ({ city }) => {
      // Use proxyFetch to avoid CORS
      const apiKey = 'YOUR_API_KEY';
      const url = `https://api.weatherapi.com/v1/current.json?key=${apiKey}&q=${city}`;
      const resp = await window.Synapse.proxyFetch(url);
      const data = JSON.parse(resp.content.data);
      
      return {
        temperature: data.current.temp_c,
        condition: data.current.condition.text
      };
    }
  };
</script>
```
