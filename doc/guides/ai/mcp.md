# Connecting to External Tools (MCP)

Note Synapse uses the **Model Context Protocol (MCP)** to talk to the outside world.
 

## What is MCP?
MCP (Model Context Protocol) is an open standard that allows AI assistants to connect to external data and tools. 

## Supported Transports
1.  **SSE (Server-Sent Events)**: Best for remote servers.
2.  **StreamHTTP**: Note Synapse supports MCP over HTTPStreaming 

## How to Connect: The Definitive Guide

### 1. The "Magic" Way (Auto-Discovery)
If your MCP server supports OpenID Connect (OIDC) discovery, Note Synapse can configure itself.

1.  **Add Endpoint**: Settings -> MCP -> Add (+).
2.  **Transport**: Select `SSE` (or HTTP).
3.  **Auth (OAuth Tab)**:
    -   Click the **Magic Wand Icon** (`auto_fix_high`).
    -   Enter the base URL of your server (e.g., `https://my-mcp-server.com`).
    -   Tap **Discover**.
4.  **Result**: Synapse fetches the meta-data and auto-fills `Authorization URL`, `Token URL`, and `Scopes`.
5.  **Login**: Click the **Login** icon button to authenticate and capture your first token.
6.  **Save**: Click Create/Save.

> **Screenshot Placeholder:** [Image of the OAuth Discovery dialog showing the "Auto Configure" button and auto-filled fields.]

### 2. The "Simple" Way (Token Auth)
For servers that just need a static secret.

1.  **Add Endpoint**: Settings -> MCP -> Add (+).
2.  **Auth (Token Tab)**:
    -   Paste your Bearer token (e.g., `sk-proj-...`).
3.  **Save**.

> **Screenshot Placeholder:** [Image of the MCP Settings dialog with the 'Token' tab selected and a token pasted in.]

### 3. The "Manual" Way (Advanced OAuth)
If auto-discovery fails, you can enter the OAuth details manually.

1.  **Auth (OAuth Tab)**: Fill in the fields manually.
    -   **Auth URL**: `https://accounts.google.com/o/oauth2/v2/auth`
    -   **Token URL**: `https://oauth2.googleapis.com/token`
    -   **Client ID**: Your registered app ID.
    -   **Scopes**: Space-separated list (e.g., `openid profile email`).
    -   **PKCE**: Check this if your server handles Proof Key for Code Exchange (standard for mobile apps).
2.  **Login**: You MUST click the Login button *inside* this dialog to verify the flow before saving.

## Debugging Tools (AI Introspection)
If a tool isn't working, use the **AI Debug Overlay**:
1.  Enable it in **Settings -> AI Debug Overlay**.
2.  Look for "MCP: Call Tool" requests.
3.  Inspect the `Result` payload to see raw JSON-RPC errors.

> **Screenshot Placeholder:** [Image of the AI Debug Overlay showing a successful MCP tool call and its JSON response.]

