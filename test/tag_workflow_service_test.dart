import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/workflow_binding_row.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'tag_workflow_service_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late TagWorkflowService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    service = TagWorkflowService(mockDb);
  });

  group('resolveBindings', () {
    test('returns empty list when no tags have bindings', () async {
      when(mockDb.getExactWorkflowBinding(any)).thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings()).thenAnswer((_) async => []);
      final result = await service.resolveBindings(['regular-tag', 'other']);
      expect(result, isEmpty);
    });

    test('resolves exact match binding', () async {
      when(mockDb.getExactWorkflowBinding('special-tag'))
          .thenAnswer((_) async => WorkflowBindingRow(
            pattern: 'special-tag', isPrefix: false, skillNoteId: 'skill-1',
            prompt: 'Process this note.', contentImmutable: false));
      when(mockDb.getExactWorkflowBinding('other')).thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings()).thenAnswer((_) async => []);
      final result = await service.resolveBindings(['special-tag', 'other']);
      expect(result.length, 1);
      expect(result[0].skillNoteId, 'skill-1');
      expect(result[0].matchedTag, 'special-tag');
    });

    test('resolves prefix match binding', () async {
      when(mockDb.getExactWorkflowBinding(any)).thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings()).thenAnswer((_) async => [
        WorkflowBindingRow(pattern: 'wiki-source-', isPrefix: true,
          skillNoteId: 'ingest-skill',
          prompt: 'Ingest source note {note_id} tagged {matched_tag} into the wiki.',
          contentImmutable: true),
      ]);
      final result = await service.resolveBindings(['wiki-source-ml', 'other']);
      expect(result.length, 1);
      expect(result[0].skillNoteId, 'ingest-skill');
      expect(result[0].matchedTag, 'wiki-source-ml');
      expect(result[0].pattern, 'wiki-source-');
      expect(result[0].contentImmutable, isTrue);
    });

    test('exact match takes precedence over prefix match for same tag', () async {
      when(mockDb.getExactWorkflowBinding('wiki-source-ml'))
          .thenAnswer((_) async => WorkflowBindingRow(
            pattern: 'wiki-source-ml', isPrefix: false, skillNoteId: 'exact-skill',
            prompt: 'Process ML source {note_id}.', contentImmutable: false));
      when(mockDb.getPrefixWorkflowBindings()).thenAnswer((_) async => [
        WorkflowBindingRow(pattern: 'wiki-source-', isPrefix: true,
          skillNoteId: 'prefix-skill',
          prompt: 'Ingest {note_id} from {matched_tag}.', contentImmutable: true),
      ]);
      final result = await service.resolveBindings(['wiki-source-ml']);
      expect(result.length, 1);
      expect(result[0].skillNoteId, 'exact-skill');
    });

    test('returns error when two tags match the same prefix pattern', () async {
      when(mockDb.getExactWorkflowBinding(any)).thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings()).thenAnswer((_) async => [
        WorkflowBindingRow(pattern: 'wiki-source-', isPrefix: true,
          skillNoteId: 'ingest-skill',
          prompt: 'Ingest source note {note_id} tagged {matched_tag} into the wiki.',
          contentImmutable: true),
      ]);
      await expectLater(
        service.resolveBindings(['wiki-source-ml', 'wiki-source-ai']),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('ambiguous'))),
      );
    });

    test('two tags matching different prefix patterns is valid', () async {
      when(mockDb.getExactWorkflowBinding(any)).thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings()).thenAnswer((_) async => [
        WorkflowBindingRow(pattern: 'wiki-source-', isPrefix: true,
          skillNoteId: 'wiki-skill', prompt: 'Ingest wiki source {note_id}.', contentImmutable: true),
        WorkflowBindingRow(pattern: 'recipe-source-', isPrefix: true,
          skillNoteId: 'recipe-skill', prompt: 'Process recipe source {note_id}.', contentImmutable: true),
      ]);
      final result = await service.resolveBindings(['wiki-source-ml', 'recipe-source-italian']);
      expect(result.length, 2);
    });
  });

  group('hasImmutableBinding', () {
    test('returns true when any tag has immutable binding', () async {
      when(mockDb.getExactWorkflowBinding(any)).thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings()).thenAnswer((_) async => [
        WorkflowBindingRow(pattern: 'wiki-source-', isPrefix: true,
          skillNoteId: 'ingest-skill',
          prompt: 'Ingest source note {note_id} tagged {matched_tag} into the wiki.',
          contentImmutable: true),
      ]);
      final result = await service.hasImmutableBinding(['wiki-source-ml', 'other']);
      expect(result, isTrue);
    });

    test('returns false when no immutable bindings', () async {
      when(mockDb.getExactWorkflowBinding(any)).thenAnswer((_) async => null);
      when(mockDb.getPrefixWorkflowBindings()).thenAnswer((_) async => []);
      final result = await service.hasImmutableBinding(['regular-tag']);
      expect(result, isFalse);
    });

    test('returns false when binding exists but contentImmutable is false', () async {
      when(mockDb.getExactWorkflowBinding('wiki-compiled-ml'))
          .thenAnswer((_) async => WorkflowBindingRow(
            pattern: 'wiki-compiled-ml', isPrefix: false, skillNoteId: 'compile-skill',
            prompt: 'Compile {note_id}.', contentImmutable: false));
      when(mockDb.getPrefixWorkflowBindings()).thenAnswer((_) async => []);
      final result = await service.hasImmutableBinding(['wiki-compiled-ml']);
      expect(result, isFalse);
    });
  });

  group('registerBinding', () {
    test('inserts a new binding', () async {
      when(mockDb.insertWorkflowBinding(any)).thenAnswer((_) async {});
      await service.registerBinding(
        pattern: 'wiki-source-', isPrefix: true, skillNoteId: 'ingest-skill',
        prompt: 'Ingest source note {note_id} tagged {matched_tag}.',
        contentImmutable: true);
      verify(mockDb.insertWorkflowBinding(any)).called(1);
    });
  });

  group('removeBinding', () {
    test('deletes a binding by pattern', () async {
      when(mockDb.deleteWorkflowBinding('wiki-source-')).thenAnswer((_) async {});
      await service.removeBinding('wiki-source-');
      verify(mockDb.deleteWorkflowBinding('wiki-source-')).called(1);
    });
  });
}
