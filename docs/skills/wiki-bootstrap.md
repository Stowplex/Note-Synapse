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
