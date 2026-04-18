import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/relationship.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/tools/note_tools.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'create_notes_link_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late NoteModificationService modService;
  late CreateNotesTool tool;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    modService = NoteModificationService(mockDb);
    getIt.registerSingleton<NoteModificationService>(modService);
    tool = CreateNotesTool();
  });

  group('CreateNotesTool inputSchema', () {
    test('includes link property in items schema', () {
      final items = (tool.inputSchema['properties'] as Map)['notes']['items'] as Map;
      final props = items['properties'] as Map;
      expect(props.containsKey('link'), isTrue,
          reason: 'inputSchema must advertise the link field so LLMs know it exists');
      final linkSchema = props['link'] as Map;
      expect(linkSchema['type'], 'array');
      final itemSchema = linkSchema['items'] as Map;
      expect((itemSchema['properties'] as Map).containsKey('relation'), isTrue);
      expect((itemSchema['properties'] as Map).containsKey('target'), isTrue);
    });
  });

  group('create_notes with link field', () {
    test('creates note AND relationship when link provided', () async {
      when(mockDb.insertNote(any)).thenAnswer((_) async => 'note-id-1');
      when(mockDb.insertRelationship(any)).thenAnswer((_) async => 'rel-id-1');
      when(mockDb.verifyAttachmentPath(any)).thenAnswer((_) async => true);

      final result = await tool.execute({
        'notes': [
          {
            'title': 'Compiled: Attention',
            'content': '## Summary\nAttention mechanisms...',
            'tags': ['wiki-compiled-ml'],
            'link': [
              {'relation': 'derived_from', 'target': 'source-note-123'},
            ],
          },
        ],
      });

      expect((result as Map)['status'], 'success');
      expect(result['created_count'], 1);

      final captured = verify(mockDb.insertRelationship(captureAny)).captured;
      expect(captured.length, 1);
      final rel = captured[0] as Relationship;
      expect(rel.toNoteId, 'source-note-123');
      expect(rel.type, 'derived_from');
    });

    test('creates note without relationship when link absent', () async {
      when(mockDb.insertNote(any)).thenAnswer((_) async => 'note-id-2');
      when(mockDb.verifyAttachmentPath(any)).thenAnswer((_) async => true);

      final result = await tool.execute({
        'notes': [
          {
            'title': 'Plain note',
            'content': 'No links.',
          },
        ],
      });

      expect((result as Map)['status'], 'success');
      verifyNever(mockDb.insertRelationship(any));
    });
  });
}
