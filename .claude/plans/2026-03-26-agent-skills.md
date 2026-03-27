# Agent Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add user-authored "agent skills" — notes tagged `agent-skill` with YAML frontmatter — that the agent discovers at session start, loads on demand via a new `load_skill` tool, injects into a protected context region, and uses to guide consistent workflows.

**Architecture:** `SkillService` handles frontmatter parsing, skill index building, tool URI resolution, and loaded-skill deduplication. `LoadSkillTool` is a new `NativeTool` that validates and returns skill content. `ContextNode` gains a `loadedSkills` list; `ContextManagerService` prepends it as a pinned, never-compacted block before the execution log. `AgentService` injects the skill index into both plan-generation and task-execution system prompts, adds `LoadSkillTool` as always-available, intercepts `load_skill` results to route content and resolve tool URIs, and injects skill-discovered tools into subsequent turns. `ConversationService` does the same for chat mode. Note editor gains an "Insert Tool" button and the note-selection dialog gains a tag filter.

**Tech Stack:** Flutter/Dart, GetIt service locator, SQLite via `DatabaseService` (`searchNotesFTS`, `getNote`), `McpTool`/`NativeTool` pattern, Mockito for tests.

---

## File Structure

**New files:**
- `lib/services/skill_service.dart` — `SkillMetadata` model + `SkillService`
- `lib/services/tools/load_skill_tool.dart` — `LoadSkillTool` NativeTool
- `test/skill_service_test.dart`
- `test/load_skill_tool_test.dart`

**Modified files:**
- `lib/models/context_node.dart` — add `loadedSkills: List<LoadedSkill>`
- `lib/services/context_manager_service.dart` — `addLoadedSkill()`, prepend skills in context assembly
- `lib/services/agent_service.dart` — skill index injection, `LoadSkillTool` registration, `load_skill` interception, `_skillDiscoveredTools`
- `lib/services/conversation_service.dart` — `_skillDiscoveredTools` for chat mode
- `lib/services/service_locator.dart` — register `SkillService`
- `lib/screens/note_selection_dialog.dart` — tag filter icon + `initialTags` param
- `lib/screens/note_detail_screen.dart` — "Insert Tool" button, tool link rendering/tap
- `lib/screens/ai_action_screen.dart` (or agent launch screen) — skills toggle

---

## Task 1: SkillService — metadata model, parsing, index, URI extraction

**Files:**
- Create: `lib/services/skill_service.dart`
- Modify: `lib/services/service_locator.dart`
- Create: `test/skill_service_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// test/skill_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'skill_service_test.mocks.dart';

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

  group('parseSkillMetadata', () {
    test('returns metadata for valid frontmatter', () {
      const content = '---\nname: Weekly Review\ndescription: Use when doing weekly review\nenabled: true\n---\n\n## Content';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta, isNotNull);
      expect(meta!.name, 'Weekly Review');
      expect(meta.description, 'Use when doing weekly review');
      expect(meta.enabled, true);
      expect(meta.noteId, 'note-1');
    });

    test('returns null when frontmatter is missing', () {
      const content = '## No frontmatter here';
      expect(service.parseSkillMetadata('note-1', content), isNull);
    });

    test('returns null when name is missing from frontmatter', () {
      const content = '---\ndescription: some desc\nenabled: true\n---\n\ncontent';
      expect(service.parseSkillMetadata('note-1', content), isNull);
    });

    test('returns null when description is missing from frontmatter', () {
      const content = '---\nname: My Skill\nenabled: true\n---\n\ncontent';
      expect(service.parseSkillMetadata('note-1', content), isNull);
    });

    test('defaults enabled to true when field absent', () {
      const content = '---\nname: Skill\ndescription: Desc\n---\n\ncontent';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta!.enabled, true);
    });

    test('parses enabled: false', () {
      const content = '---\nname: Skill\ndescription: Desc\nenabled: false\n---\n\ncontent';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta!.enabled, false);
    });
  });

  group('buildSkillIndex', () {
    test('returns only enabled skills', () async {
      final notes = [
        _makeNote('id-1', '---\nname: Skill A\ndescription: Desc A\nenabled: true\n---\n\nbody'),
        _makeNote('id-2', '---\nname: Skill B\ndescription: Desc B\nenabled: false\n---\n\nbody'),
        _makeNote('id-3', 'no frontmatter'),
      ];
      when(mockDb.searchNotesFTS('', tags: ['agent-skill']))
          .thenAnswer((_) async => notes);
      final index = await service.buildSkillIndex();
      expect(index.keys, containsAll(['id-1']));
      expect(index.containsKey('id-2'), false);
      expect(index.containsKey('id-3'), false);
    });
  });

  group('buildSkillIndexPrompt', () {
    test('returns empty string for empty index', () {
      expect(service.buildSkillIndexPrompt({}), isEmpty);
    });

    test('includes noteId and description for each skill', () {
      final index = {
        'note-abc': SkillMetadata(noteId: 'note-abc', name: 'My Skill', description: 'Use for X', enabled: true),
      };
      final prompt = service.buildSkillIndexPrompt(index);
      expect(prompt, contains('note-abc'));
      expect(prompt, contains('My Skill'));
      expect(prompt, contains('Use for X'));
    });
  });

  group('extractToolUris', () {
    test('extracts tool URIs from content', () {
      const content = '''
Use [search](notesynapse://tool/builtin/search_notes) and
[MyApp](notesynapse://tool/user_defined/uuid-123/analyze).
Also [MCP](notesynapse://tool/mcp/my-service/search).
''';
      final uris = service.extractToolUris(content);
      expect(uris, containsAll([
        'notesynapse://tool/builtin/search_notes',
        'notesynapse://tool/user_defined/uuid-123/analyze',
        'notesynapse://tool/mcp/my-service/search',
      ]));
    });

    test('returns empty list when no tool URIs present', () {
      const content = 'No tools here, just [a note link](notesynapse://note/abc).';
      expect(service.extractToolUris(content), isEmpty);
    });
  });

  group('loadedSkill deduplication', () {
    test('isAlreadyLoaded returns false before mark', () {
      expect(service.isAlreadyLoaded('note-1'), false);
    });

    test('isAlreadyLoaded returns true after markLoaded', () {
      service.markLoaded('note-1');
      expect(service.isAlreadyLoaded('note-1'), true);
    });

    test('resetSession clears loaded set', () {
      service.markLoaded('note-1');
      service.resetSession();
      expect(service.isAlreadyLoaded('note-1'), false);
    });
  });
}

Note _makeNote(String id, String content) => Note(
  id: id, title: 'title', content: content,
  type: NoteType.note, createdAt: DateTime.now(), updatedAt: DateTime.now(),
  subNotes: [], tags: ['agent-skill'], attachmentPaths: [],
);
```

- [ ] **Step 2: Run tests to confirm they fail**

```
flutter test test/skill_service_test.dart
```
Expected: FAIL with import/class-not-found errors.

- [ ] **Step 3: Create SkillService**

```dart
// lib/services/skill_service.dart
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';

class SkillMetadata {
  final String noteId;
  final String name;
  final String description;
  final bool enabled;

  const SkillMetadata({
    required this.noteId,
    required this.name,
    required this.description,
    required this.enabled,
  });
}

class SkillService {
  final DatabaseService _db;
  final Set<String> _loadedSkillNoteIds = {};

  SkillService(this._db);

  // --- Parsing ---

  SkillMetadata? parseSkillMetadata(String noteId, String content) {
    if (!content.startsWith('---\n')) return null;
    final endIdx = content.indexOf('\n---\n', 4);
    if (endIdx == -1) return null;
    final frontmatter = content.substring(4, endIdx);
    final fields = <String, String>{};
    for (final line in frontmatter.split('\n')) {
      final colonIdx = line.indexOf(':');
      if (colonIdx == -1) continue;
      final key = line.substring(0, colonIdx).trim();
      final value = line.substring(colonIdx + 1).trim();
      if (key.isNotEmpty) fields[key] = value;
    }
    final name = fields['name'];
    final description = fields['description'];
    if (name == null || name.isEmpty) return null;
    if (description == null || description.isEmpty) return null;
    final enabled = fields['enabled']?.toLowerCase() != 'false';
    return SkillMetadata(noteId: noteId, name: name, description: description, enabled: enabled);
  }

  String stripFrontmatter(String content) {
    if (!content.startsWith('---\n')) return content;
    final endIdx = content.indexOf('\n---\n', 4);
    if (endIdx == -1) return content;
    return content.substring(endIdx + 5).trim();
  }

  // --- Index ---

  Future<Map<String, SkillMetadata>> buildSkillIndex() async {
    final notes = await _db.searchNotesFTS('', tags: ['agent-skill']);
    final index = <String, SkillMetadata>{};
    for (final note in notes) {
      final meta = parseSkillMetadata(note.id, note.content);
      if (meta != null && meta.enabled) {
        index[note.id] = meta;
      }
    }
    return index;
  }

  String buildSkillIndexPrompt(Map<String, SkillMetadata> index) {
    if (index.isEmpty) return '';
    final sb = StringBuffer();
    sb.writeln('\n## Available Agent Skills');
    sb.writeln(
      'When a skill is relevant to the task, call load_skill with the noteId to get detailed workflow instructions.\n',
    );
    for (final entry in index.entries) {
      sb.writeln('${entry.key}: ${entry.value.name} — ${entry.value.description}');
    }
    return sb.toString();
  }

  // --- Tool URI extraction ---

  List<String> extractToolUris(String content) {
    final regex = RegExp(r'notesynapse://tool/[^\s\)\"\']+');
    return regex.allMatches(content).map((m) => m.group(0)!).toList();
  }

  /// Parse a notesynapse://tool/ URI into its components.
  /// Returns null if the URI is not a valid tool URI.
  ({String namespace, String id, String? function})? parseToolUri(String uri) {
    const prefix = 'notesynapse://tool/';
    if (!uri.startsWith(prefix)) return null;
    final path = uri.substring(prefix.length);
    final parts = path.split('/');
    if (parts.length < 2) return null;
    final namespace = parts[0]; // builtin | user_defined | mcp
    final id = parts[1];
    final function = parts.length > 2 ? parts[2] : null;
    return (namespace: namespace, id: id, function: function);
  }

  // --- Deduplication ---

  bool isAlreadyLoaded(String noteId) => _loadedSkillNoteIds.contains(noteId);

  void markLoaded(String noteId) => _loadedSkillNoteIds.add(noteId);

  void resetSession() => _loadedSkillNoteIds.clear();
}
```

- [ ] **Step 4: Register SkillService in service_locator.dart**

Open `lib/services/service_locator.dart`. Find where other services are registered (e.g., `getIt.registerSingleton<DatabaseService>(...)`). Add:

```dart
getIt.registerSingleton<SkillService>(
  SkillService(getIt<DatabaseService>()),
);
```

Register it after `DatabaseService` is registered.

- [ ] **Step 5: Generate mocks**

```
dart run build_runner build --delete-conflicting-outputs
```

- [ ] **Step 6: Run tests to confirm they pass**

```
flutter test test/skill_service_test.dart
```
Expected: All tests PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/services/skill_service.dart lib/services/service_locator.dart test/skill_service_test.dart test/skill_service_test.mocks.dart
git commit -m "feat: add SkillService with frontmatter parsing, skill index, and tool URI extraction"
```

---

## Task 2: LoadSkillTool NativeTool

**Files:**
- Create: `lib/services/tools/load_skill_tool.dart`
- Create: `test/load_skill_tool_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// test/load_skill_tool_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/tools/load_skill_tool.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'load_skill_tool_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late SkillService skillService;
  late LoadSkillTool tool;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    skillService = SkillService(mockDb);
    getIt.registerSingleton<SkillService>(skillService);
    tool = LoadSkillTool();
  });

  test('returns skill content when note is valid', () async {
    const content = '---\nname: My Skill\ndescription: desc\nenabled: true\n---\n\n## Workflow\nDo this.';
    when(mockDb.getNote('note-1')).thenAnswer((_) async => _makeNote('note-1', content));
    final result = await tool.execute({'noteId': 'note-1'});
    expect(result, isA<String>());
    expect(result as String, contains('# Skill: My Skill'));
    expect(result, contains('## Workflow'));
    expect(result, isNot(contains('---')));
  });

  test('returns error when note not found', () async {
    when(mockDb.getNote('missing')).thenAnswer((_) async => null);
    final result = await tool.execute({'noteId': 'missing'});
    expect(result, isA<Map>());
    expect((result as Map)['error'], contains('not found'));
  });

  test('returns error when frontmatter is missing', () async {
    when(mockDb.getNote('note-1')).thenAnswer((_) async => _makeNote('note-1', 'no frontmatter'));
    final result = await tool.execute({'noteId': 'note-1'});
    expect((result as Map)['error'], contains('not a valid skill'));
  });

  test('returns error when skill is disabled', () async {
    const content = '---\nname: My Skill\ndescription: desc\nenabled: false\n---\n\nbody';
    when(mockDb.getNote('note-1')).thenAnswer((_) async => _makeNote('note-1', content));
    final result = await tool.execute({'noteId': 'note-1'});
    expect((result as Map)['error'], contains('disabled'));
  });

  test('returns cached content on second call (dedup)', () async {
    const content = '---\nname: Skill\ndescription: desc\nenabled: true\n---\n\nbody';
    when(mockDb.getNote('note-1')).thenAnswer((_) async => _makeNote('note-1', content));
    await tool.execute({'noteId': 'note-1'});
    final result2 = await tool.execute({'noteId': 'note-1'});
    // Second call: getNote called only once total (cached)
    verify(mockDb.getNote('note-1')).called(1);
    expect(result2, isA<String>());
  });

  test('has correct name and inputSchema', () {
    expect(tool.name, 'load_skill');
    expect(tool.inputSchema['properties'], containsKey('noteId'));
  });
}

Note _makeNote(String id, String content) => Note(
  id: id, title: 'title', content: content,
  type: NoteType.note, createdAt: DateTime.now(), updatedAt: DateTime.now(),
  subNotes: [], tags: ['agent-skill'], attachmentPaths: [],
);
```

- [ ] **Step 2: Run tests to confirm they fail**

```
flutter test test/load_skill_tool_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Create LoadSkillTool**

```dart
// lib/services/tools/load_skill_tool.dart
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'note_tools.dart';

class LoadSkillTool extends NativeTool {
  // Cache: noteId -> formatted content
  final Map<String, String> _cache = {};

  @override
  String get name => 'load_skill';

  @override
  String get description =>
      'Load a skill note by ID to get detailed workflow instructions for a specific task or workflow type. '
      'Use this when a skill in the Available Agent Skills list is relevant to the current task.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'noteId': {
        'type': 'string',
        'description': 'The note ID of the skill to load (from the Available Agent Skills list)',
      },
    },
    'required': ['noteId'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final noteId = (args['noteId'] as String? ?? '').trim();
    if (noteId.isEmpty) return {'error': 'noteId is required'};

    // Return from cache if already loaded this session
    if (_cache.containsKey(noteId)) return _cache[noteId]!;

    final db = getIt<DatabaseService>();
    final skillService = getIt<SkillService>();

    final note = await db.getNote(noteId);
    if (note == null) return {'error': 'Skill note $noteId not found'};

    final meta = skillService.parseSkillMetadata(noteId, note.content);
    if (meta == null) {
      return {'error': 'Note $noteId is not a valid skill (missing or malformed frontmatter)'};
    }
    if (!meta.enabled) return {'error': "Skill '${meta.name}' is disabled"};

    final body = skillService.stripFrontmatter(note.content);
    final formatted = '# Skill: ${meta.name}\n\n$body';

    _cache[noteId] = formatted;
    skillService.markLoaded(noteId);
    return formatted;
  }

  /// Clear cache for a new session.
  void resetSession() => _cache.clear();
}
```

- [ ] **Step 4: Regenerate mocks**

```
dart run build_runner build --delete-conflicting-outputs
```

- [ ] **Step 5: Run tests**

```
flutter test test/load_skill_tool_test.dart
```
Expected: All PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/services/tools/load_skill_tool.dart test/load_skill_tool_test.dart test/load_skill_tool_test.mocks.dart
git commit -m "feat: add LoadSkillTool NativeTool for loading agent skill notes"
```

---

## Task 3: ContextNode loadedSkills field + ContextManagerService integration

**Files:**
- Modify: `lib/models/context_node.dart`
- Modify: `lib/services/context_manager_service.dart`

- [ ] **Step 1: Add LoadedSkill class and loadedSkills field to ContextNode**

Open `lib/models/context_node.dart`. Add the `LoadedSkill` class before `ContextNode`, and add `loadedSkills` as a field:

```dart
// Add before ContextNode class
class LoadedSkill {
  final String noteId;
  final String content;
  const LoadedSkill({required this.noteId, required this.content});
}
```

Inside `ContextNode`, find the field declarations and add:
```dart
// Add alongside executionLog
List<LoadedSkill> loadedSkills = [];
```

If `ContextNode` has a `copyWith` method, add `loadedSkills` to it:
```dart
loadedSkills: loadedSkills ?? this.loadedSkills,
```

- [ ] **Step 2: Add addLoadedSkill to ContextManagerService**

Open `lib/services/context_manager_service.dart`. Add this method to the `ContextManagerService` class:

```dart
/// Add a loaded skill to the root context node (session-scoped, deduplicated).
void addLoadedSkill(String noteId, String content) {
  final root = rootContext;
  if (root == null) return;
  // Deduplicate by noteId
  if (root.loadedSkills.any((s) => s.noteId == noteId)) return;
  root.loadedSkills.add(LoadedSkill(noteId: noteId, content: content));
}
```

Make sure to import `LoadedSkill` if it's in a separate file (it's in `context_node.dart` which is likely already imported).

- [ ] **Step 3: Prepend loadedSkills in buildContextForNode**

In `lib/services/context_manager_service.dart`, find `buildContextForNode` (around line 146). After the `<GlobalObjective>` block is written to the buffer, add the skills block:

```dart
// After the GlobalObjective block (after its closing writeln and blank line):
final root = _getRoot(node);
if (root.loadedSkills.isNotEmpty) {
  buffer.writeln('<LoadedSkills note="These skill workflows guide your approach. Follow them.">');
  for (final skill in root.loadedSkills) {
    buffer.writeln(skill.content);
    buffer.writeln();
  }
  buffer.writeln('</LoadedSkills>');
  buffer.writeln();
}
```

Apply the same change to `buildContextForResearchTask` (around line 336) and `buildSynthesisContext` (around line 669), inserting the same skills block after the GlobalObjective section in each method.

- [ ] **Step 4: Verify compaction is unaffected**

Open `compactNodeContext` (around line 484). Confirm it only operates on `node.executionLog` (not `loadedSkills`). The current code does:
```dart
node.estimatedTokens = node.executionLog.join().length ~/ 4;
```
Since `loadedSkills` is not in `executionLog`, compaction already excludes it. No change needed.

- [ ] **Step 5: Run existing tests to confirm no regression**

```
flutter test test/context_manager_service_test.dart
```
Expected: All existing tests PASS. If this test file doesn't exist, run:
```
flutter test
```
Expected: No new failures.

- [ ] **Step 6: Commit**

```bash
git add lib/models/context_node.dart lib/services/context_manager_service.dart
git commit -m "feat: add loadedSkills pinned region to ContextNode and ContextManagerService"
```

---

## Task 4: AgentService — skill index injection and LoadSkillTool registration

**Files:**
- Modify: `lib/services/agent_service.dart`

- [ ] **Step 1: Add skill state fields to AgentService**

Open `lib/services/agent_service.dart`. In the class fields section (around lines 53-73), add:

```dart
bool _skillsEnabled = true;
Map<String, SkillMetadata> _skillIndex = {};
final List<McpTool> _skillDiscoveredTools = [];
LoadSkillTool? _loadSkillTool;
```

Add the import at the top:
```dart
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/tools/load_skill_tool.dart';
```

- [ ] **Step 2: Expose LoadSkillTool via nativeTools getter**

Find the `nativeTools` getter (around line 1003-1009):
```dart
List<NativeTool> get nativeTools {
  _readTaskResultTool ??= ReadTaskResultTool(_contextManager);
  return List.unmodifiable([..._nativeTools, _readTaskResultTool!]);
}
```

Update it to include `LoadSkillTool` when skills are enabled:
```dart
List<NativeTool> get nativeTools {
  _readTaskResultTool ??= ReadTaskResultTool(_contextManager);
  if (_skillsEnabled) {
    _loadSkillTool ??= LoadSkillTool();
    return List.unmodifiable([..._nativeTools, _readTaskResultTool!, _loadSkillTool!]);
  }
  return List.unmodifiable([..._nativeTools, _readTaskResultTool!]);
}
```

- [ ] **Step 3: Build and inject skill index in generatePlan**

In `generatePlan` (around line 1038), add a parameter and index-building call:

Add `skillsEnabled` parameter to the method signature:
```dart
Future<List<AgentTask>> generatePlan(
  String objective, {
  Map<String, List<McpTool>> activeTools = const {},
  ToolExecutor? executeTool,
  String? context,
  List<PlatformFile> contextAttachments = const [],
  bool skillsEnabled = true,   // ADD THIS
}) async {
```

Early in the method body (after `_externalTools = activeTools;`), add:
```dart
_skillsEnabled = skillsEnabled;
_skillDiscoveredTools.clear();
getIt<SkillService>().resetSession();
_loadSkillTool?.resetSession();

if (_skillsEnabled) {
  _skillIndex = await getIt<SkillService>().buildSkillIndex();
} else {
  _skillIndex = {};
}
```

Find where the `prompt` string is assembled (around line 1137, after `nativeToolsDesc` is built). The prompt ends with something like `$noteExplorationSection`. Append the skill index:

```dart
final skillIndexSection = _skillsEnabled
    ? getIt<SkillService>().buildSkillIndexPrompt(_skillIndex)
    : '';

final prompt = '''
...existing prompt content...
$noteExplorationSection$skillIndexSection
...''';
```

(Insert `$skillIndexSection` at the end of the existing prompt string, before any closing backtick or after the last section variable.)

- [ ] **Step 4: Inject skill index in task execution system prompt**

In `_performTask` (around line 1733-1842), find where `toolsDesc` is built and the system prompt is assembled. The prompt contains:
```dart
Available Tools (read_task_result is always available for fetching context):
$toolsDesc
```

Add skill-discovered tools to `toolsDesc`. Find the toolsDesc assembly and add:
```dart
final skillToolsDesc = _skillDiscoveredTools.isNotEmpty
    ? '\nSkill-Discovered Tools (added by loaded skills):\n' +
      _skillDiscoveredTools.map(
        (t) => '- ${t.name}: ${t.description}\n  Params: ${jsonEncode(t.inputSchema)}'
      ).join('\n')
    : '';

final toolsDesc = [
  ...currentAllowedNative.map(
    (t) => '- ${t.name}: ${t.description}\n  Params: ${jsonEncode(t.inputSchema)}',
  ),
  ...currentAllowedExternal.map(
    (t) => '- ${t.name}: ${t.description}\n  Params: ${jsonEncode(t.inputSchema)}',
  ),
].join('\n') + skillToolsDesc;
```

Also append the skill index at the bottom of the task execution system prompt (so the agent knows about undiscovered skills):
```dart
final taskSkillSection = _skillsEnabled && _skillIndex.isNotEmpty
    ? getIt<SkillService>().buildSkillIndexPrompt(_skillIndex)
    : '';
```
Then include `$taskSkillSection` at the end of the task system prompt string.

- [ ] **Step 5: Ensure load_skill is always available in _performTask**

In `_performTask`, find the section that guarantees `read_task_result` is always included (around lines 1693-1715):
```dart
final readTaskResultTool = nativeTools
    .where((t) => t.name == 'read_task_result')
    .toList();
```

Add similar handling for `load_skill`:
```dart
final alwaysAvailable = nativeTools
    .where((t) => t.name == 'read_task_result' || (t.name == 'load_skill' && _skillsEnabled))
    .toList();

if (task.allowedTools.isNotEmpty) {
  final userFiltered = enabledNativeTools
      .where((t) => task.allowedTools.contains(t.name))
      .toList();
  final missing = alwaysAvailable.where(
    (t) => !userFiltered.any((u) => u.name == t.name)
  );
  return [...userFiltered, ...missing];
}
if (enabledNativeTools.any((t) => alwaysAvailable.any((a) => a.name == t.name))) {
  return enabledNativeTools;
}
return [...enabledNativeTools, ...alwaysAvailable];
```

- [ ] **Step 6: Analyze to check for errors**

```
flutter analyze lib/services/agent_service.dart
```
Expected: No new errors.

- [ ] **Step 7: Commit**

```bash
git add lib/services/agent_service.dart
git commit -m "feat: inject skill index into AgentService prompts and register LoadSkillTool"
```

---

## Task 5: AgentService — intercept load_skill results, route to context and tool injection

**Files:**
- Modify: `lib/services/agent_service.dart`

- [ ] **Step 1: Add _handleLoadSkillResult helper**

In `lib/services/agent_service.dart`, add a private method to the class:

```dart
/// Called when a load_skill tool call returns successfully.
/// Routes skill content to the loadedSkills context region and resolves tool URIs.
Future<void> _handleLoadSkillResult(String noteId, String content) async {
  // Add to pinned context region
  _contextManager.addLoadedSkill(noteId, content);

  // Extract and resolve tool URIs from skill content
  final skillService = getIt<SkillService>();
  final uris = skillService.extractToolUris(content);
  for (final uri in uris) {
    final parsed = skillService.parseToolUri(uri);
    if (parsed == null) continue;
    final tools = await _resolveSkillToolUri(parsed);
    for (final tool in tools) {
      if (!_skillDiscoveredTools.any((t) => t.name == tool.name)) {
        _skillDiscoveredTools.add(tool);
      }
    }
  }
  notifyListeners();
}

/// Resolve a parsed tool URI to a list of McpTools.
Future<List<McpTool>> _resolveSkillToolUri(
  ({String namespace, String id, String? function}) parsed,
) async {
  switch (parsed.namespace) {
    case 'builtin':
      // Find in native tools list, convert to McpTool
      final tool = _nativeTools.where((t) => t.name == parsed.id).firstOrNull;
      if (tool == null) return [];
      return [McpTool(
        name: tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema,
      )];

    case 'user_defined':
      // Delegate to AiToolService — look up bundle by UUID.
      // Check lib/services/ai_tool_service.dart for the method that retrieves a
      // single AiToolAppBundle by UUID (e.g. getToolApp, getBundle, or filter getToolBundles()).
      final aiToolService = getIt<AiToolService>();
      final bundles = await aiToolService.getToolBundles();
      final bundle = bundles.where((b) => b.uuid == parsed.id).firstOrNull;
      if (bundle == null) return [];
      final allTools = bundle.toMcpTools();
      if (parsed.function != null) {
        return allTools.where((t) => t.name == parsed.function).toList();
      }
      return allTools;

    case 'mcp':
      // Delegate to McpService — use getEndpoints() and filter by name
      final mcpService = getIt<McpService>();
      final endpoints = await mcpService.getEndpoints();
      final endpoint = endpoints.where((e) => e.name == parsed.id).firstOrNull;
      if (endpoint == null) return [];
      // Use cached tools if available, otherwise refresh
      final allTools = endpoint.cachedTools?.tools
          ?? await mcpService.refreshTools(endpoint.id);
      if (parsed.function != null) {
        return allTools.where((t) => t.name == parsed.function).toList();
      }
      return allTools;

    default:
      return [];
  }
}
```

Add the necessary imports for `AiToolService` and `McpService` at the top of `agent_service.dart`:
```dart
import 'package:note_synapse/services/ai_tool_service.dart';
import 'package:note_synapse/services/mcp_service.dart';
```

- [ ] **Step 2: Call _handleLoadSkillResult after load_skill tool execution**

In `_performTask`, find where tool execution results are processed (the section after a tool is executed and its result is obtained). Add interception for `load_skill`:

```dart
// After: final toolResult = await _executeTool(toolName, toolArgs, ...);
// Add:
if (toolName == 'load_skill' && toolResult is String) {
  final noteId = (toolArgs['noteId'] as String? ?? '').trim();
  if (noteId.isNotEmpty) {
    await _handleLoadSkillResult(noteId, toolResult);
  }
}
```

The exact insertion point is after the tool result is obtained but before it's logged as an observation. Search for where `toolResult` is added to execution history (look for "Observation:" string near tool execution).

- [ ] **Step 3: Log trace annotation when skill-discovered tools are added**

In `_handleLoadSkillResult`, after adding tools to `_skillDiscoveredTools`, log a trace entry so the agent trace screen shows the injection. Find the root context node and log to it:

```dart
// After the loop that adds to _skillDiscoveredTools:
if (uris.isNotEmpty) {
  final addedNames = _skillDiscoveredTools
      .where((t) => uris.any((u) => u.contains(t.name)))
      .map((t) => t.name)
      .join(', ');
  if (addedNames.isNotEmpty) {
    _contextManager.rootContext?.log(
      "Skill loaded: injected tools [$addedNames]",
    );
  }
}
```

- [ ] **Step 4: Analyze to check for compilation errors**

```
flutter analyze lib/services/agent_service.dart
```
Expected: No errors. The `getToolBundles()` method on `AiToolService` and `getEndpoints()` / `refreshTools()` on `McpService` should exist based on prior exploration. If method signatures differ, check the actual declarations in those service files.

- [ ] **Step 5: Commit**

```bash
git add lib/services/agent_service.dart
git commit -m "feat: intercept load_skill results to route content and inject skill-discovered tools"
```

---

## Task 6: ConversationService — chat mode skill support

**Files:**
- Modify: `lib/services/conversation_service.dart`

- [ ] **Step 1: Add skill state to ConversationService**

Open `lib/services/conversation_service.dart`. Add skill-related fields to the class:

```dart
bool _skillsEnabled = false;
Map<String, SkillMetadata> _skillIndex = {};
final List<McpTool> _skillDiscoveredTools = [];
LoadSkillTool? _loadSkillTool;
```

Add imports:
```dart
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/tools/load_skill_tool.dart';
```

- [ ] **Step 2: Add enableSkills method**

```dart
Future<void> enableSkills() async {
  _skillsEnabled = true;
  _skillDiscoveredTools.clear();
  getIt<SkillService>().resetSession();
  _loadSkillTool?.resetSession();
  _skillIndex = await getIt<SkillService>().buildSkillIndex();
}

void disableSkills() {
  _skillsEnabled = false;
  _skillIndex = {};
  _skillDiscoveredTools.clear();
}
```

- [ ] **Step 3: Include load_skill in function_tools when skills are enabled**

Find where `function_tools` / tools are assembled for the API call in `ConversationService`. This is the list passed to `AIService.generateContent(...)`. After the existing tool list is built, merge in skill-discovered tools and optionally `load_skill`:

```dart
// Wherever functionTools list is assembled before the API call:
if (_skillsEnabled) {
  // Ensure load_skill is in the function tools
  _loadSkillTool ??= LoadSkillTool();
  final loadSkillMcp = McpTool(
    name: _loadSkillTool!.name,
    description: _loadSkillTool!.description,
    inputSchema: _loadSkillTool!.inputSchema,
  );
  if (!functionTools.any((t) => t.name == 'load_skill')) {
    functionTools.add(loadSkillMcp);
  }
  // Add skill-discovered tools
  for (final t in _skillDiscoveredTools) {
    if (!functionTools.any((f) => f.name == t.name)) {
      functionTools.add(t);
    }
  }
}
```

- [ ] **Step 4: Intercept load_skill tool results in chat mode**

Find where tool call results are processed in `ConversationService` (the section where the AI response includes a function call and it's executed). After a tool result is obtained, add interception:

```dart
if (toolName == 'load_skill' && result is String) {
  final noteId = (toolArgs['noteId'] as String? ?? '').trim();
  if (noteId.isNotEmpty && _skillsEnabled) {
    _loadSkillTool ??= LoadSkillTool();
    // Extract tool URIs and resolve them
    final skillService = getIt<SkillService>();
    final uris = skillService.extractToolUris(result);
    for (final uri in uris) {
      final parsed = skillService.parseToolUri(uri);
      if (parsed == null) continue;
      // For chat mode, resolve user_defined and mcp tools
      // (builtin tools are already in function_tools if user selected them)
      if (parsed.namespace == 'mcp') {
        final mcpService = getIt<McpService>();
        final endpoint = await mcpService.getEndpointByName(parsed.id);
        if (endpoint != null) {
          final tools = await mcpService.getToolsForEndpoint(endpoint.id);
          final filtered = parsed.function != null
              ? tools.where((t) => t.name == parsed.function).toList()
              : tools;
          for (final t in filtered) {
            if (!_skillDiscoveredTools.any((s) => s.name == t.name)) {
              _skillDiscoveredTools.add(t);
            }
          }
        }
      }
    }
  }
}
```

Also inject the skill index into the system prompt when building the conversation context (find where system prompt is assembled and append `getIt<SkillService>().buildSkillIndexPrompt(_skillIndex)` when `_skillsEnabled`).

- [ ] **Step 5: Analyze**

```
flutter analyze lib/services/conversation_service.dart
```
Expected: No errors.

- [ ] **Step 6: Commit**

```bash
git add lib/services/conversation_service.dart
git commit -m "feat: add skill support to ConversationService for chat mode"
```

---

## Task 7: Note Selection Dialog — tag filter

**Files:**
- Modify: `lib/screens/note_selection_dialog.dart`

- [ ] **Step 1: Add initialTags parameter and tag filter state**

Open `lib/screens/note_selection_dialog.dart`. Find the widget class (likely a `StatefulWidget`). Add the `initialTags` parameter to the constructor:

```dart
final List<String>? initialTags;

const NoteSelectionDialog({
  super.key,
  // ... existing params ...
  this.initialTags,
});
```

In the `State` class, add tag filter state:
```dart
List<String> _activeTagFilters = [];
```

In `initState`, initialize from `initialTags`:
```dart
@override
void initState() {
  super.initState();
  _activeTagFilters = List.from(widget.initialTags ?? []);
}
```

- [ ] **Step 2: Add filter icon button to dialog header**

In the `build` method, find the dialog header (likely an `AppBar` or a `Row` with a title). Add a filter icon button:

```dart
IconButton(
  icon: Stack(
    children: [
      const Icon(Icons.filter_list),
      if (_activeTagFilters.isNotEmpty)
        Positioned(
          right: 0, top: 0,
          child: Container(
            width: 8, height: 8,
            decoration: const BoxDecoration(
              color: Colors.blue,
              shape: BoxShape.circle,
            ),
          ),
        ),
    ],
  ),
  onPressed: _showTagFilterDialog,
),
```

- [ ] **Step 3: Implement _showTagFilterDialog**

```dart
Future<void> _showTagFilterDialog() async {
  // Reuse the existing tag selection pattern from the app
  // Show a dialog listing all tags, user can select multiple
  // Look at how the main screen's tag filter works and follow the same pattern
  final allTags = await getIt<DatabaseService>().getAllTags();
  if (!mounted) return;
  final selected = await showDialog<List<String>>(
    context: context,
    builder: (ctx) => _TagFilterDialog(
      allTags: allTags,
      selectedTags: _activeTagFilters,
    ),
  );
  if (selected != null) {
    setState(() {
      _activeTagFilters = selected;
    });
    _applyFilters();
  }
}
```

Create a minimal `_TagFilterDialog` widget in the same file:
```dart
class _TagFilterDialog extends StatefulWidget {
  final List<String> allTags;
  final List<String> selectedTags;
  const _TagFilterDialog({required this.allTags, required this.selectedTags});

  @override
  State<_TagFilterDialog> createState() => _TagFilterDialogState();
}

class _TagFilterDialogState extends State<_TagFilterDialog> {
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.selectedTags);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Filter by Tags'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: widget.allTags.map((tag) => CheckboxListTile(
            title: Text(tag),
            value: _selected.contains(tag),
            onChanged: (checked) {
              setState(() {
                if (checked == true) {
                  _selected.add(tag);
                } else {
                  _selected.remove(tag);
                }
              });
            },
          )).toList(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Apply tag filter to note list**

Find `_applyFilters` or the note-loading method. When `_activeTagFilters` is non-empty, filter results to only notes that contain all active tags:

```dart
void _applyFilters() {
  // If using a search service, re-run search with tag filters
  // Pass _activeTagFilters to the existing search/fetch call
  // Exact implementation depends on how notes are currently loaded;
  // follow the same pattern as the existing text search filtering
  _loadNotes(tagFilters: _activeTagFilters.isEmpty ? null : _activeTagFilters);
}
```

In `_loadNotes` (or the existing fetch method), add the tag filter parameter and pass it to `DatabaseService.searchNotesFTS`:
```dart
Future<void> _loadNotes({List<String>? tagFilters}) async {
  final notes = await getIt<DatabaseService>().searchNotesFTS(
    _searchQuery,
    tags: tagFilters,
  );
  setState(() { _notes = notes; });
}
```

- [ ] **Step 5: Pass initialTags from skill note editor**

Find where `NoteSelectionDialog` is opened when inserting a note link inside a skill note. This is typically in `note_detail_screen.dart` in the note link insertion handler. Detect if the current note is a skill (has `agent-skill` tag) and pass `initialTags: ['agent-skill']`:

```dart
// When opening NoteSelectionDialog for a note link in a skill note:
NoteSelectionDialog(
  // ... existing params ...
  initialTags: widget.note.tags.contains('agent-skill') ? ['agent-skill'] : null,
)
```

- [ ] **Step 6: Run analyze**

```
flutter analyze lib/screens/note_selection_dialog.dart
```
Expected: No errors.

- [ ] **Step 7: Commit**

```bash
git add lib/screens/note_selection_dialog.dart
git commit -m "feat: add tag filter to NoteSelectionDialog with initialTags parameter"
```

---

## Task 8: Note Editor — Insert Tool button and picker

**Files:**
- Create: `lib/screens/tool_picker_sheet.dart`
- Modify: `lib/screens/note_detail_screen.dart`

- [ ] **Step 1: Create ToolPickerSheet**

```dart
// lib/screens/tool_picker_sheet.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/ai_tool_service.dart';
import 'package:note_synapse/services/mcp_service.dart';
import 'package:note_synapse/services/tools/note_tools.dart';

/// Bottom sheet for inserting tool links into note content.
/// Returns a markdown link string like [toolName](notesynapse://tool/...) when dismissed with a selection.
class ToolPickerSheet extends StatefulWidget {
  const ToolPickerSheet({super.key});

  /// Show the bottom sheet and return the selected markdown link, or null if cancelled.
  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const ToolPickerSheet(),
    );
  }

  @override
  State<ToolPickerSheet> createState() => _ToolPickerSheetState();
}

class _ToolPickerSheetState extends State<ToolPickerSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _select(String markdownLink) => Navigator.pop(context, markdownLink);

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (_, scrollController) => Column(
        children: [
          TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: 'Built-in'),
              Tab(text: 'User Defined'),
              Tab(text: 'MCP'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _BuiltinToolsTab(onSelect: _select),
                _UserDefinedToolsTab(onSelect: _select),
                _McpToolsTab(onSelect: _select),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Built-in tab ---

class _BuiltinToolsTab extends StatelessWidget {
  final void Function(String) onSelect;
  const _BuiltinToolsTab({required this.onSelect});

  // These are the built-in NativeTool names and descriptions.
  // Keep in sync with note_tools.dart registrations.
  static const _tools = [
    ('search_notes', 'Search notes by keyword and optional tag filters'),
    ('read_note', 'Read a note\'s content progressively (stat, toc, summary, full)'),
    ('run_sql', 'Execute SQL queries on the local database'),
    ('ls', 'List available tag filters and folder structure'),
    ('modify_note', 'Modify a note\'s content, title, or tags'),
    ('create_notes', 'Create one or more new notes'),
    ('delete_notes', 'Delete notes by ID'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: _tools.map((t) => ListTile(
        title: Text(t.$1),
        subtitle: Text(t.$2),
        trailing: const Icon(Icons.add),
        onTap: () => onSelect('[${t.$1}](notesynapse://tool/builtin/${t.$1})'),
      )).toList(),
    );
  }
}

// --- User Defined tab ---

class _UserDefinedToolsTab extends StatefulWidget {
  final void Function(String) onSelect;
  const _UserDefinedToolsTab({required this.onSelect});
  @override
  State<_UserDefinedToolsTab> createState() => _UserDefinedToolsTabState();
}

class _UserDefinedToolsTabState extends State<_UserDefinedToolsTab> {
  List<AiToolAppBundle>? _bundles;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bundles = await getIt<AiToolService>().getToolBundles();
    if (mounted) setState(() => _bundles = bundles);
  }

  @override
  Widget build(BuildContext context) {
    if (_bundles == null) return const Center(child: CircularProgressIndicator());
    if (_bundles!.isEmpty) return const Center(child: Text('No user-defined tools found.'));
    return ListView(
      children: _bundles!.expand((bundle) {
        final tools = bundle.toMcpTools();
        return [
          ListTile(
            title: Text(bundle.appName),
            subtitle: Text('${tools.length} function(s)'),
            trailing: const Icon(Icons.add),
            onTap: () => widget.onSelect('[${bundle.appName}](notesynapse://tool/user_defined/${bundle.uuid})'),
          ),
          ...tools.map((t) => Padding(
            padding: const EdgeInsets.only(left: 16),
            child: ListTile(
              leading: const Icon(Icons.subdirectory_arrow_right, size: 16),
              title: Text(t.name),
              subtitle: Text(t.description ?? ''),
              trailing: const Icon(Icons.add),
              onTap: () => widget.onSelect('[${bundle.appName}.${t.name}](notesynapse://tool/user_defined/${bundle.uuid}/${t.name})'),
            ),
          )),
        ];
      }).toList(),
    );
  }
}

// --- MCP tab ---

class _McpToolsTab extends StatefulWidget {
  final void Function(String) onSelect;
  const _McpToolsTab({required this.onSelect});
  @override
  State<_McpToolsTab> createState() => _McpToolsTabState();
}

class _McpToolsTabState extends State<_McpToolsTab> {
  Map<McpEndpoint, List<McpTool>>? _endpointTools;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mcpService = getIt<McpService>();
    final endpoints = await mcpService.getEndpoints();
    final result = <McpEndpoint, List<McpTool>>{};
    for (final ep in endpoints) {
      result[ep] = await mcpService.getToolsForEndpoint(ep.id);
    }
    if (mounted) setState(() => _endpointTools = result);
  }

  @override
  Widget build(BuildContext context) {
    if (_endpointTools == null) return const Center(child: CircularProgressIndicator());
    if (_endpointTools!.isEmpty) return const Center(child: Text('No MCP endpoints configured.'));
    return ListView(
      children: _endpointTools!.entries.expand((entry) {
        final ep = entry.key;
        final tools = entry.value;
        return [
          ListTile(
            title: Text(ep.name),
            subtitle: Text('${tools.length} tool(s)'),
            trailing: const Icon(Icons.add),
            onTap: () => widget.onSelect('[${ep.name}](notesynapse://tool/mcp/${ep.name})'),
          ),
          ...tools.map((t) => Padding(
            padding: const EdgeInsets.only(left: 16),
            child: ListTile(
              leading: const Icon(Icons.subdirectory_arrow_right, size: 16),
              title: Text(t.name),
              subtitle: Text(t.description ?? ''),
              trailing: const Icon(Icons.add),
              onTap: () => widget.onSelect('[${ep.name}.${t.name}](notesynapse://tool/mcp/${ep.name}/${t.name})'),
            ),
          )),
        ];
      }).toList(),
    );
  }
}
```

Note: adjust `AiToolService` method calls (`getToolBundles`, `bundle.appName`, `bundle.uuid`) to match actual API — check `lib/services/ai_tool_service.dart` for the correct method names.

- [ ] **Step 2: Add "Insert Tool" button to note editor toolbar**

Open `lib/screens/note_detail_screen.dart`. Find the toolbar where the "insert note link" or "attachment" button lives. Add an "Insert Tool" button nearby:

```dart
IconButton(
  icon: const Icon(Icons.build_outlined),
  tooltip: 'Insert Tool Link',
  onPressed: () async {
    final link = await ToolPickerSheet.show(context);
    if (link != null && mounted) {
      // Insert the markdown link at the current cursor position in the editor
      final controller = _editorController; // use the actual controller variable name
      final currentText = controller.text;
      final selection = controller.selection;
      final newText = currentText.replaceRange(
        selection.start,
        selection.end,
        link,
      );
      controller.value = controller.value.copyWith(
        text: newText,
        selection: TextSelection.collapsed(offset: selection.start + link.length),
      );
    }
  },
),
```

The `_editorController` name should match the actual `TextEditingController` used in the note editor. Check the file for the controller variable name.

- [ ] **Step 3: Analyze**

```
flutter analyze lib/screens/tool_picker_sheet.dart lib/screens/note_detail_screen.dart
```
Expected: No errors. Fix any method-name mismatches against actual `AiToolService`/`McpService` APIs.

- [ ] **Step 4: Commit**

```bash
git add lib/screens/tool_picker_sheet.dart lib/screens/note_detail_screen.dart
git commit -m "feat: add Insert Tool button and picker to note editor"
```

---

## Task 9: Note Editor — tool link tap behavior

**Files:**
- Modify: `lib/screens/note_detail_screen.dart` (or wherever note links are rendered and tapped)

- [ ] **Step 1: Locate tool link tap handling**

In `lib/screens/note_detail_screen.dart` (and any related widget files), find where `notesynapse://note/` links are handled on tap. This is typically in a `_handleLinkTap` or `onTapLink` callback. Add handling for `notesynapse://tool/` links:

```dart
Future<void> _handleLinkTap(String? text, String? href, String? title) async {
  if (href == null) return;

  if (href.startsWith('notesynapse://note/')) {
    // existing note link handling
    final noteId = href.substring('notesynapse://note/'.length);
    // ... navigate to note ...
    return;
  }

  if (href.startsWith('notesynapse://tool/')) {
    await _handleToolLinkTap(href);
    return;
  }

  // ... other existing link types ...
}

Future<void> _handleToolLinkTap(String href) async {
  final skillService = getIt<SkillService>();
  final parsed = skillService.parseToolUri(href);
  if (parsed == null) return;

  switch (parsed.namespace) {
    case 'builtin':
      _showBuiltinToolDocDialog(parsed.id);

    case 'user_defined':
      // Navigate to tool playground
      final aiToolService = getIt<AiToolService>();
      final bundle = await aiToolService.getToolBundle(parsed.id);
      if (bundle != null && mounted) {
        Navigator.pushNamed(context, '/tool-playground', arguments: bundle);
        // Or use the existing navigation pattern for user apps
      }

    case 'mcp':
      // Navigate to AI Settings > MCP > specific endpoint
      if (mounted) {
        Navigator.pushNamed(context, '/settings/mcp', arguments: parsed.id);
        // Or use the existing navigation pattern for MCP settings
      }
  }
}

void _showBuiltinToolDocDialog(String toolName) {
  // Find the tool description from the known native tools
  const toolDocs = {
    'search_notes': 'Search notes by keyword with optional tag filters.\n\nParams:\n- query (string): search terms\n- tags (list, optional): filter by tags',
    'read_note': 'Read note content progressively.\n\nParams:\n- noteId (string): note ID\n- mode (string): stat | toc | summary | lines | full | pdf_pages',
    'run_sql': 'Execute SQL on the local database.\n\nParams:\n- query (string): SQL statement\n- write (bool): true for INSERT/UPDATE/DELETE',
    'ls': 'List tag filters and folder structure.\n\nNo required params.',
    'modify_note': 'Update a note\'s content, title, or tags.\n\nParams:\n- noteId, content, title, tags (all optional)',
    'create_notes': 'Create new notes.\n\nParams:\n- notes (list): [{title, content, tags}]',
    'delete_notes': 'Delete notes by ID.\n\nParams:\n- noteIds (list): note IDs to delete',
  };
  final doc = toolDocs[toolName] ?? 'No documentation available for $toolName.';
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(toolName),
      content: Text(doc),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    ),
  );
}
```

- [ ] **Step 2: Verify navigation routes exist**

Check `lib/main.dart` or wherever routes are defined. Confirm `/settings/mcp` and the tool playground route exist. If the navigation pattern uses a different approach (e.g., direct widget push), adapt accordingly.

- [ ] **Step 3: Analyze**

```
flutter analyze lib/screens/note_detail_screen.dart
```
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add lib/screens/note_detail_screen.dart
git commit -m "feat: add tap behavior for tool links in note view (doc dialog, MCP settings, tool playground)"
```

---

## Task 10: Agent launch UI — skills toggle

**Files:**
- Modify: `lib/screens/ai_action_screen.dart` (or the agent launch/tool-selection screen)

- [ ] **Step 1: Add skills enabled state**

Open `lib/screens/ai_action_screen.dart`. Find the widget State class. Add:

```dart
bool _skillsEnabled = true;
int _skillCount = 0;
```

In `initState` (or a `_loadSkillCount` helper), load the skill count:

```dart
Future<void> _loadSkillCount() async {
  final index = await getIt<SkillService>().buildSkillIndex();
  if (mounted) setState(() => _skillCount = index.length);
}
```

Call `_loadSkillCount()` from `initState`.

- [ ] **Step 2: Add skills toggle to the tool selection UI**

Find where the tool toggles / tool selection list is rendered. Add a skills entry alongside them:

```dart
SwitchListTile(
  title: const Text('Agent Skills'),
  subtitle: Text(
    _skillCount > 0
        ? '$_skillCount skill${_skillCount == 1 ? '' : 's'} available'
        : 'No skills found — create a note tagged "agent-skill"',
  ),
  value: _skillsEnabled,
  onChanged: _skillCount > 0
      ? (val) => setState(() => _skillsEnabled = val)
      : null, // Disabled (greyed out) if no skills found
),
```

- [ ] **Step 3: Pass skillsEnabled to AgentService.generatePlan**

Find where `generatePlan` is called (or where the agent session is started) in this screen. Pass the flag:

```dart
await agentService.generatePlan(
  objective,
  activeTools: _selectedTools,
  skillsEnabled: _skillsEnabled,   // ADD THIS
);
```

Also, for chat mode, when starting a conversation with tools and skills enabled, call `conversationService.enableSkills()` or `disableSkills()` based on the toggle.

- [ ] **Step 4: Analyze**

```
flutter analyze lib/screens/ai_action_screen.dart
```
Expected: No errors.

- [ ] **Step 5: Commit**

```bash
git add lib/screens/ai_action_screen.dart
git commit -m "feat: add skills toggle to agent launch UI"
```

---

## Task 11: Final integration check

- [ ] **Step 1: Run full test suite**

```
flutter test
```
Expected: All tests PASS. Fix any failures before proceeding.

- [ ] **Step 2: Run analyzer**

```
flutter analyze
```
Expected: No errors.

- [ ] **Step 3: Build for macOS to confirm compilation**

```
flutter build macos
```
Expected: Build succeeds.

- [ ] **Step 4: Smoke test manually**

1. Create a note with tag `agent-skill` and frontmatter:
   ```
   ---
   name: Test Skill
   description: Use this skill when testing agent skills
   enabled: true
   ---

   ## Test Workflow
   1. Call load_skill on this note to verify it loads.
   2. Use [search_notes](notesynapse://tool/builtin/search_notes) to find related notes.
   ```
2. Open agent mode. Confirm "Agent Skills (1 available)" toggle appears.
3. Start an objective. Confirm skill index appears in the plan generation prompt (check agent trace).
4. During execution, trigger `load_skill` with the test note's ID. Confirm skill content appears in the context and `search_notes` is added to skill-discovered tools.
5. Open the test skill note in the editor. Confirm "Insert Tool" button appears in toolbar.
6. Tap the Insert Tool button, navigate to Built-in tab, select `search_notes`. Confirm link is inserted.
7. Tap the inserted link in view mode. Confirm doc dialog appears.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "feat: agent skills — complete implementation"
```
