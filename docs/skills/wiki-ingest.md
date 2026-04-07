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
- [modify_note](notesynapse://tool/builtin/modify_note) — single-note fallback for update operations
- [modify_notes](notesynapse://tool/builtin/modify_notes) — preferred batched update for compiled notes, index, log, and source tags
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

Then immediately read the index note. The index note is the namespace source of truth.

```
read_note: { note_id: "[index-id]", mode: "full" }
```

Before creating or updating anything, extract from the index:
- existing entity/topic entries
- any linked or referenced workspace log note
- existing compiled note links already tracked for this namespace

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
      text: "\n- New claim. [Source: [Title]](synapseresource://note/[source-id])"
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
    content: "> [!SUMMARY] [One-line summary]\n\n## Overview\n[...]\n\n## Claims\n- Claim. [Source: [Title]](synapseresource://note/[source-id])\n\n## Sources\n- [Source Title](synapseresource://note/[source-id]) — [contribution]\n\n## See Also\n",
    tags: ["wiki-compiled-<ns>", "wiki-entity-<ns>"],
    link: [{ relation: "derived_from", target: "[source-id]" }]
  }]
}
```

Use `wiki-entity-<ns>` or `wiki-topic-<ns>` as appropriate.

### Step 5: Update Namespace-Scoped Index

Always use the existing index note you read in Step 1. Do not invent a fresh index, and do not treat a keyword search as a substitute for reading the index.

Update the correct section in the index instead of blindly appending to the end:

```
modify_notes: {
  modifications: [{
    note_id: "[index-id]",
    modification: {
      content: {
        action: "append",
        section: "## Entities",
        insert_position: "append",
        text: "- [Entity Name](synapseresource://note/[id]) — summary"
      }
    }
  }]
}
```

### Step 6: Update Namespace-Scoped Log

Determine the workspace log in this order:
1. use the log note referenced by the index, if present
2. else `search_notes: { query: "", tags: ["wiki-log-<ns>"] }`
3. only create a new log note if both fail

```
modify_notes: {
  modifications: [{
    note_id: "[log-id]",
    modification: {
      content: {
        action: "append",
        text: "\n## [YYYY-MM-DD HH:mm] Ingest | [Source Title]\n\n**Action:** Ingested source note\n**Notes affected:** [list]\n**Summary:** Extracted N entities from [Source Title]\n"
      }
    }
  }]
}
```

### Step 7: Tag Source as Ingested

Prefer one final batched write phase after any needed `create_notes` call is complete.

```
modify_notes: {
  modifications: [
    {
      note_id: "[source-id]",
      modification: {
        tags: { added: ["ingested"] }
      }
    }
  ]
}
```

This does NOT modify content (allowed for wiki-source-* notes).

### Step 8: Report

Only report full completion after observations confirm:
- the index note was updated successfully
- the workspace log was updated successfully
- the source note was tagged `ingested` successfully

If any required update fails or is denied, report a partial ingest instead:
"Partially ingested [Title] into namespace `<ns>`. Created: [list]. Updated: [list]. Missing: [list]."

## Token Budget Guidance

- **Budget > 50K**: Full ingest in one session
- **Budget 16K-50K**: One entity at a time, report progress
- **Budget < 16K**: One entity per session, tell user to continue
