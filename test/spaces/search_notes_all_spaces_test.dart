import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/space_scope_service.dart';

/// M2: `searchNotesFTS(includeAllSpacesTag:)` ORs the reserved tag around the
/// **scope** conjunction, so a note marked visible everywhere is found by a
/// Space-scoped search. Real sqflite: the point is the SQL.
///
/// The scope lives in its own parameter, `scopeTags`, and is the only thing the
/// OR wraps. `tags` — the caller's own requirement — is ANDed outside it, so
/// `all-spaces` can excuse a note from the Space but never from what the caller
/// actually asked for (A7). One list ORed as a whole is the bug this shape
/// prevents: a search for `invoice` inside a Space would return every
/// `all-spaces` note.
Note buildNote(
  String id, {
  required String content,
  List<String> tags = const [],
}) {
  final now = DateTime(2026, 1, 1);
  return Note(
    id: id,
    title: 'Note $id',
    content: content,
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
    tags: tags,
  );
}

void main() {
  late DatabaseService db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    db = DatabaseService.createNew();
    await db.database;
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seed(List<Note> notes) async {
    for (final note in notes) {
      await db.insertNote(note);
    }
  }

  Future<List<String>> search(
    String query, {
    List<String>? tags,
    List<String>? scopeTags,
    bool includeAllSpacesTag = false,
  }) async {
    final results = await db.searchNotesFTS(
      query,
      tags: tags,
      scopeTags: scopeTags,
      includeAllSpacesTag: includeAllSpacesTag,
    );
    return results.map((n) => n.id).toList()..sort();
  }

  test(
    'an all-spaces note matches a scoped search only with the flag',
    () async {
      await seed([
        buildNote('member', content: 'quantum entanglement', tags: ['thesis']),
        buildNote(
          'everywhere',
          content: 'quantum entanglement',
          tags: [SpaceScopeService.allSpacesTag],
        ),
        buildNote(
          'outsider',
          content: 'quantum entanglement',
          tags: ['cooking'],
        ),
      ]);

      expect(await search('quantum entanglement', scopeTags: ['thesis']), [
        'member',
      ]);
      expect(
        await search(
          'quantum entanglement',
          scopeTags: ['thesis'],
          includeAllSpacesTag: true,
        ),
        ['everywhere', 'member'],
      );
    },
  );

  test(
    'the OR wraps the whole scope conjunction rather than adding another AND',
    () async {
      // A two-tag space. `partial` carries one of the two tags: it must stay out
      // either way. `everywhere` carries neither: the flag must let it in.
      await seed([
        buildNote(
          'member',
          content: 'quantum entanglement',
          tags: ['thesis', '2026'],
        ),
        buildNote('partial', content: 'quantum entanglement', tags: ['thesis']),
        buildNote(
          'everywhere',
          content: 'quantum entanglement',
          tags: [SpaceScopeService.allSpacesTag],
        ),
      ]);

      expect(
        await search('quantum entanglement', scopeTags: ['thesis', '2026']),
        ['member'],
      );
      expect(
        await search(
          'quantum entanglement',
          scopeTags: ['thesis', '2026'],
          includeAllSpacesTag: true,
        ),
        ['everywhere', 'member'],
      );
    },
  );

  test(
    'a note carrying both the space tags and all-spaces appears once',
    () async {
      await seed([
        buildNote(
          'both',
          content: 'quantum entanglement',
          tags: ['thesis', '2026', SpaceScopeService.allSpacesTag],
        ),
      ]);

      expect(
        await search(
          'quantum entanglement',
          scopeTags: ['thesis', '2026'],
          includeAllSpacesTag: true,
        ),
        ['both'],
      );
    },
  );

  test('the caller\'s tags are ANDed outside the OR (A7)', () async {
    // The F1 regression, at SQL level. `cross` is the note the merged
    // predicate leaked: it satisfies `all-spaces` and nothing else, so ORing
    // around the whole conjunction returned it for a search asking `invoice`.
    await seed([
      buildNote(
        'member',
        content: 'quantum entanglement',
        tags: ['thesis', 'invoice'],
      ),
      buildNote(
        'memberNoInvoice',
        content: 'quantum entanglement',
        tags: ['thesis'],
      ),
      buildNote(
        'crossInvoice',
        content: 'quantum entanglement',
        tags: [SpaceScopeService.allSpacesTag, 'invoice'],
      ),
      buildNote(
        'cross',
        content: 'quantum entanglement',
        tags: [SpaceScopeService.allSpacesTag],
      ),
      buildNote('outsider', content: 'quantum entanglement', tags: ['invoice']),
    ]);

    expect(
      await search(
        'quantum entanglement',
        tags: ['invoice'],
        scopeTags: ['thesis'],
        includeAllSpacesTag: true,
      ),
      ['crossInvoice', 'member'],
    );
  });

  test('the flag needs a scope: tags alone are never ORed away', () async {
    // `tags` is the caller's requirement, not a scope, so there is nothing for
    // `all-spaces` to excuse. A caller that passes the flag without a scope
    // gets the plain conjunction — fail-closed, and the shape that made the
    // merged predicate possible cannot come back by accident.
    await seed([
      buildNote('member', content: 'quantum entanglement', tags: ['thesis']),
      buildNote(
        'everywhere',
        content: 'quantum entanglement',
        tags: [SpaceScopeService.allSpacesTag],
      ),
    ]);

    expect(
      await search(
        'quantum entanglement',
        tags: ['thesis'],
        includeAllSpacesTag: true,
      ),
      ['member'],
    );
  });

  test('the flag changes nothing when no tags are given', () async {
    await seed([
      buildNote('plain', content: 'quantum entanglement'),
      buildNote(
        'everywhere',
        content: 'quantum entanglement',
        tags: [SpaceScopeService.allSpacesTag],
      ),
    ]);

    expect(await search('quantum entanglement'), ['everywhere', 'plain']);
    expect(await search('quantum entanglement', includeAllSpacesTag: true), [
      'everywhere',
      'plain',
    ]);
  });

  test(
    'the default leaves an ordinary tagged search exactly as it was',
    () async {
      await seed([
        buildNote('hit', content: 'wiki source overview', tags: ['reference']),
        buildNote('wrongTag', content: 'wiki source overview', tags: ['other']),
        buildNote('wrongText', content: 'unrelated prose', tags: ['reference']),
      ]);

      expect(await search('wiki source', tags: ['reference']), ['hit']);
      expect(
        await db.searchNotesFTS('wiki source', tags: ['reference']),
        hasLength(1),
      );
    },
  );

  test(
    'the flag matches nothing extra when no note carries all-spaces',
    () async {
      await seed([
        buildNote('member', content: 'quantum entanglement', tags: ['thesis']),
        buildNote(
          'outsider',
          content: 'quantum entanglement',
          tags: ['cooking'],
        ),
      ]);

      expect(
        await search(
          'quantum entanglement',
          scopeTags: ['thesis'],
          includeAllSpacesTag: true,
        ),
        ['member'],
      );
    },
  );

  test('only the search_notes tool opts into the all-spaces flag', () {
    // M2 built the seam and left every caller on the default; M5 opted in
    // exactly one — `NoteSearchTool`, covered by
    // test/spaces/search_notes_tool_scope_test.dart. Any *other* caller that
    // starts passing the flag owns an acceptance test for it, and this guard
    // is how that debt gets noticed.
    const optedIn = 'lib/services/tools/note_tools.dart';
    final offenders = <String>[];
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      if (!source.contains('searchNotesFTS(')) continue;
      if (file.path.endsWith('database_service.dart')) continue;
      if (file.path.endsWith(optedIn)) continue;
      if (source.contains('includeAllSpacesTag')) {
        offenders.add(file.path);
      }
    }

    expect(offenders, isEmpty);
    // ...and the one that did opt in still does, so deleting the scoping does
    // not quietly satisfy this test.
    expect(File(optedIn).readAsStringSync(), contains('includeAllSpacesTag'));
  });
}
