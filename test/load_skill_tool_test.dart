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
    expect((tool.inputSchema['properties'] as Map).containsKey('noteId'), isTrue);
  });

  test('returns error for empty noteId', () async {
    final result = await tool.execute({'noteId': ''});
    expect((result as Map)['error'], contains('noteId'));
  });
}

Note _makeNote(String id, String content) => Note(
  id: id, title: 'title', content: content,
  type: NoteType.note, createdAt: DateTime.now(), updatedAt: DateTime.now(),
  subNotes: [], tags: ['agent-skill'], attachmentPaths: [],
);
