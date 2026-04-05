# Phase C: Wiki Workflow Contract

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define the wiki schema artifact and workflow UX spec that all wiki skills will follow. No code changes — these are markdown deliverables that establish the contract.

**Architecture:** Two documents: (1) `docs/wiki-schema.md` defines terminology, tag conventions, compiled note structure, provenance rules; (2) `docs/wiki-workflow-ux.md` defines the four user-visible operations against existing product surfaces.

**Tech Stack:** Markdown

**Parent plan:** `.claude/plans/temporal-tickling-lovelace.md` — Phase C

---

## File Structure

| Action | Path | Responsibility |
|--------|------|---------------|
| Create | `docs/wiki-schema.md` | C1: Canonical schema artifact |
| Create | `docs/wiki-workflow-ux.md` | C2: Workflow UX spec |

---

### Task 1: Write the Wiki Schema Artifact (C1)

**Files:**
- Create: `docs/wiki-schema.md`

This document is the single source of truth for how wiki workspaces work in Note Synapse. Two different agents following this schema should produce structurally similar compiled notes.

- [ ] **Step 1: Create the schema document**

```markdown
# Note Synapse Wiki Schema

## Purpose

This document defines the canonical schema for wiki workspaces in Note Synapse. All wiki skills must follow these conventions. Two independent agents following this schema should produce structurally similar notes.

## Core Principle

Wiki pages are regular notes. There is no separate "wiki page" type. Wiki workspaces are distinguished from ordinary note collections by tag conventions, note structure, and workflow rules.

## Terminology

| Term | Definition |
|------|-----------|
| **source note** | A note treated as raw evidence. Tagged `wiki-source`. Content and title are immutable once tagged — enforced by `NoteModificationService`. Tags, links, and attachments can still be modified. |
| **compiled note** | A regular note maintained by agent workflows. Tagged `wiki-compiled` plus a type tag (see below). Content is LLM-generated and updated by ingest/lint operations. |
| **wiki workspace** | A set of regular notes sharing the same tag prefix and conventions, plus an index note and a log note. |
| **schema skill** | The skill note that defines the workflow contract for a specific workspace. References this schema. |

## Tag Conventions

All wiki-related tags use the `wiki-` prefix.

| Tag | Applied To | Meaning |
|-----|-----------|---------|
| `wiki-source` | Source notes | Raw evidence. Content immutable via agent tools. |
| `wiki-compiled` | All compiled notes | LLM-generated content maintained by workflows. |
| `wiki-index` | Index note (one per workspace) | Master catalog of all wiki notes. |
| `wiki-log` | Log note (one per workspace) | Append-only operation chronicle. |
| `wiki-entity` | Compiled notes about a person, org, concept | Entity/concept page. |
| `wiki-topic` | Compiled notes about a subject area | Topic overview page. |
| `wiki-synthesis` | Query-derived compiled notes | Filed from chat via Add to Note. |

A compiled note always has `wiki-compiled` AND one type tag (e.g., `wiki-compiled` + `wiki-entity`).

## Required Compiled Note Structure

Every compiled note must follow this layout:

```
> [!SUMMARY] One-line summary for read_note mode='summary'

## Overview
[2-3 paragraph overview of the entity/topic]

## Claims
[Each claim on its own line with source attribution]
- Claim text. [Source: Note Title](notesynapse://note/{source-note-id})
- Another claim. [Source: Note Title](notesynapse://note/{source-note-id})
- Unverified claim. [unverified]

## Sources
[List of source notes that contributed to this compiled note]
- [Source Title](notesynapse://note/{id}) — what it contributed

## See Also
[Links to related compiled notes]
- [Related Note](notesynapse://note/{id}) — relationship description
```

### Index Note Structure

```
> [!SUMMARY] Wiki Index for [workspace domain]

## Entities
- [Entity Name](notesynapse://note/{id}) — one-line summary

## Topics
- [Topic Name](notesynapse://note/{id}) — one-line summary

## Syntheses
- [Synthesis Title](notesynapse://note/{id}) — one-line summary

## Sources
- [Source Title](notesynapse://note/{id}) — date added, type
```

### Log Note Structure

Append-only. Each entry is a markdown heading with timestamp.

```
## [YYYY-MM-DD HH:mm] Operation Type | Context

**Action:** What was done
**Notes affected:** list of note titles/IDs
**Summary:** One-line outcome
```

## Provenance Rules

1. Every claim in a compiled note's `## Claims` section must link to a source note or a source-linked compiled note.
2. Claims without source attribution must be marked `[unverified]`.
3. When a source is removed or superseded, claims derived from it must be re-evaluated in the next lint pass.

## Contradiction Handling

When two sources make conflicting claims:

1. Both versions are preserved in the compiled note's `## Claims` section.
2. Each version is attributed to its source.
3. A `[contradiction]` marker is added.
4. Example:

```
- Transformer attention uses additive scoring. [Source: Paper A](notesynapse://note/a) [contradiction]
- Transformer attention uses dot-product scoring. [Source: Paper B](notesynapse://note/b) [contradiction]
```

5. Contradictions are never collapsed silently.
6. Lint identifies contradiction markers and reports them for human review.

## Supersession

When a newer source explicitly supersedes an older one:

1. The old claim is kept but marked `[superseded by: Source Title]`.
2. The new claim is added with its source.
3. The supersession relationship is recorded in `## Sources`.

## Source Immutability

- Notes tagged `wiki-source` cannot have content or title modified by agent tools.
- This is enforced at the code level in `NoteModificationService.applyModifications()`.
- `ContentIngestionService` redirects output for `wiki-source` notes to a new compiled note.
- Manual editing by the user is still possible (intentional corrections).
```

- [ ] **Step 2: Review the document for completeness against the parent plan's Phase C1 requirements**

Check that the document covers:
- [x] Terminology: source note, compiled note, wiki workspace, schema skill
- [x] Tag conventions with `wiki-` prefix
- [x] Required compiled note layouts (entity, topic, synthesis, index, log)
- [x] Provenance rules
- [x] Contradiction and supersession handling
- [x] Source immutability

- [ ] **Step 3: Commit**

```bash
git add docs/wiki-schema.md
git commit -m "docs: add canonical wiki schema artifact (Phase C1)

Defines terminology, tag conventions, compiled note structure,
provenance rules, and contradiction handling for wiki workspaces."
```

---

### Task 2: Write the Workflow UX Spec (C2)

**Files:**
- Create: `docs/wiki-workflow-ux.md`

This document maps the four wiki operations to existing product surfaces. No new UI surfaces are proposed.

- [ ] **Step 1: Create the workflow UX spec**

```markdown
# Note Synapse Wiki Workflow UX

## Purpose

This document defines the four user-visible wiki operations against existing Note Synapse surfaces. No new product surfaces are required for the initial workflow.

## Prerequisites

- Wiki schema artifact: `docs/wiki-schema.md`
- Source immutability enforcement: `NoteModificationService` wiki-source guard (Phase B5)
- `create_notes` link field in schema (Phase B1)

---

## 1. Bootstrap

### Goal
Create a recognizable wiki workspace using regular notes.

### Entry Point
User runs the agent with the "Wiki Bootstrap" skill loaded, providing a domain/topic.

Example objective: "Bootstrap a wiki workspace for Machine Learning Fundamentals"

### What the Agent Does
1. Searches for existing `wiki-index` notes to avoid duplicates
2. Creates the **Index note**:
   - Title: "Wiki Index: [Domain]"
   - Tags: `wiki-index`, `wiki-compiled`
   - Content: empty structure per schema
3. Creates the **Log note**:
   - Title: "Wiki Log: [Domain]"
   - Tags: `wiki-log`, `wiki-compiled`
   - Content: initial bootstrap entry
4. Appends bootstrap entry to log

### Outputs
- 1 index note
- 1 log note
- Log entry recording the bootstrap

### What Distinguishes a Wiki Workspace
The presence of notes tagged `wiki-index` and `wiki-log`. The workspace is the set of notes reachable from the index via tags and relationships.

---

## 2. Ingest

### Goal
Process one source note into updates across multiple compiled notes.

### Entry Point
1. User tags a note `wiki-source`
2. User runs the agent with the "Wiki Ingest" skill
3. User specifies which source note to ingest (by title or ID)

Example objective: "Ingest 'Attention Is All You Need' into the wiki"

### What the Agent Does
1. Reads the source note using progressive discovery:
   - `read_note mode='stat'` for metadata
   - `read_note mode='toc'` or `mode='lines'` for content
   - `read_note mode='pdf_text'` for PDF attachments (when available)
2. Identifies entities, topics, and claims in the source
3. For each entity/topic:
   - `search_notes` with relevant tags to find existing compiled notes
   - If exists: `modify_note` to append new claims to `## Claims`, update `## Sources`
   - If new: `create_notes` with correct tags, structure per schema, and `link` to source
4. Updates the index note via `modify_note` (append new entries)
5. Appends to the log note via `modify_note` (append operation entry)

### Outputs
- 1+ compiled notes created or updated
- Index note updated
- Log note updated
- Relationships created from source to compiled notes

### Source Note Handling
- Source note content is NEVER modified
- Enforced by `NoteModificationService` wiki-source guard
- Tags and links on the source note CAN be modified (e.g., adding `ingested` tag)

---

## 3. Query and Filing

### Goal
Answer questions from compiled notes and make it clear how answers move from conversation into durable notes.

### Entry Point
User asks a question in chat mode with wiki skills enabled.

Example: "How does attention work in transformers?"

### What the Agent Does (Query)
1. Searches compiled notes first (`search_notes` filtered by `wiki-compiled` tag)
2. Reads relevant compiled notes for context
3. Synthesizes answer with citations to compiled notes and their sources
4. If the synthesis adds new knowledge, suggests filing

### Filing Decision
The agent tells the user when an answer is worth filing:
> "This synthesis combines information from multiple compiled notes in a new way. Consider filing it using **Add to Note** as a `wiki-synthesis` note."

### Filing Path (User Action)
Three existing surfaces, no new UI needed:

1. **Single response filing:**
   - User clicks `Add to Note` on the chat message (`chat_message_action_row.dart`)
   - Opens `AddNoteDialog` → create new note or append to existing
   - User adds tags: `wiki-compiled`, `wiki-synthesis`

2. **Multi-turn consolidation:**
   - User opens conversation tree (`conversation_tree_screen.dart`)
   - Multi-selects relevant nodes
   - Uses `saveSelectedNodesAsNote` to consolidate into one note
   - User adds tags: `wiki-compiled`, `wiki-synthesis`

3. **Append to existing compiled note:**
   - User clicks `Add to Note` → selects existing compiled note → appends

### When to Use Which
| Scenario | Surface |
|----------|---------|
| Single focused answer | Add to Note → new note |
| Multi-turn deep synthesis | Conversation tree → consolidate |
| Updating an existing entity/topic | Add to Note → append to existing |
| Ephemeral chat (no new knowledge) | Don't file — leave in conversation |

---

## 4. Lint

### Goal
Make wiki maintenance a defined operation with explicit outputs.

### Entry Point
User runs the agent with the "Wiki Lint" skill.

Example objective: "Lint the machine learning wiki workspace"

### What the Agent Does
1. Reads the index note to get the full list of wiki notes
2. For each compiled note:
   - Check `## Sources` section exists and is non-empty
   - Check `## See Also` for broken links (target notes that don't exist)
   - Check for `[unverified]` claims that might now have sources
   - Check for `[contradiction]` markers
3. Find orphan notes: notes with `wiki-compiled` tag but no relationships (via `run_sql`)
4. Find stale notes: compiled notes not updated since a configurable threshold
5. Write findings to a **Wiki Lint Report** note
6. Append to log

### Lint Report Structure
```
> [!SUMMARY] Wiki Lint Report — [date]

## Missing Sources (N notes)
- [Note Title](notesynapse://note/{id}) — no ## Sources section

## Orphan Notes (N notes)
- [Note Title](notesynapse://note/{id}) — no relationships

## Stale Notes (N notes, not updated in 30+ days)
- [Note Title](notesynapse://note/{id}) — last updated [date]

## Contradictions (N)
- [Note Title](notesynapse://note/{id}) — N contradiction markers

## Unverified Claims (N)
- [Note Title](notesynapse://note/{id}) — N unverified claims
```

### What Lint Does NOT Do
- Lint does not delete notes
- Lint does not merge notes
- Lint does not resolve contradictions
- Lint may add missing `## See Also` links if the relationship is clear
- All structural changes require user confirmation

---

## Summary: Operation → Surface Mapping

| Operation | Entry Point | Agent Tools Used | User Surface |
|-----------|-------------|-----------------|-------------|
| Bootstrap | Agent + skill | `search_notes`, `create_notes` | None (agent-only) |
| Ingest | Agent + skill | `read_note`, `search_notes`, `modify_note`, `create_notes` | None (agent-only) |
| Query | Chat + skill | `search_notes`, `read_note` | Chat response |
| Filing | User action | None | Add to Note / conversation tree |
| Lint | Agent + skill | `read_note`, `search_notes`, `run_sql`, `modify_note`, `create_notes` | None (agent-only) |
```

- [ ] **Step 2: Review for completeness against parent plan's Phase C2 requirements**

Check:
- [x] Bootstrap flow spec with entry point, outputs, persistence
- [x] Ingest flow spec with entry point, agent behavior, source handling
- [x] Query filing flow spec using existing UX (Add to Note, conversation tree)
- [x] Lint flow spec with explicit outputs
- [x] No new product surfaces required
- [x] Each operation maps to existing entry points

- [ ] **Step 3: Commit**

```bash
git add docs/wiki-workflow-ux.md
git commit -m "docs: add wiki workflow UX spec (Phase C2)

Maps bootstrap, ingest, query filing, and lint operations to
existing Note Synapse surfaces. No new UI surfaces required."
```

---

### Task 3: Cross-validate schema and workflow spec

- [ ] **Step 1: Check internal consistency**

Read both documents and verify:
- Tag names in workflow spec match schema tag conventions
- Compiled note structure in workflow outputs matches schema required structure
- Source immutability in workflow spec matches schema rules
- Lint checks align with schema provenance and contradiction rules

- [ ] **Step 2: Fix any inconsistencies inline**

If tags, structure, or rules don't match between the two documents, update the workflow spec to match the schema (schema is authoritative).

- [ ] **Step 3: Commit any fixups**

```bash
git add docs/wiki-schema.md docs/wiki-workflow-ux.md
git commit -m "docs: cross-validate wiki schema and workflow spec"
```
