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
