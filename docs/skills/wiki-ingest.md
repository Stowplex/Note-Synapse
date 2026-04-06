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
