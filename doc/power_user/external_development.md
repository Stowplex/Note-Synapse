# External Development: The `.nsapp` Workflow

While the in-app editor can handle simple apps, you might prefer a proper IDE (VS Code, Cursor, etc.) for complex applications.

Note Synapse apps can be imported from a standard YAML format.

## The `.yaml` Format
An exported app is a single YAML file containing metadata and Base64-encoded source code.

```yaml
name: My Weather App
uuid: 1234-5678-uuid
app_type: normal # normal, note_action, or ai_tool
description: A dashboard for weather.
author: Jane Doe
license: MIT
libraries:
  - name: Chart.js
    instructions: |
      Use for plotting temp.
    dependencies:
      - link: https://cdn.jsdelivr.net/npm/chart.js
code: PCFET0NUW... (Base64 Encoded HTML)
```

## Developer Workflow
We recommend keeping your source code as a plain `index.html` file and your metadata in a `manifest.yaml`.

### Folder Structure
```
my_weather_app/
├── index.html       # Your HTML/JS/CSS
├── manifest.yaml    # Metadata
└── bundle.py        # Build script
```

### `manifest.yaml` Usage
Keep the `code` field empty in your source manifest. The build script will fill it.

```yaml
name: Super Weather
app_type: normal
description: Shows weather.
author: You
license: MIT
```

### Build Script (`bundle.py`)
Use this Python script to bundle your HTML into a Synapse-ready YAML file.

```python
import yaml
import base64
import os
import sys

def bundle_app(manifest_path, html_path, output_path):
    # 1. Read Manifest
    with open(manifest_path, 'r') as f:
        manifest = yaml.safe_load(f)

    # 2. Read HTML and Encode
    with open(html_path, 'r', encoding='utf-8') as f:
        html_content = f.read()
    
    encoded_code = base64.b64encode(html_content.encode('utf-8')).decode('utf-8')

    # 3. Inject Code
    manifest['code'] = encoded_code
    
    # 4. Generate UUID if missing (Optional)
    if 'uuid' not in manifest:
        import uuid
        manifest['uuid'] = str(uuid.uuid4())

    # 5. Write Output
    with open(output_path, 'w') as f:
        yaml.dump(manifest, f, sort_keys=False)
    
    print(f"✅ App bundled to {output_path}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python bundle.py <manifest.yaml> <index.html> [output.yaml]")
        sys.exit(1)
        
    manifest = sys.argv[1]
    html = sys.argv[2]
    output = sys.argv[3] if len(sys.argv) > 3 else "dist_app.yaml"
    
    bundle_app(manifest, html, output)
```

### Usage
1.  Run: `python bundle.py manifest.yaml index.html my_app.yaml`
2.  Transfer `my_app.yaml` to your device (iCloud, AirDrop, etc.).
3.  In Synapse: **Apps** -> **Import App** -> Select the YAML file.

## Example: Quick Weather App (`index.html`)

```html
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: sans-serif; padding: 20px; background: #1a1a1a; color: white; }
        .temp { font-size: 4em; font-weight: bold; }
    </style>
</head>
<body>
    <h1>Current City</h1>
    <div id="weather" class="temp">Loading...</div>
    
    <script>
        async function load() {
            // Note: Synapse.chatAI is great for "Fake" weather if you don't have an API key!
            const prompt = "What is the typical weather in Tokyo right now? Give me just the temperature number in Celsius.";
            const resp = await window.Synapse.chatAI(prompt);
            document.getElementById('weather').innerText = resp.response + "°C";
        }
        load();
    </script>
</body>
</html>
```
