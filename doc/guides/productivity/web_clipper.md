# Hands-On: Web Clipper & API Vibe Coding

Stop copy-pasting. Start clipping.

## The "Readability" Toggle
### Problem
You want to read a long article in Note Synapse, but the "Raw" view is full of ads, popups, and broken layout scripts.

### Walkthrough
1.  **Open Browser**: Go to any article (e.g., a Hacker News link).
2.  **Share**: Tap the system **Share** button -> **Note Synapse**.
3.  **The Switch**:
    -   **ON**: Synapse strips all junk. *Why?* Better for reading and standardizing the text for the AI.
    -   **OFF**: Synapse keeps the raw HTML. *Why?* Better for "Vibe Coding" where you need the exact table structure or API code blocks.
4.  **Save**.

## Dealing with Images
Images are tricky. Here are the two ways Note Synapse handles them.

### Method 1: The "Rich" Clip
If you use the Web Clipper with **Readability ON**, Synapse tries to download the main article images as **Attachments**.
-   They appear at the bottom of the note.
-   They act as local files (great for offline).

### Method 2: Fetching Later
Sometimes the clipper misses images, or you clipped in "Raw" mode (where images are just URL links).
1.  Open the Note.
2.  Tap the **Examples/Menu** (`more_vert`) icon.
3.  Select **"Fetch Remote Images"**.
4.  **Result**: The app scans the note for `![](http://...)` links, downloads them, and converts them to local attachments `![](file://...)`.


## Hands-On: Clipping API Docs for Vibe Coding
### Usage
You want to build an app that uses the **Stripe API**, but the AI doesn't know the latest endpoints.

1.  Navigate to the Stripe API reference for "Create Charge".
2.  **Share** to Note Synapse.
3.  **Turn Readability OFF**.
    -   *Why?* You want the raw table structures and code blocks so the AI can understand the exact JSON schema.
4.  **Use it**: Now use this note as context to say "Write me a Stripe dashboard".
