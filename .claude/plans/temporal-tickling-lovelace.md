# Karpathy LLM Wiki x Note Synapse Agent Skills Alignment

## Context

Karpathy's [LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) (April 2026) proposes an LLM-maintained personal knowledge base with three layers: **Raw Sources** (immutable documents), **The Wiki** (LLM-generated interlinked markdown pages), and **The Schema** (configuration telling the LLM how to structure everything). Three operations — **Ingest**, **Query**, **Lint** — let the LLM incrementally build and maintain the wiki. Supporting structures include an **index.md** (catalog of all pages) and **log.md** (append-only operation chronicle).

Note Synapse already has a rich agent system with skills (notes tagged `agent-skill`), hierarchical task execution, native tools for note CRUD/search/SQL, user apps (HTML/JS plugins), and content ingestion. The question: how do we align these systems?

---

## 1. What Note Synapse Already Has

| LLM Wiki Concept | Note Synapse Equivalent | Location |
|---|---|---|
| Raw Sources | Notes with attachments (PDFs, images, files) | `lib/models/note.dart`, attachment system |
| Wiki pages (markdown) | Notes (markdown with tags, relationships, sub-notes) | `lib/models/note.dart`, `NoteDetailScreen` |
| Schema / AGENTS.md | Agent Skills (notes tagged `agent-skill` with YAML frontmatter) | `lib/services/skill_service.dart` |
| Ingest operation | `ContentIngestionService` — tag-based AI processing of attachments | `lib/services/content_ingestion_service.dart` |
| Query operation | Agent with `search_notes`, `read_note`, `run_sql` tools + conversation AI | `lib/services/tools/note_tools.dart` |
| Cross-references | Note relationships (from/to with type) + note links in markdown | `database_service.dart` relationships |
| Entity/concept pages | Notes with tags serving as categories | Tag system, `tag_management_screen.dart` |
| Agent execution | Full hierarchical agent: plan review, task tree, context nodes, pause/resume | `lib/services/agent_service.dart` |
| Tool calling | Native tools: search, read, SQL, modify, create, delete notes + MCP + load_skill | `lib/services/tools/note_tools.dart` |
| CLI search | `run_sql` tool gives agent direct DB query capability | `RunSqlTool` in note_tools.dart |
| User Apps / visualization | HTML/JS plugins with Synapse API (runQuery, chatAI, saveNotes, etc.) | `lib/services/user_app_runtime_bridge.dart` |

**Key strength**: Note Synapse's skill system is a direct analogue to the "Schema" layer — skills *are* the configuration documents that tell the agent how to work.

---

## 2. Gap Analysis

### Gap A: No "Wiki Maintenance" Workflow (Ingest that touches multiple pages)
**What's missing**: Karpathy's ingest touches 10-15 wiki pages per source. Note Synapse's `ContentIngestionService` processes a single note's attachments and writes back to that note. There's no concept of "read a source, then create/update summary pages, entity pages, index page, and log entry."

**How to close**: **Agent Skill** (no code changes needed)
- Write a skill note called "Wiki Ingest" that instructs the agent to:
  1. Read the source note via `read_note`
  2. Search for existing entity/concept notes via `search_notes`
  3. Update existing notes via `modify_note` or create new ones via `create_notes`
  4. Update an index note and log note via `modify_note`
- All required tools already exist: `read_note`, `search_notes`, `modify_note`, `create_notes`, `run_sql`

### Gap B: No Dedicated Index Page / Auto-maintained Catalog
**What's missing**: LLM Wiki has `index.md` — a structured catalog of all wiki pages with summaries, categories, and links. Updated on every ingest.

**How to close**: **Agent Skill** (no code changes needed)
- The skill from Gap A can maintain a pinned "Index" note using existing `modify_note`
- The agent can use `run_sql` to enumerate all notes with specific tags for comprehensive indexing
- A tag convention (e.g., `wiki-page`, `wiki-index`) keeps wiki notes organized

### Gap C: No Append-only Operation Log
**What's missing**: LLM Wiki's `log.md` — a chronological record of all ingest/query/lint operations.

**How to close**: **Agent Skill** (no code changes needed)
- Skill instructs agent to append to a designated "Log" note via `modify_note` after each operation
- Format: `## [date] operation | source title`
- Existing `modify_note` supports appending content

### Gap D: No "Lint" / Health-Check Workflow
**What's missing**: Periodic review to find contradictions, stale claims, orphan pages, missing cross-references, data gaps.

**How to close**: **Agent Skill** (no code changes needed)
- Write a "Wiki Lint" skill that instructs the agent to:
  1. Read the index note to get all wiki pages
  2. Check each page for staleness (via `read_note` stat mode for dates)
  3. Find orphan notes (no relationships) via `run_sql`
  4. Check for missing cross-references via content analysis
  5. Append findings to a "Lint Report" note
  6. Update log

### Gap E: Query Answers Filed Back as Wiki Pages
**What's missing**: LLM Wiki suggests good query answers should be "filed back into the wiki as new pages." Currently, conversation answers live in conversation history, not as notes.

**How to close**: **Agent Skill** (partially) + **Native UI change** (recommended)
- **Skill approach**: Instruct agent to `create_notes` with the synthesized answer when a query is comprehensive enough
- **Native UI improvement**: Add a "Save as Note" action to conversation messages (on `ChatMessageActionRow` widget). This is a small UI addition that has broad value beyond the wiki pattern.
  - File: `lib/widgets/chat_message_action_row.dart`
  - Already has copy/share actions; add "Save as Note" that creates a note from message content

### Gap F: No Source Immutability Concept
**What's missing**: LLM Wiki distinguishes "raw sources" (immutable) from "wiki pages" (LLM-generated, mutable). Note Synapse treats all notes equally.

**How to close**: **Tag Convention in Skill** (no code changes needed)
- Use tags: `source` (immutable raw material) vs `wiki-page` (LLM-generated)
- Skill can instruct agent to never modify `source`-tagged notes
- Optional: a `read-only` note attribute could be a small native enhancement, but tags work fine

### Gap G: No Graph Visualization of Wiki
**What's missing**: LLM Wiki suggests Obsidian-style graph view to see connections, identify hubs/orphans.

**How to close**: **User App** (HTML/JS extension)
- Build a User App that uses `Synapse.runQuery()` to fetch notes and relationships
- Render as an interactive force-directed graph (D3.js or similar)
- Already possible with current Synapse API — `runQuery` gives full SQL access
- Could also use `Synapse.openNote()` for click-to-navigate

### Gap H: No Hybrid Search (BM25 + Vector)
**What's missing**: LLM Wiki mentions tools like `qmd` for hybrid search with BM25 + vector search + LLM re-ranking.

**How to close**: **Native Change** (new tool or service enhancement)
- Current: `search_notes` uses SQLite FTS only
- Enhancement options:
  1. **Minimal**: Add an agent skill that uses `run_sql` with FTS5 ranking features already in SQLite — this is available now
  2. **Medium**: Add vector embeddings to notes and a `vector_search` native tool — requires new service + DB schema change
  3. **Full**: Combine FTS + vector in a hybrid search tool with LLM re-ranking
- **Recommendation**: Start with a skill leveraging existing FTS. Vector search is a larger project for later.

### Gap I: No Scheduled/Periodic Agent Execution
**What's missing**: LLM Wiki's Lint operation implies periodic health checks. Currently, agent execution is always user-initiated.

**How to close**: **Native Change** (new service)
- Add a simple scheduled task system that can trigger agent skills on a schedule
- Could be as simple as a background timer that runs a specific skill daily/weekly
- Alternatively: **User App** that uses `Synapse.chatAI()` on a timer, but this is limited since user apps only run when open

### Gap J: No "Marp" / Rich Output Formats
**What's missing**: LLM Wiki mentions answers as slide decks, charts, canvas — not just text.

**How to close**: **User App** (already achievable)
- User Apps already render HTML/JS — they can display charts (Chart.js), slides (reveal.js), etc.
- Agent can use `create_notes` to create note content, then a User App renders it
- `Synapse.chatAI()` in a User App can generate structured data and render it visually

---

## 3. Summary: Implementation Tiers

### Tier 1: Agent Skills Only (Zero code changes)
These are the highest-value, lowest-effort items. Write skill notes that teach the agent the LLM Wiki workflows.

| Skill | What It Does |
|---|---|
| **Wiki Ingest** | Process a source → create/update summary, entity pages, index, log |
| **Wiki Query** | Search wiki, synthesize answer, optionally file as new page |
| **Wiki Lint** | Health-check: find orphans, stale pages, gaps, contradictions |
| **Wiki Index Maintainer** | Rebuild/update the master index note |
| **Source Filing** | Tag conventions for sources vs wiki-pages |

### Tier 2: User Apps (Zero code changes)
Build HTML/JS extensions for visualization and interaction.

| App | What It Does |
|---|---|
| **Wiki Graph** | Force-directed graph of wiki notes + relationships (D3.js) |
| **Wiki Dashboard** | Overview stats: page count, recent ingests, lint warnings |
| **Slide Deck Renderer** | Render markdown slides from wiki content (reveal.js) |

### Tier 3: Recommended Native Changes

| Change | Type | Effort | Files |
|---|---|---|---|
| **"Save as Note" on chat messages** | UI widget enhancement | Small | `lib/widgets/chat_message_action_row.dart` |
| **Batch note operations in agent** | Tool enhancement (modify multiple notes atomically) | Small | `lib/services/tools/note_tools.dart` — `modify_note` already exists but single-note; add batch mode |
| **Note read-only flag** | DB + model + UI | Medium | `lib/models/note.dart`, `database_service.dart`, `note_detail_screen.dart` |
| **Scheduled skill execution** | New service | Medium | New `lib/services/scheduled_task_service.dart` |
| **Vector search** | New service + DB migration | Large | New embedding service, DB schema, new tool |

---

## 4. Recommendation

**Start with Tier 1.** The skill system is perfectly designed for this — it's literally the "Schema" layer from Karpathy's architecture. Write 3-5 skill notes that encode the Wiki Ingest, Query, and Lint workflows. The agent already has all the tools it needs (`read_note`, `search_notes`, `modify_note`, `create_notes`, `run_sql`).

The only native change worth doing immediately is **"Save as Note"** on chat messages — it's small, broadly useful, and bridges the gap between conversations and the note knowledge base.

Everything else (graph visualization, dashboards) can come as User Apps, proving out the plugin system while delivering real value.

---

## 5. Verification

- **Skills**: Create test skill notes, run agent with each workflow, verify notes are created/updated correctly
- **User Apps**: Test graph app with sample wiki notes, verify Synapse API queries work
- **Native changes**: `flutter test` for any modified services, manual testing for UI additions
