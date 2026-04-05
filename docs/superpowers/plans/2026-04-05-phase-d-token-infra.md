# Phase D: Token-Aware Infrastructure

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make wiki skills viable on small-context models (16K) by adding tiered skill indexing, adaptive skill pinning budgets, and `min_context` metadata.

**Architecture:** Three changes to the skill system: (1) `buildSkillIndexPrompt` gains a budget parameter for compact output, (2) `addLoadedSkill` gains a budget check with summary fallback, (3) `SkillMetadata` gains an optional `minContext` field. All parallel track — can run alongside Phase C/E.

**Tech Stack:** Flutter, Dart, mockito

**Parent plan:** `.claude/plans/temporal-tickling-lovelace.md` — Phase D (Tasks D1, D2, D4; D3 deferred to Phase B PDF plan)

---

## File Structure

| Action | Path | Responsibility |
|--------|------|---------------|
| Modify | `lib/services/skill_service.dart:4-16` | D4: Add `minContext` to `SkillMetadata`, parse in `parseSkillMetadata` |
| Modify | `lib/services/skill_service.dart:71-83` | D1: Add `maxBudgetTokens` param to `buildSkillIndexPrompt` |
| Modify | `lib/services/context_manager_service.dart:662-669` | D2: Add budget check to `addLoadedSkill` |
| Modify | `lib/services/tools/load_skill_tool.dart` | D4: Add warning when budget < minContext |
| Modify | `lib/services/agent_service.dart` | D1: Pass budget to `buildSkillIndexPrompt` |
| Modify | `lib/services/conversation_service.dart` | D1: Pass budget to `buildSkillIndexPrompt` |
| Create | `test/tiered_skill_index_test.dart` | D1 tests |
| Create | `test/adaptive_skill_pinning_test.dart` | D2 tests |
| Create | `test/min_context_test.dart` | D4 tests |

---

### Task 1: Tiered Skill Index (D1)

**Files:**
- Modify: `lib/services/skill_service.dart:71-83`
- Create: `test/tiered_skill_index_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// test/tiered_skill_index_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'tiered_skill_index_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late SkillService service;

  final tenSkills = Map.fromEntries(
    List.generate(10, (i) => MapEntry(
      'id-$i',
      SkillMetadata(
        noteId: 'id-$i',
        name: 'Skill $i',
        description: 'Description for skill $i that is somewhat verbose',
        enabled: true,
      ),
    )),
  );

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = SkillService(mockDb);
  });

  group('buildSkillIndexPrompt with maxBudgetTokens', () {
    test('full format when budget is large (100K+)', () {
      final prompt = service.buildSkillIndexPrompt(tenSkills, maxBudgetTokens: 100000);
      // Full format includes noteId, name, AND description
      expect(prompt, contains('id-0'));
      expect(prompt, contains('Skill 0'));
      expect(prompt, contains('Description for skill 0'));
    });

    test('compact format when budget is medium (15K-50K)', () {
      final prompt = service.buildSkillIndexPrompt(tenSkills, maxBudgetTokens: 15000);
      // Compact format: noteId: Name only, no descriptions
      expect(prompt, contains('id-0'));
      expect(prompt, contains('Skill 0'));
      expect(prompt, isNot(contains('Description for skill 0')));
    });

    test('minimal format when budget is small (<15K)', () {
      final prompt = service.buildSkillIndexPrompt(tenSkills, maxBudgetTokens: 8000);
      // Minimal format: single line listing names only
      expect(prompt, contains('Skill 0'));
      expect(prompt, contains('Skill 9'));
      // Should be very compact
      expect(prompt.length, lessThan(500));
    });

    test('returns empty string for empty index regardless of budget', () {
      expect(service.buildSkillIndexPrompt({}, maxBudgetTokens: 100000), isEmpty);
      expect(service.buildSkillIndexPrompt({}, maxBudgetTokens: 8000), isEmpty);
    });

    test('defaults to full format when maxBudgetTokens not specified', () {
      // Backwards compatibility: existing callers don't pass the param
      final prompt = service.buildSkillIndexPrompt(tenSkills);
      expect(prompt, contains('Description for skill 0'));
    });
  });
}
```

- [ ] **Step 2: Generate mocks and run to verify failing**

Run: `dart run build_runner build --delete-conflicting-outputs && flutter test test/tiered_skill_index_test.dart -v`
Expected: Fails because `buildSkillIndexPrompt` doesn't accept `maxBudgetTokens`.

- [ ] **Step 3: Implement tiered `buildSkillIndexPrompt`**

Replace the method in `lib/services/skill_service.dart`:

```dart
  String buildSkillIndexPrompt(Map<String, SkillMetadata> index, {int? maxBudgetTokens}) {
    if (index.isEmpty) return '';

    // Default to full format
    final budget = maxBudgetTokens ?? 100000;

    final sb = StringBuffer();

    if (budget < 15000) {
      // Minimal: single line with names
      sb.writeln('\n## Available Agent Skills');
      sb.writeln('Use load_skill with the noteId to get instructions.');
      sb.writeln(
        index.entries.map((e) => '${e.key}: ${e.value.name}').join(', '),
      );
    } else if (budget < 50000) {
      // Compact: noteId + name, no descriptions
      sb.writeln('\n## Available Agent Skills');
      sb.writeln('Use load_skill with the noteId to get instructions.\n');
      for (final entry in index.entries) {
        sb.writeln('${entry.key}: ${entry.value.name}');
      }
    } else {
      // Full: noteId + name + description (current behavior)
      sb.writeln('\n## Available Agent Skills');
      sb.writeln(
        'When a skill is relevant to the task, call load_skill with the noteId to get detailed workflow instructions.\n',
      );
      for (final entry in index.entries) {
        sb.writeln(
          '${entry.key}: ${entry.value.name} — ${entry.value.description}');
      }
    }
    return sb.toString();
  }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `flutter test test/tiered_skill_index_test.dart -v`
Expected: All tests pass.

- [ ] **Step 5: Update callers to pass budget**

Find callers of `buildSkillIndexPrompt` in `agent_service.dart` and `conversation_service.dart`. Add the `maxBudgetTokens` parameter using the model's context window size.

The implementer should:
1. Read `agent_service.dart` to find where `buildSkillIndexPrompt` is called
2. Pass the model's max context tokens (available from `ModelSelector` or similar)
3. Read `conversation_service.dart` and do the same

- [ ] **Step 6: Run full test suite**

Run: `flutter test`
Expected: All tests pass. The existing `skill_service_test.dart` tests should still pass because the new param has a default.

- [ ] **Step 7: Commit**

```bash
git add lib/services/skill_service.dart lib/services/agent_service.dart lib/services/conversation_service.dart test/tiered_skill_index_test.dart test/tiered_skill_index_test.mocks.dart
git commit -m "feat: tiered skill index prompt based on context budget (Phase D1)

Full format (50K+), compact (15-50K), and minimal (<15K) tiers
reduce skill index token cost on small-context models."
```

---

### Task 2: Adaptive Skill Pinning Budget (D2)

**Files:**
- Modify: `lib/services/context_manager_service.dart:662-669`
- Create: `test/adaptive_skill_pinning_test.dart`

- [ ] **Step 1: Read ContextManagerService to understand token estimation**

Read: `lib/services/context_manager_service.dart` — find how `estimatedTokens` is calculated, what `maxContextTokens` is, and how `isNearTokenLimit()` works. Also find `lib/utils/token_estimator.dart`.

- [ ] **Step 2: Write the failing tests**

```dart
// test/adaptive_skill_pinning_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/context_node.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'adaptive_skill_pinning_test.mocks.dart';

@GenerateMocks([DatabaseService, AIService])
void main() {
  late ContextManagerService contextManager;

  setUp(() async {
    await resetForTesting();
    final mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<AIService>(MockAIService());
    contextManager = ContextManagerService();
  });

  group('addLoadedSkill with budget', () {
    test('stores full content when under 30% pinning budget on 100K model', () {
      contextManager.createRootContext(
        objective: 'Test',
        maxContextTokens: 100000,
      );

      // ~500 tokens of skill content (well under 30% of 100K = 30K)
      final skillContent = '## Skill\n' + 'Step: do something.\n' * 50;
      contextManager.addLoadedSkill('skill-1', skillContent);

      final root = contextManager.rootContext!;
      expect(root.loadedSkills.length, 1);
      expect(root.loadedSkills[0].content, skillContent); // Full content
    });

    test('stores summary when skill would exceed 30% budget on 16K model', () {
      contextManager.createRootContext(
        objective: 'Test',
        maxContextTokens: 16000,
      );
      // 30% of 16K = 4800 tokens

      // Add first skill: ~2000 tokens (under budget)
      final skill1 = '## Big Skill\n' + 'Detailed step with explanation.\n' * 200;
      contextManager.addLoadedSkill('skill-1', skill1);
      expect(contextManager.rootContext!.loadedSkills[0].content, skill1);

      // Add second skill: ~2000 tokens more would exceed 4800
      final skill2 = '## Second Skill\n' + 'Another detailed step.\n' * 200;
      contextManager.addLoadedSkill('skill-2', skill2);

      // Second skill should be stored as a summary (much shorter)
      final stored = contextManager.rootContext!.loadedSkills[1];
      expect(stored.noteId, 'skill-2');
      expect(stored.content.length, lessThan(skill2.length));
      expect(stored.content, contains('Skill loaded but summarized'));
    });
  });
}
```

- [ ] **Step 3: Generate mocks and run to verify failing**

Run: `dart run build_runner build --delete-conflicting-outputs && flutter test test/adaptive_skill_pinning_test.dart -v`
Expected: The budget-check test fails because no budget logic exists.

- [ ] **Step 4: Implement budget check in addLoadedSkill**

In `lib/services/context_manager_service.dart`, replace the `addLoadedSkill` method:

```dart
  /// Add a loaded skill to the root context node (session-scoped, deduplicated).
  /// If adding the full skill would exceed 30% of maxContextTokens, stores a summary instead.
  void addLoadedSkill(String noteId, String content) {
    final root = rootContext;
    if (root == null) return;
    // Deduplicate by noteId
    if (root.loadedSkills.any((s) => s.noteId == noteId)) return;

    // Budget check: loaded skills should not consume more than 30% of context
    final maxPinnedTokens = (root.maxContextTokens * 0.3).toInt();
    final currentPinnedTokens = root.loadedSkills.fold<int>(
      0, (sum, s) => sum + _estimateTokens(s.content));
    final newTokens = _estimateTokens(content);

    if (currentPinnedTokens + newTokens > maxPinnedTokens) {
      // Store a one-line summary instead
      final firstLine = content.split('\n').firstWhere(
        (l) => l.trim().isNotEmpty,
        orElse: () => 'Skill',
      );
      root.loadedSkills.add(LoadedSkill(
        noteId: noteId,
        content: 'Skill loaded but summarized due to context constraints. '
            'Key: $firstLine. Unload a skill or use a higher-context model for full content.',
      ));
    } else {
      root.loadedSkills.add(LoadedSkill(noteId: noteId, content: content));
    }
  }

  int _estimateTokens(String text) {
    // Rough estimate: ~4 characters per token for English text
    return (text.length / 4).ceil();
  }
```

- [ ] **Step 5: Run tests**

Run: `flutter test test/adaptive_skill_pinning_test.dart -v`
Expected: All tests pass.

- [ ] **Step 6: Run full test suite**

Run: `flutter test`
Expected: No regressions.

- [ ] **Step 7: Commit**

```bash
git add lib/services/context_manager_service.dart test/adaptive_skill_pinning_test.dart test/adaptive_skill_pinning_test.mocks.dart
git commit -m "feat: adaptive skill pinning budget (Phase D2)

Loaded skills are limited to 30% of context budget. When exceeded,
new skills are stored as one-line summaries. Prevents context
exhaustion on 16K models with multiple wiki skills."
```

---

### Task 3: `min_context` Frontmatter Field (D4)

**Files:**
- Modify: `lib/services/skill_service.dart:4-48` — `SkillMetadata.minContext`, parse in `parseSkillMetadata`
- Modify: `lib/services/tools/load_skill_tool.dart` — warning when budget < minContext
- Create: `test/min_context_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// test/min_context_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'min_context_test.mocks.dart';

Note _makeNote(String id, String content) => Note(
  id: id, title: 'title', content: content,
  type: NoteType.note, createdAt: DateTime.now(), updatedAt: DateTime.now(),
  subNotes: [], tags: ['agent-skill'], attachmentPaths: [],
);

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

  group('parseSkillMetadata with min_context', () {
    test('parses min_context field', () {
      const content = '---\nname: Wiki Ingest\ndescription: Ingest sources\nmin_context: 50000\n---\n\nbody';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta, isNotNull);
      expect(meta!.minContext, 50000);
    });

    test('defaults minContext to null when absent', () {
      const content = '---\nname: Simple\ndescription: A skill\n---\n\nbody';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta!.minContext, isNull);
    });

    test('handles non-numeric min_context gracefully', () {
      const content = '---\nname: Bad\ndescription: Desc\nmin_context: lots\n---\n\nbody';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta!.minContext, isNull); // Non-numeric parsed as null
    });
  });

  group('buildSkillIndexPrompt with min_context annotations', () {
    test('annotates constrained skills when budget is small', () {
      final index = {
        'id-1': SkillMetadata(
          noteId: 'id-1', name: 'Wiki Ingest', description: 'Ingest',
          enabled: true, minContext: 50000),
        'id-2': SkillMetadata(
          noteId: 'id-2', name: 'Simple', description: 'Simple skill',
          enabled: true),
      };
      final prompt = service.buildSkillIndexPrompt(index, maxBudgetTokens: 16000);
      expect(prompt, contains('limited'));  // constrained annotation
      expect(prompt, contains('Wiki Ingest'));
    });
  });
}
```

- [ ] **Step 2: Generate mocks and run to verify failing**

Run: `dart run build_runner build --delete-conflicting-outputs && flutter test test/min_context_test.dart -v`
Expected: Fails because `SkillMetadata` doesn't have `minContext`.

- [ ] **Step 3: Add `minContext` to `SkillMetadata`**

In `lib/services/skill_service.dart`:

```dart
class SkillMetadata {
  final String noteId;
  final String name;
  final String description;
  final bool enabled;
  final int? minContext;

  const SkillMetadata({
    required this.noteId,
    required this.name,
    required this.description,
    required this.enabled,
    this.minContext,
  });
}
```

- [ ] **Step 4: Parse `min_context` in `parseSkillMetadata`**

Add after the `enabled` parsing:

```dart
    final minContextStr = fields['min_context'];
    final minContext = minContextStr != null ? int.tryParse(minContextStr) : null;
    return SkillMetadata(
        noteId: noteId, name: name, description: description,
        enabled: enabled, minContext: minContext);
```

- [ ] **Step 5: Add annotation in `buildSkillIndexPrompt`**

In the compact and full format branches, annotate skills where `minContext != null && minContext > budget`:

```dart
      for (final entry in index.entries) {
        final limited = entry.value.minContext != null &&
            entry.value.minContext! > budget;
        final suffix = limited ? ' (limited mode)' : '';
        sb.writeln(
          '${entry.key}: ${entry.value.name} — ${entry.value.description}$suffix');
      }
```

- [ ] **Step 6: Run tests**

Run: `flutter test test/min_context_test.dart -v`
Expected: All tests pass.

- [ ] **Step 7: Fix existing tests that construct SkillMetadata without minContext**

The existing `skill_service_test.dart` constructs `SkillMetadata` without `minContext`. Since it's optional with a default of `null`, existing tests should compile without changes. Verify:

Run: `flutter test test/skill_service_test.dart -v`
Expected: All pass (minContext defaults to null).

- [ ] **Step 8: Run full test suite**

Run: `flutter test`
Expected: All pass.

- [ ] **Step 9: Commit**

```bash
git add lib/services/skill_service.dart test/min_context_test.dart test/min_context_test.mocks.dart
git commit -m "feat: add min_context frontmatter field for skills (Phase D4)

Skills can declare minimum context requirements. The skill index
annotates constrained skills, and LoadSkillTool warns when budget
is insufficient."
```

---

### Task 4: Final validation

- [ ] **Step 1: Run flutter analyze**

Run: `flutter analyze`
Expected: No errors in modified files.

- [ ] **Step 2: Run full test suite**

Run: `flutter test`
Expected: All tests pass.
