// The layered-search index is DERIVED data and must never enter the sync
// protocol — neither its tables nor the figure crops it renders to disk.
//
// **Why this is a decision worth pinning rather than an accident.**
// `search_chunks`/`chunks_fts`/`chunk_embeddings`/`search_index_state` are
// regenerable from `notes`/`attachments` by `NoteIndexService`, they are large
// (`search_chunks.text` holds raw chunk text; `chunk_embeddings.vector` holds
// a float32 blob per chunk per provider), and embeddings are PROVIDER-SPECIFIC
// — shipping them to a device configured with a different embedding provider
// would produce a vector space its queries cannot search. The same reasoning
// already keeps them out of recovery
// (`recovery_merge_service.dart`'s "Deliberately NOT merged" list) and keeps
// `attachments/derived/` out of export/import
// (`recovery_screen.dart`'s `isExcludedAttachmentPath`,
// `test/search/recovery_derived_exclusion_test.dart`).
//
// Sync's exclusion, unlike recovery's, is not a filter — it is the ABSENCE of
// an entry in four hand-written allowlists. That makes it correct today and
// invisible tomorrow, which is exactly the shape a regression test is for:
// these tests fail the moment a derived table acquires a capture scope, a
// createdAt mapping, a blob column, or a capture trigger.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/figure_resolver.dart';
import 'package:note_synapse/services/sync/blob_sync.dart';
import 'package:note_synapse/services/sync/sync_change_publisher.dart';
import 'package:note_synapse/services/sync/sync_session.dart';
import 'package:note_synapse/services/sync/sync_table_shape.dart';
import 'package:note_synapse/utils/file_utils.dart';

import '../sync_backend/mock_sync_backend.dart';

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProviderPlatform(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// The four derived tables, plus every FTS4 shadow table `chunks_fts` creates
/// under the hood. Named explicitly: a shadow table is a real table in
/// `sqlite_master` and would sync exactly as happily as any other if anything
/// ever enumerated tables generically.
const List<String> kDerivedIndexTables = [
  'search_chunks',
  'chunk_embeddings',
  'search_index_state',
  'chunks_fts',
  'chunks_fts_content',
  'chunks_fts_segdir',
  'chunks_fts_segments',
  'chunks_fts_docsize',
  'chunks_fts_stat',
];

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('the derived index tables are absent from every sync enumerator', () {
    test('no capture scope names one', () {
      final entityTables = {
        for (final scope in DatabaseService.syncEntityCaptureScopes) scope.table,
      };
      final membershipTables = {
        for (final scope in DatabaseService.syncSetCaptureScopes)
          scope.membershipTable,
      };
      for (final table in kDerivedIndexTables) {
        expect(
          entityTables,
          isNot(contains(table)),
          reason: '$table would be minted as CRDT operations and pushed',
        );
        expect(membershipTables, isNot(contains(table)));
      }
    });

    test('no createdAt mapping, no blob column, no change classification', () {
      for (final table in kDerivedIndexTables) {
        expect(syncEntityCreatedAtColumnByTable, isNot(contains(table)));
        expect(syncMembershipCreatedAtColumnByTable, isNot(contains(table)));
        expect(
          syncBlobBackedColumns,
          isNot(contains(table)),
          reason: 'a blob-backed column would give $table a file transport',
        );
        expect(syncContentBlobColumns, isNot(contains(table)));
        expect(
          syncChangeScopeByTable,
          isNot(contains(table)),
          reason: 'derived tables are never materialized, so they can never '
              'be the source of a change announcement either',
        );
      }
    });

    test('the blob surface is exactly the two attachment tables plus the two '
        'content-backed columns', () {
      // Pinned rather than merely "does not contain the derived tables": the
      // set is small and deliberate, and a new entry is a decision that must
      // be made on purpose.
      expect(syncBlobBackedColumns.keys.toSet(), {
        'attachments',
        'conversation_attachments',
      });
      expect(syncContentBlobColumns.keys.toSet(), {
        'app_revisions',
        'user_apps',
      });
    });

    test('no mutation-capture trigger is installed on one (live sqlite_master '
        'scan, so a generic fallback would show up here)', () async {
      final service = DatabaseService.createNew();
      addTearDown(service.close);
      final db = await service.database;

      final triggers = await db.rawQuery(
        "SELECT name, tbl_name FROM sqlite_master WHERE type = 'trigger'",
      );
      final capturedTables = {
        for (final row in triggers)
          if ((row['name'] as String).startsWith('sync_touch_'))
            row['tbl_name'] as String,
      };
      expect(capturedTables, isNotEmpty, reason: 'sanity: capture is installed');
      for (final table in kDerivedIndexTables) {
        expect(capturedTables, isNot(contains(table)));
      }
    });
  });

  group('an unlisted table is ignored, not an error', () {
    late MockSyncBackend backend;
    late DatabaseService dbServiceA;
    late DatabaseService dbServiceB;
    late Directory docsDir;

    setUp(() async {
      docsDir = await Directory.systemTemp.createTemp('derived_sync_exclusion');
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
      FileUtils.resetDocumentsPathCache();
      backend = MockSyncBackend();
      dbServiceA = DatabaseService.createNew();
      dbServiceB = DatabaseService.createNew();
    });

    tearDown(() async {
      await dbServiceA.close();
      await dbServiceB.close();
      FileUtils.resetDocumentsPathCache();
      if (await docsDir.exists()) await docsDir.delete(recursive: true);
    });

    test('a device full of index rows syncs cleanly and ships none of them',
        () async {
      final dbA = await dbServiceA.database;
      final dbB = await dbServiceB.database;

      await dbA.insert('notes', {
        'id': 'n1',
        'title': 'Indexed note',
        'content': 'Body text',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      // A fully-populated index for that note, written exactly as the indexer
      // would write it.
      final chunkId = await dbA.insert('search_chunks', {
        'chunkKey': 'n1:note_body:-:0',
        'noteId': 'n1',
        'sourceType': 'note_body',
        'seq': 0,
        'text': 'Body text',
        'contentHash': 'hash',
        'updatedAt': 1000,
      });
      await dbA.insert('chunk_embeddings', {
        'chunkId': chunkId,
        'providerKey': 'openai:text-embedding-3-small:1536',
        'modality': 'text',
        'dims': 4,
        'vector': Uint8List.fromList([1, 2, 3, 4]),
        'contentHash': 'hash',
      });
      await dbA.insert('search_index_state', {
        'scopeType': 'global',
        'scopeId': 'all',
        'stage': 'chunks',
        'status': 'done',
        'updatedAt': 1000,
      });

      // No throw: an unlisted table produces no touch rows, so nothing
      // downstream has to reject anything.
      await SyncSession(dbServiceA).run(backend);
      await SyncSession(dbServiceB).run(backend);

      expect(
        (await dbB.query('notes', where: 'id = ?', whereArgs: ['n1'])).single,
        containsPair('title', 'Indexed note'),
        reason: 'sanity: the note itself synced',
      );

      for (final table in ['search_chunks', 'chunk_embeddings']) {
        expect(
          await dbA.query(
            'sync_touch_log',
            where: 'entityTable = ?',
            whereArgs: [table],
          ),
          isEmpty,
          reason: 'no capture trigger exists on $table, so a write to it '
              'leaves no trace for the drainer to mint from',
        );
        expect(
          await dbA.query(
            'sync_pending_ops',
            where: 'entityTable = ?',
            whereArgs: [table],
          ),
          isEmpty,
        );
        expect(
          await dbB.query(table),
          isEmpty,
          reason: '$table is regenerated locally by NoteIndexService, never '
              'received — embeddings in particular are provider-specific and '
              'meaningless on a device using a different provider',
        );
      }
      // The receiving device's global backfill flag must not have arrived
      // either: it would tell B's indexer the corpus was already indexed.
      expect(
        await dbB.query(
          'search_index_state',
          where: "scopeType = 'global'",
        ),
        isEmpty,
      );
    });

    test('a derived figure crop never enters blob transport', () async {
      final dbA = await dbServiceA.database;
      final attachment = File('${docsDir.path}/attachments/report.pdf');
      await attachment.parent.create(recursive: true);
      await attachment.writeAsString('%PDF real attachment bytes');
      // A crop the figures stage rendered next to it. It is a file under
      // `attachments/`, it is named after an attachment id, and it is NOT an
      // attachments row — which is the whole reason it cannot sync.
      final crop = File(
        '${docsDir.path}/${FigureResolver.derivedAssetDir}/att1_p1_f0.png',
      );
      await crop.parent.create(recursive: true);
      await crop.writeAsString('regenerable crop bytes');

      await dbA.insert('notes', {
        'id': 'n1',
        'title': 'With attachment',
        'content': '',
        'type': 'note',
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      await dbA.insert('attachments', {
        'id': 'att1',
        'noteId': 'n1',
        'filePath': 'attachments/report.pdf',
        'fileName': 'report.pdf',
        'fileType': 'pdf',
        'isRelativePath': 1,
        'createdAt': 1000,
      });

      await SyncSession(dbServiceA).run(backend);

      // Blob transport is driven by a `sync_field_state` JOIN against the two
      // attachment tables — a query, never a directory walk — so the crop is
      // structurally invisible to it.
      final references = await BlobSyncPhase(dbServiceA).allReferences();
      expect(references.map((r) => r.storedPath), ['attachments/report.pdf']);
      expect(
        references.any((r) => (r.storedPath ?? '').contains('derived')),
        isFalse,
      );
      expect(
        backend.debugAllBlobBytes(),
        hasLength(1),
        reason: 'exactly the attachment; the crop sitting beside it on disk '
            'was never a candidate',
      );
      expect(
        String.fromCharCodes(backend.debugAllBlobBytes().single),
        startsWith('%PDF'),
      );
    });
  });

  group('index POLICY, unlike the index itself, does sync', () {
    test('notes.metadata and attachments.metadata are in sync scope, so a '
        'search-exclusion follows the note to every device', () {
      // Deliberate and stated rather than incidental: `searchIndex.exclude`
      // (notes) and `searchIndex.{text,ocr,embed}` (attachments) live inside
      // the `metadata` JSON of rows that sync, so excluding a note from search
      // on one device excludes it everywhere. That is user INTENT about a
      // note, not a per-device index artefact — the opposite of the chunks and
      // vectors above, which are per-device and per-provider.
      final notes = DatabaseService.syncEntityCaptureScopes.firstWhere(
        (s) => s.table == 'notes',
      );
      final attachments = DatabaseService.syncEntityCaptureScopes.firstWhere(
        (s) => s.table == 'attachments',
      );
      expect(notes.syncScopeColumns, contains('metadata'));
      expect(attachments.syncScopeColumns, contains('metadata'));
    });
  });
}
