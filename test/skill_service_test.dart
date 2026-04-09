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

  group('stripFrontmatter', () {
    test('strips frontmatter and returns body', () {
      const content =
          '---\nname: Skill\ndescription: Desc\n---\n\n## Body\nContent here.';
      expect(service.stripFrontmatter(content), '## Body\nContent here.');
    });

    test('returns content unchanged when no frontmatter', () {
      const content = '## No frontmatter';
      expect(service.stripFrontmatter(content), '## No frontmatter');
    });
  });

  group('parseSkillMetadata', () {
    test('returns metadata for valid frontmatter', () {
      const content =
          '---\nname: Weekly Review\ndescription: Use when doing weekly review\nenabled: true\n---\n\n## Content';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta, isNotNull);
      expect(meta!.name, 'Weekly Review');
      expect(meta.description, 'Use when doing weekly review');
      expect(meta.enabled, true);
      expect(meta.noteId, 'note-1');
      expect(meta.skillRef, 'weekly-review');
    });

    test('returns null when frontmatter is missing', () {
      const content = '## No frontmatter here';
      expect(service.parseSkillMetadata('note-1', content), isNull);
    });

    test('returns null when name is missing from frontmatter', () {
      const content =
          '---\ndescription: some desc\nenabled: true\n---\n\ncontent';
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
      const content =
          '---\nname: Skill\ndescription: Desc\nenabled: false\n---\n\ncontent';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta!.enabled, false);
    });
  });

  group('buildSkillIndex', () {
    test('returns only enabled skills', () async {
      final notes = [
        _makeNote(
          'id-1',
          '---\nname: Skill A\ndescription: Desc A\nenabled: true\n---\n\nbody',
        ),
        _makeNote(
          'id-2',
          '---\nname: Skill B\ndescription: Desc B\nenabled: false\n---\n\nbody',
        ),
        _makeNote('id-3', 'no frontmatter'),
      ];
      when(mockDb.getNotesByTag('agent-skill')).thenAnswer((_) async => notes);
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

    test('includes skillRef and description for each skill', () {
      final index = {
        'note-abc': SkillMetadata(
          noteId: 'note-abc',
          skillRef: 'my-skill',
          name: 'My Skill',
          description: 'Use for X',
          enabled: true,
        ),
      };
      final prompt = service.buildSkillIndexPrompt(index);
      expect(prompt, contains('skillRef=my-skill'));
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
      expect(
        uris,
        containsAll([
          'notesynapse://tool/builtin/search_notes',
          'notesynapse://tool/user_defined/uuid-123/analyze',
          'notesynapse://tool/mcp/my-service/search',
        ]),
      );
    });

    test('returns empty list when no tool URIs present', () {
      const content =
          'No tools here, just [a note link](notesynapse://note/abc).';
      expect(service.extractToolUris(content), isEmpty);
    });
  });

  group('parseToolUri', () {
    test('parses builtin URI', () {
      final result = service.parseToolUri(
        'notesynapse://tool/builtin/search_notes',
      );
      expect(result, isNotNull);
      expect(result!.namespace, 'builtin');
      expect(result.id, 'search_notes');
      expect(result.function, isNull);
    });

    test('parses user_defined URI with function', () {
      final result = service.parseToolUri(
        'notesynapse://tool/user_defined/uuid-123/analyze',
      );
      expect(result!.namespace, 'user_defined');
      expect(result.id, 'uuid-123');
      expect(result.function, 'analyze');
    });

    test('parses mcp URI', () {
      final result = service.parseToolUri(
        'notesynapse://tool/mcp/my-service/search',
      );
      expect(result!.namespace, 'mcp');
      expect(result.id, 'my-service');
      expect(result.function, 'search');
    });

    test('returns null for non-tool URI', () {
      expect(service.parseToolUri('notesynapse://note/abc'), isNull);
    });

    test('returns null for malformed tool URI', () {
      expect(service.parseToolUri('notesynapse://tool/builtin'), isNull);
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
  id: id,
  title: 'title',
  content: content,
  type: NoteType.note,
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
  subNotes: [],
  tags: ['agent-skill'],
  attachmentPaths: [],
);
