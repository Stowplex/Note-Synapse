# Hands-On: Agentic Research

Turn Note Synapse into a background worker.

## The "Research Agent" Workflow
### Problem
You want to know "How does Note Synapse handle dependency injection?" but you don't want to search through 50 files yourself.

### Walkthrough
1.  **Start Agent Mode**: Toggle the toggle switch from "Chat" to "Agent".
2.  **Define Objective**: Type: *"Analyze the codebase and explain the Service Locator pattern usage."*
3.  **Attach Context**:
    -   Tap the **Paperclip**.
    -   Add `lib/services/service_locator.dart`.
    -   *Tip*: Giving the agent a starting point helps it run faster.
4.  **Run**: Tap Send.
5.  **Multi-Tasking**:
    -   **Android Users**: You can minimize the app. A "Foreground Service" notification will appear ("Synapse Agent is Thinking...").
    -   Go check your email. The agent will continue reading files and reasoning in the background.

## Reviewing the Plan
1.  Before executing, the Agent will propose a **Plan** (e.g., "1. List files, 2. Read File A, 3. Read File B").
2.  **Edit the Plan**: You can delete steps that seem irrelevant (e.g., "Don't read `main.dart`, I know that's not it").
3.  **Approve**: Tap "Execute" to start the background work.

> **Screenshot Placeholder:** [Image of the Agent Plan Review screen, showing a list of proposed tasks with generic checkboxes.]
