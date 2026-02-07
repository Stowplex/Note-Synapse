# Web Clipper

The Web Clipper allows you to save content from your browser or other apps directly into Note Synapse. It supports intelligent extraction, readability enhancement, and file handling.

## How to Clip
1.  **Share**: In your browser (e.g., Chrome, Safari), tap the **Share** button.
2.  **Select Synapse**: Choose **Note Synapse** from the list of apps.
3.  **Choose Mode**: The clipper will analyze the content and offer the best saving method.

## 1. Web Pages (Readability)
When sharing a standard URL, Synapse behaves like a "Read-it-Later" app.

### Readability Toggle
*   **The Problem**: Many websites are cluttered with ads, popups, and broken layouts.
*   **The Fix**: Toggle **Readability Mode** (Book icon) in the clipper preview.
    *   **On**: Applies a clean, distraction-free layout, strips navigation/ads, and converts *only the article content* to Markdown.
    *   **Off**: Captures the raw HTML structure (useful for "Vibe Coding" where you want the exact DOM).

> ![Screenshot: The Web Clipper popup showing the Readability toggle button](placeholder_images/clipper_readability.png)

### Image Scraper
You don't have to save every banner ad.
*   **Detection**: Synapse validates all images on the page.
*   **Select**: You can check/uncheck purely decorative images before saving.
*   **Save**: Selected images are downloaded and attached locally to your note, ensuring they don't break if the original website goes down.

## 2. Auto-Download (PDFs & Files)
If you share a link to a file (e.g., an academic paper PDF, a ZIP file, or a Doc), Synapse automatically detects the **MIME Type**.
*   **Action**: Instead of saving the *link*, it downloads the actual **File**.
*   **Storage**: The file is saved to your local attachment storage.
*   **Note**: A new note is created with the file attached, tagged as `#download`.
