# Architecture

## Technical Stack
- **Framework**: Flutter (Dart)
- **Database**: SQLite (via `sqflite` FFI)
- **AI**: Gemini API / OpenAI API (Standardized Interface)
- **Network**: HTTP/1.1 + HTTP/3 (QUIC)

## Network Resilience (HTTP/3)
LLM inference requests are long-lived and fragile. Simple timeouts break agents.
Note Synapse uses a custom networking stack including **HTTP/3 (QUIC)** to ensure stability on flaky mobile networks (e.g., switching from WiFi to 5G while an agent is thinking).
- **Libraries**: Custom Rust-based HTTP client bridged via FFI.

## Agent Architecture
Agents are not just "loops".
- **Android**: Agents run as **Foreground Services**. This means you can start a deep research task, switch to another app, lock your phone, and the agent continues to work.
- **State Machine**: Notes are the state. An agent reads a note, performs an action, and updates the note. This provides "Time Travel" debugging for agents.

## Local-First Data Model
Your data is yours.
- **DB Path**: `note_synapse.db` in your App Documents folder.
- **Attachments**: Stored as raw files in `attachments/`.
- **Querying**: You can open the DB with any SQLite viewer. The schema is straightforward:
    - `notes`: id, title, content (markdown), type
    - `note_tags`: many-to-many link
    - `relationships`: graph edges (parent/child, related)
