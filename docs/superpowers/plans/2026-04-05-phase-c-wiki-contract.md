# Phase C: Wiki Workflow Contract

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the tag-to-workflow binding platform mechanism, then define the namespace-aware wiki schema and workflow UX spec.

**Architecture:** Three deliverables: (0) tag-to-workflow binding code in `SkillService` + `wiki_tag_utils.dart`, (1) `docs/wiki-schema.md` with namespaced tag conventions, (2) `docs/wiki-workflow-ux.md` with tag-triggered operations. Tags carry namespaces (`wiki-source-ml`, not `wiki-source`). Ingest is triggered by tag-to-workflow binding, not manual skill invocation.

**Tech Stack:** Dart (Task 0), Markdown (Tasks 1-2)

**Parent plan:** `.claude/plans/temporal-tickling-lovelace.md` — Phase C

---

## File Structure

| Action | Path | Responsibility |
|--------|------|---------------|
| Modify | `lib/services/skill_service.dart` | C0: Add `resolveTagWorkflow` with prefix matching |
| Modify | `lib/services/database_service.dart` | C0: Add `workflow_skill_id` to tag metadata |
| Read | `lib/utils/wiki_tag_utils.dart` | C0: Already created in Phase B5; reused here |
| Create | `test/tag_workflow_binding_test.dart` | C0: Tests for tag-to-workflow resolution |
| Create | `docs/wiki-schema.md` | C1: Namespace-aware schema artifact |
| Create | `docs/wiki-workflow-ux.md` | C2: Namespace + tag-triggered workflow UX spec |

---

### Task 0: Tag-Associated Workflow Bindings (C0)

**Files:**
- Modify: `lib/services/database_service.dart` — add `getTagWorkflowSkillId`, `setTagWorkflowSkillId`, `getTagWorkflowsByPrefix`
- Modify: `lib/services/skill_service.dart` — add `resolveTagWorkflow`
- Create: `test/tag_workflow_binding_test.dart`

This is a platform mechanism: tags can optionally bind to a skill. The existing `getTagExtractionPrompt` stores a prompt per tag; this adds `workflow_skill_id` alongside it. Prefix matching allows `wiki-source-*` to all bind to the same ingest skill.

- [ ] **Step 1: Read existing tag schema in DatabaseService**

Read: `lib/services/database_service.dart` — find the tags table schema and `getTagExtractionPrompt`/`updateTagExtractionPrompt` methods to understand the existing pattern.

- [ ] **Step 2: Write the failing tests**

```dart
// test/tag_workflow_binding_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'tag_workflow_binding_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late SkillService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = SkillService(mockDb);
  });

  group('resolveTagWorkflow', () {
    test('returns null when no tags have workflow bindings', () async {
      when(mockDb.getTagWorkflowsByPrefix('wiki-source-'))
          .thenAnswer((_) async => {});

      final result = await service.resolveTagWorkflow(['regular-tag', 'other']);
      expect(result, isNull);
    });

    test('resolves wiki-source-ml to bound skill via prefix match', () async {
      when(mockDb.getTagWorkflowsByPrefix('wiki-source-'))
          .thenAnswer((_) async => {'wiki-source-': 'ingest-skill-id'});

      final result = await service.resolveTagWorkflow(['wiki-source-ml', 'other']);
      expect(result, isNotNull);
      expect(result!.skillId, 'ingest-skill-id');
      expect(result.matchedTag, 'wiki-source-ml');
      expect(result.namespace, 'ml');
    });

    test('resolves wiki-source-harry-potter with multi-word namespace', () async {
      when(mockDb.getTagWorkflowsByPrefix('wiki-source-'))
          .thenAnswer((_) async => {'wiki-source-': 'ingest-skill-id'});

      final result = await service.resolveTagWorkflow(['wiki-source-harry-potter']);
      expect(result!.namespace, 'harry-potter');
    });

    test('throws on ambiguous multiple wiki-source-* tags', () async {
      when(mockDb.getTagWorkflowsByPrefix('wiki-source-'))
          .thenAnswer((_) async => {'wiki-source-': 'ingest-skill-id'});

      expect(
        () => service.resolveTagWorkflow(['wiki-source-ml', 'wiki-source-ai']),
        throwsA(isA<Exception>().having(
          (e) => e.toString(), 'message', contains('ambiguous'))),
      );
    });

    test('exact tag match takes precedence over prefix match', () async {
      when(mockDb.getTagWorkflowSkillId('wiki-source-ml'))
          .thenAnswer((_) async => 'exact-skill-id');
      when(mockDb.getTagWorkflowsByPrefix('wiki-source-'))
          .thenAnswer((_) async => {'wiki-source-': 'prefix-skill-id'});

      final result = await service.resolveTagWorkflow(['wiki-source-ml']);
      expect(result!.skillId, 'exact-skill-id');
    });
  });
}
```

- [ ] **Step 3: Generate mocks**

Run: `dart run build_runner build --delete-conflicting-outputs`

- [ ] **Step 4: Add DB methods for tag workflow bindings**

In `lib/services/database_service.dart`, add alongside existing `getTagExtractionPrompt`:

```dart
  /// Get the workflow skill ID bound to a specific tag.
  Future<String?> getTagWorkflowSkillId(String tagName) async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT workflowSkillId FROM tags WHERE name = ?
    ''', [tagName]);
    if (result.isEmpty) return null;
    return result.first['workflowSkillId'] as String?;
  }

  /// Set the workflow skill ID for a tag.
  Future<void> setTagWorkflowSkillId(String tagId, String? skillId) async {
    final db = await database;
    await db.update(
      'tags',
      {'workflowSkillId': skillId},
      where: 'id = ?',
      whereArgs: [tagId],
    );
  }

  /// Get all tag workflow bindings that match a given prefix.
  /// Returns a map of tag prefix → skill ID.
  Future<Map<String, String>> getTagWorkflowsByPrefix(String prefix) async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT name, workflowSkillId FROM tags
      WHERE name LIKE ? AND workflowSkillId IS NOT NULL
    ''', ['$prefix%']);
    return {
      for (final row in result)
        row['name'] as String: row['workflowSkillId'] as String,
    };
  }
```

**Note:** The `tags` table needs a `workflowSkillId` column. Add a migration:

```dart
  // In the migration section (check current DATABASE_VERSION):
  if (oldVersion < NEW_VERSION) {
    await db.execute('ALTER TABLE tags ADD COLUMN workflowSkillId TEXT');
  }
```

The implementer must check the current `DATABASE_VERSION` and increment it. Also update `recovery_screen.dart` per CLAUDE.md instructions.

- [ ] **Step 5: Add `resolveTagWorkflow` to SkillService**

```dart
/// Result of resolving a tag to its workflow binding.
class TagWorkflowBinding {
  final String skillId;
  final String matchedTag;
  final String? namespace;

  const TagWorkflowBinding({
    required this.skillId,
    required this.matchedTag,
    this.namespace,
  });
}
```

In `SkillService`:

```dart
  /// Resolve a list of tags to a workflow binding.
  /// Returns null if no tags have workflow bindings.
  /// Throws if multiple wiki-source-* tags are present (ambiguous).
  Future<TagWorkflowBinding?> resolveTagWorkflow(List<String> tags) async {
    // Use WikiTagUtils for namespace detection
    // Check for ambiguous wiki-source tags first
    final namespace = WikiTagUtils.getWikiSourceNamespaceStrict(tags);

    // If we found a wiki-source tag, resolve its workflow
    if (namespace != null) {
      final matchedTag = tags.firstWhere(WikiTagUtils.isWikiSourceTag);

      // Try exact match first
      final exactSkillId = await _db.getTagWorkflowSkillId(matchedTag);
      if (exactSkillId != null) {
        return TagWorkflowBinding(
          skillId: exactSkillId,
          matchedTag: matchedTag,
          namespace: namespace,
        );
      }

      // Try prefix match
      final prefixBindings = await _db.getTagWorkflowsByPrefix('wiki-source-');
      // A prefix binding with key 'wiki-source-' matches all wiki-source-* tags
      final prefixSkillId = prefixBindings['wiki-source-'];
      if (prefixSkillId != null) {
        return TagWorkflowBinding(
          skillId: prefixSkillId,
          matchedTag: matchedTag,
          namespace: namespace,
        );
      }
    }

    return null;
  }
```

- [ ] **Step 6: Run tests**

Run: `flutter test test/tag_workflow_binding_test.dart -v`
Expected: All tests pass.

- [ ] **Step 7: Run full test suite**

Run: `flutter test`
Expected: No regressions.

- [ ] **Step 8: Commit**

```bash
git add lib/services/skill_service.dart lib/services/database_service.dart test/tag_workflow_binding_test.dart test/tag_workflow_binding_test.mocks.dart
git commit -m "feat: tag-to-workflow bindings with prefix matching (Phase C0)

Tags can optionally bind to a skill via workflowSkillId. Resolution
supports exact match and prefix match (wiki-source-* → ingest skill).
Ambiguous multiple wiki-source-* tags produce a clear error."
```

---

### Task 1: Write the Namespace-Aware Wiki Schema Artifact (C1)

**Files:**
- Create: `docs/wiki-schema.md`

- [ ] **Step 1: Create the schema document**

```markdown
# Note Synapse Wiki Schema

## Purpose

This document defines the canonical schema for wiki workspaces in Note Synapse. All wiki skills must follow these conventions. Two independent agents following this schema should produce structurally similar notes.

## Core Principle

Wiki pages are regular notes. There is no separate "wiki page" type. Wiki workspaces are distinguished from ordinary note collections by namespaced tag conventions, note structure, and workflow rules.

## Namespace Model

Each wiki workspace has a **namespace** — a short identifier like `ml`, `harry-potter`, or `cooking`. All tags in a workspace carry the namespace as a suffix. Multiple independent workspaces coexist without collision.

There is no flat `wiki-source` or `wiki-compiled` tag. Source and compiled identity always includes the namespace.

## Terminology

| Term | Definition |
|------|-----------|
| **source note** | A note treated as raw evidence. Tagged `wiki-source-<ns>`. Content and title are immutable once tagged — enforced by prefix-aware guard in `NoteModificationService`. Tags, links, and attachments can still be modified. |
| **compiled note** | A regular note maintained by agent workflows. Tagged `wiki-compiled-<ns>` plus a type tag. Content is LLM-generated. |
| **wiki workspace** | A namespace — a set of regular notes sharing the same namespace suffix in their tags, plus one index and one log per namespace. |
| **schema skill** | The skill note that defines the workflow contract. References this schema. |

## Tag Conventions

All wiki-related tags use the `wiki-<role>-<namespace>` pattern.

| Tag Pattern | Applied To | Meaning |
|-------------|-----------|---------|
| `wiki-source-<ns>` | Source notes | Raw evidence in namespace `<ns>`. Content immutable via agent tools. |
| `wiki-compiled-<ns>` | All compiled notes | LLM-generated content in namespace `<ns>`. |
| `wiki-index-<ns>` | Index note (one per namespace) | Master catalog for namespace `<ns>`. |
| `wiki-log-<ns>` | Log note (one per namespace) | Append-only operation chronicle for namespace `<ns>`. |
| `wiki-entity-<ns>` | Entity compiled notes | Person, organization, algorithm, concept. |
| `wiki-topic-<ns>` | Topic compiled notes | Subject area grouping multiple entities. |
| `wiki-synthesis-<ns>` | Query-derived compiled notes | Filed from chat via Add to Note. |

A compiled note always has `wiki-compiled-<ns>` AND one type tag (e.g., `wiki-compiled-ml` + `wiki-entity-ml`).

**Examples for namespace `ml`:**
- Source: `wiki-source-ml`
- Entity: `wiki-compiled-ml` + `wiki-entity-ml`
- Index: `wiki-index-ml` + `wiki-compiled-ml`
- Log: `wiki-log-ml` + `wiki-compiled-ml`

## Trigger Mechanism

Tagging a note `wiki-source-<ns>` triggers the wiki ingest workflow via the tag-to-workflow binding (see `SkillService.resolveTagWorkflow`). The bound skill receives the matched tag and derives the namespace from the suffix.

The bootstrap skill registers the `wiki-source-<ns>` prefix → ingest skill binding when creating a new workspace.

## Required Compiled Note Structure

Every compiled note must follow this layout:

```
> [!SUMMARY] One-line summary for read_note mode='summary'

## Overview
[2-3 paragraph overview of the entity/topic]

## Claims
[Each claim on its own line with source attribution]
- Claim text. [Source: Note Title](notesynapse://note/{source-note-id})
- Unverified claim. [unverified]

## Sources
- [Source Title](notesynapse://note/{id}) — what it contributed

## See Also
- [Related Note](notesynapse://note/{id}) — relationship description
```

### Index Note Structure

```
> [!SUMMARY] Wiki Index for [Domain] (namespace: <ns>)

## Entities
- [Entity Name](notesynapse://note/{id}) — one-line summary

## Topics
- [Topic Name](notesynapse://note/{id}) — one-line summary

## Syntheses
- [Synthesis Title](notesynapse://note/{id}) — one-line summary

## Sources
- [Source Title](notesynapse://note/{id}) — date added
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

1. Every claim in `## Claims` must link to a source note or source-linked compiled note.
2. Claims without attribution must be marked `[unverified]`.
3. When a source is removed or superseded, claims derived from it must be re-evaluated in the next lint pass.

## Contradiction Handling

When two sources make conflicting claims:
1. Both versions preserved with source attribution.
2. `[contradiction]` marker added.
3. Contradictions are never collapsed silently.
4. Lint reports them for human review.

## Supersession

When a newer source supersedes an older one:
1. Old claim marked `[superseded by: Source Title]`.
2. New claim added with its source.
3. Supersession recorded in `## Sources`.

## Source Immutability

- Notes with any `wiki-source-*` tag cannot have content or title modified by agent tools.
- Enforced by prefix-aware guard in `NoteModificationService.applyModifications()` using `WikiTagUtils`.
- `ContentIngestionService` redirects output to a new compiled note in the same namespace.
- Manual editing by the user is still possible.
- Multiple `wiki-source-*` tags on one note is an error (ambiguous namespace).

## Cross-Namespace Rules

A compiled note in namespace A can reference a source from namespace B in its `## Sources` section. But the compiled note carries only its own namespace tags. Cross-namespace references are explicit, not implicit.
```

- [ ] **Step 2: Verify no flat tags appear in the document**

Search the document for bare `wiki-source`, `wiki-compiled`, `wiki-index`, `wiki-log` without namespace suffix. None should appear except in the "there is no flat tag" rule.

- [ ] **Step 3: Commit**

```bash
git add docs/wiki-schema.md
git commit -m "docs: add namespace-aware wiki schema artifact (Phase C1)

All tags carry namespace suffix (wiki-source-<ns>, wiki-compiled-<ns>).
No flat wiki-source tag. Multiple independent workspaces supported."
```

---

### Task 2: Write the Workflow UX Spec (C2)

**Files:**
- Create: `docs/wiki-workflow-ux.md`

- [ ] **Step 1: Create the workflow UX spec**

```markdown
# Note Synapse Wiki Workflow UX

## Purpose

This document defines the four user-visible wiki operations using namespaced tags and tag-to-workflow bindings. Ingest is triggered by tagging, not by manually invoking a skill.

## Prerequisites

- Tag-to-workflow bindings: `SkillService.resolveTagWorkflow` (Phase C0)
- Wiki schema: `docs/wiki-schema.md` (Phase C1)
- Source immutability: prefix-aware guard (Phase B5)
- `create_notes` link field (Phase B1)

---

## 1. Bootstrap

### Goal
Create a namespaced wiki workspace.

### Entry Point
User runs the agent with the "Wiki Bootstrap" skill, providing a domain name.

Example: "Bootstrap a wiki workspace for machine learning"

### What the Agent Does
1. Derives namespace from domain (e.g., "Machine Learning" → `ml`)
2. Checks for existing `wiki-index-ml` to avoid duplicates
3. Creates **Index note**: "Wiki Index: Machine Learning"
   - Tags: `wiki-index-ml`, `wiki-compiled-ml`
4. Creates **Log note**: "Wiki Log: Machine Learning"
   - Tags: `wiki-log-ml`, `wiki-compiled-ml`
5. Registers `wiki-source-ml` prefix → Wiki Ingest skill binding
6. Appends bootstrap entry to log

### Outputs
- 1 index note (tagged `wiki-index-ml`)
- 1 log note (tagged `wiki-log-ml`)
- Tag-to-workflow binding registered

---

## 2. Ingest

### Goal
Process one source note into compiled notes within a namespace.

### Entry Point
User tags a note `wiki-source-<ns>`. The tag-to-workflow binding automatically resolves to the Wiki Ingest skill with namespace context.

Example: User tags a note `wiki-source-ml` → system resolves the binding → ingest runs in namespace `ml`.

**No manual skill invocation needed.** The tag IS the trigger.

### What the Agent Does
1. Receives the matched tag (`wiki-source-ml`) and derives namespace (`ml`)
2. Reads the source note using progressive discovery
3. Identifies entities, topics, and claims
4. For each entity/topic:
   - `search_notes` with tags `['wiki-compiled-ml']` to find existing notes
   - Update or create with correct namespaced tags
5. Updates namespace-scoped index (`wiki-index-ml`)
6. Appends to namespace-scoped log (`wiki-log-ml`)
7. Creates relationships from source to compiled notes

### Source Note Handling
- Content NEVER modified (enforced by prefix-aware guard)
- Tags and links CAN be modified (e.g., adding `ingested` tag)

### Disambiguation
If a note has both `wiki-source-ml` and `wiki-source-ai`, ingest fails with: "Ambiguous: note belongs to multiple wiki namespaces. Remove all but one wiki-source-* tag."

---

## 3. Query and Filing

### Goal
Answer questions from compiled notes, optionally scoped by namespace.

### Entry Point
User asks a question in chat mode with wiki skills enabled.

### Namespace Scoping
- "How does attention work?" → searches all `wiki-compiled-*` notes
- "Ask the ML wiki: how does attention work?" → searches only `wiki-compiled-ml`

### Filing Path
Same three existing surfaces:

1. **Single response**: Add to Note → new note, user tags `wiki-compiled-<ns>`, `wiki-synthesis-<ns>`
2. **Multi-turn**: Conversation tree → consolidate → user tags appropriately
3. **Append**: Add to Note → existing compiled note

---

## 4. Lint

### Goal
Audit wiki health within a specific namespace.

### Entry Point
User runs agent with "Wiki Lint" skill, specifying namespace.

Example: "Lint the ML wiki"

### Namespace Scoping
All checks scoped to the namespace:
- Index: `wiki-index-ml`
- Compiled notes: `wiki-compiled-ml`
- Orphan detection: notes with `wiki-compiled-ml` but no relationships

Lint does NOT report notes from other namespaces.

---

## Summary: Operation → Trigger Mapping

| Operation | Trigger | Namespace Source |
|-----------|---------|-----------------|
| Bootstrap | Manual (agent + skill) | User provides domain name |
| Ingest | Tag-to-workflow binding (`wiki-source-<ns>`) | Derived from tag suffix |
| Query | Chat (+ optional namespace in question) | Explicit or all namespaces |
| Lint | Manual (agent + skill + namespace) | User specifies namespace |
```

- [ ] **Step 2: Verify ingest entry point is tag-triggered, not manual**

The workflow spec must state that ingest is triggered by tagging, not by "run the ingest skill." Verify the ingest section says "the tag IS the trigger."

- [ ] **Step 3: Commit**

```bash
git add docs/wiki-workflow-ux.md
git commit -m "docs: add namespace + tag-triggered workflow UX spec (Phase C2)

Ingest triggered by wiki-source-<ns> tag binding, not manual skill
invocation. All operations namespace-scoped."
```

---

### Task 3: Cross-validate schema and workflow spec

- [ ] **Step 1: Check internal consistency**

- Tag patterns in workflow spec match schema tag conventions
- Namespace model consistent between documents
- Trigger mechanism in workflow spec matches schema trigger section
- Lint scope in workflow matches schema rules

- [ ] **Step 2: Fix any inconsistencies inline and commit**

```bash
git add docs/wiki-schema.md docs/wiki-workflow-ux.md
git commit -m "docs: cross-validate wiki schema and workflow spec"
```
