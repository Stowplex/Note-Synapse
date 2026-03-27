# Agent Skills Design

**Date:** 2026-03-25
**Status:** Approved

## Overview

Agent Skills extend Note Synapse's agentic capabilities with reusable, user-authored workflow templates. Skills are ordinary notes tagged `agent-skill` with a YAML frontmatter header. The agent discovers available skills at startup, lazily loads skill content on demand, and dynamically injects skill-referenced tools into the active tool set.

Skills work in two modes:
- **Chat mode (A):** skills inject tools into the `function_tools` section of API requests
- **Agentic mode (B):** skills inject tool descriptions into the system prompt; LLM calls them via `<action type="tool">`

---

## Section 1: Skill Note Format

A skill is a regular note tagged `agent-skill` with YAML frontmatter:

```markdown
---
name: Weekly Review
description: Use when the user wants a structured weekly review of notes and tasks
enabled: true
---

## Weekly Review Workflow

1. Search notes from this week with `search_notes`
2. For task breakdown, call `load_skill` on [Task Decomposition](notesynapse://note/<uuid>)
3. Consult [My Projects Overview](notesynapse://note/<uuid>) with `read_note` for project context
4. Produce a summary with action items
```

**Frontmatter fields:**
- `name` — display name
- `description` — a single sentence describing *when* this skill should be used (shown in agent discovery index)
- `enabled` — `true` to participate in discovery; `false` to exclude

**Note links in skill content:**
- Links to other `agent-skill` notes — sub-skills; agent loads them with `load_skill(<uuid>)`
- Links to regular notes — references; agent reads them with `read_note`
- Tool references — `notesynapse://tool/builtin/<name>`, `notesynapse://tool/user_defined/<uuid>[/<function>]`, or `notesynapse://tool/mcp/<service_name>[/<function>]`

Skills are created and edited entirely in the existing note editor. No special UI is required.

---

## Section 2: Skill Discovery & System Prompt Integration

At agent startup, `SkillService` builds the skill index:

1. Query all notes tagged `agent-skill`
2. Parse YAML frontmatter from each note's content
3. Filter to `enabled: true`; skip and log notes with missing or malformed frontmatter
4. Build map: `noteId → { name, description }`

This index is injected into **both** the plan generation prompt and the task execution system prompt:

```
## Available Agent Skills
When a skill is relevant, call load_skill(<noteId>) to get the full workflow.

<noteId1>: Weekly Review — Use when the user wants a structured weekly review
<noteId2>: Task Decomposition — Use when breaking a large goal into subtasks
```

The plan generation prompt uses this to reference skill names in task descriptions. Task execution uses `load_skill` at runtime to get the actual workflow content.

The skill index is built once at agent session start and cached for the session duration.

---

## Section 3: `load_skill` Tool

New `NativeTool` in `lib/services/tools/load_skill_tool.dart`.

**Name:** `load_skill`

**Description:** Load a skill note by ID to get detailed workflow instructions.

**Input schema:**
```json
{
  "noteId": { "type": "string", "description": "The note ID of the skill to load" }
}
```

**Behavior:**
1. Fetch note by ID from `DatabaseService`
2. Note not found → error: `"Skill note <noteId> not found"`
3. Parse YAML frontmatter — missing or malformed → error: `"Note <noteId> is not a valid skill (missing or malformed frontmatter)"`
4. `enabled: false` → error: `"Skill '<name>' is disabled"`
5. Strip frontmatter; return: `"# Skill: <name>\n\n<content>"`
6. `SkillService` scans the returned content for `notesynapse://tool/` and `notesynapse://mcp/` URIs and resolves them into the session's skill-discovered tools set (see Section 4)

**Availability:** Included by default in both chat mode and agentic mode. Can be excluded per-conversation via the skills toggle (see Section 5). Not user-configurable globally.

---

## Section 4: Tool Discovery & Dynamic Injection

When `load_skill` returns content, the service layer scans it for tool URI references and resolves them:

| URI | Resolution |
|-----|-----------|
| `notesynapse://tool/builtin/<tool_name>` | Built-in native tool by name |
| `notesynapse://tool/user_defined/<uuid>` | All functions from user app via `AiToolService` |
| `notesynapse://tool/user_defined/<uuid>/<function>` | Single function from user app |
| `notesynapse://tool/mcp/<service_name>` | All tools from MCP endpoint via `McpService` |
| `notesynapse://tool/mcp/<service_name>/<function>` | Single tool from MCP endpoint |

Resolved tools are added to a **skill-discovered tools set** for the session. Tools only accumulate — they are never removed mid-conversation.

**Tool availability policy:**
1. **User-selected tools** — always present; user explicitly enabled them
2. **Skill-discovered tools** — injected as skills are loaded; persist for the session

**Injection by mode:**

*Chat mode (A):*
- `ConversationService` maintains a `skillDiscoveredTools` list
- Each API call merges user-selected + skill-discovered tools into the `function_tools` section
- New tools become available from the turn after `load_skill` returns

*Agentic mode (B):*
- `AgentService` maintains a `skillDiscoveredTools` list per session
- Task system prompts include tool descriptions from both user-selected and skill-discovered sets
- When a skill is loaded mid-execution, new tools are available from the next ReAct turn onward
- Tool descriptions use the existing agent tool format (name, description, parameters)

---

## Section 5: UI & Trace

**Agent launch / chat tool settings:**
- Skills participation is a toggleable entry alongside other tools — **enabled by default**
- Label: `Agent Skills (N available)` where N is the count of enabled skill notes
- Disabling removes both the skill index from the system prompt and `load_skill` from the tool list

**Agent trace screen:**
- `load_skill` calls appear as trace steps like any other tool call, showing the noteId and resolved skill name
- Skill-discovered tool injections appear as a trace annotation: `"Skill 'Weekly Review' added tools: [function_name]"`

**No new settings** in `AgenticSettingsScreen` — skill behavior is controlled per-conversation via the toggle above.

---

## Section 8: Context Management for Skills

**Context layout per API call:**

```
[ System Prompt: Goal + Tools + Skill Index ]   ← text only, unchanged
[ Skills Messages: loaded skill content ]        ← pinned, never compressed, may be multi-modal
[ Observation Rounds: execution log ]            ← compressible as today
```

Loaded skill content is inserted as a **pinned message block** in the conversation messages, positioned before the observation rounds. `ContextManagerService` maintains a separate `loadedSkills` list alongside the compressible execution log.

**Compaction behavior:**
- The compaction algorithm operates **only on the Observations region** — skill messages are never touched
- Skill token usage is tracked separately from observation token usage
- The compaction threshold applies to observations only; skill tokens are additive on top

**When `load_skill` is called:**
1. Skill content (text + any multi-modal references) is appended to the `loadedSkills` list in `ContextManagerService`
2. It is NOT added to the observations stream
3. All subsequent API calls include the full `loadedSkills` block before observations

**Deduplication:** if `load_skill` is called twice with the same noteId, the second call returns the cached content without appending a duplicate to the `loadedSkills` block.

---

## New Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `SkillService` | `lib/services/skill_service.dart` | Index building, frontmatter parsing, skill-discovered tool resolution |
| `LoadSkillTool` | `lib/services/tools/load_skill_tool.dart` | NativeTool: validates skill note, returns content |
| Skill index prompt section | `AgentService` | Injected into plan generation + task execution system prompts |
| `skillDiscoveredTools` list | `AgentService` + `ConversationService` | Dynamic tool accumulation per session |
| Skills toggle | Agent launch UI + chat tool settings | Per-conversation opt-out |
| Insert Tool button + picker | Note editor toolbar | Tool link insertion UI (3 tabs: Built-in, User Defined, MCP) |
| Tag filter in note selection dialog | `NoteSelectionDialog` | Filter icon + `initialTags` parameter |
| `loadedSkills` pinned block | `ContextManagerService` | Protected skill region in message context, excluded from compaction |

---

## Section 6: Tool Link Insertion UI (Note Editor)

A new **"Insert Tool"** button in the note editor toolbar (alongside existing note/attachment link buttons). Tapping it opens a bottom sheet with three tabs:

**Tab 1 — Built-in**
Lists all native tools (search_notes, read_note, run_sql, etc.) with their descriptions. No sub-function expansion — built-in tools are single-function. Tapping a tool inserts:
`[search_notes](notesynapse://tool/builtin/search_notes)`

**Tab 2 — User Defined**
Lists user app tools from `AiToolService`. Each tool is expandable to show individual functions with descriptions. User can insert the whole tool or a specific function:
- Whole tool: `[MyApp](notesynapse://tool/user_defined/<uuid>)`
- Specific function: `[MyApp.analyze](notesynapse://tool/user_defined/<uuid>/analyze)`

**Tab 3 — MCP**
Lists MCP endpoints from `McpService`, expandable to individual tool functions:
- Whole endpoint: `[MyMCP](notesynapse://tool/mcp/<service_name>)`
- Specific function: `[MyMCP.search](notesynapse://tool/mcp/<service_name>/search)`

Inserted text is a standard markdown link, rendered as a tappable chip in the note editor (consistent with existing note link rendering).

**Tap behavior for tool links in note view:**
- **Built-in** → show a doc dialog with the tool's name, description, and parameter summary
- **MCP** → navigate to AI Settings → MCP → that specific endpoint/tool
- **User Defined** → navigate to the tool playground for that app

---

## Section 7: Tag Filter in Note Selection Dialog

The note selection dialog gains a **filter icon** in its header, matching the tag filter UI in the main screen. Tapping it opens the existing tag selection flow. Selected tags filter the note list (AND logic). Clearing resets to unfiltered.

The dialog accepts an optional `initialTags` parameter. When provided, the filter opens with those tags already active:
- **Insert skill link from within a skill note** → `initialTags: ["agent-skill"]`, landing directly on skill notes
- **All other note link insertion** → `initialTags: null`, filter starts empty as today

No other structural changes to the dialog.

---

## What Is Not Changed

- Note editor — skills are authored as regular notes
- Existing native tools (`read_note`, `search_notes`, etc.) — unchanged
- `AgenticSettingsService` — no new global settings
- MCP and user app tool infrastructure — reused as-is via `McpService` and `AiToolService`
