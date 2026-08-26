// Isolated tests for `lib/services/recovery_merge_service.dart` — the M1.6
// (.claude/plans/plan-and-propse-the-glistening-dolphin.md, § M1 status,
// "recovery_screen.dart consistency pass") sub-milestone.
//
// M1.6's own scoping note is explicit that this path needs tests of its
// own, not reliance on M1.3 (tags identity schema)'s or M1.4 (User-App
// soft-delete conversion)'s own test coverage: "a rarely-exercised,
// high-stakes path (it runs when the app failed to boot normally)
// warranting isolated testing". Before this milestone, the merge logic
// lived entirely as private methods on `_RecoveryScreenState`
// (recovery_screen.dart) and could not be unit-tested at all — Dart's
// library-scoped privacy meant no test file could reach it without driving
// the full widget (file picker, BuildContext, l10n, platform channels).
// M1.6 extracted it into `RecoveryMergeService`, a plain class with public
// methods taking two already-open sqflite `Database` handles, specifically
// to make this file possible.
//
// Every test below builds two REAL, full-schema databases via
// `DatabaseService.createNew()` (the same fresh-install path, `_onCreate`,
// production uses) — `stagingDb` standing in for a copy of the CURRENT
// device's own live database, `backupDb` standing in for an imported
// backup — so the partial unique index (`idx_tags_name_live`), the M1.5
// hard-delete guard triggers, and every real column default are genuinely
// exercised, not approximated.
//
// Originally three things (now six, M1.12 added two more — see below),
// matching the task's own acceptance bar:
//  1. `mergeTags` liveness cases: a tombstoned-in-backup / live-in-staging
//     tag of the same name, and the reverse (live-in-backup /
//     tombstoned-in-staging), each confirmed to merge without hitting
//     `idx_tags_name_live`'s constraint and to leave the correct tag live
//     (plus a same-id case showing the (necessarily) conservative
//     no-timestamp-to-compare behavior), plus a control test proving the
//     partial index really is active in this schema (so "no constraint
//     violation" above is a meaningful claim, not vacuously true).
//  2. `mergeUserApps`' UUID-clash path (`_insertPinnedRevisionForApp`) —
//     the one spot M1.6 changed real merge behavior, not just extracted
//     it: a tombstoned backup app is now skipped entirely (no new revision
//     inserted, staging's own copy untouched), and a backup app whose
//     `selectedRevisionId` points at a raw-tombstoned revision copies the
//     EFFECTIVE (fallback-elected) revision's content instead of the
//     literal, stale one — plus a regression case confirming the ordinary,
//     common case (selectedRevisionId already live) is unaffected.
//  3. Every one of the fifteen M1.1 sync control-plane tables is
//     confirmed — by assertion, not merely absence of an error — to be
//     completely untouched by a full run of every merge method, even when
//     staging and backup start with different data in every one of those
//     tables.
//  4. `mergeTagWorkflowBindings` (M1.7, `filters` + `tag_workflow_bindings`
//     soft-delete conversion): a pattern absent from staging imports the
//     backup row as-is, and a pattern present in both — in whatever
//     liveness combination — leaves staging's own row completely
//     untouched, mirroring `mergeTags`' own same-id conservative behavior
//     (this table has no `updatedAt`/HLC field either, so there is no
//     reliable signal to decide which side is newer).
//  5. `mergeConversationMessages` (M1.12): a real bug found while
//     converting `conversation_messages` to soft-delete — its batch SELECT
//     hand-picks a column list (for CursorWindow-safety around potentially
//     huge `content`/`metadata` columns) that never included `__deleted__`,
//     so a tombstoned message in the backup silently resurrected to
//     `__deleted__=0` on import. Fixed by adding the column to the SELECT;
//     verified here directly (tombstoned stays tombstoned, live stays
//     live, already-present-in-staging is left untouched).
//  6. `mergeUserApps` -> `_copyAppLibrariesAndDependencies` (M1.12): the
//     identical hand-picked-SELECT-missing-`__deleted__` bug for
//     `user_app_library_dependencies`, found while fixing #5 above —
//     predates M1.12 (the column has existed on this table since M1.4) but
//     was never caught until this investigation. Same fix, same test
//     shape (tombstoned stays tombstoned, live stays live), exercised
//     through the public `mergeUserApps` entry point since
//     `_copyAppLibrariesAndDependencies` itself is private.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/recovery_merge_service.dart';

/// The fifteen M1.1 CRDT-cloud-sync control-plane tables (design doc §
/// Architecture 1; DatabaseService._syncControlPlaneTableStatements) that
/// RecoveryMergeService's own class doc comment says are deliberately
/// never merged.
const _syncControlPlaneTables = [
  'sync_field_state',
  'sync_set_state',
  'sync_grave',
  'sync_touch_log',
  'sync_pending_ops',
  'sync_state',
  'sync_ack_frontier',
  'sync_device_labels',
  'sync_view_cache',
  'sync_blob_refs',
  'sync_publish_intent',
  'sync_materialize_queue',
  'sync_conflict_copies',
  'sync_dedup_index',
  'sync_dot_redirects',
];

/// One valid, schema-satisfying sentinel row per sync control-plane table,
/// parameterized by [tag] so a staging-tagged row and a backup-tagged row
/// never collide on any table's primary key and remain trivially
/// distinguishable in assertions.
Map<String, Map<String, Object?>> _syncTableSentinelRows(String tag) {
  const now = 1000;
  return {
    'sync_field_state': {
      'entityTable': 'notes',
      'entityId': 'entity-$tag',
      'fieldName': 'title',
      'valueJson': '"v-$tag"',
      'blobHash': null,
      'authorId': 'author-$tag',
      'authorSeq': 1,
      'hlc': 'hlc-$tag',
      'contentKey': null,
      'frontierJson': '{}',
      'updatedAt': now,
    },
    'sync_set_state': {
      'entityTable': 'notes',
      'entityId': 'entity-$tag',
      'fieldName': 'tags',
      'memberUuid': 'member-$tag',
      'authorId': 'author-$tag',
      'authorSeq': 1,
      'hlc': 'hlc-$tag',
      'contentKey': null,
      'frontierJson': '{}',
      'updatedAt': now,
    },
    'sync_grave': {
      'subjectTable': 'notes',
      'subjectId': 'subject-$tag',
      'purgedAt': now,
      'reason': 'test-$tag',
    },
    'sync_touch_log': {
      'entityTable': 'notes',
      'entityId': 'entity-$tag',
      'fieldName': 'title',
      'memberUuid': null,
      'touchedAt': now,
      'processedAt': null,
    },
    'sync_pending_ops': {
      'authorId': 'author-$tag',
      'authorSeq': 1,
      'hlc': 'hlc-$tag',
      'contentKey': null,
      'kind': 'field',
      'entityTable': 'notes',
      'entityId': 'entity-$tag',
      'fieldName': 'title',
      'memberUuid': null,
      'valueJson': '"v-$tag"',
      'blobHash': null,
      'targetDotsJson': null,
      'frontierJson': '{}',
      'createdAt': now,
      'publishedAt': null,
    },
    'sync_state': {'key': 'key-$tag', 'value': 'value-$tag'},
    'sync_ack_frontier': {
      'deviceId': 'device-$tag',
      'authorId': 'author-$tag',
      'ackedSeq': 1,
      'updatedAt': now,
    },
    'sync_device_labels': {
      'deviceId': 'device-$tag',
      'label': 'Label $tag',
      'isCurrentDevice': 0,
      'retiredAt': null,
      'updatedAt': now,
    },
    'sync_view_cache': {
      'entityTable': 'notes',
      'entityId': 'entity-$tag',
      'filePath': '/path/$tag',
      'projectionDigest': 'digest-$tag',
      'lastSyncedAt': now,
    },
    'sync_blob_refs': {
      'blobHash': 'blob-$tag',
      'status': 'live',
      'candidateSince': null,
      'lastCheckedAt': null,
      'createdAt': now,
    },
    'sync_publish_intent': {
      'intentHash': 'intent-$tag',
      'parentCommitHash': null,
      'payloadHash': 'payload-$tag',
      'status': 'pending',
      'createdAt': now,
      'confirmedAt': null,
    },
    'sync_materialize_queue': {
      'blockingReason': 'missing_parent',
      'entityTable': 'notes',
      'entityId': 'entity-$tag',
      'fieldName': 'title',
      'operationJson': null,
      'blockingKey': 'key-$tag',
      'enqueuedAt': now,
    },
    'sync_conflict_copies': {
      'id': 'conflict-$tag',
      'subjectTable': 'notes',
      'subjectId': 'subject-$tag',
      'kind': 'field_conflict',
      'fieldName': 'title',
      'resolvedFieldsJson': '{}',
      'createdAt': now,
    },
    'sync_dedup_index': {
      'contentKey': 'ck-$tag',
      'canonicalAuthorId': 'author-$tag',
      'canonicalAuthorSeq': 1,
    },
    'sync_dot_redirects': {
      'observedAuthorId': 'obs-$tag',
      'observedAuthorSeq': 1,
      'canonicalAuthorId': 'canon-$tag',
      'canonicalAuthorSeq': 2,
    },
  };
}

Future<void> _insertTag(
  Database db, {
  required String id,
  required String name,
  bool deleted = false,
}) async {
  await db.insert('tags', {
    'id': id,
    'name': name,
    'color': '#000000',
    'createdAt': 1000,
    'usageCount': 0,
    '__deleted__': deleted ? 1 : 0,
    'redirectTarget': null,
  });
}

Future<void> _insertWorkflowBinding(
  Database db, {
  required String pattern,
  bool isPrefix = false,
  String skillNoteId = 'skill-1',
  String prompt = 'p',
  bool deleted = false,
}) async {
  await db.insert('tag_workflow_bindings', {
    'pattern': pattern,
    'isPrefix': isPrefix ? 1 : 0,
    'skillNoteId': skillNoteId,
    'prompt': prompt,
    'contentImmutable': 0,
    '__deleted__': deleted ? 1 : 0,
  });
}

Future<void> _insertUserApp(
  Database db, {
  required String id,
  required String uuid,
  String? selectedRevisionId,
  bool deleted = false,
}) async {
  await db.insert('user_apps', {
    'id': id,
    'uuid': uuid,
    'name': 'App $uuid',
    'description': 'desc',
    'steps': 'step1',
    'htmlContent': '<html></html>',
    'appState': null,
    'type': 'normal',
    'selectedRevisionId': selectedRevisionId,
    'author': '',
    'license': '',
    'createdAt': 1000,
    'updatedAt': 1000,
    '__deleted__': deleted ? 1 : 0,
  });
}

Future<void> _insertRevision(
  Database db, {
  required String id,
  required String appId,
  required int revisionNumber,
  String appCode = '<html>code</html>',
  bool deleted = false,
  int? deletedAt,
}) async {
  await db.insert('app_revisions', {
    'id': id,
    'appId': appId,
    'revisionNumber': revisionNumber,
    'revisionTimestamp': 1000,
    'userPrompt': 'prompt',
    'aiResponse': 'response',
    'appCode': appCode,
    'attachmentPaths': null,
    '__deleted__': deleted ? 1 : 0,
    'deletedAt': deletedAt,
  });
}

Future<void> _insertConversationMessage(
  Database db, {
  required String id,
  String content = 'hi',
  bool deleted = false,
}) async {
  await db.insert('conversation_messages', {
    'id': id,
    'type': 'user',
    'content': content,
    'timestamp': 1000,
    'modelUsed': null,
    'metadata': null,
    '__deleted__': deleted ? 1 : 0,
  });
}

/// Returns the auto-generated `user_app_libraries.id`.
Future<int> _insertLibrary(
  Database db, {
  required String appUuid,
  required int revisionId,
  bool deleted = false,
}) async {
  return await db.insert('user_app_libraries', {
    'app_uuid': appUuid,
    'revision_id': revisionId,
    'name': 'lib',
    'usage_instructions': null,
    '__deleted__': deleted ? 1 : 0,
  });
}

Future<void> _insertLibraryDependency(
  Database db, {
  required int libraryId,
  bool deleted = false,
}) async {
  await db.insert('user_app_library_dependencies', {
    'original_url': 'https://example.com/lib.js',
    'local_path': 'lib.js',
    'bytes': Uint8List(0),
    'library_id': libraryId,
    '__deleted__': deleted ? 1 : 0,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late RecoveryMergeService mergeService;
  late DatabaseService stagingService;
  late DatabaseService backupService;
  late Database stagingDb;
  late Database backupDb;

  setUp(() async {
    mergeService = RecoveryMergeService();
    stagingService = DatabaseService.createNew();
    backupService = DatabaseService.createNew();
    stagingDb = await stagingService.database;
    backupDb = await backupService.database;
  });

  tearDown(() async {
    await stagingService.close();
    await backupService.close();
  });

  group('mergeTags — M1.3 liveness cases, verified in isolation (M1.6)', () {
    test(
      'control: idx_tags_name_live really does reject two live rows sharing '
      'a name (so the no-violation assertions below are meaningful)',
      () async {
        await _insertTag(stagingDb, id: 'x1', name: 'Foo');
        await expectLater(
          _insertTag(stagingDb, id: 'x2', name: 'Foo'),
          throwsA(isA<DatabaseException>()),
        );
      },
    );

    test(
      'backup has a TOMBSTONED tag, staging has a LIVE tag of the same '
      'name: merges without a constraint violation, and the live staging '
      'tag wins (backup row not inserted)',
      () async {
        await _insertTag(stagingDb, id: 'staging-live', name: 'Foo');
        await _insertTag(backupDb, id: 'backup-dead', name: 'Foo', deleted: true);

        await mergeService.mergeTags(stagingDb, backupDb);

        final tags = await stagingDb.query('tags');
        expect(tags, hasLength(1));
        expect(tags.single['id'], 'staging-live');
        expect(tags.single['__deleted__'], 0);

        final live = await DatabaseService.findLiveTagByName(stagingDb, 'Foo');
        expect(live, isNotNull);
        expect(live!['id'], 'staging-live');
      },
    );

    test(
      'backup has a LIVE tag, staging has a TOMBSTONED tag of the same '
      'name: merges without a constraint violation, backup row is '
      'imported live, staging tombstone is left untouched, and the live '
      'tag correctly resolves afterward',
      () async {
        await _insertTag(stagingDb, id: 'staging-dead', name: 'Foo', deleted: true);
        await _insertTag(backupDb, id: 'backup-live', name: 'Foo');

        await mergeService.mergeTags(stagingDb, backupDb);

        final tags = await stagingDb.query('tags', orderBy: 'id');
        expect(tags, hasLength(2));

        final deadRow = tags.firstWhere((r) => r['id'] == 'staging-dead');
        expect(deadRow['__deleted__'], 1);
        final liveRow = tags.firstWhere((r) => r['id'] == 'backup-live');
        expect(liveRow['__deleted__'], 0);

        final live = await DatabaseService.findLiveTagByName(stagingDb, 'Foo');
        expect(live, isNotNull);
        expect(live!['id'], 'backup-live');
      },
    );

    test(
      'same id present in both copies with different liveness (only '
      'reachable via a prior cross-device merge, not ordinary single-'
      'device use): staging keeps its own row untouched -- tags has no '
      'timestamp to arbitrate which side is newer, so the conservative, '
      'never-silently-overwrite choice is correct',
      () async {
        await _insertTag(stagingDb, id: 'same-id', name: 'Foo', deleted: true);
        await _insertTag(backupDb, id: 'same-id', name: 'Foo'); // live in backup

        await mergeService.mergeTags(stagingDb, backupDb);

        final tags = await stagingDb.query('tags');
        expect(tags, hasLength(1));
        expect(tags.single['id'], 'same-id');
        expect(
          tags.single['__deleted__'],
          1,
          reason: "staging's own tombstoned row must not be silently "
              'resurrected by the merge',
        );
      },
    );

    test(
      'two different tombstoned rows sharing a name from each side both '
      'survive the merge (no constraint violation among tombstoned rows)',
      () async {
        await _insertTag(stagingDb, id: 'staging-dead', name: 'Foo', deleted: true);
        await _insertTag(backupDb, id: 'backup-dead', name: 'Foo', deleted: true);

        await mergeService.mergeTags(stagingDb, backupDb);

        final tags = await stagingDb.query('tags');
        expect(tags, hasLength(2));
        expect(tags.every((r) => r['__deleted__'] == 1), isTrue);
        expect(await DatabaseService.findLiveTagByName(stagingDb, 'Foo'), isNull);
      },
    );
  });

  group(
    'mergeTagWorkflowBindings — M1.7 liveness-aware conservative merge',
    () {
      test(
        'pattern absent from staging: backup row is inserted as-is, '
        'preserving its own liveness state',
        () async {
          await _insertWorkflowBinding(
            backupDb,
            pattern: 'proj/',
            isPrefix: true,
            deleted: true,
          );

          await mergeService.mergeTagWorkflowBindings(stagingDb, backupDb);

          final bindings = await stagingDb.query('tag_workflow_bindings');
          expect(bindings, hasLength(1));
          expect(bindings.single['pattern'], 'proj/');
          expect(bindings.single['__deleted__'], 1);
        },
      );

      test(
        'same pattern present in both, backup LIVE / staging TOMBSTONED: '
        "staging's own tombstone is left untouched -- no updatedAt/HLC "
        'field exists on this table to decide which side is newer '
        '(mirrors mergeTags\' own same-id conservative behavior)',
        () async {
          await _insertWorkflowBinding(
            stagingDb,
            pattern: 'proj/',
            deleted: true,
          );
          await _insertWorkflowBinding(backupDb, pattern: 'proj/');

          await mergeService.mergeTagWorkflowBindings(stagingDb, backupDb);

          final bindings = await stagingDb.query('tag_workflow_bindings');
          expect(bindings, hasLength(1));
          expect(
            bindings.single['__deleted__'],
            1,
            reason: "staging's own tombstoned row must not be silently "
                'resurrected by the merge',
          );
        },
      );

      test(
        'same pattern present in both, backup TOMBSTONED / staging LIVE: '
        "staging's own live row is left untouched, not clobbered by the "
        "backup's tombstone",
        () async {
          await _insertWorkflowBinding(
            stagingDb,
            pattern: 'proj/',
            skillNoteId: 'staging-skill',
          );
          await _insertWorkflowBinding(
            backupDb,
            pattern: 'proj/',
            skillNoteId: 'backup-skill',
            deleted: true,
          );

          await mergeService.mergeTagWorkflowBindings(stagingDb, backupDb);

          final bindings = await stagingDb.query('tag_workflow_bindings');
          expect(bindings, hasLength(1));
          expect(bindings.single['__deleted__'], 0);
          expect(
            bindings.single['skillNoteId'],
            'staging-skill',
            reason: "staging's own live row content must not be "
                "overwritten by the backup's (tombstoned) copy",
          );
        },
      );
    },
  );

  group('mergeUserApps — effective-visibility-aware UUID-clash merging (M1.6 fix)', () {
    test(
      'backup app is tombstoned: pinned-revision merge is skipped '
      'entirely, staging is left completely untouched',
      () async {
        const uuid = 'app-uuid-1';

        await _insertUserApp(
          stagingDb,
          id: 'staging-app',
          uuid: uuid,
          selectedRevisionId: 'staging-rev-1',
        );
        await _insertRevision(
          stagingDb,
          id: 'staging-rev-1',
          appId: 'staging-app',
          revisionNumber: 1,
          appCode: 'STAGING_CODE',
        );

        // Backup independently has the SAME app uuid but tombstoned, with
        // its own (differently-idd) revision.
        await _insertUserApp(
          backupDb,
          id: 'backup-app',
          uuid: uuid,
          selectedRevisionId: 'backup-rev-1',
          deleted: true,
        );
        await _insertRevision(
          backupDb,
          id: 'backup-rev-1',
          appId: 'backup-app',
          revisionNumber: 1,
          appCode: 'BACKUP_CODE_SHOULD_NOT_APPEAR',
        );

        await mergeService.mergeUserApps(stagingDb, backupDb);

        final revisions = await stagingDb.query(
          'app_revisions',
          where: 'appId = ?',
          whereArgs: ['staging-app'],
        );
        expect(
          revisions,
          hasLength(1),
          reason: 'no new revision should have been inserted',
        );
        expect(revisions.single['id'], 'staging-rev-1');

        final apps = await stagingDb.query(
          'user_apps',
          where: 'uuid = ?',
          whereArgs: [uuid],
        );
        expect(apps.single['selectedRevisionId'], 'staging-rev-1');
        expect(apps.single['__deleted__'], 0);
      },
    );

    test(
      "backup app is live but its selectedRevisionId points at a raw-"
      'tombstoned revision (a zero-live-revisions app, only reachable via '
      'a prior cross-device merge): the EFFECTIVE (fallback-elected) '
      'revision is copied, not the literal, stale selectedRevisionId row',
      () async {
        const uuid = 'app-uuid-2';

        await _insertUserApp(
          stagingDb,
          id: 'staging-app-2',
          uuid: uuid,
          selectedRevisionId: 'staging-rev-2-1',
        );
        await _insertRevision(
          stagingDb,
          id: 'staging-rev-2-1',
          appId: 'staging-app-2',
          revisionNumber: 1,
          appCode: 'STAGING_LIVE_CODE',
        );

        // Backup: app is live, but BOTH revisions are raw-tombstoned (a
        // zero-live-revisions state) -- computeAppRevisionVisibility must
        // elect the highest-deletedAt one (rev 2, deletedAt=2000) as the
        // fallback, per its own documented tie-break rule.
        // selectedRevisionId is deliberately left pointing at the STALE
        // rev 1 to prove the merge does not trust it literally.
        await _insertUserApp(
          backupDb,
          id: 'backup-app-2',
          uuid: uuid,
          selectedRevisionId: 'backup-rev-2-1',
        );
        await _insertRevision(
          backupDb,
          id: 'backup-rev-2-1',
          appId: 'backup-app-2',
          revisionNumber: 1,
          appCode: 'CODE_STALE_SHOULD_NOT_BE_COPIED',
          deleted: true,
          deletedAt: 1000,
        );
        await _insertRevision(
          backupDb,
          id: 'backup-rev-2-2',
          appId: 'backup-app-2',
          revisionNumber: 2,
          appCode: 'CODE_FALLBACK_SHOULD_BE_COPIED',
          deleted: true,
          deletedAt: 2000,
        );

        // Sanity-check the fallback election directly against backupDb,
        // independent of the merge, so a failure below is unambiguous
        // about which layer is wrong.
        final visibility = await DatabaseService().computeAppRevisionVisibility(
          'backup-app-2',
          executor: backupDb,
        );
        expect(visibility.fallbackRevisionId, 'backup-rev-2-2');

        await mergeService.mergeUserApps(stagingDb, backupDb);

        final revisions = await stagingDb.query(
          'app_revisions',
          where: 'appId = ?',
          whereArgs: ['staging-app-2'],
          orderBy: 'revisionNumber ASC',
        );
        expect(revisions, hasLength(2));
        final newRevision = revisions.last;
        expect(newRevision['revisionNumber'], 2);
        expect(
          newRevision['appCode'],
          'CODE_FALLBACK_SHOULD_BE_COPIED',
          reason: 'must copy the effective (fallback-elected) revision, '
              'not the literal, now-stale selectedRevisionId',
        );
        expect(newRevision['__deleted__'], 0, reason: 'the copy is a new LIVE revision');

        final apps = await stagingDb.query(
          'user_apps',
          where: 'uuid = ?',
          whereArgs: [uuid],
        );
        expect(apps.single['selectedRevisionId'], newRevision['id']);
      },
    );

    test(
      'the fourth fallback arm: backup app HAS live revisions (so '
      'fallbackRevisionId is null, not the zero-live-revisions case above) '
      'but selectedRevisionId points at neither a live revision nor a real '
      'row at all -- falls through to the latest LIVE revision by '
      'revisionNumber, mirroring getLatestAppRevision\'s own tie-break',
      () async {
        const uuid = 'app-uuid-2b';

        await _insertUserApp(
          stagingDb,
          id: 'staging-app-2b',
          uuid: uuid,
          selectedRevisionId: 'staging-rev-2b-1',
        );
        await _insertRevision(
          stagingDb,
          id: 'staging-rev-2b-1',
          appId: 'staging-app-2b',
          revisionNumber: 1,
          appCode: 'STAGING_LIVE_CODE',
        );

        // Backup: two LIVE revisions (so fallbackRevisionId is null --
        // this is NOT the zero-live-revisions case), but selectedRevisionId
        // points at a dangling id that matches neither of them.
        await _insertUserApp(
          backupDb,
          id: 'backup-app-2b',
          uuid: uuid,
          selectedRevisionId: 'backup-rev-2b-does-not-exist',
        );
        await _insertRevision(
          backupDb,
          id: 'backup-rev-2b-1',
          appId: 'backup-app-2b',
          revisionNumber: 1,
          appCode: 'CODE_OLDER_LIVE_REVISION',
        );
        await _insertRevision(
          backupDb,
          id: 'backup-rev-2b-2',
          appId: 'backup-app-2b',
          revisionNumber: 2,
          appCode: 'CODE_LATEST_LIVE_REVISION',
        );

        // Sanity-check directly against backupDb: fallbackRevisionId must
        // be null here (live revisions exist), proving this test actually
        // exercises the fourth arm, not the fallback-elected one above.
        final visibility = await DatabaseService().computeAppRevisionVisibility(
          'backup-app-2b',
          executor: backupDb,
        );
        expect(visibility.fallbackRevisionId, isNull);
        expect(visibility.visibleRevisionIds, {'backup-rev-2b-1', 'backup-rev-2b-2'});

        await mergeService.mergeUserApps(stagingDb, backupDb);

        final revisions = await stagingDb.query(
          'app_revisions',
          where: 'appId = ?',
          whereArgs: ['staging-app-2b'],
          orderBy: 'revisionNumber ASC',
        );
        expect(revisions, hasLength(2));
        final newRevision = revisions.last;
        expect(newRevision['revisionNumber'], 2);
        expect(
          newRevision['appCode'],
          'CODE_LATEST_LIVE_REVISION',
          reason: 'with a dangling selectedRevisionId and no fallback-elected '
              'revision, the latest LIVE revision by revisionNumber must win',
        );
      },
    );

    test(
      'regression: backup app live with selectedRevisionId pointing at a '
      'live revision (the ordinary case) is unaffected -- literal '
      'selectedRevisionId content is still copied directly',
      () async {
        const uuid = 'app-uuid-3';

        await _insertUserApp(
          stagingDb,
          id: 'staging-app-3',
          uuid: uuid,
          selectedRevisionId: 'staging-rev-3-1',
        );
        await _insertRevision(
          stagingDb,
          id: 'staging-rev-3-1',
          appId: 'staging-app-3',
          revisionNumber: 1,
        );

        await _insertUserApp(
          backupDb,
          id: 'backup-app-3',
          uuid: uuid,
          selectedRevisionId: 'backup-rev-3-1',
        );
        await _insertRevision(
          backupDb,
          id: 'backup-rev-3-1',
          appId: 'backup-app-3',
          revisionNumber: 1,
          appCode: 'CODE_LIVE',
        );

        await mergeService.mergeUserApps(stagingDb, backupDb);

        final revisions = await stagingDb.query(
          'app_revisions',
          where: 'appId = ?',
          whereArgs: ['staging-app-3'],
          orderBy: 'revisionNumber ASC',
        );
        expect(revisions, hasLength(2));
        expect(revisions.last['appCode'], 'CODE_LIVE');
      },
    );

    test(
      'brand-new app (no UUID clash) is imported verbatim, preserving its '
      'own raw tombstone states across app/revisions -- unaffected by the '
      'M1.6 fix, which only changes the UUID-clash path',
      () async {
        const uuid = 'app-uuid-4';

        await _insertUserApp(
          backupDb,
          id: 'backup-app-4',
          uuid: uuid,
          selectedRevisionId: 'backup-rev-4-1',
          deleted: true,
        );
        await _insertRevision(
          backupDb,
          id: 'backup-rev-4-1',
          appId: 'backup-app-4',
          revisionNumber: 1,
          deleted: true,
          deletedAt: 500,
        );

        await mergeService.mergeUserApps(stagingDb, backupDb);

        final apps = await stagingDb.query('user_apps', where: 'uuid = ?', whereArgs: [uuid]);
        expect(apps, hasLength(1));
        expect(apps.single['__deleted__'], 1);

        final revisions = await stagingDb.query(
          'app_revisions',
          where: 'appId = ?',
          whereArgs: ['backup-app-4'],
        );
        expect(revisions, hasLength(1));
        expect(revisions.single['__deleted__'], 1);
      },
    );
  });

  group(
    'mergeConversationMessages -- M1.12 __deleted__ regression (the '
    'hand-picked column list previously dropped it)',
    () {
      test(
        'a tombstoned message in the backup stays tombstoned after merge, '
        'not silently resurrected to __deleted__=0',
        () async {
          await _insertConversationMessage(
            backupDb,
            id: 'msg-1',
            deleted: true,
          );

          await mergeService.mergeConversationMessages(stagingDb, backupDb);

          final messages = await stagingDb.query('conversation_messages');
          expect(messages, hasLength(1));
          expect(messages.single['id'], 'msg-1');
          expect(
            messages.single['__deleted__'],
            1,
            reason: 'before the fix, __deleted__ was never selected from '
                "the backup at all, so the row always imported with "
                "SQLite's column default (0), silently resurrecting a "
                'tombstoned message',
          );
        },
      );

      test(
        'a live message in the backup imports live, as a control showing '
        'the fix did not flip the default the other way',
        () async {
          await _insertConversationMessage(backupDb, id: 'msg-2');

          await mergeService.mergeConversationMessages(stagingDb, backupDb);

          final messages = await stagingDb.query('conversation_messages');
          expect(messages, hasLength(1));
          expect(messages.single['__deleted__'], 0);
        },
      );

      test(
        'a message already present in staging (by id) is left completely '
        'untouched regardless of the backup copy\'s liveness',
        () async {
          await _insertConversationMessage(stagingDb, id: 'msg-3');
          await _insertConversationMessage(
            backupDb,
            id: 'msg-3',
            deleted: true,
          );

          await mergeService.mergeConversationMessages(stagingDb, backupDb);

          final messages = await stagingDb.query('conversation_messages');
          expect(messages, hasLength(1));
          expect(messages.single['__deleted__'], 0);
        },
      );
    },
  );

  group(
    'mergeUserApps -> _copyAppLibrariesAndDependencies -- M1.12 '
    '__deleted__ regression (pre-existing bug, same hand-picked-column-'
    'list pattern as mergeConversationMessages above, found while fixing '
    'that one)',
    () {
      test(
        'a tombstoned user_app_library_dependencies row in the backup '
        'stays tombstoned after merging a brand-new app, not silently '
        'resurrected to __deleted__=0',
        () async {
          const uuid = 'app-uuid-dep-1';
          await _insertUserApp(
            backupDb,
            id: 'backup-app-dep-1',
            uuid: uuid,
            selectedRevisionId: 'backup-rev-dep-1',
          );
          await _insertRevision(
            backupDb,
            id: 'backup-rev-dep-1',
            appId: 'backup-app-dep-1',
            revisionNumber: 1,
          );
          final libraryId = await _insertLibrary(
            backupDb,
            appUuid: uuid,
            revisionId: 1,
          );
          await _insertLibraryDependency(
            backupDb,
            libraryId: libraryId,
            deleted: true,
          );

          await mergeService.mergeUserApps(stagingDb, backupDb);

          final libraries = await stagingDb.query(
            'user_app_libraries',
            where: 'app_uuid = ?',
            whereArgs: [uuid],
          );
          expect(libraries, hasLength(1));

          final dependencies = await stagingDb.query(
            'user_app_library_dependencies',
            where: 'library_id = ?',
            whereArgs: [libraries.single['id']],
          );
          expect(dependencies, hasLength(1));
          expect(
            dependencies.single['__deleted__'],
            1,
            reason: 'before the fix, __deleted__ was never selected from '
                'the backup at all (same hand-picked-column-list-for-'
                'chunked-BLOB-reading pattern as mergeConversationMessages), '
                "so the row always imported with SQLite's column default "
                '(0), silently resurrecting a tombstoned dependency',
          );
        },
      );

      test(
        'a live user_app_library_dependencies row in the backup imports '
        'live, as a control showing the fix did not flip the default the '
        'other way',
        () async {
          const uuid = 'app-uuid-dep-2';
          await _insertUserApp(
            backupDb,
            id: 'backup-app-dep-2',
            uuid: uuid,
            selectedRevisionId: 'backup-rev-dep-2',
          );
          await _insertRevision(
            backupDb,
            id: 'backup-rev-dep-2',
            appId: 'backup-app-dep-2',
            revisionNumber: 1,
          );
          final libraryId = await _insertLibrary(
            backupDb,
            appUuid: uuid,
            revisionId: 1,
          );
          await _insertLibraryDependency(backupDb, libraryId: libraryId);

          await mergeService.mergeUserApps(stagingDb, backupDb);

          final libraries = await stagingDb.query(
            'user_app_libraries',
            where: 'app_uuid = ?',
            whereArgs: [uuid],
          );
          final dependencies = await stagingDb.query(
            'user_app_library_dependencies',
            where: 'library_id = ?',
            whereArgs: [libraries.single['id']],
          );
          expect(dependencies, hasLength(1));
          expect(dependencies.single['__deleted__'], 0);
        },
      );
    },
  );

  group('sync_* control-plane tables are never touched by any merge method', () {
    test(
      'every one of the fifteen M1.1 sync tables is byte-identical before '
      'and after a full run of every RecoveryMergeService method, even '
      'though staging and backup start with different rows in every one '
      'of them',
      () async {
        final stagingRows = _syncTableSentinelRows('staging');
        final backupRows = _syncTableSentinelRows('backup');

        // Sanity: this test's own table list matches the production
        // fifteen-table list exactly (guards against the two lists
        // silently drifting apart).
        expect(_syncControlPlaneTables, hasLength(15));
        expect(stagingRows.keys.toSet(), _syncControlPlaneTables.toSet());

        for (final table in _syncControlPlaneTables) {
          await stagingDb.insert(table, stagingRows[table]!);
          await backupDb.insert(table, backupRows[table]!);
        }

        final beforeByTable = <String, List<Map<String, Object?>>>{};
        for (final table in _syncControlPlaneTables) {
          beforeByTable[table] = await stagingDb.query(table);
        }

        // Run every public merge method RecoveryMergeService exposes,
        // mirroring recovery_screen.dart's own call sequence. Every source
        // query against backupDb (other than the sync tables themselves)
        // returns zero rows here, so each call is a safe no-op on content
        // tables -- only the sync tables' untouched-ness is under test.
        await mergeService.mergeNotes(stagingDb, backupDb);
        await mergeService.mergeSubNotes(stagingDb, backupDb);
        await mergeService.mergeTags(stagingDb, backupDb);
        await mergeService.mergeTagImages(stagingDb, backupDb);
        await mergeService.mergeNoteTags(stagingDb, backupDb);
        await mergeService.mergeRelationships(stagingDb, backupDb);
        await mergeService.mergeFilters(stagingDb, backupDb);
        await mergeService.mergeUserApps(stagingDb, backupDb);
        await mergeService.mergeAttachments(stagingDb, backupDb);
        await mergeService.mergeConversations(stagingDb, backupDb);
        await mergeService.mergeConversationMessages(stagingDb, backupDb);
        await mergeService.mergeConversationAttachments(stagingDb, backupDb);
        await mergeService.mergeConversationMessageMappings(stagingDb, backupDb);
        await mergeService.mergeMessageParents(stagingDb, backupDb);
        await mergeService.mergeConversationTagMappings(stagingDb, backupDb);
        await mergeService.mergeConversationNoteMappings(stagingDb, backupDb);
        await mergeService.mergeNoteAnnotations(stagingDb, backupDb);
        await mergeService.mergeTagWorkflowBindings(stagingDb, backupDb);

        for (final table in _syncControlPlaneTables) {
          final after = await stagingDb.query(table);
          expect(
            after,
            equals(beforeByTable[table]),
            reason: '$table must be completely untouched by recovery merge',
          );
          // Specifically confirm the backup's row (a different primary
          // key/content, tagged '-backup') was never imported, not merely
          // that content is unchanged in aggregate: exactly the original
          // staging-tagged row survives, verbatim (including any
          // autoincrement id sqflite assigned it on insert).
          expect(after, hasLength(1));
          expect(after.single, equals(beforeByTable[table]!.single));
          final rowText = after.single.values.whereType<String>().join('|');
          expect(rowText, contains('-staging'));
          expect(rowText, isNot(contains('-backup')));
        }
      },
    );
  });
}
