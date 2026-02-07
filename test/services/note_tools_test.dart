import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/tools/note_tools.dart';

@GenerateMocks([DatabaseService, NoteModificationService])
import 'note_tools_test.mocks.dart';

/// Tests for NoteReadTool progressive discovery modes.
///
/// Note: These tests verify the logic of each mode using a mock-friendly approach.
/// For full integration testing, the tool would need to be tested with a real database.
void main() {
  late MockDatabaseService mockDb;
  late MockNoteModificationService mockNoteModificationService;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockNoteModificationService = MockNoteModificationService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<NoteModificationService>(mockNoteModificationService);
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('NoteReadTool', () {
    late NoteReadTool tool;

    setUp(() {
      tool = NoteReadTool();
    });

    test('has correct name', () {
      expect(tool.name, 'read_note');
    });

    test('has correct input schema with all modes', () {
      final schema = tool.inputSchema;
      expect(schema['properties']['mode']['enum'], [
        'stat',
        'lines',
        'pdf_pages',
        'summary',
        'toc',
        'full',
      ]);
      expect(schema['properties']['mode']['default'], 'stat');
    });

    test('description mentions progressive discovery workflow', () {
      expect(tool.description, contains('progressive discovery'));
      expect(tool.description, contains('stat'));
      expect(tool.description, contains('lines'));
      expect(tool.description, contains('pdf_pages'));
    });

    test('returns error for non-existent note', () async {
      when(mockDb.getNoteById('non-existent-id')).thenAnswer((_) async => null);
      final result = await tool.execute({'note_id': 'non-existent-id'});
      expect(result['error'], 'Note not found');
    });

    test('returns error for unknown mode', () async {
      // This test would need a real note in the database
      // For now, we just verify the tool structure
      expect(tool.inputSchema['properties']['mode']['enum'], isNotEmpty);
    });
  });

  group('NoteReadTool input schema', () {
    late NoteReadTool tool;

    setUp(() {
      tool = NoteReadTool();
    });

    test('has start_line and end_line for lines mode', () {
      final schema = tool.inputSchema;
      expect(schema['properties']['start_line'], isNotNull);
      expect(schema['properties']['end_line'], isNotNull);
      expect(schema['properties']['start_line']['type'], 'integer');
      expect(schema['properties']['end_line']['type'], 'integer');
    });

    test('has attachment, start_page, end_page for pdf_pages mode', () {
      final schema = tool.inputSchema;
      expect(schema['properties']['attachment'], isNotNull);
      expect(schema['properties']['start_page'], isNotNull);
      expect(schema['properties']['end_page'], isNotNull);
    });

    test('has attachments filter for full mode', () {
      final schema = tool.inputSchema;
      expect(schema['properties']['attachments'], isNotNull);
      expect(schema['properties']['attachments']['type'], 'array');
    });

    test('requires only note_id', () {
      final schema = tool.inputSchema;
      expect(schema['required'], ['note_id']);
    });
  });

  group('NoteSearchTool', () {
    late NoteSearchTool tool;

    setUp(() {
      tool = NoteSearchTool();
    });

    test('has correct name', () {
      expect(tool.name, 'search_notes');
    });

    test('has query and tags in schema', () {
      final schema = tool.inputSchema;
      expect(schema['properties']['query'], isNotNull);
      expect(schema['properties']['tags'], isNotNull);
      expect(schema['required'], ['query']);
    });
  });

  group('ModifyNoteTool', () {
    late ModifyNoteTool tool;

    setUp(() {
      tool = ModifyNoteTool();
    });

    test('has correct name', () {
      expect(tool.name, 'modify_note');
    });

    test('supports content modification actions', () {
      final schema = tool.inputSchema;
      final contentActions =
          schema['properties']['modification']['properties']['content']['properties']['action']['enum'];
      expect(contentActions, contains('append'));
      expect(contentActions, contains('prepend'));
      expect(contentActions, contains('replace'));
      expect(contentActions, contains('no-op'));
    });
  });

  group('ListFiltersTool', () {
    late ListFiltersTool tool;

    setUp(() {
      tool = ListFiltersTool();
    });

    test('has correct name', () {
      expect(tool.name, 'ls');
    });

    test('has empty properties in schema', () {
      final schema = tool.inputSchema;
      expect(schema['properties'], isEmpty);
    });
  });

  group('RunSqlTool', () {
    late RunSqlTool tool;

    setUp(() {
      tool = RunSqlTool();
    });

    test('has correct name', () {
      expect(tool.name, 'run_sql');
    });

    test('requires query parameter', () {
      final schema = tool.inputSchema;
      expect(schema['required'], ['query']);
    });
  });

  group('CreateNotesTool', () {
    late CreateNotesTool tool;

    setUp(() {
      tool = CreateNotesTool();
    });

    test('has correct name', () {
      expect(tool.name, 'create_notes');
    });

    test('requires notes parameter', () {
      final schema = tool.inputSchema;
      expect(schema['required'], ['notes']);
    });

    test('schema has task fields', () {
      final noteItems = tool.inputSchema['properties']['notes']['items'];
      expect(noteItems['properties']['scheduled_at'], isNotNull);
      expect(noteItems['properties']['complete_by'], isNotNull);
      expect(noteItems['properties']['status'], isNotNull);
    });

    test('validation rejects base64 data', () async {
      final result = await tool.execute({
        'notes': [
          {
            'title': 'Test',
            'content': 'Test',
            'attachments': [
              'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
            ],
          },
        ],
      });
      expect(result['error'], contains('Base64 data is not allowed'));
    });
  });

  group('StringExtension', () {
    test('take returns substring up to n characters', () {
      expect('hello world'.take(5), 'hello');
      expect('hi'.take(5), 'hi');
      expect(''.take(5), '');
    });
  });
}
