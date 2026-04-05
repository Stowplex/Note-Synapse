# Phase E: Wiki Skill Pack + Pilot (Namespace-Aware)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write four namespace-aware wiki skills (Bootstrap, Ingest, Query, Lint) as note content, then validate end-to-end on a fixed pilot corpus in namespace `ml`.

**Architecture:** Skills are note content (markdown with YAML frontmatter). They use namespaced tags (`wiki-source-<ns>`, `wiki-compiled-<ns>`, etc.) and receive namespace context from tag-to-workflow bindings. All operations are scoped to a namespace.

**Tech Stack:** Markdown skill notes, existing Note Synapse tools

**Parent plan:** `.claude/plans/temporal-tickling-lovelace.md` — Phase E

**Prerequisites:** Phase A (foundation validated), Phase B (tool gaps closed, prefix-aware immutability), Phase C (tag-to-workflow bindings, namespace-aware schema + workflow spec)

---

## File Structure

| Action | Path | Responsibility |
|--------|------|---------------|
| Create | `docs/skills/wiki-bootstrap.md` | E1: Bootstrap skill content |
| Create | `docs/skills/wiki-ingest.md` | E2: Ingest skill content |
| Create | `docs/skills/wiki-lint.md` | E3: Lint skill content |
| Create | `docs/skills/wiki-query.md` | E4: Query skill content |
| Create | `docs/wiki-pilot-plan.md` | E5: Pilot corpus plan |

---

### Task 1: Wiki Bootstrap Skill (E1)

**Files:**
- Create: `docs/skills/wiki-bootstrap.md`

- [ ] **Step 1: Create the skill note content**

```markdown
---
name: Wiki Bootstrap
description: Set up a namespaced wiki workspace with index and log notes. Use when starting a new knowledge base.
enabled: true
min_context: 16000
---

## Purpose

Create a new wiki workspace in a namespace. Creates an index note and log note with namespaced tags, and registers the tag-to-workflow binding so that tagging notes `wiki-source-<ns>` will trigger ingest.

## Tools Required

- [search_notes](notesynapse://tool/builtin/search_notes) — check for existing workspace
- [create_notes](notesynapse://tool/builtin/create_notes) — create index and log

## Workflow

### Step 1: Determine Domain and Namespace

Ask the user: "What domain or topic should this wiki workspace cover?"

Derive a short namespace from the domain:
- "Machine Learning" → `ml`
- "Harry Potter" → `harry-potter`
- "Cooking Recipes" → `cooking`

The namespace should be lowercase, use hyphens for spaces, and be short.

### Step 2: Check for Existing Workspace

```
search_notes: { query: "", tags: ["wiki-index-<ns>"] }
```

If a `wiki-index-<ns>` note already exists:
- Tell the user: "A wiki workspace for <domain> already exists (namespace: <ns>). Tag source notes with `wiki-source-<ns>` to trigger ingest."
- STOP.

### Step 3: Create Index Note

```
create_notes: {
  notes: [{
    title: "Wiki Index: [Domain]",
    content: "> [!SUMMARY] Wiki Index for [Domain] (namespace: <ns>)\n\n## Entities\n\n## Topics\n\n## Syntheses\n\n## Sources\n",
    tags: ["wiki-index-<ns>", "wiki-compiled-<ns>"]
  }]
}
```

### Step 4: Create Log Note

```
create_notes: {
  notes: [{
    title: "Wiki Log: [Domain]",
    content: "> [!SUMMARY] Operation log for [Domain] wiki (namespace: <ns>)\n\n## [YYYY-MM-DD HH:mm] Bootstrap\n\n**Action:** Created wiki workspace\n**Notes affected:** Wiki Index, Wiki Log\n**Summary:** Initialized [Domain] wiki workspace (namespace: <ns>)\n",
    tags: ["wiki-log-<ns>", "wiki-compiled-<ns>"]
  }]
}
```

### Step 5: Confirm

Report to the user:
- "Wiki workspace created for [Domain] (namespace: `<ns>`)"
- "Index note: [id]"
- "Log note: [id]"
- "To add sources: tag any note with `wiki-source-<ns>` — ingest will trigger automatically."
```

- [ ] **Step 2: Verify no flat tags**

Check that `wiki-index`, `wiki-log`, `wiki-compiled` (without namespace suffix) do NOT appear anywhere in the skill content.

- [ ] **Step 3: Commit**

```bash
mkdir -p docs/skills
git add docs/skills/wiki-bootstrap.md
git commit -m "docs: add namespace-aware Wiki Bootstrap skill (Phase E1)"
```

---

### Task 2: Wiki Ingest Skill (E2)

**Files:**
- Create: `docs/skills/wiki-ingest.md`

This skill is triggered by the tag-to-workflow binding when a note is tagged `wiki-source-<ns>`. It receives the matched tag and derives the namespace.

- [ ] **Step 1: Create the skill note content**

```markdown
---
name: Wiki Ingest
description: Process a wiki-source note into compiled entity/topic notes within a namespace. Triggered by wiki-source-<ns> tag.
enabled: true
min_context: 50000
---

## Purpose

Ingest one source note into a wiki workspace. This skill receives the namespace from the tag-to-workflow binding (the matched tag is `wiki-source-<ns>`, so namespace is `<ns>`). All operations are scoped to that namespace.

## Tools Required

- [read_note](notesynapse://tool/builtin/read_note) — read source and existing compiled notes
- [search_notes](notesynapse://tool/builtin/search_notes) — find existing compiled notes and workspace notes
- [modify_note](notesynapse://tool/builtin/modify_note) — update compiled notes, index, log
- [create_notes](notesynapse://tool/builtin/create_notes) — create new compiled notes with links

## Namespace Context

This skill is triggered by a tag-to-workflow binding. The execution context provides:
- **matched tag**: e.g., `wiki-source-ml`
- **namespace**: e.g., `ml` (derived from tag suffix)

All tag references below use `<ns>` as the namespace placeholder.

## Workflow

### Step 1: Locate Workspace

```
search_notes: { query: "", tags: ["wiki-index-<ns>"] }
```

If no index found: "No wiki workspace found for namespace `<ns>`. Run Wiki Bootstrap first."

### Step 2: Read the Source Note

Progressive discovery:
```
read_note: { note_id: "[source-id]", mode: "stat" }
```

Then:
- Text content: `read_note mode='lines'`
- PDF attachments: `read_note mode='pdf_text'`
- Large notes: `read_note mode='toc'` first, then targeted reads

### Step 3: Identify Entities and Topics

From the source content, identify:
- **Entities**: People, organizations, algorithms, concepts
- **Topics**: Subject areas grouping multiple entities
- **Claims**: Specific factual assertions with provenance

### Step 4: For Each Entity/Topic

#### 4a: Search for Existing Compiled Note (namespace-scoped)

```
search_notes: { query: "[entity name]", tags: ["wiki-compiled-<ns>"] }
```

#### 4b: If Exists — Update

```
modify_note: {
  note_id: "[compiled-id]",
  modification: {
    content: {
      action: "append",
      text: "\n- New claim. [Source: [Title]](notesynapse://note/[source-id])"
    }
  }
}
```

Update `## Sources` if needed. Add link if not already linked:
```
modify_note: {
  note_id: "[compiled-id]",
  modification: {
    link: { added: [{ relation: "derived_from", target: "[source-id]" }] }
  }
}
```

#### 4c: If New — Create (with namespaced tags)

```
create_notes: {
  notes: [{
    title: "[Entity/Topic Name]",
    content: "> [!SUMMARY] [One-line summary]\n\n## Overview\n[...]\n\n## Claims\n- Claim. [Source: [Title]](notesynapse://note/[source-id])\n\n## Sources\n- [Source Title](notesynapse://note/[source-id]) — [contribution]\n\n## See Also\n",
    tags: ["wiki-compiled-<ns>", "wiki-entity-<ns>"],
    link: [{ relation: "derived_from", target: "[source-id]" }]
  }]
}
```

Use `wiki-entity-<ns>` or `wiki-topic-<ns>` as appropriate.

### Step 5: Update Namespace-Scoped Index

```
modify_note: {
  note_id: "[index-id]",
  modification: {
    content: {
      action: "append",
      text: "\n- [Entity Name](notesynapse://note/[id]) — summary"
    }
  }
}
```

### Step 6: Update Namespace-Scoped Log

```
modify_note: {
  note_id: "[log-id]",
  modification: {
    content: {
      action: "append",
      text: "\n## [YYYY-MM-DD HH:mm] Ingest | [Source Title]\n\n**Action:** Ingested source note\n**Notes affected:** [list]\n**Summary:** Extracted N entities from [Source Title]\n"
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

This does NOT modify content (allowed for wiki-source-* notes).

### Step 8: Report

"Ingested [Title] into namespace `<ns>`. Created: [list]. Updated: [list]."

## Token Budget Guidance

- **Budget > 50K**: Full ingest in one session
- **Budget 16K-50K**: One entity at a time, report progress
- **Budget < 16K**: One entity per session, tell user to continue
```

- [ ] **Step 2: Commit**

```bash
git add docs/skills/wiki-ingest.md
git commit -m "docs: add namespace-aware Wiki Ingest skill (Phase E2)

Triggered by wiki-source-<ns> tag binding. All operations scoped
to namespace. No flat tags."
```

---

### Task 3: Wiki Lint Skill (E3)

**Files:**
- Create: `docs/skills/wiki-lint.md`

- [ ] **Step 1: Create the skill note content**

```markdown
---
name: Wiki Lint
description: Audit wiki health within a namespace — find orphans, stale notes, missing sources, contradictions.
enabled: true
min_context: 30000
---

## Purpose

Audit wiki workspace health within a specific namespace. All checks are scoped to the namespace's tags.

## Tools Required

- [read_note](notesynapse://tool/builtin/read_note)
- [search_notes](notesynapse://tool/builtin/search_notes)
- [run_sql](notesynapse://tool/builtin/run_sql)
- [create_notes](notesynapse://tool/builtin/create_notes)
- [modify_note](notesynapse://tool/builtin/modify_note)

## Workflow

### Step 1: Determine Namespace

Ask the user which namespace to lint, or derive from context.

### Step 2: Locate Workspace

```
search_notes: { query: "", tags: ["wiki-index-<ns>"] }
```

### Step 3: Collect All Compiled Notes in Namespace

```
search_notes: { query: "", tags: ["wiki-compiled-<ns>"] }
```

### Step 4: Check Each Compiled Note

For each, use `read_note mode='lines'` and check:
1. **Missing Sources**: Does `## Sources` section exist and have entries?
2. **Unverified Claims**: Count `[unverified]` markers
3. **Contradictions**: Count `[contradiction]` markers
4. **Broken See Also**: Do linked notes exist?
5. **Staleness**: `updatedAt` from `read_note mode='stat'` — flag if > 30 days

### Step 5: Find Orphans (Namespace-Scoped)

```
run_sql: {
  query: "SELECT n.id, n.title FROM notes n JOIN note_tags nt ON n.id = nt.noteId JOIN tags t ON nt.tagId = t.id WHERE t.name = 'wiki-compiled-<ns>' AND n.id NOT IN (SELECT fromNoteId FROM relationships UNION SELECT toNoteId FROM relationships)"
}
```

### Step 6: Build Lint Report

```
create_notes: {
  notes: [{
    title: "Wiki Lint Report: <ns> — [date]",
    content: "> [!SUMMARY] Wiki Lint Report for namespace <ns> — [date]\n\n## Missing Sources (N)\n[...]\n\n## Orphans (N)\n[...]\n\n## Stale (N)\n[...]\n\n## Contradictions (N)\n[...]\n\n## Unverified Claims (N)\n[...]\n\n## Health Score\n[X/Y passed]\n",
    tags: ["wiki-compiled-<ns>"]
  }]
}
```

### Step 7: Update Log

Append to `wiki-log-<ns>`.

## What Lint Does NOT Do

- Does not delete or merge notes
- Does not resolve contradictions
- Report-only (except optionally adding missing See Also links)
```

- [ ] **Step 2: Commit**

```bash
git add docs/skills/wiki-lint.md
git commit -m "docs: add namespace-scoped Wiki Lint skill (Phase E3)"
```

---

### Task 4: Wiki Query Skill (E4)

**Files:**
- Create: `docs/skills/wiki-query.md`

- [ ] **Step 1: Create the skill note content**

```markdown
---
name: Wiki Query
description: Answer questions from compiled wiki notes, optionally scoped by namespace. Cite sources, suggest filing.
enabled: true
min_context: 16000
---

## Purpose

Answer questions by searching compiled wiki notes first. Supports namespace scoping ("ask the ML wiki") or cross-namespace search.

## Tools Required

- [search_notes](notesynapse://tool/builtin/search_notes)
- [read_note](notesynapse://tool/builtin/read_note)

## Workflow

### Step 1: Determine Namespace Scope

- If user specifies namespace ("ask the ML wiki"): scope to `wiki-compiled-ml`
- If unspecified: search all compiled notes (no tag filter, or use `wiki-compiled-` prefix awareness)

### Step 2: Search Compiled Notes

```
search_notes: { query: "[keywords]", tags: ["wiki-compiled-<ns>"] }
```

Or without namespace filter for cross-namespace queries.

### Step 3: Read and Synthesize

Read relevant notes via progressive discovery. Cite sources:
> "Attention uses scaled dot-product scoring (from [Attention Mechanism](notesynapse://note/id), sourced from [Vaswani et al.](notesynapse://note/source-id))."

### Step 4: Fall Back to Sources If Needed

If compiled notes lack coverage:
```
search_notes: { query: "[question]", tags: ["wiki-source-<ns>"] }
```

Note in response: "This information is not yet compiled."

### Step 5: Suggest Filing When Appropriate

If the answer combines multiple sources in a new way:
> "This synthesis may be worth filing. Use **Add to Note** and tag it `wiki-compiled-<ns>` + `wiki-synthesis-<ns>`."

Do NOT suggest filing for simple lookups or ephemeral questions.
```

- [ ] **Step 2: Commit**

```bash
git add docs/skills/wiki-query.md
git commit -m "docs: add namespace-aware Wiki Query skill (Phase E4)"
```

---

### Task 5: Pilot Corpus Plan (E5)

**Files:**
- Create: `docs/wiki-pilot-plan.md`

- [ ] **Step 1: Create the pilot plan**

```markdown
# Wiki Pilot Plan

## Purpose

Validate the namespace-aware wiki workflow end-to-end on a small corpus.

## Domain and Namespace

- Domain: Machine Learning Fundamentals
- Namespace: `ml`
- All tags: `wiki-source-ml`, `wiki-compiled-ml`, `wiki-index-ml`, etc.

## Source Notes (5)

5 notes, each 300-800 words, tagged `wiki-source-ml`:

1. **"Attention Is All You Need" Summary** — Transformer, self-attention, multi-head
2. **"Word2Vec and Embeddings"** — Word embeddings, skip-gram, CBOW
3. **"Backpropagation Explained"** — Chain rule, gradients, loss functions
4. **"Convolutional Neural Networks"** — Convolutions, pooling, architectures
5. **"Gradient Descent Variants"** — SGD, Adam, learning rates, momentum

## Execution

### Phase 1: Bootstrap
1. Run Wiki Bootstrap → namespace `ml`
2. Verify: `wiki-index-ml` and `wiki-log-ml` notes created
3. Verify: tag-to-workflow binding registered

### Phase 2: Ingest (5 rounds)
For each source (1-5):
1. Tag note `wiki-source-ml` → ingest triggers via tag binding
2. Verify after each:
   - Source unchanged
   - Compiled notes created/updated with `wiki-compiled-ml` + type tags
   - Index and log updated (namespace-scoped)
   - Relationships created
   - No flat tags (no `wiki-source`, `wiki-compiled` without namespace)

### Phase 3: Query (5 queries)
With Wiki Query skill enabled:
1. "How does attention work in transformers?"
2. "Compare word2vec with transformer embeddings"
3. "What role does backpropagation play in training CNNs?"
4. "Differences between SGD and Adam?"
5. "How do convolutions relate to attention mechanisms?"

### Phase 4: Filing (2 syntheses)
File 2 answers as notes tagged `wiki-compiled-ml` + `wiki-synthesis-ml`.

### Phase 5: Lint
1. Introduce issues: remove `## Sources` from one note, create orphan
2. Run Wiki Lint scoped to namespace `ml`
3. Verify: report identifies issues, only in namespace `ml`

## Evaluation Checklist

- [ ] Compiled notes more useful after 5th source than 1st
- [ ] Query quality improves with compiled context
- [ ] All 5 source notes unchanged
- [ ] Add to Note surfaces sufficient for filing
- [ ] Lint identifies real issues within namespace
- [ ] ALL tags carry namespace suffix (no flat tags)
- [ ] Tag-to-workflow binding triggers ingest automatically
- [ ] Multiple namespaces could coexist (no global collision)
- [ ] On cloud model: full ingest per source in one session
```

- [ ] **Step 2: Commit**

```bash
git add docs/wiki-pilot-plan.md
git commit -m "docs: add namespace-aware wiki pilot plan (Phase E5)"
```

---

### Task 6: Cross-validate all skills against schema

- [ ] **Step 1: Verify tag patterns**

All 4 skills must use `wiki-<role>-<ns>` pattern. No flat tags.

- [ ] **Step 2: Verify tool names match actual tools**

Tool URI format: `notesynapse://tool/builtin/<name>` where `<name>` matches tool names in `note_tools.dart`.

- [ ] **Step 3: Fix inconsistencies and commit**

```bash
git add docs/skills/
git commit -m "docs: cross-validate wiki skills against schema"
```
