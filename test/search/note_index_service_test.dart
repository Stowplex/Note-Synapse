// Integration tests for NoteIndexService (plan §1.3): reindex diffing,
// DatabaseService write-path hooks, exclusion policy, backfill resumability,
// debounce coalescing, and FTS4-unavailable degradation. Real sqlite via
// sqflite_common_ffi, following test/database_test.dart patterns.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/note_annotation.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/attachment_text_extractor.dart';
import 'package:note_synapse/services/search/note_chunker.dart';
import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:note_synapse/services/search/search_service.dart';
import 'package:note_synapse/services/search/search_text_normalizer.dart';
import 'package:note_synapse/services/search_settings_service.dart';

import 'ocr_test_stubs.dart';

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      Directory.systemTemp.path;
}

void main() {
  late DatabaseService db;
  late DataChangeNotifier notifier;
  late NoteIndexService indexer;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    // Notes with attachments resolve full paths through path_provider.
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  setUp(() async {
    db = DatabaseService.createNew();
    await db.database;
    notifier = DataChangeNotifier();
    indexer = NoteIndexService(
      db,
      changeNotifier: notifier,
      debounceDelay: const Duration(milliseconds: 50),
      ocrExtractor: stubOcrExtractor(db),
      figureExtractor: stubFigureExtractor(),
    );
  });

  tearDown(() async {
    indexer.dispose();
    await db.close();
  });

  Note buildNote(
    String id, {
    String? title,
    String? content,
    List<String> tags = const [],
    List<SubNote> subNotes = const [],
  }) {
    return Note(
      id: id,
      title: title ?? 'Note $id',
      content: content ?? 'Body of note $id.',
      type: NoteType.note,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      tags: tags,
      subNotes: subNotes,
    );
  }

  Future<List<Map<String, dynamic>>> chunksFor(String noteId) async {
    final raw = await db.database;
    return raw.query(
      'search_chunks',
      where: 'noteId = ?',
      whereArgs: [noteId],
      orderBy: 'chunkKey',
    );
  }

  Future<List<Map<String, dynamic>>> ftsRowsFor(String noteId) async {
    final raw = await db.database;
    return raw.rawQuery(
      'SELECT docid, content FROM chunks_fts WHERE docid IN '
      '(SELECT id FROM search_chunks WHERE noteId = ?)',
      [noteId],
    );
  }

  Future<Map<String, dynamic>?> noteState(String noteId) async {
    final raw = await db.database;
    final rows = await raw.query(
      'search_index_state',
      where: "scopeType = 'note' AND scopeId = ? AND stage = 'chunks'",
      whereArgs: [noteId],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, dynamic>?> globalState() async {
    final raw = await db.database;
    final rows = await raw.query(
      'search_index_state',
      where: "scopeType = 'global' AND scopeId = 'all' AND stage = 'chunks'",
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Inserts a note row via raw SQL, bypassing the DatabaseService hooks —
  /// for tests that need notes the indexer has never seen.
  Future<void> rawInsertNote(String id, {String content = 'raw body'}) async {
    final raw = await db.database;
    await raw.insert('notes', {
      'id': id,
      'title': 'Raw $id',
      'content': content,
      'type': 'note',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  const twoSectionContent =
      '# Alpha\n'
      'Alpha section paragraph with some unique words here.\n'
      '\n'
      '# Beta\n'
      'Beta section paragraph with different unique words there.\n';

  group('reindexNote', () {
    test('writes chunks, docid-aligned FTS rows, and done state', () async {
      final note = buildNote(
        'n1',
        title: 'Groceries',
        content: twoSectionContent,
        tags: ['shopping'],
      );
      await db.insertNote(note);
      await indexer.reindexNote('n1');

      final chunks = await chunksFor('n1');
      final byKey = {for (final c in chunks) c['chunkKey'] as String: c};
      expect(
        byKey.keys,
        containsAll(['n1:meta:-:0', 'n1:note_body:-:0', 'n1:note_body:-:1']),
      );

      // Meta chunk restores tag matching.
      expect(byKey['n1:meta:-:0']!['text'], contains('shopping'));

      // FTS rows exist for every chunk, keyed by search_chunks.id (docid).
      final ftsRows = await ftsRowsFor('n1');
      expect(ftsRows.length, chunks.length);
      final raw = await db.database;
      final match = await raw.rawQuery(
        "SELECT docid FROM chunks_fts WHERE content MATCH 'shopping'",
      );
      expect(match.single['docid'], byKey['n1:meta:-:0']!['id']);

      final state = await noteState('n1');
      expect(state!['status'], 'done');
      expect(
        await globalState(),
        isNull,
        reason: 'single-note reindex never sets the global flag',
      );
    });

    test('rewrites only changed chunks and purges stale ones', () async {
      final note = buildNote('n1', content: twoSectionContent);
      await db.insertNote(note);
      await indexer.reindexNote('n1');

      final raw = await db.database;
      // Sentinel timestamps prove which rows get rewritten.
      await raw.update('search_chunks', {'updatedAt': 111});
      final before = {
        for (final c in await chunksFor('n1')) c['chunkKey'] as String: c,
      };
      final alphaId = before['n1:note_body:-:0']!['id'] as int;
      final betaId = before['n1:note_body:-:1']!['id'] as int;
      // Seed embeddings on both body chunks: the changed chunk's embedding
      // must be invalidated, the unchanged one kept.
      for (final chunkId in [alphaId, betaId]) {
        await raw.insert('chunk_embeddings', {
          'chunkId': chunkId,
          'providerKey': 'test:model:4',
          'modality': 'text',
          'dims': 4,
          'vector': Uint8List.fromList([0, 0, 0, 0]),
          'contentHash': 'x',
        });
      }

      final edited = twoSectionContent.replaceFirst(
        'different unique words there',
        'edited words in the beta paragraph',
      );
      await db.updateNote(note.copyWith(content: edited));
      await indexer.reindexNote('n1');

      final after = {
        for (final c in await chunksFor('n1')) c['chunkKey'] as String: c,
      };
      // Unchanged chunk: same rowid, untouched timestamp, embedding kept.
      expect(after['n1:note_body:-:0']!['id'], alphaId);
      expect(after['n1:note_body:-:0']!['updatedAt'], 111);
      // Changed chunk: updated in place (same rowid), new hash, new stamp.
      expect(after['n1:note_body:-:1']!['id'], betaId);
      expect(after['n1:note_body:-:1']!['updatedAt'], isNot(111));
      expect(
        after['n1:note_body:-:1']!['contentHash'],
        isNot(before['n1:note_body:-:1']!['contentHash']),
      );
      final embeddings = await raw.query('chunk_embeddings');
      expect(embeddings.single['chunkId'], alphaId);

      // Delete section Beta entirely -> its chunk and FTS row disappear.
      final alphaOnly = edited.substring(0, edited.indexOf('# Beta'));
      await db.updateNote(note.copyWith(content: alphaOnly));
      await indexer.reindexNote('n1');

      final finalChunks = await chunksFor('n1');
      expect(
        finalChunks.map((c) => c['chunkKey']),
        isNot(contains('n1:note_body:-:1')),
      );
      expect((await ftsRowsFor('n1')).length, finalChunks.length);
      final orphanFts = await raw.rawQuery(
        'SELECT docid FROM chunks_fts WHERE docid NOT IN (SELECT id FROM search_chunks)',
      );
      expect(orphanFts, isEmpty);
    });

    test('reindex of a missing note purges its rows', () async {
      final note = buildNote('n1');
      await db.insertNote(note);
      await indexer.reindexNote('n1');
      expect(await chunksFor('n1'), isNotEmpty);

      final raw = await db.database;
      // Tombstone write, not a real DELETE: `notes` is hard-delete-guarded
      // (M1.13) and deletion is soft-delete everywhere, so this IS the
      // "row went away behind the indexer's back" case. Written straight to
      // the connection, so it bypasses the hooks the same way.
      await raw.update('notes', {'__deleted__': 1}, where: "id = 'n1'");
      await indexer.reindexNote('n1');
      expect(await chunksFor('n1'), isEmpty);
      expect(await noteState('n1'), isNull);
    });
  });

  group('write-path hooks', () {
    test(
      'insert/update/delete through DatabaseService maintain the index',
      () async {
        final note = buildNote('n1', content: 'Original searchable body.');
        await db.insertNote(note);
        await indexer.flushPending();
        expect(await chunksFor('n1'), isNotEmpty);

        await db.updateNote(note.copyWith(content: 'Rewritten body text.'));
        await indexer.flushPending();
        final texts = (await chunksFor('n1')).map((c) => c['text']).join(' ');
        expect(texts, contains('Rewritten body text.'));
        expect(texts, isNot(contains('Original searchable body.')));

        await db.deleteNote('n1');
        await indexer.flushPending();
        expect(await chunksFor('n1'), isEmpty);
        expect(await ftsRowsFor('n1'), isEmpty);
        expect(await noteState('n1'), isNull);
      },
    );

    test(
      'subnote and annotation CRUD through DatabaseService reindex',
      () async {
        final note = buildNote('n1');
        await db.insertNote(note);
        await indexer.flushPending();

        await db.insertSubNote(
          SubNote(
            id: 'sub1',
            name: 'Checklist',
            content: 'subnote searchable content',
            createdAt: DateTime.now(),
          ),
          'n1',
        );
        await indexer.flushPending();
        expect(
          (await chunksFor('n1')).map((c) => c['chunkKey']),
          contains('n1:subnote:sub1:0'),
        );

        await db.saveNoteAnnotation(
          NoteAnnotation(
            id: 'ann1',
            noteId: 'n1',
            content: 'annotation searchable content',
            attachmentPaths: const [],
            createdAt: DateTime.now(),
          ),
        );
        await indexer.flushPending();
        expect(
          (await chunksFor('n1')).map((c) => c['chunkKey']),
          contains('n1:annotation:ann1:0'),
        );

        await db.deleteNoteAnnotation('ann1');
        await indexer.flushPending();
        expect(
          (await chunksFor('n1')).map((c) => c['chunkKey']),
          isNot(contains('n1:annotation:ann1:0')),
        );
      },
    );

    test(
      're-parenting an annotation reindexes both old and new owner',
      () async {
        await db.insertNote(buildNote('n1'));
        await db.insertNote(buildNote('n2'));
        await db.saveNoteAnnotation(
          NoteAnnotation(
            id: 'ann1',
            noteId: 'n1',
            content: 'movable annotation content',
            attachmentPaths: const [],
            createdAt: DateTime.now(),
          ),
        );
        await indexer.flushPending();
        expect(
          (await chunksFor('n1')).map((c) => c['chunkKey']),
          contains('n1:annotation:ann1:0'),
        );

        // Same id, different owner: ConflictAlgorithm.replace re-parents it.
        await db.saveNoteAnnotation(
          NoteAnnotation(
            id: 'ann1',
            noteId: 'n2',
            content: 'movable annotation content',
            attachmentPaths: const [],
            createdAt: DateTime.now(),
          ),
        );
        await indexer.flushPending();
        expect(
          (await chunksFor('n1')).map((c) => c['chunkKey']),
          isNot(contains('n1:annotation:ann1:0')),
          reason: 'the old owner must drop the moved annotation chunk',
        );
        expect(
          (await chunksFor('n2')).map((c) => c['chunkKey']),
          contains('n2:annotation:ann1:0'),
        );
      },
    );

    test('updateNoteMetadata reindexes (policy lives in metadata)', () async {
      final note = buildNote('n1');
      await db.insertNote(note);
      await indexer.flushPending();
      expect(await chunksFor('n1'), isNotEmpty);

      await db.updateNoteMetadata('n1', {
        'searchIndex': {'exclude': true},
      });
      await indexer.flushPending();
      expect(await chunksFor('n1'), isEmpty);
      expect((await noteState('n1'))!['status'], 'skipped');
    });

    test('DataChangeNotifier noteIds events reach the indexer', () async {
      await rawInsertNote('raw1');
      notifier.publish(const DataChangeEvent(noteIds: {'raw1'}));
      await notifier.waitForIdle();
      await indexer.flushPending();
      expect(await chunksFor('raw1'), isNotEmpty);
    });

    test('bulk events trigger a completeness sweep', () async {
      await rawInsertNote('raw1');
      notifier.publish(const DataChangeEvent(bulk: true));
      await notifier.waitForIdle();
      // Bulk sweep is debounced (debounceDelay) then runs a backfill.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((await globalState())?['status'] != 'done') {
        if (DateTime.now().isAfter(deadline)) {
          fail('bulk sweep did not complete a backfill');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(await chunksFor('raw1'), isNotEmpty);
    });
  });

  group('exclusion policy', () {
    test(
      'purge on exclude, skipped state, global completeness, re-include',
      () async {
        await db.insertNote(buildNote('kept'));
        await db.insertNote(buildNote('hidden'));
        await indexer.flushPending();
        expect(await chunksFor('hidden'), isNotEmpty);

        await indexer.setNoteSearchExclusion('hidden', true);
        await indexer.flushPending();
        expect(await chunksFor('hidden'), isEmpty);
        expect(await ftsRowsFor('hidden'), isEmpty);
        expect((await noteState('hidden'))!['status'], 'skipped');
        expect(
          NoteIndexService.isNoteSearchExcluded(
            await db.getNoteMetadata('hidden'),
          ),
          isTrue,
        );

        // Excluded notes count as done: the global flag is still achievable.
        await indexer.backfillAll();
        expect((await globalState())!['status'], 'done');
        expect(await chunksFor('hidden'), isEmpty);
        expect(await chunksFor('kept'), isNotEmpty);

        await indexer.setNoteSearchExclusion('hidden', false);
        await indexer.flushPending();
        expect(await chunksFor('hidden'), isNotEmpty);
        expect((await noteState('hidden'))!['status'], 'done');
        expect(
          await db.getNoteMetadata('hidden'),
          isNull,
          reason: 'clearing the last flag removes the metadata entirely',
        );
      },
    );
  });

  group('backfillAll', () {
    test(
      'resumable: already-indexed notes are skipped; global flag set',
      () async {
        await rawInsertNote('a');
        await rawInsertNote('b');
        await rawInsertNote('c');
        // Simulate an interrupted backfill: a and b indexed, c not.
        await indexer.reindexNote('a');
        await indexer.reindexNote('b');
        final raw = await db.database;
        await raw.update('search_index_state', {
          'updatedAt': 1,
        }, where: "scopeType = 'note'");
        expect(await globalState(), isNull);

        await indexer.backfillAll();

        // a and b were skipped (state rows untouched), c was indexed.
        expect((await noteState('a'))!['updatedAt'], 1);
        expect((await noteState('b'))!['updatedAt'], 1);
        expect((await noteState('c'))!['updatedAt'], isNot(1));
        expect(await chunksFor('c'), isNotEmpty);
        expect((await globalState())!['status'], 'done');
        expect(indexer.progress.value.running, isFalse);
        expect(indexer.progress.value.done, 3);
        expect(indexer.progress.value.total, 3);

        // A second run skips everything.
        await raw.update('search_index_state', {
          'updatedAt': 1,
        }, where: "scopeType = 'note'");
        await indexer.backfillAll();
        expect((await noteState('c'))!['updatedAt'], 1);
      },
    );

    test('force clears the global flag and re-verifies every note', () async {
      await rawInsertNote('a');
      await indexer.backfillAll();
      expect((await globalState())!['status'], 'done');
      final idsBefore = (await chunksFor('a')).map((c) => c['id']).toList();
      expect(idsBefore, isNotEmpty);

      final raw = await db.database;
      await raw.update('search_index_state', {'updatedAt': 1});
      await raw.update('search_chunks', {'updatedAt': 111});
      await indexer.backfillAll(force: true);

      // State rows rewritten (not skipped) ...
      expect((await noteState('a'))!['updatedAt'], isNot(1));
      expect((await globalState())!['status'], 'done');
      // ... but unchanged chunks are diff no-ops (same rowids, untouched).
      final after = await chunksFor('a');
      expect(after.map((c) => c['id']).toList(), idsBefore);
      expect(after.map((c) => c['updatedAt']).toSet(), {111});
    });

    test('purges chunks orphaned by raw-SQL note deletes', () async {
      await rawInsertNote('gone');
      await indexer.reindexNote('gone');
      expect(await chunksFor('gone'), isNotEmpty);

      final raw = await db.database;
      // Tombstone write: see the reindexNote case above — a real DELETE on
      // `notes` is refused by the M1.13 hard-delete guard.
      await raw.update('notes', {'__deleted__': 1}, where: "id = 'gone'");
      await indexer.backfillAll();
      expect(await chunksFor('gone'), isEmpty);
      expect(await noteState('gone'), isNull);
    });
  });

  group('debounce', () {
    test('rapid scheduleReindex calls coalesce into one run', () async {
      await rawInsertNote('n1');
      indexer.debugReindexRuns = 0;
      for (var i = 0; i < 5; i++) {
        indexer.scheduleReindex('n1');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Wait past the (rolling) debounce window, then drain the queue.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await indexer.flushPending();
      expect(indexer.debugReindexRuns, 1);
      expect(await chunksFor('n1'), isNotEmpty);
    });
  });

  group('FTS availability guard', () {
    test(
      'index is maintained without chunks_fts after the table is dropped',
      () async {
        expect(db.chunksFtsAvailable, isTrue);
        final raw = await db.database;
        await raw.execute('DROP TABLE chunks_fts');
        // Reopen: availability is probed in onOpen.
        await db.close();
        await db.database;
        expect(db.chunksFtsAvailable, isFalse);

        final note = buildNote('n1', content: twoSectionContent);
        await db.insertNote(note);
        await indexer.reindexNote('n1');
        expect(await chunksFor('n1'), isNotEmpty);
        expect((await noteState('n1'))!['status'], 'done');

        // Diff-update and removal also run cleanly without FTS.
        await db.updateNote(note.copyWith(content: 'changed body'));
        await indexer.reindexNote('n1');
        await indexer.removeNote('n1');
        expect(await chunksFor('n1'), isEmpty);
      },
    );
  });

  group('removeNote', () {
    test('deletes chunks, FTS rows, embeddings, and state', () async {
      final note = buildNote('n1');
      await db.insertNote(note);
      await indexer.reindexNote('n1');
      final raw = await db.database;
      final chunkId = (await chunksFor('n1')).first['id'] as int;
      await raw.insert('chunk_embeddings', {
        'chunkId': chunkId,
        'providerKey': 'test:model:4',
        'modality': 'text',
        'dims': 4,
        'vector': Uint8List.fromList([0, 0, 0, 0]),
        'contentHash': 'x',
      });

      await indexer.removeNote('n1');
      expect(await chunksFor('n1'), isEmpty);
      expect(await ftsRowsFor('n1'), isEmpty);
      expect(await raw.query('chunk_embeddings'), isEmpty);
      expect(await noteState('n1'), isNull);
    });
  });

  group('pause/resume', () {
    test(
      'paused indexer defers events; resume re-checks completeness',
      () async {
        await indexer.pause();
        await db.insertNote(buildNote('n1'));
        await indexer.flushPending();
        expect(
          await chunksFor('n1'),
          isEmpty,
          reason: 'no index write may happen while paused',
        );

        indexer.resume();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while ((await globalState())?['status'] != 'done') {
          if (DateTime.now().isAfter(deadline)) {
            fail('resume did not trigger a completeness backfill');
          }
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(await chunksFor('n1'), isNotEmpty);
      },
    );

    test('pause drains the queued index write before resolving', () async {
      await db.insertNote(buildNote('n1', content: twoSectionContent));
      // Queue a reindex directly on the serialized queue, but do not await
      // it: pause() must not resolve before this write has committed.
      final pending = indexer.reindexNote('n1');
      await indexer.pause();
      expect(
        await chunksFor('n1'),
        isNotEmpty,
        reason: 'pause() resolved before the queued write committed',
      );
      await pending;
    });

    test('note edits while paused are reindexed on resume', () async {
      final note = buildNote('n1', content: 'before pause content');
      await db.insertNote(note);
      await indexer.flushPending();
      await indexer.backfillAll();
      expect((await globalState())!['status'], 'done');

      await indexer.pause();
      await db.updateNote(note.copyWith(content: 'edited while paused'));
      await indexer.flushPending();
      expect(
        (await chunksFor('n1')).map((c) => c['text']).join(' '),
        contains('before pause content'),
        reason: 'no reindex may run while paused',
      );

      indexer.resume();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!(await chunksFor(
        'n1',
      )).map((c) => c['text']).join(' ').contains('edited while paused')) {
        if (DateTime.now().isAfter(deadline)) {
          fail('edit made while paused was never reindexed after resume');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });

    test('resume sweeps even when the global flag is already done', () async {
      await indexer.backfillAll();
      expect((await globalState())!['status'], 'done');

      await indexer.pause();
      // Raw write while paused: no hook, no capture event — only an
      // unconditional resume sweep can find it.
      await rawInsertNote('rawp');
      indexer.resume();

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((await chunksFor('rawp')).isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          fail('resume did not run a completeness sweep');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
  });

  group('tag operations', () {
    test(
      'deleteTag notifies every owning note and updates meta chunks',
      () async {
        await db.insertNote(buildNote('n1', tags: ['doomed', 'kept']));
        await db.insertNote(buildNote('n2', tags: ['doomed']));
        await indexer.flushPending();
        expect(
          (await chunksFor('n1')).map((c) => c['text']).join(' '),
          contains('doomed'),
        );

        final notified = <String>[];
        final original = db.onNoteContentChanged;
        db.onNoteContentChanged = (id) {
          notified.add(id);
          original?.call(id);
        };

        await db.deleteTag('doomed');
        expect(notified, containsAll(['n1', 'n2']));

        await indexer.flushPending();
        final n1Text = (await chunksFor('n1')).map((c) => c['text']).join(' ');
        expect(n1Text, isNot(contains('doomed')));
        expect(n1Text, contains('kept'));
        expect(
          (await chunksFor('n2')).map((c) => c['text']).join(' '),
          isNot(contains('doomed')),
        );
      },
    );

    test(
      'replaceTag notifies every owning note and updates meta chunks',
      () async {
        await db.insertNote(buildNote('n1', tags: ['oldtag']));
        await db.insertNote(buildNote('n2', tags: ['oldtag']));
        await indexer.flushPending();

        final notified = <String>[];
        final original = db.onNoteContentChanged;
        db.onNoteContentChanged = (id) {
          notified.add(id);
          original?.call(id);
        };

        await db.replaceTag('oldtag', 'newtag');
        expect(notified, containsAll(['n1', 'n2']));

        await indexer.flushPending();
        for (final noteId in ['n1', 'n2']) {
          final text = (await chunksFor(
            noteId,
          )).map((c) => c['text']).join(' ');
          expect(text, isNot(contains('oldtag')));
          expect(text, contains('newtag'));
        }
      },
    );
  });

  group('stale-snapshot guard', () {
    test(
      'a batch write from a stale snapshot is aborted, not applied',
      () async {
        await rawInsertNote('n1', content: 'stale snapshot body');
        final staleNote = (await db.getNote('n1'))!;
        // A backfill batch snapshots the note (and its state: none yet) ...
        final staleDrafts = chunkNote(staleNote);
        final staleNormalized = [
          for (final d in staleDrafts) normalizeForIndex(d.text),
        ];
        final staleFingerprint = noteContentFingerprint(staleNote, const []);

        // ... then a fresher debounced reindex lands first.
        final raw = await db.database;
        await raw.update('notes', {
          'content': 'fresh reindexed body',
        }, where: "id = 'n1'");
        await indexer.reindexNote('n1');
        final freshHash = (await noteState('n1'))!['contentHash'];

        // The stale batch write reaches the serialized queue AFTER the fresh
        // one: the in-transaction state re-check must turn it into a no-op.
        await indexer.debugWriteChunksGuarded(
          'n1',
          staleDrafts,
          staleNormalized,
          staleFingerprint,
          snapshotStateHash: null, // no state row existed at snapshot time
        );

        expect((await noteState('n1'))!['contentHash'], freshHash);
        final text = (await chunksFor('n1')).map((c) => c['text']).join(' ');
        expect(text, contains('fresh reindexed body'));
        expect(text, isNot(contains('stale snapshot body')));
      },
    );

    test('a matching snapshot lets the batch write proceed', () async {
      await rawInsertNote('n1', content: 'only version of the body');
      final note = (await db.getNote('n1'))!;
      final drafts = chunkNote(note);
      final normalized = [for (final d in drafts) normalizeForIndex(d.text)];
      await indexer.debugWriteChunksGuarded(
        'n1',
        drafts,
        normalized,
        noteContentFingerprint(note, const []),
        snapshotStateHash: null,
      );
      expect(await chunksFor('n1'), isNotEmpty);
      expect((await noteState('n1'))!['status'], 'done');
    });
  });

  group('backfill deferral', () {
    test(
      'a note with a pending debounced edit does not count as done',
      () async {
        // Long debounce so the pending timer cannot fire mid-backfill.
        indexer.dispose();
        indexer = NoteIndexService(
          db,
          changeNotifier: notifier,
          debounceDelay: const Duration(seconds: 30),
          ocrExtractor: stubOcrExtractor(db),
          figureExtractor: stubFigureExtractor(),
        );
        await rawInsertNote('n1');
        indexer.scheduleReindex('n1');

        await indexer.backfillAll();
        expect(
          await globalState(),
          isNull,
          reason: 'a deferred note must keep the global flag unset',
        );
        expect(
          await chunksFor('n1'),
          isEmpty,
          reason: 'the pending debounced reindex owns the note',
        );
        expect(
          await noteState('n1'),
          isNull,
          reason: 'deferral must leave the note state untouched',
        );

        // Once the fresher write lands, completeness is achievable again.
        await indexer.flushPending();
        expect(await chunksFor('n1'), isNotEmpty);
        await indexer.backfillAll();
        expect((await globalState())!['status'], 'done');
      },
    );

    test('deferred backfill still converges to a complete index', () async {
      await rawInsertNote('n1');
      indexer.scheduleReindex('n1');
      await indexer.backfillAll();

      // Whether the timer fired mid-run or the note was deferred, the
      // debounced write plus the follow-up completeness check converge.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((await globalState())?['status'] != 'done' ||
          (await chunksFor('n1')).isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          fail('deferred backfill never converged to a complete index');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
  });

  group('forced backfill latch', () {
    test(
      'force during a running backfill runs a forced pass afterwards',
      () async {
        await rawInsertNote('a');
        await indexer.reindexNote('a');
        final raw = await db.database;
        await raw.update('search_index_state', {
          'updatedAt': 1,
        }, where: "scopeType = 'note'");

        final first = indexer.backfillAll(); // in flight, would skip 'a'
        final forced = indexer.backfillAll(force: true);
        expect(
          identical(forced, first),
          isFalse,
          reason: 'a force request must not degrade to the running pass',
        );

        await forced;
        // The forced pass re-verified 'a': its state row was rewritten.
        expect((await noteState('a'))!['updatedAt'], isNot(1));
        expect((await globalState())!['status'], 'done');
        await first;
      },
    );
  });

  group('backfill batching', () {
    test('planBackfillBatches enforces note cap and byte budget', () {
      final tinyIds = List.generate(120, (i) => 'n$i');
      final tinyLengths = {for (final id in tinyIds) id: 10};
      expect(
        NoteIndexService.planBackfillBatches(
          tinyIds,
          tinyLengths,
        ).map((b) => b.length),
        [50, 50, 20],
      );

      // 3 notes of ~1.5MB: a 2MB budget forces one note per batch, so 50
      // such notes can never be chunked in a single compute() call.
      final bigIds = ['a', 'b', 'c'];
      final bigLengths = {for (final id in bigIds) id: 1500 * 1024};
      expect(NoteIndexService.planBackfillBatches(bigIds, bigLengths), [
        ['a'],
        ['b'],
        ['c'],
      ]);

      // A single note over the whole budget still gets a batch.
      expect(
        NoteIndexService.planBackfillBatches(
          ['huge'],
          {'huge': 5 * 1024 * 1024},
        ),
        [
          ['huge'],
        ],
      );
    });

    test('completeness sweep skips chunking for up-to-date notes', () async {
      await rawInsertNote('a');
      await rawInsertNote('b');
      await indexer.backfillAll();
      expect(indexer.debugBackfillNotesChunked, 2);

      indexer.debugBackfillNotesChunked = 0;
      await indexer.backfillAll();
      expect(
        indexer.debugBackfillNotesChunked,
        0,
        reason: 'up-to-date notes must be skipped before chunking',
      );
    });
  });

  group('attachment metadata', () {
    test('lastViewedPage-only updates do not trigger reindex', () async {
      final note = Note(
        id: 'n1',
        title: 'With attachment',
        content: 'body',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        attachmentPaths: ['attachments/doc.pdf'],
      );
      await db.insertNote(note);
      await indexer.flushPending();
      final attachment = (await db.getAttachmentsForNote('n1')).single;

      final notified = <String>[];
      final original = db.onNoteContentChanged;
      db.onNoteContentChanged = (id) {
        notified.add(id);
        original?.call(id);
      };

      await db.updateLastViewedPage(attachment.id, 7);
      await db.updateLastViewedPage(attachment.id, 9);
      expect(
        notified,
        isEmpty,
        reason: 'page views must not trigger re-chunking',
      );

      await db.updateAttachmentMetadata(attachment.id, {
        'lastViewedPage': 9,
        'ocrDone': true,
      });
      expect(notified, [
        'n1',
      ], reason: 'a real metadata change must still notify');
    });
  });

  group('pdf_text stage', () {
    late Directory pdfDir;

    /// Text pages served by the fake opener, keyed by absolute file path.
    final pagesByPath = <String, List<String>>{};
    final openedSources = <_RecordingPdfSource>[];
    var openCalls = 0;

    setUp(() async {
      pdfDir = await Directory.systemTemp.createTemp('pdf_stage');
      pagesByPath.clear();
      openedSources.clear();
      openCalls = 0;
    });

    tearDown(() async {
      await pdfDir.delete(recursive: true);
    });

    /// Replaces the default indexer with one whose extractor uses the fake
    /// opener (pdfrx cannot run headless in flutter test).
    ///
    /// [pageCapLoader] overrides the fixed [pageCap] where a test needs the
    /// cap to move (or to fail) during a run; [figuresEnabledLoader]
    /// overrides the figure-switch seam (null keeps the production one).
    NoteIndexService makePdfIndexer({
      int pageCap = 100,
      Future<int> Function()? pageCapLoader,
      Future<bool> Function()? figuresEnabledLoader,
      Future<String> Function(String path)? loadOverride,
    }) {
      indexer.dispose();
      indexer = NoteIndexService(
        db,
        changeNotifier: notifier,
        debounceDelay: const Duration(milliseconds: 50),
        ocrExtractor: stubOcrExtractor(db),
        figureExtractor: stubFigureExtractor(),
        figuresEnabledLoader: figuresEnabledLoader,
        extractor: AttachmentTextExtractor(
          db,
          opener: (path) async {
            openCalls++;
            final source = _RecordingPdfSource(
              pagesByPath[path] ?? const [],
              loadOverride == null ? null : (i) => loadOverride(path),
            );
            openedSources.add(source);
            return source;
          },
          pageCapLoader: pageCapLoader ?? () async => pageCap,
        ),
      );
      return indexer;
    }

    /// Creates the backing file and the attachments row (raw insert, so no
    /// hook fires — tests drive reindex explicitly for determinism).
    Future<String> insertPdfAttachment(
      String id,
      String noteId,
      List<String> pages, {
      Map<String, dynamic>? metadata,
    }) async {
      final file = File('${pdfDir.path}/$id.pdf');
      await file.writeAsString('backing bytes for $id');
      pagesByPath[file.path] = pages;
      final raw = await db.database;
      await raw.insert('attachments', {
        'id': id,
        'noteId': noteId,
        'filePath': file.path,
        'fileName': '$id.pdf',
        'fileType': 'pdf',
        'isRelativePath': 0,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'includeInAIContext': 1,
        'metadata': metadata == null ? null : jsonEncode(metadata),
      });
      return file.path;
    }

    Future<List<Map<String, dynamic>>> attachmentChunks(String attId) async {
      final raw = await db.database;
      return raw.query(
        'search_chunks',
        where: "sourceType = 'attachment_text' AND sourceId = ?",
        whereArgs: [attId],
        orderBy: 'seq',
      );
    }

    Future<Map<String, dynamic>?> attachmentState(String attId) async {
      final raw = await db.database;
      final rows = await raw.query(
        'search_index_state',
        where:
            "scopeType = 'attachment' AND scopeId = ? AND stage = 'pdf_text'",
        whereArgs: [attId],
      );
      return rows.isEmpty ? null : rows.first;
    }

    Future<Map<String, dynamic>?> globalStageState(String stage) async {
      final raw = await db.database;
      final rows = await raw.query(
        'search_index_state',
        where: "scopeType = 'global' AND scopeId = 'all' AND stage = ?",
        whereArgs: [stage],
      );
      return rows.isEmpty ? null : rows.first;
    }

    test(
      'end-to-end: PDF page text searchable with page deep-link info',
      () async {
        makePdfIndexer();
        await db.insertNote(buildNote('n1', content: 'note body here'));
        await insertPdfAttachment('a1', 'n1', [
          'First page about axolotl regeneration.',
          'Second page mentions bioluminescent plankton.',
        ]);
        await indexer.flushPending();
        await indexer.backfillAll();

        final chunks = await attachmentChunks('a1');
        expect(chunks, hasLength(2));
        expect(chunks[0]['page'], 1);
        expect(chunks[1]['page'], 2);
        expect(chunks[1]['chunkKey'], 'n1:attachment_text:a1:1000');

        final state = await attachmentState('a1');
        expect(state!['status'], 'done');
        expect(await globalStageState('pdf_text'), isNotNull);

        final search = SearchService(
          db,
          indexer,
          notesProvider: () => db.getAllNotes(),
        );
        final response = await search.searchLexical('plankton');
        expect(response.usedSubstringFallback, isFalse);
        final result = response.results.single;
        expect(result.noteId, 'n1');
        expect(result.best.sourceType, 'attachment_text');
        expect(result.attachmentId, 'a1');
        expect(result.page, 2, reason: 'deep link must carry the 1-based page');
      },
    );

    test('note reindex leaves attachment chunks intact', () async {
      makePdfIndexer();
      await db.insertNote(buildNote('n1', content: 'original body'));
      await insertPdfAttachment('a1', 'n1', ['pdf page text']);
      await indexer.reindexNote('n1');
      await indexer.flushPending();
      expect(await attachmentChunks('a1'), hasLength(1));

      final raw = await db.database;
      await raw.update(
        'notes',
        {'content': 'completely new body'},
        where: 'id = ?',
        whereArgs: ['n1'],
      );
      await indexer.reindexNote('n1');
      await indexer.flushPending();

      expect(
        await attachmentChunks('a1'),
        hasLength(1),
        reason:
            'the note chunk diff must not treat attachment chunks '
            'as stale',
      );
      // And unchanged attachment state means no re-extraction either.
      expect(openCalls, 1);
    });

    test('attachment deletion removes its chunks and state', () async {
      makePdfIndexer();
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment('a1', 'n1', ['page text here']);
      await indexer.reindexNote('n1');
      await indexer.flushPending();
      expect(await attachmentChunks('a1'), hasLength(1));

      final raw = await db.database;
      // Tombstone write: `attachments` is hard-delete-guarded (M1.13), so
      // this is how an attachment actually goes away.
      await raw.update(
        'attachments',
        {'__deleted__': 1},
        where: 'id = ?',
        whereArgs: ['a1'],
      );
      await indexer.reindexNote('n1');
      await indexer.flushPending();

      expect(await attachmentChunks('a1'), isEmpty);
      expect(await attachmentState('a1'), isNull);
    });

    test('over-cap PDF: distinct skip state by default, extracted when '
        'explicitly on', () async {
      makePdfIndexer(pageCap: 100);
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment(
        'a1',
        'n1',
        List.generate(120, (i) => 'tiny page ${i + 1}'),
      );
      await indexer.reindexNote('n1');
      await indexer.flushPending();

      expect(await attachmentChunks('a1'), isEmpty);
      final skipped = await attachmentState('a1');
      expect(
        skipped!['status'],
        'skipped_too_large',
        reason: 'distinct state so settings can list large skipped PDFs',
      );

      // Explicit opt-in (the attach-time prompt writes text: on).
      final raw = await db.database;
      await raw.update(
        'attachments',
        {
          'metadata': jsonEncode({
            'searchIndex': {'text': 'on'},
          }),
        },
        where: 'id = ?',
        whereArgs: ['a1'],
      );
      await indexer.reindexNote('n1');
      await indexer.flushPending();

      expect(await attachmentChunks('a1'), hasLength(120));
      expect((await attachmentState('a1'))!['status'], 'done');

      // Cap changes never re-run an explicitly opted-in PDF: the cap cannot
      // bind when text == 'on'.
      final opensBefore = openCalls;
      makePdfIndexer(pageCap: 50);
      await indexer.reindexNote('n1');
      await indexer.flushPending();
      expect(
        openCalls,
        opensBefore,
        reason: 'text:on bypasses the cap, so a cap change is a no-op',
      );
      expect(await attachmentChunks('a1'), hasLength(120));
    });

    test(
      'excluded note purges attachment chunks; un-excluding re-extracts',
      () async {
        makePdfIndexer();
        await db.insertNote(buildNote('n1'));
        await insertPdfAttachment('a1', 'n1', ['searchable pdf text']);
        await indexer.reindexNote('n1');
        await indexer.flushPending();
        expect(await attachmentChunks('a1'), hasLength(1));

        await indexer.setNoteSearchExclusion('n1', true);
        await indexer.flushPending();
        expect(await attachmentChunks('a1'), isEmpty);
        expect((await attachmentState('a1'))!['status'], 'skipped');

        await indexer.setNoteSearchExclusion('n1', false);
        await indexer.flushPending();
        expect(
          await attachmentChunks('a1'),
          hasLength(1),
          reason: 'the ex= component of the state hash must force a re-run',
        );
        expect((await attachmentState('a1'))!['status'], 'done');
      },
    );

    test('pause aborts extraction between pages; resume re-runs it', () async {
      final firstPageStarted = Completer<void>();
      final firstPageGate = Completer<String>();
      var gated = true;
      makePdfIndexer(
        loadOverride: (path) {
          if (gated) {
            if (!firstPageStarted.isCompleted) firstPageStarted.complete();
            return firstPageGate.future;
          }
          return Future.value('page text after resume');
        },
      );
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment('a1', 'n1', ['page one', 'page two']);

      await indexer.reindexNote('n1'); // chunk txn done; pdf pass queued
      await firstPageStarted.future; // extraction is inside page 1
      final pausing = indexer.pause();
      firstPageGate.complete('page one text');
      await pausing;

      expect(
        openedSources.last.pageLoads,
        1,
        reason: 'pause must abort between pages, not mid-queue',
      );
      expect(
        await attachmentChunks('a1'),
        isEmpty,
        reason: 'aborted extraction writes nothing',
      );
      expect(await attachmentState('a1'), isNull);

      gated = false;
      indexer.resume();
      await indexer.backfillAll();
      expect(await attachmentChunks('a1'), hasLength(2));
      expect((await attachmentState('a1'))!['status'], 'done');
    });

    test('failed extraction never blocks chunks-stage completeness', () async {
      makePdfIndexer();
      await db.insertNote(buildNote('n1'));
      // Backing file is deliberately missing: extraction fails.
      final raw = await db.database;
      await raw.insert('attachments', {
        'id': 'a1',
        'noteId': 'n1',
        'filePath': '${pdfDir.path}/never_written.pdf',
        'fileName': 'never_written.pdf',
        'fileType': 'pdf',
        'isRelativePath': 0,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'includeInAIContext': 1,
      });
      await indexer.flushPending();
      await indexer.backfillAll();

      expect(
        (await globalStageState('chunks'))!['status'],
        'done',
        reason: 'phase-1 completeness is independent of pdf extraction',
      );
      expect((await attachmentState('a1'))!['status'], 'error');
      expect(await attachmentChunks('a1'), isEmpty);
    });

    test('unchanged file and policy skip re-extraction on sweeps', () async {
      makePdfIndexer();
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment('a1', 'n1', ['stable page text']);
      await indexer.flushPending();
      await indexer.backfillAll();
      expect(openCalls, 1);

      await indexer.backfillAll(force: false);
      expect(
        openCalls,
        1,
        reason: 'sweep must be stat-only for unchanged attachments',
      );
    });

    test('ensureBackfilled resumes an interrupted pdf_text pass', () async {
      makePdfIndexer();
      await db.insertNote(buildNote('n1'));
      await indexer.flushPending();
      await indexer.backfillAll();
      expect((await globalStageState('chunks'))!['status'], 'done');

      // Simulate an app killed mid-pdf-pass: the chunks global flag is done
      // (it is written BEFORE the pdf pass), but the pdf_text pass never
      // finished — no pdf_text global row, an attachment never visited.
      await insertPdfAttachment('a1', 'n1', ['page indexed after restart']);
      final raw = await db.database;
      await raw.delete('search_index_state', where: "stage = 'pdf_text'");
      expect(await globalStageState('pdf_text'), isNull);
      expect(await attachmentChunks('a1'), isEmpty);

      await indexer.ensureBackfilled();

      expect(
        await attachmentChunks('a1'),
        hasLength(1),
        reason:
            'ensureBackfilled must drive the pdf pass when the '
            'pdf_text global flag is absent, even with chunks done',
      );
      expect((await attachmentState('a1'))!['status'], 'done');
      expect((await globalStageState('pdf_text'))!['status'], 'done');
    });

    test('cap change re-runs only attachments it could affect', () async {
      makePdfIndexer(pageCap: 100);
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment('small', 'n1', ['page one', 'page two']);
      await insertPdfAttachment(
        'big',
        'n1',
        List.generate(120, (i) => 'tiny page ${i + 1}'),
      );
      await indexer.reindexNote('n1');
      await indexer.flushPending();
      expect(await attachmentChunks('small'), hasLength(2));
      expect((await attachmentState('big'))!['status'], 'skipped_too_large');
      final opensAfterFirst = openCalls;

      // Raise the cap: the skipped_too_large PDF is admitted; the done
      // 2-pager (pages recorded in its state hash) is untouched.
      makePdfIndexer(pageCap: 200);
      await indexer.reindexNote('n1');
      await indexer.flushPending();
      expect(
        await attachmentChunks('big'),
        hasLength(120),
        reason: 'a raised cap must re-run a skipped_too_large PDF',
      );
      expect((await attachmentState('big'))!['status'], 'done');
      expect(
        openCalls,
        opensAfterFirst + 1,
        reason:
            'a done 2-page PDF must NOT be re-extracted by a cap '
            'change that cannot affect it',
      );

      // Lower the cap below the big PDF's recorded page count: only the
      // now-over-cap document re-runs (and is purged); the 2-pager stays.
      final opensAfterSecond = openCalls;
      makePdfIndexer(pageCap: 50);
      await indexer.reindexNote('n1');
      await indexer.flushPending();
      expect((await attachmentState('big'))!['status'], 'skipped_too_large');
      expect(await attachmentChunks('big'), isEmpty);
      expect(await attachmentChunks('small'), hasLength(2));
      expect(openCalls, opensAfterSecond + 1);
    });

    test(
      'raw-SQL rename away from .pdf purges chunks and state on reindex',
      () async {
        makePdfIndexer();
        await db.insertNote(buildNote('n1'));
        await insertPdfAttachment('a1', 'n1', ['soon-orphaned pdf text']);
        await indexer.reindexNote('n1');
        await indexer.flushPending();
        expect(await attachmentChunks('a1'), hasLength(1));

        final raw = await db.database;
        await raw.update(
          'attachments',
          {'fileName': 'a1.txt', 'fileType': 'txt'},
          where: 'id = ?',
          whereArgs: ['a1'],
        );
        await indexer.reindexNote('n1');
        await indexer.flushPending();

        expect(
          await attachmentChunks('a1'),
          isEmpty,
          reason: 'a non-PDF attachment must not keep attachment_text rows',
        );
        expect(await attachmentState('a1'), isNull);
      },
    );

    // ── page-cap policy on the stage's global row ─────────────────────────
    //
    // The settings screen writes the cap and immediately kicks
    // ensureBackfilled(). A bare `done` global row short-circuits that sweep,
    // so the per-attachment hashes — which DO track the cap (see the
    // 'cap change re-runs only attachments it could affect' test above) —
    // never get compared, and raising the cap for a 512-page PDF does nothing
    // until a forced rebuild. The row therefore records the cap its pass ran
    // under, exactly like the ocr and figures rows record theirs.

    test(
      'the pdf_text global row records the cap its pass ran under',
      () async {
        makePdfIndexer(pageCap: 100);
        await db.insertNote(buildNote('n1'));
        await insertPdfAttachment('a1', 'n1', ['page one']);
        await indexer.flushPending();
        await indexer.backfillAll();
        expect((await globalStageState('pdf_text'))!['contentHash'], 'cap=100');

        makePdfIndexer(pageCap: 250);
        await indexer.backfillAll();
        expect(
          (await globalStageState('pdf_text'))!['contentHash'],
          'cap=250',
          reason: 'the completed pass must stamp the cap it actually used',
        );
      },
    );

    test(
      'a raised cap re-admits a skipped_too_large PDF on the next sweep',
      () async {
        makePdfIndexer(pageCap: 100);
        await db.insertNote(buildNote('n1'));
        await insertPdfAttachment(
          'big',
          'n1',
          List.generate(120, (i) => 'report page ${i + 1}'),
        );
        await indexer.flushPending();
        await indexer.backfillAll();
        expect((await attachmentState('big'))!['status'], 'skipped_too_large');
        expect(await attachmentChunks('big'), isEmpty);

        // Exactly what the settings screen does: store the cap, kick a sweep.
        makePdfIndexer(pageCap: 1000);
        await indexer.ensureBackfilled();

        expect(
          (await attachmentState('big'))!['status'],
          'done',
          reason: 'a raised cap must reach the index through a plain sweep',
        );
        expect(await attachmentChunks('big'), hasLength(120));
        expect(
          (await globalStageState('pdf_text'))!['contentHash'],
          'cap=1000',
        );
      },
    );

    test('a lowered cap re-skips a PDF that is now over it', () async {
      makePdfIndexer(pageCap: 200);
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment(
        'big',
        'n1',
        List.generate(120, (i) => 'report page ${i + 1}'),
      );
      await indexer.flushPending();
      await indexer.backfillAll();
      expect((await attachmentState('big'))!['status'], 'done');
      expect(await attachmentChunks('big'), hasLength(120));

      makePdfIndexer(pageCap: 50);
      await indexer.ensureBackfilled();

      expect((await attachmentState('big'))!['status'], 'skipped_too_large');
      expect(
        await attachmentChunks('big'),
        isEmpty,
        reason: 'a document the user put back out of scope leaves the index',
      );
    });

    test('an unchanged cap re-runs no pdf_text work', () async {
      makePdfIndexer(pageCap: 100);
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment('a1', 'n1', ['stable page text']);
      await indexer.flushPending();
      await indexer.backfillAll();
      final opensAfterFirst = openCalls;

      // A raw-SQL attachment insert fires no hook, so only a pass that
      // actually runs can pick it up: it makes "swept again" observable, the
      // redundant work a policy-aware completeness check must avoid.
      await insertPdfAttachment('a2', 'n1', ['left for a later sweep']);
      await indexer.ensureBackfilled();

      expect(openCalls, opensAfterFirst, reason: 'no re-extraction');
      expect(
        await attachmentChunks('a2'),
        isEmpty,
        reason: 'an unchanged policy must leave the completed stage alone',
      );
    });

    test('a cap change landing mid-sweep is not lost', () async {
      // The hash is captured BEFORE the pass and written after it, so a cap
      // that changes while a sweep runs leaves a row that no longer matches.
      // Without that, the sweep certifies pdf_text complete under a cap its
      // pass never used — and since the stages after it DID read the new cap,
      // every other completeness check passes too and the over-cap PDF stays
      // skipped until a forced rebuild.
      var cap = 100;
      var armed = false;
      makePdfIndexer(
        pageCapLoader: () async => cap,
        // The figures pass reads its own policy AFTER the pdf_text pass has
        // finished, so flipping the cap from this seam lands the settings
        // write precisely in that window.
        figuresEnabledLoader: () async {
          if (armed) cap = 1000;
          return true;
        },
      );
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment(
        'big',
        'n1',
        List.generate(120, (i) => 'report page ${i + 1}'),
      );
      await indexer.flushPending();
      await indexer.backfillAll();
      expect((await attachmentState('big'))!['status'], 'skipped_too_large');

      armed = true;
      await indexer.backfillAll();
      expect(cap, 1000, reason: 'the cap moved after the pdf_text pass');
      expect((await attachmentState('big'))!['status'], 'skipped_too_large');

      await indexer.ensureBackfilled();

      expect(
        (await attachmentState('big'))!['status'],
        'done',
        reason:
            'only the stage\'s own row remembers which cap its pass ran '
            'under',
      );
      expect(await attachmentChunks('big'), hasLength(120));
    });

    test('an unreadable page-cap setting degrades to the default', () async {
      // SharedPreferences has no platform channel under flutter_tester, and
      // the policy hash is read on EVERY sweep — before the stage holds a
      // single eligible attachment, and in databases with no attachments at
      // all. The seam must fall back to the documented default instead of
      // aborting the whole sweep.
      makePdfIndexer(
        pageCapLoader: () async =>
            throw StateError('Binding has not yet been initialized.'),
      );
      await db.insertNote(buildNote('n1'));
      await indexer.flushPending();
      await indexer.backfillAll();

      expect(
        (await globalStageState('pdf_text'))!['contentHash'],
        'cap=${SearchSettingsService.defaultPdfPageCap}',
      );
      // The completeness check reads it again and must not throw either.
      await indexer.ensureBackfilled();
      expect((await globalStageState('chunks'))!['status'], 'done');
    });

    test('backfill sweep purges non-PDF attachment_text rows', () async {
      makePdfIndexer();
      await db.insertNote(buildNote('n1'));
      await insertPdfAttachment('a1', 'n1', ['soon-orphaned pdf text']);
      await indexer.reindexNote('n1');
      await indexer.flushPending();
      expect(await attachmentChunks('a1'), hasLength(1));

      final raw = await db.database;
      await raw.update(
        'attachments',
        {'fileName': 'a1.txt', 'fileType': 'txt'},
        where: 'id = ?',
        whereArgs: ['a1'],
      );
      await indexer.backfillAll();

      expect(await attachmentChunks('a1'), isEmpty);
      expect(await attachmentState('a1'), isNull);
    });
  });
}

class _RecordingPdfSource implements PdfTextSource {
  _RecordingPdfSource(this.pages, this.loadOverride);

  final List<String> pages;
  final Future<String> Function(int pageIndex)? loadOverride;
  bool disposed = false;
  int pageLoads = 0;

  @override
  int get pageCount => pages.length;

  @override
  Future<String> loadPageText(int pageIndex) {
    pageLoads++;
    final override = loadOverride;
    if (override != null) return override(pageIndex);
    return Future.value(pages[pageIndex]);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
