import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/starter_service.dart';

import 'starter_skill_all_spaces_test.mocks.dart';

/// M6: starter skills ship with the app, not with a Space.
///
/// Two guarantees, one behavioural test each:
/// * they carry `all-spaces` so they stay reachable from every Space and from
///   none (added to the fixed tag list, never routed through the stamp —
///   invariant 7 forbids StarterService from stamping and A2 forbids the stamp
///   from adding this tag);
/// * **correction C5** — the install stays idempotent with a Space active,
///   because the already-installed set is computed space-blind.
@GenerateMocks([DatabaseService])
Note existingSkill(String id, String skillRef, {List<String> tags = const []}) {
  final now = DateTime(2026, 1, 1);
  return Note(
    id: id,
    title: skillRef,
    content:
        '---\nname: $skillRef\nskill_ref: $skillRef\n'
        'description: an installed skill\n---\n\nbody',
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
    tags: [SkillService.agentSkillTag, ...tags],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockDatabaseService mockDb;
  late SpaceScopeService scope;
  late List<Note> inserted;

  // The one bundled starter skill; its ref comes from the asset's frontmatter.
  const bundledRef = 'knowledge-exploration';
  const spaceS = SpaceSnapshot(id: 'space-s', includeTags: ['thesis']);

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    scope = SpaceScopeService();
    inserted = [];
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<SpaceScopeService>(scope);
    scope.setSpaceSnapshots([spaceS]);
    when(mockDb.insertNote(any)).thenAnswer((invocation) async {
      final note = invocation.positionalArguments.first as Note;
      inserted.add(note);
      return note.id;
    });
    when(
      mockDb.getNotesByTag(SkillService.agentSkillTag),
    ).thenAnswer((_) async => const []);
  });

  group('starter skills carry all-spaces', () {
    test('every installed starter skill is tagged all-spaces', () async {
      final count = await StarterService.installStarterSkills();
      expect(count, greaterThan(0));
      expect(inserted, isNotEmpty);
      for (final note in inserted) {
        expect(
          note.tags,
          containsAll(<String>[
            SkillService.agentSkillTag,
            'starter-skill',
            SpaceScopeService.allSpacesTag,
          ]),
          reason: '${note.id} would be invisible inside every Space',
        );
      }
    });

    test('the tag list is fixed, not the active Space stamp (A2)', () async {
      // Installing inside a Space must not file the skill into it: the tags are
      // exactly the three literals, never the Space's include-tags.
      scope.setActive(spaceS.id, spaceS.includeTags);
      await StarterService.installStarterSkills();
      expect(inserted, isNotEmpty);
      for (final note in inserted) {
        expect(note.tags, isNot(contains('thesis')));
      }
    });

    test('an installed starter skill is visible from inside a Space',
        () async {
      await StarterService.installStarterSkills();
      expect(inserted, isNotEmpty);
      when(
        mockDb.getNotesByTag(SkillService.agentSkillTag),
      ).thenAnswer((_) async => inserted);
      scope.setActive(spaceS.id, spaceS.includeTags);
      final index = await SkillService(mockDb, spaceScope: scope)
          .buildSkillIndex();
      expect(index.values.map((m) => m.skillRef), contains(bundledRef));
    });
  });

  group('correction C5: install stays idempotent with a Space active', () {
    test('a second install with no Space installs nothing', () async {
      await StarterService.installStarterSkills();
      final first = List<Note>.from(inserted);
      expect(first, isNotEmpty);
      when(
        mockDb.getNotesByTag(SkillService.agentSkillTag),
      ).thenAnswer((_) async => first);
      inserted.clear();

      final count = await StarterService.installStarterSkills();
      expect(count, 0);
      expect(inserted, isEmpty);
    });

    test('a second install inside a Space installs nothing', () async {
      await StarterService.installStarterSkills();
      final first = List<Note>.from(inserted);
      when(
        mockDb.getNotesByTag(SkillService.agentSkillTag),
      ).thenAnswer((_) async => first);
      inserted.clear();

      scope.setActive(spaceS.id, spaceS.includeTags);
      final count = await StarterService.installStarterSkills();
      expect(count, 0, reason: 'C5: the existing set must be space-blind');
      expect(inserted, isEmpty);
    });

    test(
      'an unfiled skill with the same ref still blocks re-install inside a '
      'Space',
      () async {
        // The discriminating case. A skill note that is *not* reachable from the
        // active Space — an older starter install, or a user-authored skill with
        // the same ref — must still be counted as installed. Compute the set
        // through a scoped index instead of `getNotesByTag` and this note
        // disappears, so the starter skill is written a second time.
        when(mockDb.getNotesByTag(SkillService.agentSkillTag)).thenAnswer(
          (_) async => [existingSkill('older-install', bundledRef)],
        );
        scope.setActive(spaceS.id, spaceS.includeTags);

        final count = await StarterService.installStarterSkills();
        expect(count, 0);
        expect(inserted, isEmpty);
      },
    );

    test('getStarterSkills reports installed state space-blind too', () async {
      when(mockDb.getNotesByTag(SkillService.agentSkillTag)).thenAnswer(
        (_) async => [existingSkill('older-install', bundledRef)],
      );
      scope.setActive(spaceS.id, spaceS.includeTags);

      final skills = await StarterService.getStarterSkills();
      final bundled = skills.firstWhere((s) => s['skillRef'] == bundledRef);
      expect(bundled['isInstalled'], isTrue);
    });
  });
}
