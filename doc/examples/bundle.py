import yaml
import base64
import os
import sys
import uuid

def bundle_app(manifest_path, html_path, output_path):
    print(f"📦 Bundling {manifest_path} + {html_path} -> {output_path}")
    
    # 1. Read Manifest
    try:
        with open(manifest_path, 'r') as f:
            manifest = yaml.safe_load(f)
    except Exception as e:
        print(f"❌ Error reading manifest: {e}")
        return

    # 2. Read HTML and Encode
    try:
        with open(html_path, 'r', encoding='utf-8') as f:
            html_content = f.read()
        
        encoded_code = base64.b64encode(html_content.encode('utf-8')).decode('utf-8')
    except Exception as e:
        print(f"❌ Error reading HTML: {e}")
        return

    # 3. Inject Code
    manifest['code'] = encoded_code
    
    # 4. Generate UUID if missing (Optional)
    if 'uuid' not in manifest:
        new_uuid = str(uuid.uuid4())
        print(f"⚠️  No UUID found in manifest. Generated: {new_uuid}")
        manifest['uuid'] = new_uuid

    # 5. Write Output
    try:
        with open(output_path, 'w') as f:
            yaml.dump(manifest, f, sort_keys=False)
        print(f"✅ App bundled successfully to {output_path}")
    except Exception as e:
        print(f"❌ Error writing output: {e}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python bundle.py <manifest.yaml> <index.html> [output.yaml]")
        sys.exit(1)
        
    manifest = sys.argv[1]
    html = sys.argv[2]
    output = sys.argv[3] if len(sys.argv) > 3 else "dist_app.yaml"
    
    bundle_app(manifest, html, output)
