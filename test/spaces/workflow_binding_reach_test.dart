import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/workflow_binding_row.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';

import 'workflow_binding_reach_test.mocks.dart';

/// M6: a workflow binding fires only when the note being ingested is within
/// the bound skill's reach.
///
/// | Skill carries  | Fires for a note that…    |
/// |----------------|---------------------------|
/// | `all-spaces`   | always                    |
/// | Space S's tags | carries S's include-tags  |
/// | neither        | matches no Space          |
///
/// Note-based, never active-Space-based: ingestion routinely finishes after the
/// user has switched Spaces, and the same note must get the same workflow
/// either way. Every reach case below is asserted with **no Space active**, so
/// a rule keyed on the active Space cannot pass them.
///
/// **Correction C6** has its own group: reach must never weaken immutability.
@GenerateMocks([DatabaseService])
Note skillNote(String id, List<String> tags) {
  final now = DateTime(2026, 1, 1);
  return Note(
    id: id,
    title: id,
    content: '---\nname: $id\ndescription: d\n---\n\nbody',
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
    tags: [SkillService.agentSkillTag, ...tags],
  );
}

void main() {
  late MockDatabaseService mockDb;
  late SpaceScopeService scope;
  late TagWorkflowService service;

  const spaceS = SpaceSnapshot(id: 'space-s', includeTags: ['thesis']);
  const spaceT = SpaceSnapshot(id: 'space-t', includeTags: ['reading']);

  /// Binds `ingest` to [skillNoteId], with no other binding in the database.
  void bind(String skillNoteId, {bool contentImmutable = false}) {
    when(mockDb.getExactWorkflowBinding('ingest')).thenAnswer(
      (_) async => WorkflowBindingRow(
        pattern: 'ingest',
        isPrefix: false,
        skillNoteId: skillNoteId,
        prompt: 'Ingest {note_id}.',
        contentImmutable: contentImmutable,
      ),
    );
  }

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    scope = SpaceScopeService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<SpaceScopeService>(scope);
    scope.setSpaceSnapshots([spaceS, spaceT]);
    service = TagWorkflowService(mockDb, spaceScope: scope);

    when(mockDb.getExactWorkflowBinding(any)).thenAnswer((_) async => null);
    when(mockDb.getPrefixWorkflowBindings()).thenAnswer((_) async => const []);
    when(mockDb.getNote('skill-everywhere')).thenAnswer(
      (_) async =>
          skillNote('skill-everywhere', [SpaceScopeService.allSpacesTag]),
    );
    when(
      mockDb.getNote('skill-thesis'),
    ).thenAnswer((_) async => skillNote('skill-thesis', ['thesis']));
    when(
      mockDb.getNote('skill-unfiled'),
    ).thenAnswer((_) async => skillNote('skill-unfiled', const []));
  });

  group('an all-spaces skill reaches every note', () {
    test('fires for a note filed in a Space', () async {
      bind('skill-everywhere');
      final r = await service.resolveBindings(['ingest', 'thesis']);
      expect(r.map((b) => b.skillNoteId), ['skill-everywhere']);
    });

    test('fires for an unfiled note', () async {
      bind('skill-everywhere');
      final r = await service.resolveBindings(['ingest']);
      expect(r.map((b) => b.skillNoteId), ['skill-everywhere']);
    });
  });

  group('a Space-filed skill reaches only that Space\'s notes', () {
    test('fires for a note carrying the Space tags', () async {
      bind('skill-thesis');
      final r = await service.resolveBindings(['ingest', 'thesis']);
      expect(r, hasLength(1));
    });

    test('does not fire for a note in another Space', () async {
      bind('skill-thesis');
      final r = await service.resolveBindings(['ingest', 'reading']);
      expect(r, isEmpty);
    });

    test('does not fire for an unfiled note', () async {
      bind('skill-thesis');
      final r = await service.resolveBindings(['ingest']);
      expect(r, isEmpty);
    });

    test('a note carrying all-spaces is still not in the Space', () async {
      // A1 makes `all-spaces` an override for *visibility*; it does not make a
      // note a member of every Space, so a Space-filed workflow must not claim
      // it.
      bind('skill-thesis');
      final r = await service.resolveBindings([
        'ingest',
        SpaceScopeService.allSpacesTag,
      ]);
      expect(r, isEmpty);
    });

    test('fires while a different Space is active (note-based, not active-'
        'Space-based)', () async {
      bind('skill-thesis');
      scope.setActive(spaceT.id, spaceT.includeTags);
      final r = await service.resolveBindings(['ingest', 'thesis']);
      expect(r, hasLength(1));
    });
  });

  group('an unfiled skill reaches only unfiled notes', () {
    test('fires for a note matching no Space', () async {
      bind('skill-unfiled');
      final r = await service.resolveBindings(['ingest']);
      expect(r, hasLength(1));
    });

    test('does not fire for a note filed in a Space', () async {
      bind('skill-unfiled');
      final r = await service.resolveBindings(['ingest', 'thesis']);
      expect(r, isEmpty);
    });
  });

  group('degenerate inputs', () {
    test('a missing skill note keeps its binding', () async {
      // Dropping a binding because its skill note could not be read would
      // silently disable a workflow, which is worse than running one.
      bind('skill-gone');
      when(mockDb.getNote('skill-gone')).thenAnswer((_) async => null);
      final r = await service.resolveBindings(['ingest', 'thesis']);
      expect(r, hasLength(1));
    });

    test(
      'with no Spaces at all every binding fires and no note is read',
      () async {
        scope.setSpaceSnapshots(const []);
        bind('skill-unfiled');
        final r = await service.resolveBindings(['ingest', 'thesis']);
        expect(r, hasLength(1));
        verifyNever(mockDb.getNote(any));
      },
    );

    test('the ambiguous prefix binding still throws after filtering', () async {
      when(mockDb.getPrefixWorkflowBindings()).thenAnswer(
        (_) async => [
          WorkflowBindingRow(
            pattern: 'wiki-source-',
            isPrefix: true,
            skillNoteId: 'skill-thesis',
            prompt: 'p',
            contentImmutable: false,
          ),
        ],
      );
      expect(
        () => service.resolveBindings(['wiki-source-ml', 'wiki-source-ai']),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('correction C6: reach never weakens immutability', () {
    test('an out-of-reach immutable binding still protects the note', () async {
      bind('skill-thesis', contentImmutable: true);
      // The note is filed in the *other* Space, so the binding does not fire…
      expect(await service.resolveBindings(['ingest', 'reading']), isEmpty);
      // …but its content is still immutable. Otherwise a protection would
      // become a mode: switch Space, edit the note.
      expect(await service.hasImmutableBinding(['ingest', 'reading']), isTrue);
    });

    test(
      'an unfiled note is protected by a Space-filed immutable binding',
      () async {
        bind('skill-thesis', contentImmutable: true);
        expect(await service.hasImmutableBinding(['ingest']), isTrue);
      },
    );

    test('the answer does not depend on which Space is active', () async {
      bind('skill-thesis', contentImmutable: true);
      final answers = <bool>[];
      for (final active in <SpaceSnapshot?>[null, spaceS, spaceT]) {
        scope.setActive(active?.id, active?.includeTags ?? const []);
        answers.add(await service.hasImmutableBinding(['ingest', 'reading']));
      }
      expect(answers, everyElement(isTrue));
    });

    test('a non-immutable binding is still not immutable', () async {
      bind('skill-thesis');
      expect(await service.hasImmutableBinding(['ingest', 'thesis']), isFalse);
    });
  });

  group('constructor shape', () {
    test('the positional-only form still compiles', () async {
      final positional = TagWorkflowService(mockDb);
      bind('skill-everywhere');
      expect(await positional.resolveBindings(['ingest']), hasLength(1));
    });
  });
}
