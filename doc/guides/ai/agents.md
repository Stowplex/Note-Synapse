# Agentic Mode: Your Autonomous Partner

Agentic Mode turns Note Synapse from a chatbot into an active problem solver. Instead of just answering with text, it can plan, use tools, create files, and execute multi-step workflows to achieve your goals.

## How to Enter Agentic Mode
Unlike standard chat tools, Agentic Mode requires **explicit activation** to engage the Planner.

1.  Open a Conversation.
2.  Expand the **Tools Panel** (Puzzle piece icon `extension`).
3.  **Check the "Agent" box** (Icon: `psychology`, Purple).
4.  Send your request (e.g., "Research the best noise-canceling headphones and create a comparison table note").

### The Planner Workflow
Once the Agent tool is active, the next message you send will trigger the **Planner Step**:

1.  **Request**: You send a complex goal.
2.  **Planning**: The AI analyzes your request and tools, then generates a **Plan** (a series of proposed steps).
3.  **Review (Planner Widget)**: You see the proposed plan in the chat. You can:
    *   **Edit**: Modify steps if the agent misunderstood.
    *   **Approve**: Click "Start" to begin execution.
    *   **Reject**: Cancel or ask for a revision.
4.  **Execution**: The agent executes tasks one by one, updating you on progress.

## Types of Tools
The planner can use three types of tools to accomplish tasks:

1.  **Built-in Tools**: Native capabilities of Note Synapse.
    *   *Examples*: Search Notes, Read Note, Create/Modify Note, SQL Query.
    *   *Agent Tool*: The planner itself is technically a built-in tool!
2.  **MCP Tools**: External tools provided by **Model Context Protocol** servers.
    *   *Examples*: Google Drive, Slack, GitHub, Filesystem access.
    *   *Setup*: specific in `Settings -> AI Settings -> MCP Servers`.
3.  **Local Tools (AI Apps)**: Custom tools created by **You** within Note Synapse.
    *   *Examples*: A specific "Customer Data Lookup" script or a "Daily Log Generator".
    *   *Creation*: Create a User App with type `AI Tool`.


> [!TIP]
> **Pro Tip: Turn your Agent into a Power Intern**
> Empower the LLM with a web-search centric MCP like **Exa.ai**, **Jina**, or **SerpApi**.
> These tools allow the agent to perform broad internet research, read results, and synthesize answers far better than standard "browsing" tools, effectively turning it into a dedicated researcher.

## Attaching Skills & Instructions
You can "teach" the agent how to behave or give it specific domain knowledge by attaching **Notes**.

1.  **Global Context (Available All Time)**:
    *   Attach notes via the **Note Icon** (`library_books`) in the top bar.
    *   These notes are visible to the planner throughout the entire conversation, used for high-level instructions (e.g., "Standard Operating Procedure: Bug Reports").
2.  **Local Step Context (Task Specific)**:
    *   Attach notes directly to a specific **Plan Step** in the Planner Widget.
    *   These notes are visible *only* to the agent executing that specific step. This gives you precise control, preventing context pollution for other steps.

## Background Execution
Agentic tasks can take time. You don't need to keep the app open.

*   **Android**: The agent runs in a **Foreground Service**. You will see a notification in your status bar showing the current subtask. You can switch apps or lock your phone.
*   **iOS**: Due to OS limitations, the agent must stay in the foreground. Note Synapse prevents screen sleep while the agent is working.

## Configuring the Planner (Settings)
Go to **Settings -> AI Settings -> Agentic Settings** to tune the planner's brain.

### 1. Performance vs. Depth
*   **Max Subtask Depth** (Default: 2): Controls how "deep" the recursion goes.
    *   `0`: Linear tasks only.
    *   `2`: Standard. Can break tasks into subtasks.
    *   `5`: Maximum complexity.
*   **Max Turns** (Default: 10): Maximum steps per task loop.

### 2. Token Optimization (Critical)
Manage the trade-off between "Context Window" (Memory) and "TPM" (Rate Limits).

> [!IMPORTANT]
> **Context Window vs. Rate Limits (TPM)**
> Models have **Tokens Per Minute (TPM)** limits. Sending full history every step can hit these limits instantly, even if the model supports a 1M token context window.

*   **Compaction Threshold**: The "Safety Valve" for TPM. When history exceeds this, old steps are zipped into a summary. Lower this if hitting rate limits.
*   **TOC Inline Threshold**: Controls **Context Pruning**. Large tool outputs are collapsed into a Table of Contents to save tokens. The agent reads specific sections only if needed.
