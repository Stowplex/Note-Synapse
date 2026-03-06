import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note_annotation.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_annotation_service.dart';
import 'package:note_synapse/services/service_locator.dart';

@GenerateMocks([DatabaseService])
import 'note_annotation_service_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late NoteAnnotationService service;

  final testAnnotation = NoteAnnotation(
    id: 'ann-1',
    noteId: 'note-a',
    content: 'test content',
    attachmentPaths: ['img.png'],
    createdAt: DateTime.utc(2026, 3, 6),
  );

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = NoteAnnotationService(mockDb);
  });

  group('saveAnnotation', () {
    test('inserts annotation into DB', () async {
      when(mockDb.saveNoteAnnotation(any)).thenAnswer((_) async {});
      await service.saveAnnotation(testAnnotation);
      verify(mockDb.saveNoteAnnotation(testAnnotation)).called(1);
    });
  });

  group('getAnnotation', () {
    test('returns annotation when found', () async {
      when(
        mockDb.getNoteAnnotation('ann-1'),
      ).thenAnswer((_) async => testAnnotation);
      final result = await service.getAnnotation('ann-1');
      expect(result?.id, 'ann-1');
    });

    test('returns null when not found', () async {
      when(mockDb.getNoteAnnotation('missing')).thenAnswer((_) async => null);
      final result = await service.getAnnotation('missing');
      expect(result, isNull);
    });
  });

  group('getAnnotationsForNote', () {
    test('returns list from DB', () async {
      when(
        mockDb.getNoteAnnotationsForNote('note-a'),
      ).thenAnswer((_) async => [testAnnotation]);
      final results = await service.getAnnotationsForNote('note-a');
      expect(results.length, 1);
      expect(results.first.content, 'test content');
    });
  });

  group('getAnnotationsForAttachment', () {
    test('returns list from DB', () async {
      final attAnnotation = NoteAnnotation(
        id: 'ann-2',
        attachmentId: 'att-1',
        content: 'att annotation',
        attachmentPaths: [],
        createdAt: DateTime.utc(2026, 3, 6),
      );
      when(
        mockDb.getNoteAnnotationsForAttachment('att-1'),
      ).thenAnswer((_) async => [attAnnotation]);
      final results = await service.getAnnotationsForAttachment('att-1');
      expect(results.length, 1);
    });
  });

  group('deleteAnnotation', () {
    test('calls DB delete', () async {
      when(mockDb.deleteNoteAnnotation('ann-1')).thenAnswer((_) async {});
      await service.deleteAnnotation('ann-1');
      verify(mockDb.deleteNoteAnnotation('ann-1')).called(1);
    });
  });
}
