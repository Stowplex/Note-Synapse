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
**What's missing**: LLM Wiki suggests good query answers should be "filed back into the wiki as new pages."

**How to close**: **Already exists** — no code changes needed
- Chat messages already have `Add to Note` action (`lib/widgets/chat_message_action_row.dart:35`) → opens `AddNoteDialog` which supports creating new notes or appending to existing ones
- Conversation tree multi-select (`lib/screens/conversation_tree_screen.dart:744`) → `saveSelectedNodesAsNote` consolidates multiple conversation nodes into one note
- **Skill approach**: Wiki Query skill tells the user when a synthesis is worth filing, pointing to the existing `Add to Note` flow

### Gap F: No Source Immutability Enforcement
**What's missing**: LLM Wiki distinguishes "raw sources" (immutable) from "wiki pages" (LLM-generated, mutable). Note Synapse treats all notes equally, and nothing prevents mutation of source-tagged notes.

**Why tags alone are insufficient**: `modify_note` will happily mutate any note regardless of tags. Worse, `ContentIngestionService` explicitly writes extracted content back into the current note (`content_ingestion_service.dart:121` — the AI can return modifications that get applied to the source note via `NoteModificationService.applyModifications()`). A bad skill, prompt, or ingestion tag can silently destroy provenance on source notes.

**How to close**: **Namespaced tag convention + Prefix-aware write-path guard** (small code change)
- Use namespaced tags: `wiki-source-<namespace>` (immutable raw material) vs `wiki-compiled-<namespace>` (LLM-generated). The namespace identifies which wiki workspace the note belongs to (e.g., `wiki-source-ml`, `wiki-compiled-ml`).
- There is no generic `wiki-source` tag. Source immutability is triggered by any tag matching the `wiki-source-` prefix.
- **Required code change**: `NoteModificationService.applyModifications()` must check for any tag with `wiki-source-` prefix and refuse content/title modifications when present. Tag and attachment modifications should still be allowed (so the note can be tagged/organized).
- **ContentIngestionService guard**: When processing a note with any `wiki-source-*` tag, the ingestion output should go to a new compiled note (or a subnote), not back into the source. The compiled note inherits the same namespace.
- Files: `lib/services/note_modification_service.dart:21`, `lib/services/content_ingestion_service.dart:121`

### Gap F2: No Tag-to-Workflow Binding
**What's missing**: Wiki operations (ingest, lint) are currently "run the right skill manually" — there is no mechanism that binds a tag to a workflow so the user can reliably trigger operations from a note's tags rather than remembering which skill to invoke.

**Why this matters**: The existing `getTagExtractionPrompt` / `ContentIngestionService` already implements a primitive version of tag-associated behavior: a tag can carry an extraction prompt, and the ingestion service runs it when a note with that tag has attachments. But this is a prompt, not a workflow. For wiki, we need tag → workflow bindings where the tag triggers a full agent skill execution with namespace context.

**How to close**: **Extend tag-associated prompts into tag-associated workflows** (medium code change)
- Add a `workflow_skill_id` column to the tag metadata (alongside existing `extraction_prompt`)
- A tag can optionally point to a skill note that defines its workflow
- Resolution rules:
  1. Exact match first: tag `wiki-source-ml` → its specific workflow binding
  2. Prefix match fallback: tag `wiki-source-ml` matches a prefix rule for `wiki-source-*` → bound skill
  3. If multiple `wiki-source-*` tags on one note, fail fast and ask user to disambiguate
- The bound workflow receives the matched tag string as execution context, so the skill knows which namespace to operate in
- This is a platform mechanism, not wiki-specific: any tag prefix can bind to any skill

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
| **Source Filing** | Namespaced tag conventions (`wiki-source-<ns>` vs `wiki-compiled-<ns>`) |

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
| **Batch note operations in agent** | Tool enhancement (modify multiple notes atomically) | Small | `lib/services/tools/note_tools.dart` — `modify_note` already exists but single-note; add batch mode |
| **Note read-only flag** | DB + model + UI | Medium | `lib/models/note.dart`, `database_service.dart`, `note_detail_screen.dart` |
| **Scheduled skill execution** | New service | Medium | New `lib/services/scheduled_task_service.dart` |
| **Vector search** | New service + DB migration | Large | New embedding service, DB schema, new tool |

---

## 4. Recommendation

**The skill system is the right substrate** — it's literally the "Schema" layer from Karpathy's architecture, and the existing tools (`read_note`, `search_notes`, `modify_note` with append/prepend/replace, `create_notes`, `run_sql`) cover core CRUD. The filing path from conversations to notes already exists via `Add to Note` + `AddNoteDialog` + conversation tree consolidation.

**However, skills alone are not the first step.** The skill pipeline (Tasks 1-8 of `2026-03-26-agent-skills.md`) is code-complete but not yet validated end-to-end. Building wiki skills on an untested foundation risks wasted effort. Additionally, two narrow tool/enforcement gaps block reliable wiki workflows: (1) `create_notes` doesn't advertise the `link` field in its schema, so the LLM won't create relationships at note-creation time; (2) nothing prevents `modify_note` or `ContentIngestionService` from mutating source-tagged notes.

**The real order is**: validate the skill pipeline → close the narrow tool/enforcement gaps + define the wiki contract → write and pilot the wiki skills → close further gaps only if the pilot proves need. See Section 8 for the detailed task list.

Visualization, dashboards, vector search, and scheduling are deferred until after the pilot.

---

## 5. Verification

- **Skills**: Create test skill notes, run agent with each workflow, verify notes are created/updated correctly
- **User Apps**: Test graph app with sample wiki notes, verify Synapse API queries work
- **Native changes**: `flutter test` for any modified services, manual testing for UI additions

---

## 6. Corrections From Alternative Plan Review

The alternative plan (`2026-04-05-llm-wiki-executable-gap-plan.md`) makes several corrections to Sections 1-5 above:

### 6A. Gap E Was Overstated — "Save as Note" Already Exists

Gap E claimed chat answers can't be filed back as notes. This is wrong. The app already has:

- **`Add to Note`** button on every chat message (`lib/widgets/chat_message_action_row.dart:35`) → opens `AddNoteDialog`
- **`AddNoteDialog`** (`lib/widgets/add_note_dialog.dart`) supports: create new note, append to existing note, AI-shaped note creation
- **Conversation tree multi-select** (`lib/screens/conversation_tree_screen.dart:744`) → `saveSelectedNodesAsNote` consolidates multiple tree nodes into one note

These three surfaces together cover query-to-wiki filing. No new "Save as Note" UI is needed.

**Section 3 Tier 3 correction**: Remove "Save as Note on chat messages" from recommended native changes. Remove item 18 from Section 9.

### 6B. Wiki Pages Are Regular Notes

The alternative plan correctly insists: wiki pages are not a separate object type. They are regular notes distinguished by tags, metadata, and workflow conventions. This plan should use the vocabulary:

- **source note**: raw evidence, not modified by ingest workflows. Tagged `wiki-source-<namespace>`.
- **compiled note**: a regular note maintained by agent workflows. Tagged `wiki-compiled-<namespace>` plus a type tag (`wiki-entity-<ns>`, `wiki-topic-<ns>`, etc.)
- **wiki workspace**: a namespace — a set of regular notes sharing the same namespace suffix in their tags + one index + one log per namespace
- **schema skill**: the skill note that defines the workflow contract

No new DB models, no new note types. Namespaces live in tag suffixes, not in a new column.

### 6C. Workflow Contract Before Code

The alternative plan correctly argues that the gap is not infrastructure but a defined, repeatable workflow UX. Before writing skills or tools, we need to define:

1. **Bootstrap**: How a user creates a wiki workspace (index, log, schema notes)
2. **Ingest**: How a source note gets processed into compiled notes
3. **Query filing**: When a chat answer stays ephemeral vs gets filed (using existing Add to Note)
4. **Lint**: What "wiki health" means and where findings go

This workflow contract is a prerequisite for skill authoring.

### 6D. What The Alternative Plan Underweights

The alternative plan defers all of:
- Agent skills validation
- Tool call gaps (multimodal, `create_notes` link schema, source immutability enforcement)
- Local-first token optimization

These are not speculative infrastructure. They are prerequisites:
- Skills validation: if `load_skill` + context pinning + tool URI resolution don't work, wiki skills can't run
- `create_notes` link schema: the implementation handles `link` data (`note_modification_service.dart:246`) but the `inputSchema` doesn't advertise it — the LLM won't create relationships at note-creation time unless the schema tells it the field exists
- Source immutability: `modify_note` and `ContentIngestionService` can both mutate source-tagged notes — without enforcement, the "raw sources are immutable" invariant is a fiction
- PDF text extraction: if local models can't read PDFs at all, source ingestion fails for the primary local-first use case

**Note on `modify_note` append/prepend**: The alternative plan's comment that this is a nonexistent gap is correct. `modify_note` already supports `content.action: 'append'|'prepend'|'replace'` in its schema (`note_tools.dart:816`), and `NoteModificationService.applyModifications()` implements all three (`note_modification_service.dart:36`). This is **not a gap** and is removed from the task list.

---

## 7. Executable Task List

Terminology: "wiki pages are regular notes" throughout. Each task specifies UX change, workflow change, validation method, and acceptance criteria.

### Priority Legend

- **P0**: Blocks everything. Must pass before subsequent phases start.
- **P1**: Required for the pilot to run at all.
- **P2**: Required for the pilot to run well on local models.
- **P3**: Improves quality. Can be deferred until pilot exposes need.

---

### Phase A: Validate Agent Skills Foundation (P0)

#### Task A1: Skill Pipeline Integration Tests

**Goal**: Prove the implemented skill system (Tasks 1-8 of `2026-03-26-agent-skills.md`) works end-to-end before building on it.

**UX change**: None.

**Workflow change**: None — this validates existing code.

**Validation method**: Unit/integration tests in `test/skill_pipeline_integration_test.dart`.

**Tests and expected outcomes**:

| Test | Expected Outcome |
|------|-----------------|
| Parse frontmatter with colons in description (`description: Use for: analysis`) | Returns `SkillMetadata` with full description string including colon |
| Parse frontmatter with multi-line description (indented continuation) | Returns null (current parser is line-based — document as known limitation or fix) |
| `buildSkillIndex()` with 0 enabled skills returns empty map | Empty map, empty prompt string |
| `buildSkillIndex()` with mix of enabled, disabled, malformed notes | Only enabled+valid notes in index |
| `LoadSkillTool.execute()` returns formatted content, second call returns cached content without DB hit | `verify(mockDb.getNote('id')).called(1)` after two execute calls |
| `LoadSkillTool.resetSession()` clears cache, next call hits DB again | `verify(mockDb.getNote('id')).called(2)` after reset + re-execute |
| `extractToolUris()` finds `notesynapse://tool/builtin/search_notes` in content | Returns list containing that URI |
| `extractToolUris()` ignores `notesynapse://note/abc` (not a tool URI) | Returns empty list |
| `parseToolUri()` for builtin, user_defined, mcp namespaces | Correct (namespace, id, function) tuples |

**Acceptance criteria**:
- [ ] All tests pass in `flutter test test/skill_pipeline_integration_test.dart`
- [ ] Known limitations documented as comments in test file

#### Task A2: Context Compaction With Loaded Skills

**Goal**: Verify loaded skills survive compaction and don't starve the execution log budget.

**UX change**: None.

**Workflow change**: None — validation only.

**Validation method**: Unit test in `test/context_manager_skill_compaction_test.dart`.

**Tests and expected outcomes**:

| Test | Expected Outcome |
|------|-----------------|
| Add 2 loaded skills (each ~500 tokens), fill execution log to 80% of a 16K budget, trigger compaction | After compaction: both skills still in `root.loadedSkills`, execution log compacted to summary + last 3 entries |
| Add 3 loaded skills totaling 4K tokens in a 16K budget, log a 10K observation | Compaction triggers. Skills unchanged. Log compacted. Total estimated tokens < 16K. |
| `buildContextForNode()` with loaded skills outputs skills before execution log | Output string contains `<LoadedSkills>` section before any `Observation:` entries |

**Acceptance criteria**:
- [ ] All tests pass
- [ ] Compaction never removes or truncates loaded skills
- [ ] After compaction, `estimatedTokens` + skill tokens < `maxContextTokens`

#### Task A3: Chat Mode Skill Discovery End-to-End

**Goal**: Verify `ConversationService` correctly loads skills, discovers tools from URIs, and makes discovered tools available in subsequent turns.

**UX change**: None.

**Workflow change**: None — validation only.

**Validation method**: Unit test in `test/conversation_skill_discovery_test.dart`, mocking `DatabaseService` and `SkillService`.

**Tests and expected outcomes**:

| Test | Expected Outcome |
|------|-----------------|
| `enableSkills()` populates `skillIndex` from DB | `skillIndex` contains enabled skills |
| `disableSkills()` clears index and discovered tools | `skillIndex.isEmpty`, `skillDiscoveredTools.isEmpty` |
| Simulated `load_skill` result containing `notesynapse://tool/builtin/search_notes` | `_skillDiscoveredTools` contains an `McpTool` named `search_notes` |
| Second `enableSkills()` call resets state cleanly | No duplicate tools from previous session |

**Acceptance criteria**:
- [ ] All tests pass
- [ ] `_skillDiscoveredTools` never contains duplicate tool names

---

### Phase B: Critical Tool Gaps (P1)

> **Note**: `modify_note` append/prepend is NOT a gap. The tool already exposes `content.action: 'append'|'prepend'|'replace'` in its `inputSchema` (`note_tools.dart:816`), and `NoteModificationService.applyModifications()` implements all three (`note_modification_service.dart:44-53`). Similarly, `modify_note` already handles relationship creation via the `link` field (`note_tools.dart:841`, `note_modification_service.dart:129`). The actual gaps in this phase are narrower.

#### Task B1: `create_notes` Schema — Expose `link` Field

**Goal**: `create_notes` implementation already handles `link` data in `NoteModificationService.createNote()` (`note_modification_service.dart:246`), but the tool's `inputSchema` doesn't advertise it. Without the schema field, the LLM won't know it can create relationships at note-creation time — it would have to create the note first, then call `modify_note` with `link`, wasting a tool call.

**UX change**: None (tool schema change only).

**Workflow change**: Agent can create notes with relationships in a single `create_notes` call. Wiki Ingest can create a compiled note and link it to the source in one step.

**Files changed**:
- `lib/services/tools/note_tools.dart` — `CreateNotesTool.inputSchema`: add `link` property to the items schema

**Validation method**: Unit tests.

**Tests and expected outcomes**:

| Test | Expected Outcome |
|------|-----------------|
| `create_notes` with `link: [{relation: 'derived_from', target: 'source-note-id'}]` | Note created AND relationship inserted in DB |
| `create_notes` without `link` field | Existing behavior unchanged, no relationships created |
| `create_notes` with `link` targeting non-existent note | Note created, relationship created (DB doesn't enforce FK on relationships — verify this) |
| `inputSchema` includes `link` property matching `modify_note`'s link schema | Schema has `'link': {'type': 'array', 'items': {'type': 'object', 'properties': {'relation': ..., 'target': ...}}}` |

**Acceptance criteria**:
- [ ] All tests pass
- [ ] `flutter analyze lib/services/tools/note_tools.dart` — no errors
- [ ] Existing `create_notes` tests still pass (no regression)
- [ ] App test: agent creates a note with `link` field → relationship visible in note detail screen

#### Task B2: `read_note mode='pdf_text'` — Text Extraction From PDFs

**Goal**: Extract text directly from PDF pages without rendering to images. Essential for local models (Gemma 4) that can't process images and for token-efficient PDF reading on any model.

**UX change**: None (tool-only).

**Workflow change**: Agent can call `read_note` with `mode: 'pdf_text'` to get text content from PDF pages. Falls back gracefully for scanned/image-only PDFs.

**Files changed**:
- `lib/services/tools/note_tools.dart` — `NoteReadTool`: add `'pdf_text'` to mode enum, implement `_executePdfText()` method

**Implementation notes**: `pdfrx` provides `PdfPage` — check if it exposes a `.text` property or text extraction API. If not, evaluate `pdf_text_extraction` or similar package. If no text extraction is available in `pdfrx`, extract what the outline/bookmarks provide and return that with a note that full text extraction requires a different package.

**Validation method**: Unit tests + manual test with a real PDF.

**Tests and expected outcomes**:

| Test | Expected Outcome |
|------|-----------------|
| `read_note mode='pdf_text'` with attachment param on a text-heavy PDF | Returns `{id, attachment, pages_read, total_pages, text: '...extracted text...'}` |
| `read_note mode='pdf_text'` without `attachment` param | Returns `{error: 'attachment parameter is required...'}` |
| `read_note mode='pdf_text'` on non-PDF attachment | Returns `{error: 'Attachment "photo.jpg" is not a PDF...'}` |
| `read_note mode='pdf_text'` on scanned PDF (no extractable text) | Returns `{text: '', note: 'No extractable text found. This may be a scanned document. Use mode=pdf_pages with a vision-capable model.'}` |
| `read_note mode='pdf_text'` with `start_page`/`end_page` | Only text from those pages returned |

**Acceptance criteria**:
- [ ] Tests pass
- [ ] Manual test: attach a text-heavy PDF to a note, agent calls `read_note mode='pdf_text'` and gets readable text
- [ ] Manual test: same PDF with Gemma 4 — agent can read PDF content without image support
- [ ] Token cost of `pdf_text` result is < 20% of equivalent `pdf_pages` visual analysis for a text-heavy page

#### Task B3: `read_note mode='image'` — Direct Image Attachment Reading

**Goal**: Allow the agent to read a specific image attachment from a note as visual input to the LLM, without loading full note content or requiring `extraction_guide`.

**UX change**: None (tool-only).

**Workflow change**: Agent calls `read_note mode='image', attachment: 'photo.jpg'` → receives the image for visual inspection. If model doesn't support images, returns an AI-generated description of the image instead.

**Files changed**:
- `lib/services/tools/note_tools.dart` — add `'image'` to mode enum, implement `_executeImage()`

**Implementation notes**: The return value must work with the agent's tool result handling. In `AgentService._performTask()`, tool results that include `PlatformFile` attachments are passed to the next LLM call as multimodal content. Check how `_executePdfPages()` currently returns its AI description vs how it could return raw images. The `_executeImage()` method should:
1. Load the image file as `PlatformFile` with bytes
2. Check `ModelSelector.currentCapabilities.supportsImages`
3. If yes: return the image as an attachment in the tool result (need to verify agent handles this)
4. If no: call `AIService.extractContentFromImage()` and return the text description

**Validation method**: Unit tests + manual test.

**Tests and expected outcomes**:

| Test | Expected Outcome |
|------|-----------------|
| `read_note mode='image'` with valid image attachment | Returns result containing image data or AI description |
| `read_note mode='image'` without `attachment` param | Returns `{error: 'attachment parameter is required...'}` |
| `read_note mode='image'` with non-image attachment (PDF) | Returns `{error: 'Attachment "doc.pdf" is not an image. Use mode=pdf_pages or pdf_text.'}` |
| `read_note mode='image'` when model doesn't support images | Returns `{description: '...AI-generated text description of image...'}` |
| `read_note mode='image'` with missing file | Returns `{error: 'File not found...'}` |

**Acceptance criteria**:
- [ ] Tests pass
- [ ] Manual test with cloud model: agent sees actual image content and can answer questions about it
- [ ] Manual test with Gemma: agent gets text description fallback
- [ ] `stat` mode attachment info includes a hint: `'hint': 'Use mode=image to view'` for image attachments

#### Task B4: Relationship Deletion/Listing Ergonomics

**Goal**: `modify_note` and `create_notes` already handle relationship **creation** via the `link` field. But there is no ergonomic way to **delete** or **list** relationships — the agent must use `run_sql` for both. For wiki workflows (lint finding stale cross-references, ingest cleaning up outdated links), this is awkward and error-prone.

**UX change**: None (tool-only).

**Workflow change**: Agent can list and delete relationships via `modify_note` instead of `run_sql`. The `link` modification field gains `removed` support (matching the pattern used by `tags` and `attachments`).

**Files changed**:
- `lib/services/tools/note_tools.dart` — `ModifyNoteTool.inputSchema`: extend `link` schema to support `removed` array
- `lib/services/note_modification_service.dart` — handle `link.removed` in `applyModifications()`
- Optionally: add a `list_relationships` read-only action to `read_note mode='stat'` output (it already shows `linked_notes` — verify this is sufficient)

**Validation method**: Unit tests.

**Tests and expected outcomes**:

| Test | Expected Outcome |
|------|-----------------|
| `modify_note` with `link: [{relation: 'related', target: 'note-b'}]` (existing behavior) | Relationship created — no regression |
| `modify_note` with `link` containing `removed: ['note-b']` | Relationship from current note to `note-b` deleted |
| `modify_note` with `link` containing both creation and removal entries | Creates new relationships AND deletes specified ones |
| `read_note mode='stat'` output `linked_notes` field | Lists all relationships with id, title, relation type, direction — verify this already works |

**Acceptance criteria**:
- [ ] Tests pass
- [ ] Agent can create AND delete relationships via `modify_note` without `run_sql`
- [ ] `read_note stat` provides enough relationship info for lint to assess cross-references

#### Task B5: Source Immutability Enforcement (Prefix-Aware)

**Goal**: Prevent `modify_note` and `ContentIngestionService` from mutating notes with any `wiki-source-*` tag. Without this, the "raw sources are immutable" invariant is unenforceable. Uses prefix matching, not an exact tag — supports multiple independent wiki namespaces.

**UX change**: When the **agent** tries to modify a `wiki-source-*` note via tool call, `modify_note` returns an error explaining the restriction. Manual edits in the note editor are unaffected.

**Workflow change**:
1. `NoteModificationService.applyModifications()` checks for any tag with `wiki-source-` prefix. If present, refuses content and title modifications. Tag, attachment, subnote, and link modifications are still allowed.
2. `ContentIngestionService`: when processing a note with any `wiki-source-*` tag, extracted content goes to a new compiled note. The compiled note inherits the same namespace (e.g., `wiki-source-ml` → compiled note gets `wiki-compiled-ml`).
3. A helper function `getWikiSourceNamespace(List<String> tags)` returns the namespace suffix from the first `wiki-source-*` tag, or `null` if no match. Used by both guards.

**Files changed**:
- `lib/services/note_modification_service.dart:21` — add prefix-aware guard in `applyModifications()`
- `lib/services/content_ingestion_service.dart:121` — redirect output for `wiki-source-*` notes
- `lib/utils/wiki_tag_utils.dart` (new) — prefix matching and namespace extraction helpers

**Validation method**: Unit tests + manual test.

**Tests and expected outcomes**:

| Test | Expected Outcome |
|------|-----------------|
| `modify_note` on note tagged `wiki-source-ml` with content change | Returns error: "Cannot modify content of a wiki-source note." |
| `modify_note` on note tagged `wiki-source-harry-potter` with title change | Returns same error |
| `modify_note` on note tagged `wiki-source-ml` with `tags: {added: ['reviewed']}` | Succeeds — tag modification allowed |
| `modify_note` on note tagged `wiki-source-ml` with `link: [...]` | Succeeds — link creation allowed |
| `modify_note` on note with NO `wiki-source-*` tags | Existing behavior unchanged |
| `ContentIngestionService` processes `wiki-source-ml` note | Creates compiled note tagged `wiki-compiled-ml`; source unchanged |
| `ContentIngestionService` processes non-wiki-source note | Existing behavior unchanged |
| `getWikiSourceNamespace(['wiki-source-ml', 'other'])` | Returns `'ml'` |
| `getWikiSourceNamespace(['regular-tag'])` | Returns `null` |
| Note with both `wiki-source-ml` and `wiki-source-ai` | Fails fast with error asking user to disambiguate |

**Acceptance criteria**:
- [ ] All tests pass
- [ ] Prefix matching works for any namespace suffix
- [ ] Multiple `wiki-source-*` tags on one note produces a clear error
- [ ] `flutter analyze` clean on all changed files

---

### Phase C: Wiki Workflow Contract (P1)

#### Task C0: Tag-Associated Workflow Bindings (Platform Mechanism)

**Goal**: Extend the existing tag-associated prompt concept (`getTagExtractionPrompt`) into a general tag-to-workflow binding mechanism. This is the platform layer that makes wiki ingest (and future tag-driven workflows) discoverable and triggerable from tags, not just manual skill invocation.

**UX change**: A tag can optionally bind to a skill note. When a note is processed (via ingestion, agent launch, or a future trigger), the system checks its tags for workflow bindings and executes the bound skill with the matched tag as context.

**Workflow change**: Tags gain an optional `workflow_skill_id` alongside the existing `extraction_prompt`. Resolution rules:

1. **Exact match first**: tag `wiki-source-ml` → its specific workflow binding
2. **Prefix match fallback**: tag `wiki-source-ml` matches a prefix rule `wiki-source-*` → bound skill
3. **Disambiguation**: if multiple `wiki-source-*` tags on one note, fail fast with an error asking the user to disambiguate
4. **Context passing**: the bound workflow receives the matched tag string as execution context, so the skill knows which namespace to operate in

**Files changed**:
- `lib/services/database_service.dart` — add `workflow_skill_id` column to tags table (or a new `tag_workflows` table)
- `lib/services/skill_service.dart` — add `resolveTagWorkflow(List<String> tags)` method with prefix matching
- `lib/utils/wiki_tag_utils.dart` (new) — `getWikiSourceNamespace(tags)`, `hasWikiSourceTag(tags)`, `isWikiSourceTag(tag)` helpers

**Design constraints**:
- One workflow per tag (not many-to-many)
- Prefix-match support for tag families (e.g., `wiki-source-*` all bind to the same skill)
- Workflow receives the matched tag string, not just the skill — the tag carries the namespace
- This is a platform mechanism, not wiki-specific: any tag prefix can bind to any skill

**Validation method**: Unit tests.

**Tests and expected outcomes**:

| Test | Expected Outcome |
|------|-----------------|
| `resolveTagWorkflow(['wiki-source-ml'])` with prefix rule `wiki-source-*` → skill-id | Returns `(skillId: 'ingest-skill', matchedTag: 'wiki-source-ml', namespace: 'ml')` |
| `resolveTagWorkflow(['regular-tag', 'wiki-source-ai'])` | Returns match for `wiki-source-ai` |
| `resolveTagWorkflow(['wiki-source-ml', 'wiki-source-ai'])` | Returns error: ambiguous — multiple wiki-source tags |
| `resolveTagWorkflow(['no-workflow-tags'])` | Returns null |
| `getWikiSourceNamespace(['wiki-source-ml'])` | Returns `'ml'` |
| `getWikiSourceNamespace(['regular'])` | Returns `null` |
| `isWikiSourceTag('wiki-source-ml')` | Returns `true` |
| `isWikiSourceTag('wiki-compiled-ml')` | Returns `false` |

**Acceptance criteria**:
- [ ] All tests pass
- [ ] Prefix matching works for any namespace suffix after `wiki-source-`
- [ ] Resolution is deterministic (exact match > prefix match)
- [ ] Ambiguous multiple matches produce a clear error

#### Task C1: Define Wiki Schema Artifact (Namespace-Aware)

**Goal**: Write the canonical schema document that defines terminology, namespaced tag conventions, compiled note structure, provenance rules, and contradiction handling.

**UX change**: None — this is a spec document.

**Workflow change**: Establishes the rules that all wiki skills will follow. Two different agents following this schema should produce structurally similar compiled notes.

**Deliverable**: `docs/wiki-schema.md` (or a note template that can be imported).

**Content requirements**:
1. **Terminology**: source note, compiled note, wiki workspace (= a namespace), schema skill
2. **Namespace model**: Each wiki workspace has a namespace (e.g., `ml`, `harry-potter`). All tags carry the namespace suffix.
3. **Tag conventions** (all namespaced):
   - `wiki-source-<ns>` — immutable raw material in namespace `<ns>`
   - `wiki-compiled-<ns>` — LLM-generated content in namespace `<ns>`
   - `wiki-index-<ns>` — index note (exactly one per namespace)
   - `wiki-log-<ns>` — log note (exactly one per namespace)
   - `wiki-entity-<ns>` — entity page in namespace
   - `wiki-topic-<ns>` — topic page in namespace
   - `wiki-synthesis-<ns>` — query-derived synthesis in namespace
4. **No generic `wiki-source` tag**: there is no flat tag. Source identity always includes namespace.
5. **Compiled note required structure**: same as before (summary, sources, claims, see also)
6. **Provenance rules**: every claim must link to a source note or source-linked compiled note
7. **Contradiction handling**: conflicting claims preserved with explicit attribution
8. **Source immutability**: notes with any `wiki-source-*` tag cannot have content/title modified by agent tools. Enforced by prefix-aware guard in `NoteModificationService`.
9. **Cross-namespace rules**: a compiled note in namespace A can reference a source from namespace B, but the compiled note carries only its own namespace tag. Cross-namespace references are explicit in `## Sources`.

**Validation method**: Human review.

**Acceptance criteria**:
- [ ] A reader can understand how multiple independent wikis coexist
- [ ] The schema can be followed manually using existing tools
- [ ] Two agents following the schema independently would produce structurally similar notes
- [ ] No flat `wiki-source` or `wiki-compiled` tags appear anywhere in the schema

#### Task C2: Define Workflow UX Spec (Namespace + Tag-Triggered)

**Goal**: Document the four user-visible operations against existing product surfaces, using namespaced tags and tag-to-workflow bindings as the trigger mechanism.

**UX change**: Ingest is triggered by tag-to-workflow binding, not manual skill invocation. The user tags a note `wiki-source-<ns>` and the system resolves the bound workflow.

**Workflow change**: Entry points are tag-driven. Each operation is scoped to a namespace.

**Deliverable**: `docs/wiki-workflow-ux.md`

**Content requirements**:

**Bootstrap**:
- Entry point: user runs agent with "Wiki Bootstrap" skill, providing a namespace name
- Creates: `Wiki Index: <Namespace>` note (tagged `wiki-index-<ns>`, `wiki-compiled-<ns>`) and `Wiki Log: <Namespace>` note (tagged `wiki-log-<ns>`, `wiki-compiled-<ns>`)
- Registers the `wiki-source-<ns>` prefix → Wiki Ingest skill binding (via tag workflow mechanism from C0)
- User distinguishes workspaces by namespace suffix

**Ingest**:
- Entry point: user tags a note `wiki-source-<ns>`. The tag-to-workflow binding (from C0) resolves to the Wiki Ingest skill with namespace context.
- The skill receives the matched tag (e.g., `wiki-source-ml`) and derives namespace `ml`
- All created/updated compiled notes are scoped to namespace `ml` (tagged `wiki-compiled-ml`, `wiki-entity-ml`, etc.)
- Index/log lookups are scoped: `search_notes tags:['wiki-index-ml']`
- Expected output: 1+ compiled notes created/updated, index updated, log appended

**Query filing**:
- Entry point: user asks a question in chat. If wiki skills are enabled, the agent searches compiled notes.
- Namespace scoping: if user specifies a namespace ("ask the ML wiki"), search `wiki-compiled-ml`. If unspecified, search all `wiki-compiled-*` notes.
- Filing: user uses existing `Add to Note` → tags result `wiki-compiled-<ns>`, `wiki-synthesis-<ns>`

**Lint**:
- Entry point: user runs agent with "Wiki Lint" skill, specifying namespace
- All checks scoped to that namespace's tags
- Output: lint report note

**Validation method**: Human review + trace through existing UI.

**Acceptance criteria**:
- [ ] Ingest entry point is a tag-to-workflow binding, not "remember to run the right skill"
- [ ] No operation requires a new product surface
- [ ] A user can execute each flow manually today using existing tools

---

### Phase D: Token-Aware Infrastructure (P2)

#### Task D1: Tiered Skill Index

**Goal**: Reduce skill index token cost for small-context models.

**UX change**: None visible. Agent prompt is shorter on small-context models.

**Workflow change**: `SkillService.buildSkillIndexPrompt()` accepts a `maxBudgetTokens` parameter. When budget is tight, it produces a compact index.

**Files changed**:
- `lib/services/skill_service.dart` — `buildSkillIndexPrompt()` method
- `lib/services/agent_service.dart` — pass budget to `buildSkillIndexPrompt()`
- `lib/services/conversation_service.dart` — same

**Validation method**: Unit tests.

**Tests and expected outcomes**:

| Test | Expected Outcome |
|------|-----------------|
| `buildSkillIndexPrompt(index, maxBudgetTokens: 100000)` | Full format: noteId, name, description per skill (current behavior) |
| `buildSkillIndexPrompt(index, maxBudgetTokens: 15000)` with 10 skills | Compact format: `skill_id: Name` only, no descriptions. Total output < 500 chars. |
| `buildSkillIndexPrompt(index, maxBudgetTokens: 8000)` with 10 skills | Minimal format: `Available skills: Name1, Name2, ...` single line. |
| `buildSkillIndexPrompt(empty, maxBudgetTokens: any)` | Returns empty string (unchanged) |

**Acceptance criteria**:
- [ ] Tests pass
- [ ] With 10 registered skills on a 16K model, skill index prompt < 200 tokens
- [ ] With 10 registered skills on a 100K model, skill index prompt unchanged from current behavior

#### Task D2: Adaptive Skill Pinning Budget

**Goal**: Prevent loaded skills from consuming more than 30% of context budget. On 16K, that's ~4,800 tokens for all pinned content.

**UX change**: If a skill would exceed the pinning budget, the agent receives a message: `"Skill loaded but summarized due to context constraints. Key instructions: [one-line summary]. Unload a skill or use a higher-context model for full skill content."`

**Workflow change**: `ContextManagerService.addLoadedSkill()` checks pinning budget before adding. If over budget, it stores a one-line summary instead of full content.

**Files changed**:
- `lib/services/context_manager_service.dart` — `addLoadedSkill()` gains budget check
- `lib/utils/token_estimator.dart` — used for estimation (already exists)

**Validation method**: Unit tests.

**Tests and expected outcomes**:

| Test | Expected Outcome |
|------|-----------------|
| Add a 500-token skill to 100K budget | Full content stored in `loadedSkills` |
| Add a 3000-token skill to 16K budget (first skill, under 30%) | Full content stored |
| Add a second 3000-token skill to 16K budget (would exceed 30%) | Second skill stored as one-line summary (~50 tokens). First skill unchanged. |
| Add skill to budget where objective + skills already > 30% | Skill stored as summary |
| `estimatePinnedTokens()` returns sum of all pinned content | Correct token estimate |

**Acceptance criteria**:
- [ ] Tests pass
- [ ] On 16K model with 2 wiki skills, agent doesn't hit compaction immediately on first tool call
- [ ] On 100K model, behavior unchanged — all skills stored in full

#### Task D3: PDF Text Fallback for Text-Only Models

**Goal**: When `read_note mode='pdf_pages'` is called on a model without image support, automatically fall back to text extraction instead of failing.

**UX change**: Agent using a local model can now read PDF content. Previously, `pdf_pages` would call `generateWithAttachments()` which would fail or return garbage on text-only models.

**Workflow change**: `_executePdfPages()` checks `ModelCapabilities.supportsImages`. If false, delegates to the same text extraction logic as Task B2's `_executePdfText()`. Returns text with a note explaining the fallback.

**Files changed**:
- `lib/services/tools/note_tools.dart` — `_executePdfPages()` method

**Validation method**: Unit tests + manual test on Gemma.

**Tests and expected outcomes**:

| Test | Expected Outcome |
|------|-----------------|
| `pdf_pages` on image-capable model | Current behavior: renders + AI describes (unchanged) |
| `pdf_pages` on text-only model with text-heavy PDF | Returns `{text: '...', fallback: true, note: 'Text extracted because model does not support images.'}` |
| `pdf_pages` on text-only model with scanned PDF | Returns `{text: '', fallback: true, error: 'Scanned PDF requires a vision-capable model.'}` |

**Acceptance criteria**:
- [ ] Tests pass
- [ ] Manual: Gemma 4 agent can read a text PDF via `pdf_pages` and produce a reasonable summary
- [ ] No regression: cloud model with image support still gets rendered page descriptions

#### Task D4: `min_context` Frontmatter Field

**Goal**: Skills can declare their minimum context requirement. The skill index and agent can warn when a model is too constrained.

**UX change**: In the skill index prompt, skills with `min_context` exceeding the current model's budget are annotated: `(limited — requires 50K+ context)`. In the agent launch screen (if skills toggle exists), these skills show a warning badge.

**Workflow change**: `SkillMetadata` gains optional `minContext` field. `buildSkillIndexPrompt()` annotates constrained skills. `LoadSkillTool` includes a warning in its output when loading a skill that exceeds budget.

**Files changed**:
- `lib/services/skill_service.dart` — `SkillMetadata.minContext`, parsing in `parseSkillMetadata()`
- `lib/services/tools/load_skill_tool.dart` — warning message when budget < minContext

**Validation method**: Unit tests.

**Tests and expected outcomes**:

| Test | Expected Outcome |
|------|-----------------|
| Parse frontmatter with `min_context: 50000` | `SkillMetadata.minContext == 50000` |
| Parse frontmatter without `min_context` | `SkillMetadata.minContext == null` (no constraint) |
| `buildSkillIndexPrompt()` with budget 16K and a skill with `min_context: 50000` | Skill entry includes `(limited mode)` annotation |
| `LoadSkillTool.execute()` for a skill with `min_context: 50000` on 16K model | Returns skill content prefixed with: `⚠ This skill is designed for 50K+ context. Running on 16K. Some steps may need to be split across sessions.` |

**Acceptance criteria**:
- [ ] Tests pass
- [ ] Skill authors can declare context requirements in frontmatter
- [ ] Agent receives clear signal about constrained execution

---

### Phase E: Wiki Skill Pack + Pilot (P1 — after Phases A-C; can overlap with Phase D)

#### Task E1: Wiki Bootstrap Skill (Namespace-Aware)

**Goal**: A skill note that guides the agent to set up a namespaced wiki workspace.

**UX change**: User creates a note tagged `agent-skill` with the bootstrap skill content. Then runs the agent with an objective like "Set up a wiki workspace for machine learning" — the agent derives namespace `ml` and creates namespaced notes.

**Workflow change**: Agent follows the skill to:
1. Ask user for domain name and derive namespace (e.g., "Machine Learning" → `ml`)
2. Check for existing `wiki-index-<ns>` note to avoid duplicates
3. Create `Wiki Index: <Domain>` note (tagged `wiki-index-<ns>`, `wiki-compiled-<ns>`)
4. Create `Wiki Log: <Domain>` note (tagged `wiki-log-<ns>`, `wiki-compiled-<ns>`)
5. Register the `wiki-source-<ns>` tag prefix → Wiki Ingest skill binding (via C0 mechanism)
6. Append bootstrap entry to log

**Deliverable**: Skill note content (markdown with YAML frontmatter).

**Validation method**: Run agent with the skill on a fresh note collection.

**Expected behavior (app test)**:
1. User creates a note with skill frontmatter and tags it `agent-skill`
2. User starts agent with objective "Bootstrap a wiki workspace for machine learning"
3. Agent derives namespace `ml`, loads the bootstrap skill
4. Agent creates Index (tagged `wiki-index-ml`) and Log (tagged `wiki-log-ml`) notes
5. Log note contains a timestamped bootstrap entry
6. Index note has the correct structure per schema

**Acceptance criteria**:
- [ ] After agent completes, `search_notes` with tag `wiki-index-ml` returns exactly 1 note
- [ ] After agent completes, `search_notes` with tag `wiki-log-ml` returns exactly 1 note
- [ ] Index note has `> [!SUMMARY]` block
- [ ] Log note has at least one timestamped entry
- [ ] Agent did not modify any existing notes
- [ ] No flat `wiki-index` or `wiki-log` tags created

#### Task E2: Wiki Ingest Skill (Namespace-Aware)

**Goal**: A skill that processes one source note into compiled note updates within a namespace.

**UX change**: User tags a note `wiki-source-<ns>`. The tag-to-workflow binding triggers ingest. The skill receives the matched tag and derives namespace from it.

**Workflow change**: Agent follows the skill to:
1. Read the source note (using progressive discovery: stat → toc → lines/pdf_text)
2. Identify entities/topics/claims in the source
3. For each entity/topic: search for existing compiled note, update or create
4. Each compiled note follows the schema structure (summary, sources, claims, see also)
5. Create relationships from source to compiled notes
6. Append to log (using `modify_note operation='append'`)
7. Update index

**Deliverable**: Skill note content. Must include token-aware instructions:
- Budget > 50K: full ingest in one session
- Budget 16K-50K: staged (one entity at a time)
- Budget < 16K: micro-ingest (one entity per session, instruction to continue)

**Validation method**: Run agent on a prepared source note.

**Expected behavior (app test)**:
1. Prepare a 500-word source note about "Transformer Architecture" tagged `wiki-source-ml`
2. Tag triggers ingest via tag-to-workflow binding (or run agent with ingest skill + namespace context)
3. Agent creates compiled notes tagged `wiki-compiled-ml`, `wiki-entity-ml` for identified entities
4. Each compiled note has correct structure per schema
5. Relationships created from source to compiled notes
6. Index (`wiki-index-ml`) updated with new entries
7. Log (`wiki-log-ml`) has ingest entry

**Acceptance criteria**:
- [ ] Source note unchanged after ingest
- [ ] At least 2 compiled notes created with correct namespaced tags
- [ ] Each compiled note's `## Sources` section references the source note
- [ ] Namespace-scoped index note updated
- [ ] Namespace-scoped log note has timestamped ingest entry
- [ ] Relationships exist between source and compiled notes
- [ ] On 16K model: agent completes at least 1 entity without context exhaustion
- [ ] No flat `wiki-compiled` or `wiki-entity` tags created (all carry namespace)

#### Task E3: Wiki Lint Skill (Namespace-Scoped)

**Goal**: A skill that audits wiki health within a specific namespace.

**UX change**: User runs agent with "Lint the ML wiki workspace" — agent derives namespace `ml` and scopes all checks to `wiki-*-ml` tags.

**Workflow change**: Agent follows the skill to:
1. Read the namespace-scoped index note (`wiki-index-<ns>`)
2. For each compiled note in namespace: check staleness, sources, cross-references
3. Find orphans (notes with `wiki-compiled-<ns>` tag but no relationships)
4. Find uncited claims
5. Write findings to a namespace-scoped lint report note
6. Append to namespace-scoped log

**Deliverable**: Skill note content.

**Validation method**: Run after Task E2's ingest, then manually introduce some issues (remove a source reference, create an orphan note).

**Expected behavior (app test)**:
1. After successful ingest in namespace `ml`, manually remove `## Sources` from one compiled note
2. Create a note tagged `wiki-compiled-ml` with no relationships
3. Run lint scoped to namespace `ml`
4. Lint report identifies: 1 note missing source references, 1 orphan note
5. Log (`wiki-log-ml`) updated

**Acceptance criteria**:
- [ ] Lint report note created with correct namespaced tag
- [ ] Report identifies orphan notes (no relationships) within the namespace
- [ ] Report identifies compiled notes missing source references within the namespace
- [ ] Report identifies stale notes (not updated in configurable period)
- [ ] Lint does not modify compiled notes (report-only)
- [ ] Namespace-scoped log updated with lint entry
- [ ] Lint does NOT report notes from other namespaces

#### Task E4: Wiki Query Skill (Namespace-Aware)

**Goal**: A skill that answers questions from compiled notes, scoped by namespace when specified, cites sources, and tells the user when to file.

**UX change**: User asks a question in chat with wiki skills enabled. Can optionally specify namespace ("ask the ML wiki").

**Workflow change**: Agent follows the skill to:
1. Search compiled notes first — scoped to `wiki-compiled-<ns>` if namespace specified, all `wiki-compiled-*` otherwise
2. Synthesize answer with citations to compiled notes and their sources
3. If answer is substantial, suggest filing with namespaced tags: `wiki-compiled-<ns>`, `wiki-synthesis-<ns>`

**Deliverable**: Skill note content.

**Validation method**: Run queries against the wiki after ingest.

**Expected behavior (app test)**:
1. After ingest of "Transformer Architecture" source, ask: "How does attention work?"
2. Agent searches compiled notes, finds "Attention Mechanism" compiled note
3. Answer cites the compiled note and traces back to the source
4. Agent suggests filing if the answer adds new synthesis

**Acceptance criteria**:
- [ ] Agent searches compiled notes before raw sources
- [ ] Answer includes citations (note titles or IDs)
- [ ] Answer quality is better than a from-scratch response (because compiled context exists)
- [ ] Agent suggests filing path using existing Add to Note flow (not a new UI)

#### Task E5: Fixed Pilot Corpus

**Goal**: Run the full loop (bootstrap → ingest × N → query → file → lint) on a small curated corpus to validate the workflow end-to-end.

**UX change**: None — this is a validation exercise.

**Workflow change**: None — exercises the workflows defined above.

**Validation method**: Manual execution with documented observations.

**Pilot spec**:
1. Domain: "Machine Learning Fundamentals" → namespace `ml`
2. 5 source notes, each 300-800 words, tagged `wiki-source-ml`
3. Run bootstrap once → creates `wiki-index-ml`, `wiki-log-ml`
4. Tag each source note `wiki-source-ml` → tag-to-workflow binding triggers ingest
5. Run 5 representative queries scoped to namespace `ml`
6. File at least 2 answers back using Add to Note (tagged `wiki-synthesis-ml`)
7. Run lint scoped to namespace `ml`
8. Document: what worked, what broke, what was awkward

**Acceptance criteria**:
- [ ] Compiled note set is visibly more useful after 5th source than after 1st
- [ ] Query quality improves because prior compiled context exists
- [ ] All source notes unchanged
- [ ] Existing `Add to Note` and tree-save surfaces are sufficient for filing
- [ ] Lint identifies real issues (not just noise)
- [ ] All notes carry namespace-scoped tags (no flat `wiki-source`/`wiki-compiled`)
- [ ] Tag-to-workflow binding triggers ingest without user remembering skill name
- [ ] On cloud model: full ingest completes in one session per source
- [ ] On local model (if tested): at least micro-ingest completes per source

---

### Phase F: Proven Gaps Only (P3 — after pilot)

These items are explicitly deferred until the pilot from Phase E exposes a concrete need.

| Item | Trigger to Build |
|------|-----------------|
| `modify_note` section-level replace | Pilot shows whole-note updates are too brittle or wasteful |
| Standalone `manage_tags` tool | Pilot shows `modify_note` tag operations are too cumbersome (note: `modify_note` already supports `tags: {added: [...], removed: [...]}`) |
| Extraction cache | Pilot shows re-reading the same source is a real cost problem |
| Vector / semantic search | Pilot shows FTS keyword search systematically misses relevant notes |
| Scheduled agent execution | Users want periodic lint without manual trigger |
| Wiki Graph User App | Users want visual exploration of compiled note relationships |
| Token budget dashboard | Users can't diagnose why agent stops mid-workflow on local model |
| Batch `modify_note` | Pilot shows 10+ individual `modify_note` calls cause context exhaustion |

---

## 8. Summary: Prioritized Task Order

```
Phase A (P0): Validate Foundation
  A1: Skill pipeline integration tests
  A2: Context compaction with loaded skills
  A3: Chat mode skill discovery tests

Phase B (P1): Critical Tool Gaps
  B1: create_notes schema — expose link field
  B2: read_note mode='pdf_text'
  B3: read_note mode='image'
  B4: Relationship deletion/listing ergonomics (modify_note link.removed)
  B5: Source immutability enforcement (prefix-aware: wiki-source-* tags)

Phase C (P1): Wiki Workflow Contract
  C0: Tag-associated workflow bindings (platform mechanism)   ← NEW
  C1: Wiki schema artifact (namespace-aware)
  C2: Workflow UX spec (namespace + tag-triggered)

Phase D (P2): Token-Aware Infrastructure      ← can overlap with C/E
  D1: Tiered skill index
  D2: Adaptive skill pinning budget
  D3: PDF text fallback for text-only models
  D4: min_context frontmatter field

Phase E (P1): Wiki Skill Pack + Pilot         ← after A, B, C complete
  E1: Wiki Bootstrap skill (namespace-aware)
  E2: Wiki Ingest skill (namespace-aware, tag-triggered)
  E3: Wiki Lint skill (namespace-scoped)
  E4: Wiki Query skill (namespace-aware)
  E5: Fixed pilot corpus (namespace: ml)

Phase F (P3): Proven Gaps Only                ← after pilot
  (see table above)
```

**Critical path**: A → B → C → E → (evaluate) → F
**Parallel track**: D runs alongside C and E

**Key architectural change**: All wiki tags are namespaced (`wiki-source-<ns>`, `wiki-compiled-<ns>`, etc.). There is no flat `wiki-source` tag. Multiple independent wiki workspaces coexist without collision. Ingest is triggered by tag-to-workflow binding, not manual skill invocation.

### Execution Plans

Each phase has a detailed execution plan with TDD steps, exact code, and commit points:

- **Phase A**: `docs/superpowers/plans/2026-04-05-phase-a-foundation-validation.md`
- **Phase B**: `docs/superpowers/plans/2026-04-05-phase-b-tool-gaps.md` (B1, B4, B5; B2/B3 deferred)
- **Phase C**: `docs/superpowers/plans/2026-04-05-phase-c-wiki-contract.md`
- **Phase D**: `docs/superpowers/plans/2026-04-05-phase-d-token-infra.md` (D1, D2, D4; D3 deferred)
- **Phase E**: `docs/superpowers/plans/2026-04-05-phase-e-wiki-skills.md`

### What already exists (not gaps)

For clarity, these capabilities are often cited as gaps but already work:

| Capability | Where It Exists |
|-----------|----------------|
| `modify_note` append/prepend/replace | `inputSchema` enum at `note_tools.dart:816`; implementation at `note_modification_service.dart:44` |
| `modify_note` relationship creation via `link` | Schema at `note_tools.dart:841`; implementation at `note_modification_service.dart:129` |
| `modify_note` tag add/remove | Schema at `note_tools.dart:829`; implementation at `note_modification_service.dart:71` |
| `create_notes` relationship creation (implementation only) | `note_modification_service.dart:246` — works but not in `inputSchema` (fixed by B1) |
| Chat → Note filing | `Add to Note` in `chat_message_action_row.dart:35` → `AddNoteDialog` (create/append/AI-shape) |
| Conversation tree → Note consolidation | `conversation_tree_screen.dart:744` multi-select → `saveSelectedNodesAsNote` |
