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
