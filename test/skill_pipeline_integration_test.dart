// test/skill_pipeline_integration_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/tools/load_skill_tool.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'skill_pipeline_integration_test.mocks.dart';

Note _makeNote(
  String id,
  String content, {
  List<String> tags = const ['agent-skill'],
}) => Note(
  id: id,
  title: 'title',
  content: content,
  type: NoteType.note,
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
  subNotes: [],
  tags: tags,
  attachmentPaths: [],
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

  group('parseSkillMetadata edge cases', () {
    test('handles colons in description value', () {
      const content =
          '---\nname: Analyzer\ndescription: Use for: deep analysis of: things\nenabled: true\n---\n\nbody';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta, isNotNull);
      expect(meta!.name, 'Analyzer');
      expect(meta.description, 'Use for: deep analysis of: things');
    });

    test('documents multi-line description limitation', () {
      const content =
          '---\nname: Skill\ndescription: |\n  Line one\n  Line two\nenabled: true\n---\n\nbody';
      final meta = service.parseSkillMetadata('note-1', content);
      // The simple line-by-line parser treats '|' as the description value.
      // This documents the known limitation with YAML block scalars.
      if (meta != null) {
        expect(meta.description, '|');
      }
    });

    test('handles extra whitespace in frontmatter values', () {
      const content =
          '---\nname:   Spaced Skill  \ndescription:   Has spaces  \n---\n\nbody';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta, isNotNull);
      expect(meta!.name, 'Spaced Skill');
      expect(meta.description, 'Has spaces');
    });

    test('handles empty content string', () {
      expect(service.parseSkillMetadata('note-1', ''), isNull);
    });

    test('handles frontmatter with no closing delimiter', () {
      const content = '---\nname: Broken\ndescription: No end';
      expect(service.parseSkillMetadata('note-1', content), isNull);
    });
  });

  group('buildSkillIndex with mixed inputs', () {
    test('returns empty map when zero enabled skills exist', () async {
      when(mockDb.getNotesByTag('agent-skill')).thenAnswer(
        (_) async => [
          _makeNote(
            'id-1',
            '---\nname: A\ndescription: D\nenabled: false\n---\n\nbody',
          ),
          _makeNote('id-2', 'no frontmatter at all'),
        ],
      );
      final index = await service.buildSkillIndex();
      expect(index, isEmpty);
    });

    test('filters malformed notes from index', () async {
      when(mockDb.getNotesByTag('agent-skill')).thenAnswer(
        (_) async => [
          _makeNote(
            'good',
            '---\nname: Valid\ndescription: Works\nenabled: true\n---\n\nbody',
          ),
          _makeNote(
            'bad-1',
            '---\nname: \ndescription: Empty name\n---\n\nbody',
          ),
          _makeNote('bad-2', '---\nenabled: true\n---\n\nbody'),
          _makeNote('bad-3', 'just plain text'),
          _makeNote(
            'disabled',
            '---\nname: Off\ndescription: Disabled\nenabled: false\n---\n\nbody',
          ),
        ],
      );
      final index = await service.buildSkillIndex();
      expect(index.length, 1);
      expect(index.containsKey('good'), true);
    });
  });

  group('buildSkillIndexPrompt', () {
    test('returns empty string for empty map', () {
      expect(service.buildSkillIndexPrompt({}), isEmpty);
    });

    test('includes all entries for non-empty map', () {
      final index = {
        'id-a': const SkillMetadata(
          noteId: 'id-a',
          skillRef: 'alpha',
          name: 'Alpha',
          description: 'Does A',
          enabled: true,
        ),
        'id-b': const SkillMetadata(
          noteId: 'id-b',
          skillRef: 'beta',
          name: 'Beta',
          description: 'Does B',
          enabled: true,
        ),
      };
      final prompt = service.buildSkillIndexPrompt(index);
      expect(prompt, contains('skillRef=alpha'));
      expect(prompt, contains('name=Alpha'));
      expect(prompt, contains('skillRef=beta'));
      expect(prompt, contains('name=Beta'));
      expect(prompt, contains('load_skill'));
    });
  });

  group('LoadSkillTool caching', () {
    late LoadSkillTool tool;

    setUp(() {
      getIt.registerSingleton<SkillService>(service);
      tool = LoadSkillTool();
    });

    test('second call returns cached content without extra DB hit', () async {
      const content =
          '---\nname: Cached\ndescription: Test\nenabled: true\n---\n\n## Steps\nDo things.';
      // LoadSkillTool calls db.getNote() internally
      when(
        mockDb.getNote('note-1'),
      ).thenAnswer((_) async => _makeNote('note-1', content));

      final result1 = await tool.execute({'noteId': 'note-1'});
      final result2 = await tool.execute({'noteId': 'note-1'});

      expect(result1, result2);
      // DB should only be hit once (caching)
      verify(mockDb.getNote('note-1')).called(1);
    });

    test('resetSession clears cache so next call hits DB again', () async {
      const content =
          '---\nname: Skill\ndescription: Test\nenabled: true\n---\n\nbody';
      when(
        mockDb.getNote('note-1'),
      ).thenAnswer((_) async => _makeNote('note-1', content));

      await tool.execute({'noteId': 'note-1'});
      tool.resetSession();
      await tool.execute({'noteId': 'note-1'});
      // After reset, should hit DB again (2 total calls)
      verify(mockDb.getNote('note-1')).called(2);
    });
  });

  group('extractToolUris', () {
    test('finds tool URIs and ignores note URIs', () {
      const content = '''
Use [search](notesynapse://tool/builtin/search_notes) to find notes.
Also see [this note](notesynapse://note/abc-123) for context.
And [MCP tool](notesynapse://tool/mcp/server-1/query).
''';
      final uris = service.extractToolUris(content);
      expect(uris, contains('notesynapse://tool/builtin/search_notes'));
      expect(uris, contains('notesynapse://tool/mcp/server-1/query'));
      expect(uris, isNot(contains('notesynapse://note/abc-123')));
    });

    test('returns empty list for content with no URIs', () {
      expect(service.extractToolUris('No links here.'), isEmpty);
    });
  });

  group('parseToolUri', () {
    test('parses builtin namespace', () {
      final r = service.parseToolUri('notesynapse://tool/builtin/search_notes');
      expect(r, isNotNull);
      expect(r!.namespace, 'builtin');
      expect(r.id, 'search_notes');
    });

    test('parses user_defined namespace with function', () {
      final r = service.parseToolUri(
        'notesynapse://tool/user_defined/uuid-123/analyze',
      );
      expect(r!.namespace, 'user_defined');
      expect(r.id, 'uuid-123');
      expect(r.function, 'analyze');
    });

    test('parses mcp namespace', () {
      final r = service.parseToolUri(
        'notesynapse://tool/mcp/my-server/do_thing',
      );
      expect(r!.namespace, 'mcp');
      expect(r.id, 'my-server');
      expect(r.function, 'do_thing');
    });

    test('returns null for note URI', () {
      expect(service.parseToolUri('notesynapse://note/abc'), isNull);
    });

    test('returns null for malformed URI with only namespace', () {
      expect(service.parseToolUri('notesynapse://tool/builtin'), isNull);
    });
  });
}
