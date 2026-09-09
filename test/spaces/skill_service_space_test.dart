import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/tools/load_skill_tool.dart';

import 'skill_service_space_test.mocks.dart';

/// M6: space-scoped skills, through [SkillService.buildSkillIndex].
///
/// `SpaceScopeService.skillVisible` is already unit-tested cell by cell in
/// `space_scope_service_test.dart`; what is under test here is that the index
/// actually *applies* it, that `allSpaces: true` escapes it, and that the
/// escape is used by exactly the two management surfaces that need it.
@GenerateMocks([DatabaseService])
Note skillNote(
  String id, {
  required String name,
  List<String> tags = const [],
  String? defaultAction,
}) {
  final now = DateTime(2026, 1, 1);
  final action = defaultAction == null
      ? ''
      : 'default_action: |\n  $defaultAction\n';
  return Note(
    id: id,
    title: name,
    content: '---\nname: $name\ndescription: Use for $name\n$action---\n\nbody',
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
  late SkillService service;

  // Two single-tag Spaces, so "inside S" and "inside another Space" are both
  // reachable, and the "unfiled" row can be told from the "filed elsewhere" one.
  const spaceS = SpaceSnapshot(id: 'space-s', includeTags: ['thesis']);
  const spaceT = SpaceSnapshot(id: 'space-t', includeTags: ['reading']);

  final filed = skillNote('skill-filed', name: 'Filed', tags: ['thesis']);
  final everywhere = skillNote(
    'skill-everywhere',
    name: 'Everywhere',
    tags: [SpaceScopeService.allSpacesTag],
  );
  final unfiled = skillNote('skill-unfiled', name: 'Unfiled');

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    scope = SpaceScopeService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<SpaceScopeService>(scope);
    scope.setSpaceSnapshots([spaceS, spaceT]);
    service = SkillService(mockDb, spaceScope: scope);
    when(
      mockDb.getNotesByTag(SkillService.agentSkillTag),
    ).thenAnswer((_) async => [filed, everywhere, unfiled]);
  });

  void inSpaceS() => scope.setActive(spaceS.id, spaceS.includeTags);
  void inSpaceT() => scope.setActive(spaceT.id, spaceT.includeTags);
  void inNoSpace() => scope.setActive(null, const []);

  group('the 3x3 visibility table, through buildSkillIndex', () {
    test('a Space-filed skill is visible inside its own Space', () async {
      inSpaceS();
      final index = await service.buildSkillIndex();
      expect(index.containsKey('skill-filed'), isTrue);
    });

    test('a Space-filed skill is hidden inside another Space', () async {
      inSpaceT();
      final index = await service.buildSkillIndex();
      expect(index.containsKey('skill-filed'), isFalse);
    });

    test('a Space-filed skill is hidden with no active Space (A4)', () async {
      inNoSpace();
      final index = await service.buildSkillIndex();
      expect(index.containsKey('skill-filed'), isFalse);
    });

    test('an all-spaces skill is visible inside its Space', () async {
      inSpaceS();
      final index = await service.buildSkillIndex();
      expect(index.containsKey('skill-everywhere'), isTrue);
    });

    test('an all-spaces skill is visible inside another Space', () async {
      inSpaceT();
      final index = await service.buildSkillIndex();
      expect(index.containsKey('skill-everywhere'), isTrue);
    });

    test('an all-spaces skill is visible with no active Space', () async {
      inNoSpace();
      final index = await service.buildSkillIndex();
      expect(index.containsKey('skill-everywhere'), isTrue);
    });

    test('an unfiled skill is hidden inside a Space', () async {
      inSpaceS();
      final index = await service.buildSkillIndex();
      expect(index.containsKey('skill-unfiled'), isFalse);
    });

    test('an unfiled skill is hidden inside another Space', () async {
      inSpaceT();
      final index = await service.buildSkillIndex();
      expect(index.containsKey('skill-unfiled'), isFalse);
    });

    test('an unfiled skill is visible with no active Space (A4)', () async {
      inNoSpace();
      final index = await service.buildSkillIndex();
      expect(index.containsKey('skill-unfiled'), isTrue);
    });
  });

  group('allSpaces: true escapes the scope', () {
    test('lists every skill inside a Space', () async {
      inSpaceS();
      final index = await service.buildSkillIndex(allSpaces: true);
      expect(
        index.keys,
        containsAll(<String>[
          'skill-filed',
          'skill-everywhere',
          'skill-unfiled',
        ]),
      );
    });

    test('lists every skill with no active Space', () async {
      inNoSpace();
      final index = await service.buildSkillIndex(allSpaces: true);
      expect(index.length, 3);
    });

    test('still drops disabled and unparseable notes', () async {
      final disabled = Note(
        id: 'skill-off',
        title: 'Off',
        content: '---\nname: Off\ndescription: d\nenabled: false\n---\n\nb',
        type: NoteType.note,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        tags: const [SkillService.agentSkillTag],
      );
      when(
        mockDb.getNotesByTag(SkillService.agentSkillTag),
      ).thenAnswer((_) async => [disabled]);
      inSpaceS();
      final index = await service.buildSkillIndex(allSpaces: true);
      expect(index, isEmpty);
    });
  });

  group('the all-spaces tag never widens the agent-skill requirement', () {
    // The shape that shipped as a blocker in M5, in skill form. Migration v47
    // put `all-spaces` on **every** `agent-skill` note, so a lookup that ORs the
    // reserved tag around the `agent-skill` requirement hands back the entire
    // skill library — plus anything else a user marked cross-space. The
    // requirement stays outside the OR: it is the tag this index is *built
    // from*, never part of the scope group.
    test('the index is built from agent-skill alone', () async {
      final crossSpaceNonSkill = Note(
        id: 'not-a-skill',
        title: 'Template',
        content: '---\nname: Template\ndescription: not a skill\n---\n\nbody',
        type: NoteType.note,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        tags: const [SpaceScopeService.allSpacesTag],
      );
      when(
        mockDb.getNotesByTag(SpaceScopeService.allSpacesTag),
      ).thenAnswer((_) async => [crossSpaceNonSkill]);

      inSpaceS();
      final index = await service.buildSkillIndex();

      verify(mockDb.getNotesByTag(SkillService.agentSkillTag)).called(1);
      verifyNever(mockDb.getNotesByTag(SpaceScopeService.allSpacesTag));
      expect(index.containsKey('not-a-skill'), isFalse);
    });

    test('scoping a Space genuinely narrows the library', () async {
      inSpaceS();
      final scoped = await service.buildSkillIndex();
      final everything = await service.buildSkillIndex(allSpaces: true);
      expect(scoped.length, lessThan(everything.length));
      expect(everything.keys, containsAll(scoped.keys));
    });
  });

  group('membership is all of the Space tags, not any', () {
    test('a skill carrying only part of a multi-tag Space is hidden', () async {
      const multi = SpaceSnapshot(
        id: 'space-m',
        includeTags: ['project', '2026'],
      );
      scope.setSpaceSnapshots([multi]);
      scope.setActive(multi.id, multi.includeTags);
      final partial = skillNote(
        'skill-partial',
        name: 'Partial',
        tags: ['project'],
      );
      final full = skillNote(
        'skill-full',
        name: 'Full',
        tags: ['project', '2026'],
      );
      when(
        mockDb.getNotesByTag(SkillService.agentSkillTag),
      ).thenAnswer((_) async => [partial, full]);

      final index = await service.buildSkillIndex();
      expect(index.containsKey('skill-partial'), isFalse);
      expect(index.containsKey('skill-full'), isTrue);
    });
  });

  group('skill refs are stable across activation', () {
    // Two skills whose names slugify to the same ref: the first keeps `review`,
    // the second becomes `review-2`. A model quotes `skillRef` back in
    // `load_skill` calls and conversation history stores it, so a ref that
    // changed when a Space hid its neighbour would silently re-point an old
    // reference at a different skill. Dedupe therefore runs before filtering.
    setUp(() {
      when(mockDb.getNotesByTag(SkillService.agentSkillTag)).thenAnswer(
        (_) async => [
          skillNote('dup-1', name: 'Review', tags: ['thesis']),
          skillNote('dup-2', name: 'Review', tags: ['reading']),
        ],
      );
    });

    test('unscoped, the second duplicate is review-2', () async {
      inNoSpace();
      final index = await service.buildSkillIndex(allSpaces: true);
      expect(index['dup-1']!.skillRef, 'review');
      expect(index['dup-2']!.skillRef, 'review-2');
    });

    test('the survivor keeps its ref when the other Space hides one', () async {
      inSpaceT();
      final index = await service.buildSkillIndex();
      expect(index.keys, ['dup-2']);
      expect(index['dup-2']!.skillRef, 'review-2');
    });
  });

  group('a hidden skill is unreachable, not merely unlisted', () {
    /// The index is what the model is *told* about, and it is filtered. The
    /// legacy `noteId` argument goes round it entirely — and a note id
    /// survives in conversation history across a Space switch, so a model
    /// quoting one back could load a skill this Space cannot see. Design
    /// decision 7 says it must not.
    group('through the legacy noteId argument', () {
      late LoadSkillTool tool;

      setUp(() {
        getIt.registerSingleton<SkillService>(service);
        tool = LoadSkillTool();
        when(mockDb.getNote('skill-filed')).thenAnswer((_) async => filed);
        when(
          mockDb.getNote('skill-everywhere'),
        ).thenAnswer((_) async => everywhere);
        when(mockDb.getNote('skill-unfiled')).thenAnswer((_) async => unfiled);
      });

      test('load_skill refuses a skill filed under another Space', () async {
        inSpaceT();

        final result = await tool.execute({'noteId': 'skill-filed'});

        expect(result, isA<Map>());
        expect(
          (result as Map)['error'],
          contains('not found'),
          reason:
              'the same answer as a missing note: which Spaces a skill is '
              'filed under is not something a hidden skill should disclose',
        );
      });

      test(
        'load_skill refuses a Space-filed skill with no Space active (A4)',
        () async {
          inNoSpace();

          final result = await tool.execute({'noteId': 'skill-filed'});

          expect((result as Map)['error'], contains('not found'));
        },
      );

      test('load_skill still serves a visible skill by noteId', () async {
        inSpaceS();

        expect(await tool.execute({'noteId': 'skill-filed'}), isA<String>());
        expect(
          await tool.execute({'noteId': 'skill-everywhere'}),
          isA<String>(),
        );
      });

      test('an unfiled skill is reachable only with no Space active', () async {
        inNoSpace();
        expect(await tool.execute({'noteId': 'skill-unfiled'}), isA<String>());

        tool.resetSession();
        inSpaceS();
        expect(await tool.execute({'noteId': 'skill-unfiled'}), isA<Map>());
      });

      test('the agent pins by noteId only after the same visibility test', () {
        // `_resolveSkillNoteId` is private and only reached from the middle of
        // `_performTask`'s tool loop, so this asserts the guard positionally:
        // the early return for a supplied noteId must not precede it.
        final src = File('lib/services/agent_service.dart').readAsStringSync();
        final start = src.indexOf('Future<String> _resolveSkillNoteId(');
        expect(start, greaterThan(0));
        final body = src.substring(start, start + 1200);
        final skillRefBranch = body.indexOf("args['skillRef']");
        final check = body.indexOf('skillVisible');
        expect(check, greaterThan(0));
        expect(
          check,
          lessThan(skillRefBranch),
          reason:
              'the noteId branch returns before the skillRef branch, so '
              'the check has to be inside it',
        );
      });
    });

    test('its skillRef cannot be resolved from the scoped index', () async {
      inSpaceT();
      final index = await service.buildSkillIndex();
      expect(service.resolveNoteIdForSkillRef(index, 'filed'), isNull);
      expect(
        service.resolveNoteIdForSkillRef(index, 'everywhere'),
        'skill-everywhere',
      );
    });

    test('its default_action is not injected into the prompt', () async {
      when(mockDb.getNotesByTag(SkillService.agentSkillTag)).thenAnswer(
        (_) async => [
          skillNote(
            'skill-filed',
            name: 'Filed',
            tags: ['thesis'],
            defaultAction: 'ALWAYS-EMIT-THESIS-CHIPS',
          ),
          skillNote(
            'skill-everywhere',
            name: 'Everywhere',
            tags: [SpaceScopeService.allSpacesTag],
            defaultAction: 'ALWAYS-EMIT-GLOBAL-CHIPS',
          ),
        ],
      );
      inSpaceT();
      final index = await service.buildSkillIndex();
      final section = service.buildDefaultActionPromptSection(index);
      expect(section, isNot(contains('ALWAYS-EMIT-THESIS-CHIPS')));
      expect(section, contains('ALWAYS-EMIT-GLOBAL-CHIPS'));
    });
  });

  group('the bundled Knowledge Exploration skill', () {
    test('survives scoping inside a Space', () async {
      when(
        mockDb.getNotesByTag(SkillService.agentSkillTag),
      ).thenAnswer((_) async => const []);
      final bundled = SkillService(
        mockDb,
        includeBundledSkills: true,
        spaceScope: scope,
      );
      inSpaceS();
      final index = await bundled.buildSkillIndex();
      expect(
        index[SkillService.bundledKnowledgeExplorationSkillPath]?.skillRef,
        'knowledge-exploration',
      );
    });

    test('is present with no active Space too', () async {
      when(
        mockDb.getNotesByTag(SkillService.agentSkillTag),
      ).thenAnswer((_) async => const []);
      final bundled = SkillService(
        mockDb,
        includeBundledSkills: true,
        spaceScope: scope,
      );
      inNoSpace();
      final index = await bundled.buildSkillIndex();
      expect(
        index.containsKey(SkillService.bundledKnowledgeExplorationSkillPath),
        isTrue,
      );
    });
  });

  group('constructor shape', () {
    test(
      'the positional-only form still compiles and defaults to shared',
      () async {
        // The 13 existing direct call sites construct `SkillService(db)`. A
        // required scope parameter would break every one of them at compile time,
        // so this test exists to fail at *compile* time if that ever changes.
        final positional = SkillService(mockDb);
        inNoSpace();
        final index = await positional.buildSkillIndex();
        expect(index.containsKey('skill-unfiled'), isTrue);
      },
    );

    test(
      'an omitted scope resolves the shared one, not a private one',
      () async {
        // A privately constructed SpaceScopeService is permanently unset, so it
        // would report every skill visible while looking like a scope. The
        // fallback must reach the registered instance — the same object the app
        // activates Spaces on.
        expect(identical(SpaceScopeService.shared(), scope), isTrue);
        final fallback = SkillService(mockDb);
        inSpaceT();
        final index = await fallback.buildSkillIndex();
        expect(index.containsKey('skill-filed'), isFalse);
        expect(index.containsKey('skill-everywhere'), isTrue);
      },
    );
  });

  group('only the management surfaces escape the scope', () {
    // §4 M6: eleven call sites build the index; exactly two are management UIs
    // that must list everything. Scanning the source keeps a twelfth from being
    // added quietly — the failure would be invisible in any behavioural test,
    // because an over-wide index looks like a working one.
    const allowed = {
      'lib/screens/tag_management_screen.dart',
      'lib/widgets/tag_detail_dialog.dart',
    };

    test('no other lib/ file passes allSpaces: true', () {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final rel = entity.path.replaceAll(r'\', '/');
        if (allowed.contains(rel)) continue;
        final src = entity.readAsStringSync();
        if (RegExp(r'buildSkillIndex\(\s*allSpaces:\s*true').hasMatch(src)) {
          offenders.add(rel);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'unexpected allSpaces: true call site',
      );
    });

    test('both management surfaces do pass it', () {
      for (final rel in allowed) {
        final src = File(rel).readAsStringSync();
        expect(
          RegExp(r'buildSkillIndex\(\s*\n?\s*allSpaces:\s*true').hasMatch(src),
          isTrue,
          reason: '$rel must list every skill',
        );
      }
    });
  });
}
