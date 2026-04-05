# Phase E: Wiki Skill Pack + Pilot

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write the four wiki skills (Bootstrap, Ingest, Query, Lint) as note content, then validate end-to-end on a fixed pilot corpus.

**Architecture:** Skills are note content (markdown with YAML frontmatter), not code. They teach the agent how to use existing tools (`read_note`, `search_notes`, `modify_note`, `create_notes`, `run_sql`, `load_skill`) to implement wiki workflows defined in `docs/wiki-schema.md` and `docs/wiki-workflow-ux.md`.

**Tech Stack:** Markdown skill notes, existing Note Synapse tools

**Parent plan:** `.claude/plans/temporal-tickling-lovelace.md` — Phase E

**Prerequisites:** Phase A (foundation validated), Phase B (tool gaps closed), Phase C (wiki contract defined)

---

## File Structure

| Action | Path | Responsibility |
|--------|------|---------------|
| Create | `docs/skills/wiki-bootstrap.md` | E1: Bootstrap skill content |
| Create | `docs/skills/wiki-ingest.md` | E2: Ingest skill content |
| Create | `docs/skills/wiki-lint.md` | E3: Lint skill content |
| Create | `docs/skills/wiki-query.md` | E4: Query skill content |
| Create | `docs/wiki-pilot-plan.md` | E5: Pilot corpus plan and evaluation checklist |

---

### Task 1: Wiki Bootstrap Skill (E1)

**Files:**
- Create: `docs/skills/wiki-bootstrap.md`

This file contains the complete skill note content. To use it, a user creates a new note in Note Synapse, pastes this content, and tags it `agent-skill`.

- [ ] **Step 1: Create the skill note content**

```markdown
---
name: Wiki Bootstrap
description: Set up a wiki workspace with index and log notes. Use when starting a new knowledge base.
enabled: true
min_context: 16000
---

## Purpose

Create a new wiki workspace — an index note and log note that serve as the foundation for compiled knowledge. Uses tag conventions from the wiki schema.

## Tools Required

- [search_notes](notesynapse://tool/builtin/search_notes) — check for existing workspace
- [create_notes](notesynapse://tool/builtin/create_notes) — create index and log

## Workflow

### Step 1: Check for Existing Workspace

Search for existing `wiki-index` notes to avoid duplicates:

```
search_notes: { query: "", tags: ["wiki-index"] }
```

If a `wiki-index` note already exists:
- Tell the user: "A wiki workspace already exists (Index: [title]). Use Wiki Ingest to add sources."
- STOP. Do not create duplicate workspace notes.

### Step 2: Determine Domain

If the user specified a domain (e.g., "Machine Learning"), use it. Otherwise, ask: "What domain or topic should this wiki workspace cover?"

### Step 3: Create Index Note

```
create_notes: {
  notes: [{
    title: "Wiki Index: [Domain]",
    content: "> [!SUMMARY] Wiki Index for [Domain]\n\n## Entities\n\n## Topics\n\n## Syntheses\n\n## Sources\n",
    tags: ["wiki-index", "wiki-compiled"]
  }]
}
```

### Step 4: Create Log Note

```
create_notes: {
  notes: [{
    title: "Wiki Log: [Domain]",
    content: "> [!SUMMARY] Operation log for [Domain] wiki\n\n## [YYYY-MM-DD HH:mm] Bootstrap\n\n**Action:** Created wiki workspace\n**Notes affected:** Wiki Index, Wiki Log\n**Summary:** Initialized [Domain] wiki workspace\n",
    tags: ["wiki-log", "wiki-compiled"]
  }]
}
```

### Step 5: Confirm

Report to the user:
- "Wiki workspace created for [Domain]"
- "Index note: [id]"
- "Log note: [id]"
- "Next step: Tag source notes with `wiki-source` and use Wiki Ingest to add them."
```

- [ ] **Step 2: Verify skill follows schema conventions**

Check against `docs/wiki-schema.md`:
- [x] Index note tagged `wiki-index` + `wiki-compiled`
- [x] Log note tagged `wiki-log` + `wiki-compiled`
- [x] Index structure matches schema
- [x] Log entry format matches schema

- [ ] **Step 3: Commit**

```bash
mkdir -p docs/skills
git add docs/skills/wiki-bootstrap.md
git commit -m "docs: add Wiki Bootstrap skill (Phase E1)"
```

---

### Task 2: Wiki Ingest Skill (E2)

**Files:**
- Create: `docs/skills/wiki-ingest.md`

The most complex skill. Reads one source note, identifies entities/topics/claims, creates or updates compiled notes, updates index and log.

- [ ] **Step 1: Create the skill note content**

```markdown
---
name: Wiki Ingest
description: Process a wiki-source note into compiled entity/topic notes. Updates index and log.
enabled: true
min_context: 50000
---

## Purpose

Ingest one source note into the wiki workspace. Read the source, identify entities/topics/claims, create or update compiled notes, update the index, and append to the log.

## Tools Required

- [read_note](notesynapse://tool/builtin/read_note) — read source and existing compiled notes
- [search_notes](notesynapse://tool/builtin/search_notes) — find existing compiled notes and workspace notes
- [modify_note](notesynapse://tool/builtin/modify_note) — update compiled notes, index, log
- [create_notes](notesynapse://tool/builtin/create_notes) — create new compiled notes with links

## Prerequisites

- A wiki workspace must exist (run Wiki Bootstrap first)
- The source note must be tagged `wiki-source`

## Workflow

### Step 1: Locate Workspace

```
search_notes: { query: "", tags: ["wiki-index"] }
```

If no index found, tell the user: "No wiki workspace found. Run Wiki Bootstrap first."

### Step 2: Read the Source Note

Use progressive discovery to read efficiently:

```
read_note: { note_id: "[source-id]", mode: "stat" }
```

Then based on what stat reveals:
- For text content: `read_note mode='lines'`
- For PDF attachments: `read_note mode='pdf_text'` (or `mode='pdf_pages'` if text extraction unavailable)
- For large notes: `read_note mode='toc'` first, then targeted `mode='lines'` with ranges

### Step 3: Identify Entities and Topics

From the source content, identify:
- **Entities**: People, organizations, algorithms, concepts that deserve their own page
- **Topics**: Subject areas that group multiple entities
- **Claims**: Specific factual assertions with clear provenance

For each identified item, decide: entity note or topic note?

### Step 4: For Each Entity/Topic

#### 4a: Search for Existing Compiled Note

```
search_notes: { query: "[entity name]", tags: ["wiki-compiled"] }
```

#### 4b: If Exists — Update

Read the existing note:
```
read_note: { note_id: "[compiled-id]", mode: "lines" }
```

Append new claims to `## Claims`:
```
modify_note: {
  note_id: "[compiled-id]",
  modification: {
    content: {
      action: "append",
      text: "\n- New claim from source. [Source: [Title]](notesynapse://note/[source-id])"
    }
  }
}
```

Update `## Sources` if this source isn't listed yet.

Add link if not already linked:
```
modify_note: {
  note_id: "[compiled-id]",
  modification: {
    link: { added: [{ relation: "derived_from", target: "[source-id]" }] }
  }
}
```

#### 4c: If New — Create

```
create_notes: {
  notes: [{
    title: "[Entity/Topic Name]",
    content: "> [!SUMMARY] [One-line summary]\n\n## Overview\n[2-3 paragraphs]\n\n## Claims\n- Claim. [Source: [Title]](notesynapse://note/[source-id])\n\n## Sources\n- [Source Title](notesynapse://note/[source-id]) — [what it contributed]\n\n## See Also\n",
    tags: ["wiki-compiled", "wiki-entity"],
    link: [{ relation: "derived_from", target: "[source-id]" }]
  }]
}
```

Use `wiki-entity` or `wiki-topic` tag as appropriate.

### Step 5: Update Index

```
modify_note: {
  note_id: "[index-id]",
  modification: {
    content: {
      action: "append",
      text: "\n- [Entity Name](notesynapse://note/[compiled-id]) — one-line summary"
    }
  }
}
```

Append under the correct section (## Entities or ## Topics).

### Step 6: Update Log

```
modify_note: {
  note_id: "[log-id]",
  modification: {
    content: {
      action: "append",
      text: "\n## [YYYY-MM-DD HH:mm] Ingest | [Source Title]\n\n**Action:** Ingested source note\n**Notes affected:** [list of created/updated compiled notes]\n**Summary:** Extracted N entities, N topics from [Source Title]\n"
    }
  }
}
```

### Step 7: Tag Source as Ingested

```
modify_note: {
  note_id: "[source-id]",
  modification: {
    tags: { added: ["ingested"] }
  }
}
```

This does NOT modify content (allowed for wiki-source notes).

### Step 8: Report

Tell the user:
- "Ingested [Source Title]"
- "Created: [list of new compiled notes]"
- "Updated: [list of updated compiled notes]"
- "Index and log updated"

## Token Budget Guidance

- **Budget > 50K**: Full ingest in one session (all entities/topics)
- **Budget 16K-50K**: Process one entity at a time. After each entity, check remaining context. If running low, report progress and tell user to continue in a new session.
- **Budget < 16K**: Process exactly one entity per session. Always report what remains to be ingested.
```

- [ ] **Step 2: Verify against schema and workflow spec**

- [x] Progressive discovery for reading source
- [x] Compiled note structure matches schema
- [x] Provenance: every claim links to source
- [x] Tags match schema conventions
- [x] Link field used for relationships
- [x] Source note never has content/title modified
- [x] Index and log updated
- [x] Token budget guidance included

- [ ] **Step 3: Commit**

```bash
git add docs/skills/wiki-ingest.md
git commit -m "docs: add Wiki Ingest skill (Phase E2)"
```

---

### Task 3: Wiki Lint Skill (E3)

**Files:**
- Create: `docs/skills/wiki-lint.md`

- [ ] **Step 1: Create the skill note content**

```markdown
---
name: Wiki Lint
description: Audit wiki health — find orphans, stale notes, missing sources, contradictions.
enabled: true
min_context: 30000
---

## Purpose

Audit the wiki workspace for health issues: orphan notes, stale claims, missing source references, contradiction markers, and broken cross-references. Produce a structured lint report.

## Tools Required

- [read_note](notesynapse://tool/builtin/read_note) — read index and compiled notes
- [search_notes](notesynapse://tool/builtin/search_notes) — find wiki notes
- [run_sql](notesynapse://tool/builtin/run_sql) — find orphans (notes with no relationships)
- [create_notes](notesynapse://tool/builtin/create_notes) — create lint report note
- [modify_note](notesynapse://tool/builtin/modify_note) — update log, optionally fix See Also links

## Workflow

### Step 1: Locate Workspace

```
search_notes: { query: "", tags: ["wiki-index"] }
```

Read the index note to get the full list of wiki notes.

### Step 2: Collect All Wiki Notes

```
search_notes: { query: "", tags: ["wiki-compiled"] }
```

### Step 3: Check Each Compiled Note

For each compiled note, use `read_note mode='lines'` and check:

1. **Missing Sources**: Does `## Sources` section exist and have at least one entry?
2. **Unverified Claims**: Count occurrences of `[unverified]` in `## Claims`
3. **Contradictions**: Count occurrences of `[contradiction]` in `## Claims`
4. **Broken See Also**: Do linked notes in `## See Also` exist? (verify with `read_note mode='stat'`)
5. **Staleness**: Check `updatedAt` from `read_note mode='stat'` — flag if older than 30 days

### Step 4: Find Orphan Notes

Notes with `wiki-compiled` tag but no relationships:

```
run_sql: {
  query: "SELECT n.id, n.title FROM notes n JOIN note_tags nt ON n.id = nt.noteId JOIN tags t ON nt.tagId = t.id WHERE t.name = 'wiki-compiled' AND n.id NOT IN (SELECT fromNoteId FROM relationships UNION SELECT toNoteId FROM relationships)"
}
```

### Step 5: Build Lint Report

```
create_notes: {
  notes: [{
    title: "Wiki Lint Report — [date]",
    content: "> [!SUMMARY] Wiki Lint Report — [date]\n\n## Missing Sources (N notes)\n[findings]\n\n## Orphan Notes (N notes)\n[findings]\n\n## Stale Notes (N notes, not updated in 30+ days)\n[findings]\n\n## Contradictions (N)\n[findings]\n\n## Unverified Claims (N)\n[findings]\n\n## Health Score\n[X/Y checks passed]\n",
    tags: ["wiki-compiled"]
  }]
}
```

### Step 6: Update Log

```
modify_note: {
  note_id: "[log-id]",
  modification: {
    content: {
      action: "append",
      text: "\n## [YYYY-MM-DD HH:mm] Lint\n\n**Action:** Wiki health audit\n**Findings:** N issues across N categories\n**Summary:** [one-line health summary]\n"
    }
  }
}
```

### Step 7: Report

Tell the user:
- "Lint complete. Report: [report note title]"
- Summary of findings by category
- "Use the report to prioritize fixes. Lint does NOT auto-fix structural issues."

## What Lint Does NOT Do

- Does not delete notes
- Does not merge notes
- Does not resolve contradictions
- Does not modify compiled note content (except optionally adding missing See Also links when relationships exist but aren't documented)
```

- [ ] **Step 2: Commit**

```bash
git add docs/skills/wiki-lint.md
git commit -m "docs: add Wiki Lint skill (Phase E3)"
```

---

### Task 4: Wiki Query Skill (E4)

**Files:**
- Create: `docs/skills/wiki-query.md`

- [ ] **Step 1: Create the skill note content**

```markdown
---
name: Wiki Query
description: Answer questions from compiled wiki notes first, cite sources, suggest filing when appropriate.
enabled: true
min_context: 16000
---

## Purpose

Answer user questions by searching compiled wiki notes first (not raw sources). Cite sources through compiled note provenance. Suggest filing when the synthesis adds new knowledge.

## Tools Required

- [search_notes](notesynapse://tool/builtin/search_notes) — search compiled notes
- [read_note](notesynapse://tool/builtin/read_note) — read compiled notes for context

## Workflow

### Step 1: Search Compiled Notes First

```
search_notes: { query: "[user's question keywords]", tags: ["wiki-compiled"] }
```

### Step 2: Read Relevant Compiled Notes

For each match, read using progressive discovery:
```
read_note: { note_id: "[id]", mode: "summary" }
```

If the summary is relevant, read full content:
```
read_note: { note_id: "[id]", mode: "lines" }
```

### Step 3: Synthesize Answer

Combine information from compiled notes to answer the question.

**Citation format**: For each claim in the answer, cite the compiled note and trace back to the source:
> "Attention uses scaled dot-product scoring (from [Attention Mechanism](notesynapse://note/compiled-id), sourced from [Vaswani et al.](notesynapse://note/source-id))."

### Step 4: Fall Back to Source Search If Needed

If compiled notes don't have enough information:
```
search_notes: { query: "[question]", tags: ["wiki-source"] }
```

Read and synthesize from source notes. Note in the response that this information is not yet compiled.

### Step 5: Suggest Filing When Appropriate

If the answer:
- Combines information from multiple compiled notes in a new way
- Answers a question not directly addressed by any single compiled note
- Produces a synthesis that would be useful for future queries

Then suggest:
> "This synthesis may be worth filing. Use **Add to Note** to save it as a compiled note with tags `wiki-compiled` and `wiki-synthesis`."

Do NOT suggest filing for:
- Simple lookups that just repeat a single compiled note's content
- Answers to ephemeral questions (e.g., "what did I ingest last?")
- Very short answers
```

- [ ] **Step 2: Commit**

```bash
git add docs/skills/wiki-query.md
git commit -m "docs: add Wiki Query skill (Phase E4)"
```

---

### Task 5: Pilot Corpus Plan (E5)

**Files:**
- Create: `docs/wiki-pilot-plan.md`

- [ ] **Step 1: Create the pilot plan**

```markdown
# Wiki Pilot Plan

## Purpose

Validate the wiki workflow end-to-end on a small curated corpus before deciding on further native changes.

## Domain

Machine Learning Fundamentals (or user's choice)

## Source Notes (5)

Prepare 5 source notes, each 300-800 words. Suggested:

1. **"Attention Is All You Need" Summary** — Transformer architecture, self-attention, multi-head attention
2. **"Word2Vec and Embeddings"** — Word embeddings, skip-gram, CBOW, vector arithmetic
3. **"Backpropagation Explained"** — Chain rule, gradient computation, loss functions
4. **"Convolutional Neural Networks"** — Convolutions, pooling, feature maps, CNN architectures
5. **"Gradient Descent Variants"** — SGD, Adam, learning rate schedules, momentum

Each note should be tagged `wiki-source` before ingest.

## Execution Steps

### Phase 1: Bootstrap
1. Run agent with Wiki Bootstrap skill
2. Verify: 1 index note, 1 log note created with correct tags
3. Record: time taken, any issues

### Phase 2: Ingest (5 rounds)
For each source note (1-5):
1. Run agent with Wiki Ingest skill, targeting that source
2. After each ingest, verify:
   - Source note unchanged
   - At least 1 compiled note created or updated
   - Compiled notes follow schema structure
   - Index updated
   - Log updated
   - Relationships created
3. Record: entities/topics extracted, time taken, any issues

### Phase 3: Query (5 queries)
Run these queries with Wiki Query skill enabled:
1. "How does attention work in transformers?"
2. "Compare word2vec with transformer embeddings"
3. "What role does backpropagation play in training CNNs?"
4. "What are the differences between SGD and Adam?"
5. "How do convolutions relate to attention mechanisms?"

For each query, verify:
- Agent searches compiled notes first
- Answer includes citations
- Answer quality is better than a from-scratch response

### Phase 4: Filing (2 syntheses)
File at least 2 query answers back into notes:
1. Use Add to Note on a single-response synthesis
2. Use conversation tree consolidation on a multi-turn synthesis
3. Tag both as `wiki-compiled`, `wiki-synthesis`

### Phase 5: Lint
1. Before lint: manually introduce issues
   - Remove `## Sources` from one compiled note
   - Create an orphan note tagged `wiki-compiled` with no relationships
2. Run agent with Wiki Lint skill
3. Verify: report identifies the introduced issues

## Evaluation Checklist

After the pilot, assess:

- [ ] Compiled note set is visibly more useful after 5th source than after 1st
- [ ] Query quality improves because prior compiled context exists
- [ ] All 5 source notes unchanged
- [ ] Existing Add to Note and tree-save surfaces are sufficient for filing
- [ ] Lint identifies real issues (not just noise)
- [ ] On cloud model: full ingest completes in one session per source
- [ ] No new product surfaces were needed
- [ ] Schema conventions were followed consistently

## Failure Modes to Document

Record any instance of:
- Agent modifying a source note (should be blocked by guard)
- Compiled notes not following schema structure
- Index/log not being updated
- Context exhaustion mid-ingest
- Duplicate compiled notes for the same entity
- Filing workflow being awkward or insufficient
```

- [ ] **Step 2: Commit**

```bash
git add docs/wiki-pilot-plan.md
git commit -m "docs: add wiki pilot plan and evaluation checklist (Phase E5)"
```

---

### Task 6: Final review of all skill content

- [ ] **Step 1: Cross-validate all 4 skills against the schema**

Read each skill file and verify:
- Tag names match `docs/wiki-schema.md`
- Compiled note structure matches schema required structure
- Tool names match actual tool names in `note_tools.dart`
- Tool URI format is correct (`notesynapse://tool/builtin/[name]`)

- [ ] **Step 2: Cross-validate skills against workflow UX spec**

Read each skill and verify it matches the corresponding operation in `docs/wiki-workflow-ux.md`:
- Bootstrap entry point and outputs match
- Ingest entry point and outputs match
- Query filing guidance matches
- Lint output structure matches

- [ ] **Step 3: Fix any inconsistencies and commit**

```bash
git add docs/skills/ docs/wiki-schema.md docs/wiki-workflow-ux.md
git commit -m "docs: cross-validate wiki skills against schema and workflow spec"
```
