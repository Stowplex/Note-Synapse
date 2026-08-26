// What a sync round ANNOUNCES — `lib/services/sync/sync_change_publisher.dart`
// plus its collection points in `materializer.dart`/`pull_phase.dart`/
// `blob_sync.dart`.
//
// The defect these cover: materialization writes `notes`/`attachments`/... rows
// with `txn.insert`/`txn.update`/`txn.delete` directly (§ 11.6(c), deliberate —
// `updateNote`/`_persistNote` would diff-and-reinsert `subnotes`/`note_tags` on
// every single-field write), so `DatabaseService`'s `onNoteContentChanged`/
// `onNoteDeleted` hooks never fire for pulled content and nothing published a
// `DataChangeEvent` either. A note edited on device A and pulled on device B
// was never chunked, never OCR'd, never embedded, and the note list never
// refreshed.
//
// Driven through real `SyncSession.run()` calls against a shared
// `MockSyncBackend` — the harness `materializer_test.dart`/`sync_session_test
// .dart` established — with a real `NoteIndexService` subscribed on the
// receiving device, so what is asserted is the actual end state of
// `search_chunks`/`chunk_embeddings`/`attachments/derived/`, not a mock
// interaction.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:note_synapse/services/sync/sync_change_publisher.dart';
import 'package:note_synapse/services/sync/sync_session.dart';
import 'package:note_synapse/utils/file_utils.dart';

import '../search/ocr_test_stubs.dart';
import '../sync_backend/mock_sync_backend.dart';

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProviderPlatform(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// One simulated device: its own database, its own notifier (so two devices
/// in one process never share an event bus), and its own `SyncSession`.
class _SimDevice {
  _SimDevice() : databaseService = DatabaseService.createNew() {
    session = SyncSession(databaseService, changeNotifier: notifier);
    notifier.addListener((event) async => events.add(event));
  }

  final DatabaseService databaseService;
  final DataChangeNotifier notifier = DataChangeNotifier();
  final List<DataChangeEvent> events = [];
  late final SyncSession session;
  NoteIndexService? indexer;

  Future<Database> get db => databaseService.database;

  /// Runs a sync round and lets every published event finish dispatching.
  Future<void> sync(MockSyncBackend backend) async {
    await session.run(backend);
    await notifier.waitForIdle();
  }

  Future<void> close() async {
    indexer?.dispose();
    await databaseService.close();
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late MockSyncBackend backend;
  late _SimDevice deviceA;
  late _SimDevice deviceB;
  late Directory docsDir;
  late Directory derivedDir;

  setUp(() async {
    docsDir = await Directory.systemTemp.createTemp('sync_change_publish');
    derivedDir = Directory('${docsDir.path}/attachments/derived');
    await derivedDir.create(recursive: true);
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
    FileUtils.resetDocumentsPathCache();
    backend = MockSyncBackend();
    deviceA = _SimDevice();
    deviceB = _SimDevice();
  });

  tearDown(() async {
    await deviceA.close();
    await deviceB.close();
    FileUtils.resetDocumentsPathCache();
    if (await docsDir.exists()) await docsDir.delete(recursive: true);
  });

  /// Subscribes a real indexer to [device]'s notifier, exactly as
  /// `service_locator.dart` does in production.
  NoteIndexService attachIndexer(_SimDevice device) {
    final indexer = NoteIndexService(
      device.databaseService,
      changeNotifier: device.notifier,
      debounceDelay: const Duration(milliseconds: 5),
      ocrExtractor: stubOcrExtractor(device.databaseService),
      figureExtractor: stubFigureExtractor(),
      figuresEnabledLoader: () async => false,
      derivedFigureDirLoader: () async => derivedDir,
    );
    device.indexer = indexer;
    return indexer;
  }

  Future<void> insertNote(
    Database db,
    String id, {
    String title = 'Title',
    String content = 'Body',
  }) {
    return db.insert('notes', {
      'id': id,
      'title': title,
      'content': content,
      'type': 'note',
      'createdAt': 1000,
      'updatedAt': 1000,
    });
  }

  Future<List<Map<String, Object?>>> chunksFor(Database db, String noteId) {
    return db.query('search_chunks', where: 'noteId = ?', whereArgs: [noteId]);
  }

  group('a pulled edit reaches the search index', () {
    test('a note materialized by a pull is chunked on the receiving device, '
        'via a published DataChangeEvent', () async {
      final dbA = await deviceA.db;
      final dbB = await deviceB.db;
      final indexerB = attachIndexer(deviceB);

      await insertNote(
        dbA,
        'n1',
        title: 'Quarterly report',
        content: 'Revenue grew by twelve percent.',
      );

      await deviceA.sync(backend);
      expect(
        await chunksFor(dbB, 'n1'),
        isEmpty,
        reason: 'B has pulled nothing yet',
      );

      await deviceB.sync(backend);
      await indexerB.flushPending();

      // The row really did materialize (the pre-existing behaviour)…
      expect(
        (await dbB.query('notes', where: 'id = ?', whereArgs: ['n1'])).single,
        containsPair('title', 'Quarterly report'),
      );
      // …and the note is now in the index, which it never was before.
      final chunks = await chunksFor(dbB, 'n1');
      expect(chunks, isNotEmpty);
      expect(
        chunks.map((c) => c['text'] as String).join(' '),
        allOf(contains('Quarterly report'), contains('Revenue grew')),
      );

      // The mechanism, not just the outcome: exactly one round-scoped event
      // naming the note, and no `bulk` degradation for a one-note pull.
      final events = deviceB.events.where((e) => !e.isEmpty).toList();
      expect(events, hasLength(1));
      expect(events.single.noteIds, contains('n1'));
      expect(events.single.bulk, isFalse);
    });

    test('a subnote/tag write announces the OWNING note, not its own row id',
        () async {
      final dbA = await deviceA.db;
      final dbB = await deviceB.db;

      await insertNote(dbA, 'n1');
      await dbA.insert('subnotes', {
        'id': 'sub1',
        'noteId': 'n1',
        'name': 'A child idea',
        'content': 'a child idea',
        'isCompleted': 0,
        'createdAt': 1000,
      });
      await dbA.insert('tags', {
        'id': 't1',
        'name': 'work',
        'color': '#fff',
        'createdAt': 1000,
      });
      await dbA.insert('note_tags', {'noteId': 'n1', 'tagId': 't1'});

      await deviceA.sync(backend);
      await deviceB.sync(backend);

      expect(
        (await dbB.query('subnotes', where: 'id = ?', whereArgs: ['sub1'])),
        hasLength(1),
        reason: 'precondition: the subnote really materialized',
      );
      final merged = deviceB.events.reduce((a, b) => a.merge(b));
      expect(
        merged.noteIds,
        contains('n1'),
        reason: 'a subnote row and a note_tags membership both belong to n1',
      );
      expect(merged.noteIds, isNot(contains('sub1')));
      expect(merged.tagsChanged, isTrue);
    });

    test('a tombstoned note purges its chunks, embeddings and derived crops',
        () async {
      final dbA = await deviceA.db;
      final dbB = await deviceB.db;
      final indexerB = attachIndexer(deviceB);

      await insertNote(dbA, 'n1', content: 'Something worth indexing.');
      await deviceA.sync(backend);
      await deviceB.sync(backend);
      await indexerB.flushPending();
      expect(await chunksFor(dbB, 'n1'), isNotEmpty);

      // Hang the two derived artefacts a real indexed note would have off
      // n1: an embedding on one of its chunks, and a figure chunk whose
      // derived crop sits on disk.
      final chunkId = (await chunksFor(dbB, 'n1')).first['id'] as int;
      await dbB.insert('chunk_embeddings', {
        'chunkId': chunkId,
        'providerKey': 'test:model:4',
        'modality': 'text',
        'dims': 4,
        'vector': Uint8List.fromList([0, 0, 0, 0]),
        'contentHash': 'h',
      });
      await dbB.insert('search_chunks', {
        'chunkKey': 'n1:figure:att1:0',
        'noteId': 'n1',
        'sourceType': 'figure',
        'sourceId': 'att1',
        'seq': 0,
        'text': 'Figure 1',
        'contentHash': 'h',
        'updatedAt': 1,
      });
      final crop = File('${derivedDir.path}/att1_p1_f0.png');
      await crop.writeAsBytes([1, 2, 3]);

      // The tombstone: exactly what `deleteNote` writes, propagated as an
      // ordinary `notes.__deleted__` field operation.
      await dbA.update(
        'notes',
        {'__deleted__': 1},
        where: 'id = ?',
        whereArgs: ['n1'],
      );
      await deviceA.sync(backend);
      deviceB.events.clear();
      await deviceB.sync(backend);
      await indexerB.flushPending();

      expect(
        (await dbB.query('notes', where: 'id = ?', whereArgs: ['n1']))
            .single['__deleted__'],
        1,
        reason: 'precondition: the tombstone materialized on B',
      );
      expect(
        deviceB.events.single.noteIds,
        contains('n1'),
        reason: 'a deletion is announced exactly like an edit; the indexer '
            'resolves a missing/__deleted__ note into a removal',
      );
      expect(await chunksFor(dbB, 'n1'), isEmpty);
      expect(
        await dbB.query(
          'chunk_embeddings',
          where: 'chunkId = ?',
          whereArgs: [chunkId],
        ),
        isEmpty,
      );
      expect(await crop.exists(), isFalse);
    });

    test('an attachment whose FILE arrives in Phase C is announced too',
        () async {
      // The row arrives in Phase B naming a file this device does not have
      // yet; the bytes land in Phase C with nothing else left in the round to
      // notice, so the blob phase publishes on its own account.
      final dbA = await deviceA.db;
      final file = File('${docsDir.path}/attachments/report.pdf');
      await file.parent.create(recursive: true);
      await file.writeAsString('%PDF-1.4 pretend bytes');

      await insertNote(dbA, 'n1');
      await dbA.insert('attachments', {
        'id': 'att1',
        'noteId': 'n1',
        'filePath': 'attachments/report.pdf',
        'fileName': 'report.pdf',
        'fileType': 'pdf',
        'isRelativePath': 1,
        'createdAt': 1000,
      });

      await deviceA.sync(backend); // uploads the blob in Phase A
      // B pulls the row (Phase B) and the bytes (Phase C) in one round; the
      // file lands under B's own documents dir, which is this test's shared
      // temp dir, so delete it first to make the download real.
      await file.delete();
      await deviceB.sync(backend);

      expect(
        await file.exists(),
        isTrue,
        reason: 'precondition: Phase C downloaded the attachment bytes',
      );
      expect(
        deviceB.events.where((e) => e.noteIds.contains('n1')).length,
        greaterThanOrEqualTo(2),
        reason: 'one announcement for the pulled rows, a second for the '
            'arriving file — the second is what lets pdf_text/ocr/figures '
            'run against a file that exists',
      );
    });
  });

  group('cost and no-op discipline', () {
    test('a re-applied log announces nothing at all', () async {
      final dbA = await deviceA.db;
      final dbB = await deviceB.db;

      await insertNote(dbA, 'n1');
      await dbA.insert('tags', {
        'id': 't1',
        'name': 'work',
        'color': '#fff',
        'createdAt': 1000,
      });
      await dbA.insert('note_tags', {'noteId': 'n1', 'tagId': 't1'});
      await deviceA.sync(backend);
      await deviceB.sync(backend);
      expect(deviceB.events, isNotEmpty);

      // Rewind B's view of every remote log and pull the identical commits
      // again. `CausalEngine.apply` returns null for an idempotent re-apply
      // and `winnerChanged: false` for an unchanged winner; `__exists__`
      // reports `alreadyPresent` and a duplicate `set_add` `alreadyLive`.
      // Every one of those is a no-op that must announce nothing.
      await dbB.delete('sync_state', where: "key LIKE 'frontier:%'");
      await dbB.delete('sync_state', where: "key LIKE 'pull_tip:%'");
      deviceB.events.clear();

      await deviceB.sync(backend);

      expect(
        deviceB.events,
        isEmpty,
        reason: 'nothing was written, so nothing may be announced — a '
            'spurious event costs a full AppProvider reload and an index '
            'sweep every sync round',
      );
    });

    test('an ordinary sync round with no new commits announces nothing',
        () async {
      await insertNote(await deviceA.db, 'n1');
      await deviceA.sync(backend);
      await deviceB.sync(backend);
      deviceB.events.clear();

      await deviceB.sync(backend);
      expect(deviceB.events, isEmpty);
    });

    test('past the targeted-refresh ceiling a pull degrades to one bulk event',
        () async {
      final publisher = SyncChangePublisher(changeNotifier: deviceB.notifier);
      final db = await deviceB.db;

      final atCeiling = SyncChangeCollector();
      for (var i = 0; i < DataChangeEvent.maxTargetedNoteIds; i++) {
        atCeiling.recordRow('notes', 'n$i');
      }
      final targeted = await publisher.buildEvent(db, atCeiling);
      expect(targeted.bulk, isFalse);
      expect(targeted.noteIds, hasLength(DataChangeEvent.maxTargetedNoteIds));

      final overCeiling = SyncChangeCollector();
      for (var i = 0; i <= DataChangeEvent.maxTargetedNoteIds; i++) {
        overCeiling.recordRow('notes', 'n$i');
      }
      final bulk = await publisher.buildEvent(db, overCeiling);
      expect(bulk.bulk, isTrue);
      expect(
        bulk.noteIds,
        isEmpty,
        reason: 'a bulk event carries no ids: the consumer reloads/sweeps '
            'rather than refetching each one under the cache lock',
      );
    });

    test('a first sync of a large library publishes bulk, not one id per note',
        () async {
      final dbA = await deviceA.db;
      for (var i = 0; i <= DataChangeEvent.maxTargetedNoteIds; i++) {
        await insertNote(dbA, 'n$i');
      }
      await deviceA.sync(backend);
      await deviceB.sync(backend);

      expect(
        (await (await deviceB.db).query('notes')).length,
        greaterThan(DataChangeEvent.maxTargetedNoteIds),
        reason: 'precondition: the whole library materialized on B',
      );
      final merged = deviceB.events.reduce((a, b) => a.merge(b));
      expect(merged.bulk, isTrue);
      expect(merged.noteIds, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('table classification', () {
    test('every table this engine can materialize is explicitly classified',
        () async {
      final unclassified = <String>[];
      for (final scope in DatabaseService.syncEntityCaptureScopes) {
        if (!syncChangeScopeByTable.containsKey(scope.table)) {
          unclassified.add(scope.table);
        }
      }
      for (final scope in DatabaseService.syncSetCaptureScopes) {
        // Membership rows are recorded against their OWNING entity table.
        if (!syncChangeScopeByTable.containsKey(scope.entityTable)) {
          unclassified.add('${scope.membershipTable} -> ${scope.entityTable}');
        }
      }
      expect(
        unclassified,
        isEmpty,
        reason: 'a table joined sync scope without a decision in '
            'syncChangeScopeByTable. Classify it: note-domain tables map to '
            'note ids, everything else is SyncChangeScope.none. Leaving it '
            'out degrades every sync round that touches it to a full reload '
            'plus a full index sweep.',
      );
    });

    test('an unclassified table degrades to bulk rather than to silence', () {
      final changes = SyncChangeCollector()..recordRow('some_future_table', 'x');
      expect(changes.bulk, isTrue);
    });

    test('a deliberately note-irrelevant table announces nothing', () {
      final changes = SyncChangeCollector()
        ..recordRow('conversations', 'c1')
        ..recordRow('user_apps', 'a1');
      expect(changes.isEmpty, isTrue);
    });

    test('a tag write refreshes the notes carrying it, whose meta chunk '
        'embeds the tag NAME', () async {
      final db = await deviceB.db;
      await insertNote(db, 'n1');
      await db.insert('tags', {
        'id': 't1',
        'name': 'work',
        'color': '#fff',
        'createdAt': 1000,
      });
      await db.insert('note_tags', {'noteId': 'n1', 'tagId': 't1'});

      final event = await SyncChangePublisher(
        changeNotifier: deviceB.notifier,
      ).buildEvent(db, SyncChangeCollector()..recordRow('tags', 't1'));

      expect(event.tagsChanged, isTrue);
      expect(event.noteIds, contains('n1'));
    });

    test('a relationship write reports its endpoints as relationship ids',
        () async {
      final db = await deviceB.db;
      await insertNote(db, 'n1');
      await insertNote(db, 'n2');
      await db.insert('relationships', {
        'id': 'r1',
        'fromNoteId': 'n1',
        'toNoteId': 'n2',
        'type': 'related',
        'createdAt': 1,
      });

      final event = await SyncChangePublisher(
        changeNotifier: deviceB.notifier,
      ).buildEvent(db, SyncChangeCollector()..recordRow('relationships', 'r1'));

      expect(event.relationshipNoteIds, {'n1', 'n2'});
      expect(
        event.noteIds,
        isEmpty,
        reason: 'a relationship does not change either note\'s own content',
      );
    });

    test('an annotation resolves through its note or its attachment',
        () async {
      final db = await deviceB.db;
      await insertNote(db, 'n1');
      await insertNote(db, 'n2');
      await db.insert('attachments', {
        'id': 'att1',
        'noteId': 'n2',
        'filePath': 'attachments/a.pdf',
        'fileName': 'a.pdf',
        'fileType': 'pdf',
        'isRelativePath': 1,
        'createdAt': 1,
      });
      await db.insert('note_annotations', {
        'id': 'an1',
        'note_id': 'n1',
        'content': 'note-scoped',
        'created_at': '2026-01-01',
      });
      await db.insert('note_annotations', {
        'id': 'an2',
        'attachment_id': 'att1',
        'content': 'attachment-scoped',
        'created_at': '2026-01-01',
      });

      final event = await SyncChangePublisher(
        changeNotifier: deviceB.notifier,
      ).buildEvent(
        db,
        SyncChangeCollector()
          ..recordRow('note_annotations', 'an1')
          ..recordRow('note_annotations', 'an2'),
      );

      expect(event.noteIds, {'n1', 'n2'});
    });
  });
}
