import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Note buildNote({List<String> tags = const []}) {
  final now = DateTime(2026, 9, 8);
  return Note(
    id: 'n1',
    title: 'Title',
    content: 'Content',
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
    tags: tags,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpaceScopeService scope;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    scope = SpaceScopeService();
  });

  group('stamp', () {
    test('is a no-op with no active space, returning the same instance', () {
      final note = buildNote(tags: ['a']);
      expect(identical(scope.stamp(note), note), isTrue);
    });

    test('adds the space tags as a union, existing tags first', () {
      scope.setActive('s1', ['thesis', '2026']);
      final stamped = scope.stamp(buildNote(tags: ['reading']));
      expect(stamped.tags, ['reading', 'thesis', '2026']);
    });

    test('preserves the space tag order when the note has no tags', () {
      scope.setActive('s1', ['thesis', '2026']);
      expect(scope.stamp(buildNote()).tags, ['thesis', '2026']);
    });

    test('is idempotent and does not reorder existing tags', () {
      scope.setActive('s1', ['thesis', '2026']);
      final once = scope.stamp(buildNote(tags: ['2026', 'reading']));
      expect(once.tags, ['2026', 'reading', 'thesis']);

      final twice = scope.stamp(once);
      expect(twice.tags, ['2026', 'reading', 'thesis']);
      // Nothing to add, so no needless copy.
      expect(identical(twice, once), isTrue);
    });

    test('does not remove tags that are not part of the space', () {
      scope.setActive('s1', ['thesis']);
      expect(scope.stamp(buildNote(tags: ['private'])).tags, [
        'private',
        'thesis',
      ]);
    });

    test('leaving every space stops stamping', () {
      scope.setActive('s1', ['thesis']);
      scope.setActive(null, const []);
      expect(scope.stamp(buildNote(tags: ['a'])).tags, ['a']);
    });
  });

  group('stampData', () {
    test('is a no-op with no active space', () {
      final data = <String, dynamic>{'title': 'x'};
      expect(identical(scope.stampData(data), data), isTrue);
    });

    test('adds tags when the key is missing entirely', () {
      scope.setActive('s1', ['thesis']);
      final result = scope.stampData(<String, dynamic>{'title': 'x'});
      expect(result['tags'], ['thesis']);
      expect(result['title'], 'x');
    });

    test('unions with a List<dynamic> of tags', () {
      scope.setActive('s1', ['thesis', '2026']);
      final result = scope.stampData(<String, dynamic>{
        'tags': <dynamic>['reading', '2026'],
      });
      expect(result['tags'], ['reading', '2026', 'thesis']);
    });

    test('replaces a non-list tags value instead of throwing', () {
      scope.setActive('s1', ['thesis']);
      expect(
        scope.stampData(<String, dynamic>{'tags': 'garbage'})['tags'],
        ['thesis'],
      );
      expect(scope.stampData(<String, dynamic>{'tags': 42})['tags'], [
        'thesis',
      ]);
      expect(scope.stampData(<String, dynamic>{'tags': null})['tags'], [
        'thesis',
      ]);
    });

    test('drops nulls inside a tags list', () {
      scope.setActive('s1', ['thesis']);
      final result = scope.stampData(<String, dynamic>{
        'tags': <dynamic>['a', null],
      });
      expect(result['tags'], ['a', 'thesis']);
    });

    test('does not mutate the caller map', () {
      scope.setActive('s1', ['thesis']);
      final data = <String, dynamic>{
        'tags': <String>['a'],
      };
      scope.stampData(data);
      expect(data['tags'], ['a']);
    });
  });

  group('noteInScope', () {
    test('everything is in scope with no active space', () {
      expect(scope.noteInScope(const []), isTrue);
      expect(scope.noteInScope(const ['anything']), isTrue);
    });

    test('a multi-tag space requires every tag', () {
      scope.setActive('s1', ['thesis', '2026']);
      expect(scope.noteInScope(const ['thesis', '2026']), isTrue);
      expect(scope.noteInScope(const ['thesis', '2026', 'extra']), isTrue);
      expect(scope.noteInScope(const ['thesis']), isFalse);
      expect(scope.noteInScope(const ['2026']), isFalse);
      expect(scope.noteInScope(const []), isFalse);
    });

    test('the all-spaces tag is always in scope', () {
      scope.setActive('s1', ['thesis', '2026']);
      expect(
        scope.noteInScope(const [SpaceScopeService.allSpacesTag]),
        isTrue,
      );
      expect(
        scope.noteInScope(const ['unrelated', SpaceScopeService.allSpacesTag]),
        isTrue,
      );
    });

    test('an id with no resolved tags does not narrow anything', () {
      scope.setActive('s1', const []);
      expect(scope.isActive, isFalse);
      expect(scope.noteInScope(const ['whatever']), isTrue);
    });
  });

  group('skillVisible — the 3x3 table', () {
    const spaceS = ['finance'];
    const spaceT = ['thesis'];
    final snapshots = [
      const SpaceSnapshot(id: 's', includeTags: spaceS),
      const SpaceSnapshot(id: 't', includeTags: spaceT),
    ];

    test('inside space S', () {
      scope.setSpaceSnapshots(snapshots);
      scope.setActive('s', spaceS);

      expect(scope.skillVisible(const ['finance']), isTrue);
      expect(
        scope.skillVisible(const [SpaceScopeService.allSpacesTag]),
        isTrue,
      );
      expect(scope.skillVisible(const []), isFalse);
      // A skill scoped to another space is hidden here.
      expect(scope.skillVisible(const ['thesis']), isFalse);
    });

    test('inside another space', () {
      scope.setSpaceSnapshots(snapshots);
      scope.setActive('t', spaceT);

      expect(scope.skillVisible(const ['finance']), isFalse);
      expect(
        scope.skillVisible(const [SpaceScopeService.allSpacesTag]),
        isTrue,
      );
      expect(scope.skillVisible(const []), isFalse);
    });

    test('no active space', () {
      scope.setSpaceSnapshots(snapshots);

      // Space-scoped skills stay hidden — the deliberate asymmetry with notes.
      expect(scope.skillVisible(const ['finance']), isFalse);
      expect(
        scope.skillVisible(const [SpaceScopeService.allSpacesTag]),
        isTrue,
      );
      // Unfiled skills are visible.
      expect(scope.skillVisible(const []), isTrue);
      expect(scope.skillVisible(const ['random']), isTrue);
    });

    test('a multi-tag space needs all of its tags to claim a skill', () {
      scope.setSpaceSnapshots([
        const SpaceSnapshot(id: 's', includeTags: ['thesis', '2026']),
      ]);

      // With no space active, carrying only part of a space's tags still
      // counts as unfiled.
      expect(scope.skillVisible(const ['thesis']), isTrue);
      expect(scope.skillVisible(const ['thesis', '2026']), isFalse);

      scope.setActive('s', ['thesis', '2026']);
      expect(scope.skillVisible(const ['thesis']), isFalse);
      expect(scope.skillVisible(const ['thesis', '2026']), isTrue);
    });

    test('all-spaces wins over every other consideration', () {
      scope.setSpaceSnapshots([
        const SpaceSnapshot(id: 's', includeTags: ['finance']),
      ]);
      scope.setActive('s', ['finance']);
      expect(
        scope.skillVisible(const ['thesis', SpaceScopeService.allSpacesTag]),
        isTrue,
      );
    });

    test('with no spaces at all every skill is visible', () {
      expect(scope.skillVisible(const []), isTrue);
      expect(scope.skillVisible(const ['finance']), isTrue);
    });
  });

  group('scopeVersion', () {
    test('starts at zero and bumps when activation changes', () {
      expect(scope.scopeVersion, 0);

      scope.setActive('s1', ['thesis']);
      expect(scope.scopeVersion, 1);

      scope.setActive(null, const []);
      expect(scope.scopeVersion, 2);
    });

    test('does not bump when the same space is re-activated', () {
      scope.setActive('s1', ['thesis']);
      final version = scope.scopeVersion;
      scope.setActive('s1', ['thesis']);
      expect(scope.scopeVersion, version);
    });

    test('bumps when the same space id gains a tag', () {
      scope.setActive('s1', ['thesis']);
      final version = scope.scopeVersion;
      scope.setActive('s1', ['thesis', '2026']);
      expect(scope.scopeVersion, version + 1);
    });

    test('bumps when the known space list changes, not when it repeats', () {
      final snapshots = [
        const SpaceSnapshot(id: 's', includeTags: ['finance']),
      ];
      scope.setSpaceSnapshots(snapshots);
      final version = scope.scopeVersion;
      expect(version, 1);

      scope.setSpaceSnapshots([
        const SpaceSnapshot(id: 's', includeTags: ['finance']),
      ]);
      expect(scope.scopeVersion, version);

      scope.setSpaceSnapshots([
        const SpaceSnapshot(id: 's', includeTags: ['finance', 'tax']),
      ]);
      expect(scope.scopeVersion, version + 1);
    });

    test('stored snapshots do not alias the caller list', () {
      // Snapshots are built from Filter.includeTags, which is a growable list
      // owned by a live Filter (it comes from includeTagsString.split(',')).
      final tags = <String>['finance'];
      scope.setSpaceSnapshots([SpaceSnapshot(id: 's', includeTags: tags)]);
      final version = scope.scopeVersion;

      tags.add('tax');

      // The scope is unchanged, and unchanged silently: a holder of a cached,
      // scope-derived index compares scopeVersion and would never learn of a
      // mutation that reached through the snapshot.
      expect(scope.spaceSnapshots.single.includeTags, ['finance']);
      expect(scope.scopeVersion, version);
      expect(scope.skillVisible(const ['finance']), isFalse);
      expect(
        () => scope.spaceSnapshots.single.includeTags.add('audit'),
        throwsUnsupportedError,
      );
    });
  });

  group('load / save', () {
    test('save persists the active id and load restores it', () async {
      scope.setActive('s1', ['thesis']);
      await scope.save();

      final reloaded = SpaceScopeService();
      await reloaded.load();
      expect(reloaded.activeSpaceId, 's1');
      // Tags are resolved by AppProvider, not persisted.
      expect(reloaded.stampTags, isEmpty);
      expect(reloaded.isActive, isFalse);
    });

    test('save clears the key when no space is active', () async {
      scope.setActive('s1', ['thesis']);
      await scope.save();

      scope.setActive(null, const []);
      await scope.save();

      final reloaded = SpaceScopeService();
      await reloaded.load();
      expect(reloaded.activeSpaceId, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(SpaceScopeService.prefsKey), isFalse);
    });

    test('load leaves the id null when nothing was persisted', () async {
      await scope.load();
      expect(scope.activeSpaceId, isNull);
    });

    // AppProvider._doLoadData reloads on every data refresh, so load() runs
    // again long after a space was resolved and activated.

    test('a reload of the same id leaves the resolved scope alone', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SpaceScopeService.prefsKey, 's1');
      scope.setActive('s1', ['thesis']);
      final version = scope.scopeVersion;

      await scope.load();

      expect(scope.activeSpaceId, 's1');
      expect(scope.stampTags, ['thesis']);
      expect(scope.scopeVersion, version);
    });

    test('a reload of a different id drops the previous stamp tags', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SpaceScopeService.prefsKey, 's2');
      scope.setActive('s1', ['thesis']);
      final version = scope.scopeVersion;

      await scope.load();

      expect(scope.activeSpaceId, 's2');
      // Reporting s2 with s1's tags would scope and stamp against the wrong
      // space until AppProvider resolves the id and calls setActive.
      expect(scope.stampTags, isEmpty);
      expect(scope.isActive, isFalse);
      // And the bump is what tells a cached scope-derived index to rebuild.
      expect(scope.scopeVersion, version + 1);
    });

    test('a reload that finds nothing clears an active space', () async {
      scope.setActive('s1', ['thesis']);
      final version = scope.scopeVersion;

      await scope.load();

      expect(scope.activeSpaceId, isNull);
      expect(scope.stampTags, isEmpty);
      expect(scope.scopeVersion, version + 1);
    });
  });

  group('isReservedTag', () {
    test('covers the two tags the app assigns meaning to', () {
      expect(SpaceScopeService.isReservedTag(SpaceScopeService.allSpacesTag),
          isTrue);
      expect(SpaceScopeService.isReservedTag(SkillService.agentSkillTag),
          isTrue);
    });

    test('the agent-skill spelling cannot drift from SkillService', () {
      // The constant is duplicated rather than imported: `skill_service.dart`
      // imports this file, so importing it back would close a cycle for one
      // string. This test is what keeps the two in step.
      expect(SkillService.agentSkillTag, 'agent-skill');
      expect(SpaceScopeService.isReservedTag('agent-skill'), isTrue);
    });

    test('an ordinary tag is not reserved, including near misses', () {
      for (final tag in [
        'thesis',
        'all-space',
        'all-spacesx',
        'All-Spaces',
        'agent-skills',
        '',
      ]) {
        expect(
          SpaceScopeService.isReservedTag(tag),
          isFalse,
          reason: '"$tag" is an ordinary tag a user may legitimately scope by',
        );
      }
    });
  });

  group('partitionChips', () {
    test('with no active Space every chip belongs to the caller', () {
      final split = scope.partitionChips(['thesis', 'urgent']);

      expect(split.tagNames, ['thesis', 'urgent']);
      expect(split.scopeTags, isNull);
      expect(split.orAllSpaces, isFalse);
    });

    test('splits the Space\'s own tags out of the caller\'s', () {
      scope.setActive('s1', ['thesis', '2026']);

      final split = scope.partitionChips(['thesis', 'urgent', '2026']);

      expect(split.scopeTags, ['thesis', '2026']);
      expect(split.tagNames, ['urgent']);
      expect(split.orAllSpaces, isTrue);
    });

    test('preserves chip order within each list', () {
      scope.setActive('s1', ['a', 'b']);

      final split = scope.partitionChips(['z', 'b', 'y', 'a']);

      expect(split.scopeTags, ['b', 'a']);
      expect(split.tagNames, ['z', 'y']);
    });

    test('an emptied scope group turns the cross-Space OR off', () {
      scope.setActive('s1', ['thesis']);

      final split = scope.partitionChips(['urgent']);

      expect(split.scopeTags, isNull);
      expect(split.orAllSpaces, isFalse);
    });

    test('an empty chip list yields two nulls', () {
      scope.setActive('s1', ['thesis']);

      final split = scope.partitionChips(const []);

      expect(split.tagNames, isNull);
      expect(split.scopeTags, isNull);
      expect(split.orAllSpaces, isFalse);
    });
  });
}
