import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'package:note_synapse/models/filter.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_source_service.dart';
import 'package:note_synapse/services/search/search_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/tools/note_tools.dart';

import 'search_notes_tool_scope_test.mocks.dart';

/// M5: the agent's note tools inside a Space.
///
/// `search_notes` scopes to the Space by default and **composes** with explicit
/// tags (A7); `scope: "all"` is the only escape. `read_note` is never scoped
/// (invariant 4: scope narrows lists, never access). `ls` marks the Space's own
/// node, because decision 5 says the scoping is announced, not silent.
@GenerateMocks([DatabaseService, SearchService])
Note buildNote(String id, {List<String> tags = const []}) {
  final now = DateTime(2026, 1, 1);
  return Note(
    id: id,
    title: 'Note $id',
    content: 'content of $id',
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
    tags: tags,
  );
}

Filter buildFilter(
  String id, {
  String? name,
  List<String> includeTags = const [],
}) {
  final now = DateTime(2026, 1, 1);
  return Filter(
    id: id,
    name: name ?? id,
    includeTags: includeTags,
    isSpace: true,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  late MockDatabaseService mockDb;
  late MockSearchService mockSearch;
  late SpaceScopeService scope;
  late NoteSearchTool search;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockSearch = MockSearchService();
    scope = SpaceScopeService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<SearchService>(mockSearch);
    getIt.registerSingleton<SpaceScopeService>(scope);
    getIt.registerSingleton<NoteSourceService>(NoteSourceService(mockDb));

    when(
      mockSearch.searchFused(
        any,
        filter: anyNamed('filter'),
        audience: anyNamed('audience'),
        ticket: anyNamed('ticket'),
        chunksPerNote: anyNamed('chunksPerNote'),
      ),
    ).thenAnswer(
      (_) async => const SearchResponse(
        results: [],
        ticket: SearchService.standaloneTicket,
        usedSubstringFallback: false,
      ),
    );
    when(mockDb.getNotesByTag(any)).thenAnswer((_) async => []);
    when(mockDb.getAllFilters()).thenAnswer((_) async => []);

    search = NoteSearchTool();
  });

  tearDown(() async {
    await resetForTesting();
  });

  void activateThesis() =>
      scope.setActive('s1', const ['thesis', '2026'], name: 'Thesis');

  /// What the tool handed to the ranked search.
  ///
  /// The scope now travels as a [NoteFilterContext] into `SearchService`
  /// rather than as loose arguments to `searchNotesFTS`, but the contract
  /// under test is unchanged: `requiredTags` and `scopeTags` are separate on
  /// purpose, because only the second is ORed with `all-spaces` (A7). A test
  /// that could not tell them apart would pass with the two merged back into
  /// one list.
  ({List<String>? tags, List<String>? scopeTags, bool orAllSpaces})
  capturedFtsCall() {
    final call = verify(
      mockSearch.searchFused(
        any,
        filter: captureAnyNamed('filter'),
        audience: anyNamed('audience'),
        ticket: anyNamed('ticket'),
        chunksPerNote: anyNamed('chunksPerNote'),
      ),
    )..called(1);
    final filter = call.captured.single as NoteFilterContext;
    return (
      tags: filter.requiredTags,
      scopeTags: filter.scopeTags,
      orAllSpaces: filter.includeAllSpacesTag,
    );
  }

  // ------------------------------------------------------------------ schema

  group('the tool declares its escape', () {
    test('scope is in the input schema, with the two values', () {
      final scopeSchema =
          search.inputSchema['properties']['scope'] as Map<String, dynamic>;
      expect(scopeSchema['type'], 'string');
      expect(scopeSchema['enum'], ['space', 'all']);
      // Optional: an agent that never mentions scope keeps working.
      expect(search.inputSchema['required'], ['query']);
    });

    test('the description names the escape, so the model can find it', () {
      expect(search.description, contains('scope="all"'));
    });
  });

  // ----------------------------------------------------------------- scoping

  group('search_notes scoping', () {
    test(
      'with no active Space the call is exactly what it always was',
      () async {
        await search.execute({'query': 'quantum'});

        final call = capturedFtsCall();
        expect(call.tags, isNull);
        expect(call.scopeTags, isNull);
        expect(call.orAllSpaces, isFalse);
      },
    );

    test(
      'inside a Space and with no tags, the Space\'s tags are the filter',
      () async {
        activateThesis();

        await search.execute({'query': 'quantum'});

        final call = capturedFtsCall();
        expect(call.tags, isNull);
        expect(call.scopeTags, ['thesis', '2026']);
        expect(call.orAllSpaces, isTrue);
      },
    );

    test(
      'explicit tags COMPOSE with the Space rather than replacing it (A7)',
      () async {
        activateThesis();

        await search.execute({
          'query': 'quantum',
          'tags': ['chapter-3'],
        });

        // The caller's tag must NOT join the scope list: only the scope list is
        // ORed with `all-spaces`, so merging them turns "chapter-3 in this
        // Space" into "chapter-3, or anything tagged all-spaces".
        final call = capturedFtsCall();
        expect(call.tags, ['chapter-3']);
        expect(call.scopeTags, ['thesis', '2026']);
        expect(call.orAllSpaces, isTrue);
      },
    );

    test(
      'a tag the Space already requires still travels as the caller\'s',
      () async {
        activateThesis();

        await search.execute({
          'query': 'quantum',
          'tags': ['thesis'],
        });

        // Redundant in SQL (the same EXISTS is tested twice) and deliberately
        // so: folding it into the scope group would let an `all-spaces` note
        // that has no `thesis` answer a search that asked for `thesis`.
        final call = capturedFtsCall();
        expect(call.tags, ['thesis']);
        expect(call.scopeTags, ['thesis', '2026']);
      },
    );

    test('scope: "all" drops the Space entirely', () async {
      activateThesis();

      await search.execute({'query': 'quantum', 'scope': 'all'});

      final call = capturedFtsCall();
      expect(call.tags, isNull);
      expect(call.scopeTags, isNull);
      expect(call.orAllSpaces, isFalse);
    });

    test('scope: "all" keeps the caller\'s own tags', () async {
      activateThesis();

      await search.execute({
        'query': 'quantum',
        'tags': ['cooking'],
        'scope': 'all',
      });

      final call = capturedFtsCall();
      expect(call.tags, ['cooking']);
      expect(call.scopeTags, isNull);
      expect(call.orAllSpaces, isFalse);
    });

    test('scope: "space" is the default spelled out', () async {
      activateThesis();

      await search.execute({'query': 'quantum', 'scope': 'space'});

      expect(capturedFtsCall().scopeTags, ['thesis', '2026']);
    });
  });

  // ------------------------------------------------------- empty-query branch

  group('the empty-query branch is scoped like the FTS branch', () {
    test(
      'an empty query inside a Space filters on the Space\'s tags',
      () async {
        activateThesis();
        when(mockDb.getNotesByTag('thesis')).thenAnswer(
          (_) async => [
            buildNote('in', tags: ['thesis', '2026']),
            buildNote('half', tags: ['thesis']),
          ],
        );
        when(
          mockDb.getNotesByTag(SpaceScopeService.allSpacesTag),
        ).thenAnswer((_) async => []);

        final result = await search.execute({'query': '  '}) as List;

        expect(result.map((r) => r['id']), ['in']);
        // The no-query branch stays on the plain tag join: with nothing to rank
        // it must never reach the index.
        verifyNever(
          mockSearch.searchFused(
            any,
            filter: anyNamed('filter'),
            audience: anyNamed('audience'),
            ticket: anyNamed('ticket'),
            chunksPerNote: anyNamed('chunksPerNote'),
          ),
        );
      },
    );

    test(
      'an all-spaces note is returned even without the Space\'s tags',
      () async {
        activateThesis();
        when(mockDb.getNotesByTag('thesis')).thenAnswer(
          (_) async => [
            buildNote('in', tags: ['thesis', '2026']),
          ],
        );
        when(mockDb.getNotesByTag(SpaceScopeService.allSpacesTag)).thenAnswer(
          (_) async => [
            buildNote('everywhere', tags: [SpaceScopeService.allSpacesTag]),
          ],
        );

        final result = await search.execute({'query': ''}) as List;

        expect(result.map((r) => r['id']), ['in', 'everywhere']);
      },
    );

    test('an all-spaces note must still carry the tags the caller asked for '
        '(A7)', () async {
      // The F1 probe on the no-query branch: `all-spaces` excuses a note from
      // the Space's tags, never from the caller's. Appending the everywhere
      // list untested returned `cross` — and since migration v47 that list is
      // every agent-skill note in the library.
      activateThesis();
      when(mockDb.getNotesByTag('invoice')).thenAnswer((_) async => []);
      when(mockDb.getNotesByTag(SpaceScopeService.allSpacesTag)).thenAnswer(
        (_) async => [
          buildNote('cross', tags: [SpaceScopeService.allSpacesTag]),
        ],
      );

      final result =
          await search.execute({
                'query': '',
                'tags': ['invoice'],
              })
              as List;

      expect(result, isEmpty);
    });

    test('an all-spaces note that does carry them is returned', () async {
      activateThesis();
      when(mockDb.getNotesByTag('invoice')).thenAnswer(
        (_) async => [
          buildNote('in', tags: ['thesis', '2026', 'invoice']),
        ],
      );
      when(mockDb.getNotesByTag(SpaceScopeService.allSpacesTag)).thenAnswer(
        (_) async => [
          buildNote('cross', tags: [SpaceScopeService.allSpacesTag]),
          buildNote(
            'crossInvoice',
            tags: [SpaceScopeService.allSpacesTag, 'invoice'],
          ),
        ],
      );

      final result =
          await search.execute({
                'query': '',
                'tags': ['invoice'],
              })
              as List;

      expect(result.map((r) => r['id']), ['in', 'crossInvoice']);
      // The primary lookup is keyed on the caller's tag, not the Space's.
      verify(mockDb.getNotesByTag('invoice')).called(1);
    });

    test(
      'a note that is both a member and all-spaces is returned once',
      () async {
        activateThesis();
        final both = buildNote(
          'both',
          tags: ['thesis', '2026', SpaceScopeService.allSpacesTag],
        );
        when(mockDb.getNotesByTag('thesis')).thenAnswer((_) async => [both]);
        when(
          mockDb.getNotesByTag(SpaceScopeService.allSpacesTag),
        ).thenAnswer((_) async => [both]);

        final result = await search.execute({'query': ''}) as List;

        expect(result.map((r) => r['id']), ['both']);
      },
    );

    test(
      'scope: "all" with an empty query does not pull in all-spaces notes',
      () async {
        activateThesis();
        when(mockDb.getNotesByTag('cooking')).thenAnswer(
          (_) async => [
            buildNote('recipe', tags: ['cooking']),
          ],
        );

        final result =
            await search.execute({
                  'query': '',
                  'tags': ['cooking'],
                  'scope': 'all',
                })
                as List;

        expect(result.map((r) => r['id']), ['recipe']);
        verifyNever(mockDb.getNotesByTag(SpaceScopeService.allSpacesTag));
      },
    );
  });

  // ---------------------------------------------------- access is not scoped

  group('read_note is never scoped (invariant 4)', () {
    test('an out-of-scope note still opens by id', () async {
      activateThesis();
      final outsider = buildNote('outsider', tags: ['cooking']);
      when(mockDb.getNoteById('outsider')).thenAnswer((_) async => outsider);
      when(mockDb.getRelationships('outsider')).thenAnswer((_) async => []);
      when(mockDb.getNoteMetadata('outsider')).thenAnswer((_) async => null);

      final result = await NoteReadTool().execute({
        'note_id': 'outsider',
        'mode': 'stat',
      });

      expect(result, isA<Map>());
      expect((result as Map)['title'], 'Note outsider');
      expect(result.containsKey('error'), isFalse);
    });
  });

  // ------------------------------------------------------------ ls announces

  group('ls marks the active Space', () {
    test('the active Space\'s node carries (active space)', () async {
      when(mockDb.getAllFilters()).thenAnswer(
        (_) async => [
          buildFilter('s1', name: 'Thesis', includeTags: ['thesis']),
          buildFilter('s2', name: 'Cooking', includeTags: ['cooking']),
        ],
      );
      scope.setActive('s1', const ['thesis'], name: 'Thesis');

      final output = await ListFiltersTool().execute({}) as String;

      expect(output, contains('[Thesis] (active space)'));
      expect(output, contains('[Cooking]'));
      expect(output, isNot(contains('[Cooking] (active space)')));
    });

    test('nothing is marked when no Space is active', () async {
      when(mockDb.getAllFilters()).thenAnswer(
        (_) async => [
          buildFilter('s1', name: 'Thesis', includeTags: ['thesis']),
        ],
      );

      final output = await ListFiltersTool().execute({}) as String;

      expect(output, isNot(contains('active space')));
    });
  });
}
