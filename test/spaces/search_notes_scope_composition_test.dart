import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/tools/note_tools.dart';

/// M5 / A7, end to end through `search_notes` against a real database.
///
/// Explicit tags are ANDed **within** the Space scope: asking for tag X inside
/// a Space means "X, in this Space". Only the *Space's* tags may be ORed away
/// by `all-spaces`.
///
/// The regression this file exists for: the tool used to merge the caller's
/// tags with the Space's into one list and OR `all-spaces` around the whole
/// conjunction, so a search for `invoice` inside a Space returned every
/// `all-spaces` note — and migration v47 back-fills `all-spaces` onto every
/// `agent-skill` note, so that is every skill in the library. Both branches of
/// the tool (FTS and the no-query tag lookup) had the same hole, so both are
/// probed here.
void main() {
  late DatabaseService db;
  late SpaceScopeService scope;
  late NoteSearchTool search;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    await resetForTesting();
    db = DatabaseService.createNew();
    await db.database;
    scope = SpaceScopeService();
    getIt.registerSingleton<DatabaseService>(db);
    getIt.registerSingleton<SpaceScopeService>(scope);
    search = NoteSearchTool();
  });

  tearDown(() async {
    await db.close();
    await resetForTesting();
  });

  Note buildNote(String id, {List<String> tags = const []}) {
    final now = DateTime(2026, 1, 1);
    return Note(
      id: id,
      title: 'Note $id',
      content: 'quantum entanglement',
      type: NoteType.note,
      createdAt: now,
      updatedAt: now,
      tags: tags,
    );
  }

  Future<void> seed(List<Note> notes) async {
    for (final note in notes) {
      await db.insertNote(note);
    }
  }

  Future<List<String>> run(Map<String, dynamic> args) async {
    final result = await search.execute(args) as List;
    return result.map((r) => r['id'] as String).toList()..sort();
  }

  /// The reviewer's probe, verbatim: a Space on `thesis`, one cross-space note
  /// carrying nothing else, and a search for a tag no note in the Space has.
  group('the reviewer probe: tag invoice inside a Space on thesis', () {
    setUp(() async {
      await seed([
        buildNote('cross', tags: [SpaceScopeService.allSpacesTag]),
      ]);
      scope.setActive('s1', const ['thesis'], name: 'Thesis');
    });

    test('the fixtures are what the probe assumes', () async {
      expect(await db.getNotesByTag('invoice'), isEmpty);
      expect(
        (await db.getNotesByTag(SpaceScopeService.allSpacesTag))
            .map((n) => n.id),
        ['cross'],
      );
    });

    test('the FTS branch returns nothing, not the cross-space note', () async {
      expect(
        await run({
          'query': 'quantum',
          'tags': ['invoice'],
        }),
        isEmpty,
      );
    });

    test('the no-query branch returns nothing either', () async {
      expect(
        await run({
          'query': '',
          'tags': ['invoice'],
        }),
        isEmpty,
      );
    });
  });

  group('composition, with notes on every side of the predicate', () {
    setUp(() async {
      await seed([
        // In the Space and carrying the requested tag: the plain hit.
        buildNote('member-invoice', tags: ['thesis', 'invoice']),
        // In the Space but without the requested tag: filtered out by the AND.
        buildNote('member-only', tags: ['thesis']),
        // Cross-space and carrying the requested tag: in, because `all-spaces`
        // excuses the Space's tags but not the caller's.
        buildNote('cross-invoice', tags: [
          SpaceScopeService.allSpacesTag,
          'invoice',
        ]),
        // Cross-space with nothing else: the note the merged predicate leaked.
        buildNote('cross-only', tags: [SpaceScopeService.allSpacesTag]),
        // Carrying the requested tag but outside the Space entirely.
        buildNote('outsider-invoice', tags: ['invoice']),
      ]);
      scope.setActive('s1', const ['thesis'], name: 'Thesis');
    });

    test('FTS branch: requested AND (space OR all-spaces)', () async {
      expect(
        await run({
          'query': 'quantum',
          'tags': ['invoice'],
        }),
        ['cross-invoice', 'member-invoice'],
      );
    });

    test('no-query branch: requested AND (space OR all-spaces)', () async {
      expect(
        await run({
          'query': '',
          'tags': ['invoice'],
        }),
        ['cross-invoice', 'member-invoice'],
      );
    });

    test('with no tags of its own the Space alone decides, both branches',
        () async {
      const inScope = ['cross-invoice', 'cross-only', 'member-invoice',
          'member-only'];
      expect(await run({'query': 'quantum'}), inScope);
      expect(await run({'query': ''}), inScope);
    });

    test('scope: "all" drops the Space and keeps the caller\'s tags',
        () async {
      const everyInvoice = ['cross-invoice', 'member-invoice',
          'outsider-invoice'];
      expect(
        await run({
          'query': 'quantum',
          'tags': ['invoice'],
          'scope': 'all',
        }),
        everyInvoice,
      );
      expect(
        await run({
          'query': '',
          'tags': ['invoice'],
          'scope': 'all',
        }),
        everyInvoice,
      );
    });

    test('a requested tag the Space also requires still gates all-spaces',
        () async {
      // `thesis` is both the Space's tag and the caller's. It must stay
      // outside the OR: de-duplicating it into the scope group would let
      // `cross-only` — which has no `thesis` — answer a search that asked
      // for `thesis` explicitly.
      const asked = ['member-invoice', 'member-only'];
      expect(
        await run({
          'query': 'quantum',
          'tags': ['thesis'],
        }),
        asked,
      );
      expect(
        await run({
          'query': '',
          'tags': ['thesis'],
        }),
        asked,
      );
    });

    test('with no Space active nothing is scoped and nothing is ORed',
        () async {
      scope.setActive(null, const []);

      expect(
        await run({
          'query': 'quantum',
          'tags': ['invoice'],
        }),
        ['cross-invoice', 'member-invoice', 'outsider-invoice'],
      );
      expect(
        await run({
          'query': '',
          'tags': ['invoice'],
        }),
        ['cross-invoice', 'member-invoice', 'outsider-invoice'],
      );
    });
  });
}
