// Sync health — the single place that answers "did anything fail to sync,
// and what?" — M2.10.
//
// ---------------------------------------------------------------------
// **Why this exists, stated bluntly: it is the fix for the defect
// GENERATOR, not for any one defect.**
// ---------------------------------------------------------------------
// Four review rounds of this milestone each found a different bug with the
// identical shape — something detected that data had not synced, and then
// dropped that knowledge on the floor:
//
//   * `ConflictAlgorithm.ignore` swallowing a `NOT NULL` violation, so
//     every mapping-table membership silently never materialized;
//   * a `sync_materialize_queue` reason (`unfillable_membership_column`)
//     that no reader anywhere consumed, so parked rows sat forever;
//   * `PullResult.failedOperations`, added to surface parked operations,
//     which had zero production consumers — a session that permanently
//     dropped a remote edit still reported a clean success;
//   * `_materializeExists`'s bare `return` for an unresolvable table, and
//     `DrainResult.nonPortableTablesSkipped`, both invisible to any user.
//
// Every one of those was individually fixable, and fixing them individually
// is what produced the next one. The common cause is that this engine had
// no concept of a PARTIAL success: `SyncSession.run()` either threw or was
// reported as `succeeded: true`, and everything in between vanished. So
// this file introduces the missing third state and gives every detector one
// place to report into.
//
// **The detectors, all of which now terminate here.** M2.13 added the
// first block below (a fifth and sixth condition sharing one read), so the
// numbered section headers in `recomputeSyncHealth` count BLOCKS of code —
// four of them — not the detector list that follows:
//   1. `DrainResult.nonPortableTablesSkipped` / `SeedScanResult
//      .nonPortableTablesSkipped` — local rows deliberately not minted.
//   2. `PullResult.failedOperations` — remote operations parked after their
//      apply/materialize step failed.
//   3. The `sync_materialize_queue` backlog, by reason — operations waiting
//      on a prerequisite, including ones whose prerequisite can never come.
//   4. Tables gated out of minting entirely because a receiving device
//      could never build their rows (`entitySyncability`).
//
// **Deliberately a snapshot, not an event log.** Health is recomputed from
// durable state at the end of every sync and stored under one `sync_state`
// key. That matters for detector 2 in particular: `PullResult
// .failedOperations` is non-empty for exactly one round (the log advances
// past a parked operation, so the next pull reports nothing), which is
// precisely why a transient in-memory field was the wrong place for it. The
// queue rows persist, so recomputing from them is stable across sessions
// and survives restarts.

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import '../logger_service.dart';
import 'dataset_bootstrap.dart';
import 'materializer.dart';
import 'pull_phase.dart';
import 'sync_table_shape.dart';

/// One category of "did not sync", with enough detail to act on.
class SyncHealthIssue {
  const SyncHealthIssue({
    required this.kind,
    required this.count,
    required this.detail,
    this.subjects = const [],
    this.oldestEntryAt,
  });

  /// Stable identifier — persisted, so do not rename without a migration
  /// path. Rendered by `cloud_sync_screen.dart` via l10n.
  final SyncHealthIssueKind kind;

  /// How many distinct things are affected (tables, operations, queue rows).
  final int count;

  /// Human-readable specifics: table names, or `authorId#seq` dots. Used
  /// for kinds that have no structured [subjects].
  final String detail;

  /// Structured subjects, when the UI can render them better than a
  /// pre-joined string — currently the raw table names behind
  /// [SyncHealthIssueKind.tablesNotSynced], which
  /// `cloud_sync_screen.dart` turns into localized, non-technical labels.
  /// Persisting the raw names (not the rendered sentence) is what lets a
  /// stored health snapshot re-render in whatever language is active now.
  final List<String> subjects;

  /// When the oldest contributing `sync_materialize_queue` row was first
  /// enqueued — the aging signal.
  ///
  /// **This exists because `enqueuedAt` was previously write-only.** Two
  /// separate places in this engine take care to preserve it, with comments
  /// calling it "the only aging signal," and nothing anywhere read it: a
  /// small echo of exactly the defect class this file was built to close
  /// (a mechanism that carefully records something no consumer consumes).
  /// Surfacing it turns "1 removal is waiting" into "…and it has been
  /// waiting since Tuesday", which is the difference between a status line
  /// and an actionable one.
  final DateTime? oldestEntryAt;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'count': count,
    'detail': detail,
    if (subjects.isNotEmpty) 'subjects': subjects,
    if (oldestEntryAt != null)
      'oldestEntryAt': oldestEntryAt!.millisecondsSinceEpoch,
  };

  static SyncHealthIssue? fromJson(Map<String, dynamic> json) {
    final kind = SyncHealthIssueKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    if (kind == null) return null; // a kind written by a newer build
    final oldest = json['oldestEntryAt'] as int?;
    return SyncHealthIssue(
      kind: kind,
      count: json['count'] as int? ?? 0,
      detail: json['detail'] as String? ?? '',
      subjects: [
        for (final s in json['subjects'] as List<dynamic>? ?? const [])
          s as String,
      ],
      oldestEntryAt: oldest == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(oldest),
    );
  }
}

enum SyncHealthIssueKind {
  /// **M2.13.** This device has joined a dataset that no longer exists on
  /// the backend — the reported failure. Ranked first everywhere it is
  /// rendered because it is the only kind that means *nothing* is syncing,
  /// and the only one with a single, concrete user action attached (reset).
  datasetMissing,

  /// **M2.13.** One or more of this device's own `authorId` logs diverged
  /// from the backend: a push halted on `ParentMismatch`
  /// (§ Architecture 3's halt-not-retarget). [SyncHealthIssue.subjects]
  /// holds the affected namespaces.
  ///
  /// Distinct from [datasetMissing] because the dataset can be perfectly
  /// present while one log is not — a partially-deleted folder, or an
  /// identity reused after a reinstall — and because the two are detected
  /// completely differently (a marker read vs. a push outcome), even though
  /// today they share one remedy.
  deviceLogDiverged,

  /// **M2.11, review round 2 (finding F2).** More than one folder in the
  /// user's Drive answers to this dataset's folder name, and this device has
  /// no recorded folder id to fall back on — so nothing syncs at all until a
  /// human says which folder is theirs.
  ///
  /// **On the health spine rather than left as a thrown exception**, because
  /// the population it fires for is an install that predates M2.11: already
  /// `ready`, never `needsReset`, so the dataset card stays green, no reset
  /// is offered, and the only thing that ever mentioned the condition was a
  /// snackbar quoting `SyncAmbiguousRootFolderException.toString()`. That is
  /// the precise shape M2.10's spine and M2.13's typed states were built to
  /// end. The remedy is in Drive (rename or remove the duplicates) or on
  /// this screen (paste the folder id from a device that is syncing), which
  /// is why no reset button is attached to it — a reset would fix nothing.
  rootFolderAmbiguous,

  /// Entity tables whose rows are deliberately not minted at all, because a
  /// receiving device could never build them (`entitySyncability`).
  ///
  /// **M2.14 note — what this kind deliberately does NOT cover, and why a
  /// sibling kind for it was written and then removed.** Attachment rows now
  /// reach a second device while the FILES they point at do not (they live
  /// on disk and have never been part of any operation), and the obvious
  /// move was a second health kind reporting `syncContentDeferredTables`. It
  /// would have marked essentially every device with an attachment
  /// permanently degraded, which is precisely the outcome this detector's
  /// own "only when the user actually HAS rows there" rule exists to avoid
  /// — and the rule's own words settle it: "'You have data that is not
  /// syncing' is actionable; 'this app does not sync attachments yet' is a
  /// release note."
  ///
  /// The honest, actionable signal for a file that did not travel is
  /// per-attachment and already exists at the point of use: the note-detail
  /// card greys the attachment and prints "File not found" in red with its
  /// tap disabled, and the immersive viewer shows `l10n.attachmentMissing`.
  /// `app_revisions` needs no sibling either — it is `canSync == false`, so
  /// THIS kind already names it, with `appCode` as the reason.
  tablesNotSynced,

  /// Remote operations parked after their apply/materialize step failed.
  operationsFailed,

  /// Operations waiting on a prerequisite entity that has not arrived.
  waitingOnMissingEntity,

  /// `set_remove`s referencing an add-dot this device has never observed.
  waitingOnMissingDot,

  /// `set_add`s whose membership row could not be fully built.
  membershipNotBuilt,
}

/// The whole picture, recomputed at the end of each sync.
class SyncHealth {
  const SyncHealth({required this.issues});

  final List<SyncHealthIssue> issues;

  static const SyncHealth healthy = SyncHealth(issues: []);

  /// True when this device is syncing, but not everything got through — the
  /// third state that did not exist before, and whose absence is why four
  /// separate silent-data-loss bugs each reported a clean success.
  bool get isDegraded => issues.isNotEmpty;

  String toJsonString() => jsonEncode({
    'issues': [for (final i in issues) i.toJson()],
  });

  static SyncHealth fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return healthy;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final list = json['issues'] as List<dynamic>? ?? const [];
      return SyncHealth(
        issues: [
          for (final entry in list)
            if (SyncHealthIssue.fromJson(entry as Map<String, dynamic>)
                case final issue?)
              issue,
        ],
      );
    } catch (_) {
      // A corrupt or newer-format row must never break the settings screen.
      return healthy;
    }
  }
}

/// `sync_state` key holding the JSON-encoded [SyncHealth].
const String syncHealthStateKey = 'sync_health';

/// **M2.13.** `sync_state` key holding a JSON array of this device's own
/// `authorId`s whose push halted on `ParentMismatch` during the last round.
///
/// Durable, and rewritten in full by every `SyncSession.run` (empty -> the
/// key is deleted), for the same reason `PullResult.failedOperations` had to
/// stop being transient: a divergence is a persistent condition reported by
/// a single round, so a purely in-memory signal would show the user a
/// problem once and then a clean bill of health forever after while nothing
/// had been fixed. Recomputing health from this row keeps the snapshot true
/// across restarts, and makes "the divergence went away" require an actual
/// successful push rather than a screen refresh.
const String divergedAuthorLogsStateKey = 'diverged_author_logs';

/// **M2.11, review round 2.** `sync_state` key holding the JSON-encoded
/// [RootFolderAmbiguity] this device last hit, or absent when there is none.
///
/// Durable for the same reason [divergedAuthorLogsStateKey] is: the
/// condition persists until the user acts on it in Drive, while the round
/// that detected it is long over by the time anyone opens a settings screen.
/// Written and cleared by `CloudSyncService`; read here so the health
/// snapshot and the sync card cannot disagree about whether it is still
/// true.
const String rootFolderAmbiguityStateKey = 'root_folder_ambiguity';

/// `'1'` when this device CREATED the dataset it is currently in, `'0'` when
/// it joined one; absent before any create-or-join has completed.
///
/// Lives beside the other durable sync-card facts rather than in a widget's
/// `State` because it is the diagnosable half of M2.11's fail-loud design:
/// if `drive.file` does not let a second device list the first's folder,
/// that device silently creates its own dataset, and this is what tells the
/// user it created rather than joined. A signal that only exists until the
/// next tap is not a signal (M2.11 review round 3, finding 5).
const String datasetCreatedHereStateKey = 'dataset_created_here';

/// The two facts a user needs in order to act on an ambiguous folder name:
/// how many folders answered to it, and what it is called.
///
/// Stored structured rather than as a rendered sentence, for the same reason
/// `LastSyncOutcome.detail` stores raw counters — a persisted row has to
/// re-render in whatever language is active *now*.
class RootFolderAmbiguity {
  const RootFolderAmbiguity({
    required this.folderName,
    required this.candidateCount,
  });

  final String folderName;
  final int candidateCount;

  String toJsonString() =>
      jsonEncode({'folderName': folderName, 'candidateCount': candidateCount});

  static RootFolderAmbiguity? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final name = json['folderName'] as String?;
      final count = json['candidateCount'] as int?;
      if (name == null || count == null || count < 2) return null;
      return RootFolderAmbiguity(folderName: name, candidateCount: count);
    } catch (_) {
      // A corrupt row must not break the settings screen — same stance as
      // `SyncHealth.fromJsonString`.
      return null;
    }
  }
}

/// Recomputes [SyncHealth] from durable state plus this round's transient
/// results, and persists it.
///
/// [failedOperations] and [nonPortableTablesSkipped] come from the round
/// that just ran; everything else is read back out of
/// `sync_materialize_queue` and the schema, so the result stays accurate on
/// a later read even though the transient inputs are gone.
Future<SyncHealth> recomputeSyncHealth(
  DatabaseService databaseService, {
  List<(String authorId, int authorSeq, String error)> failedOperations =
      const [],
  List<(String deviceLogId, int deviceSeq, String error)> unreadableCommits =
      const [],
}) async {
  final db = await databaseService.database;
  final issues = <SyncHealthIssue>[];

  // ── 1/4: the engine-level states that mean "nothing is syncing" ──────
  //
  // Read from `sync_state` rather than passed in, exactly like the queue
  // backlog below and for the same reason: all three conditions persist
  // until something is actually done about them, while the round that
  // DETECTED any of them is long over by the time anyone looks at a settings
  // screen. Reported first because they subsume the rest — when the dataset
  // is gone, "3 removals are waiting on a missing entity" is noise. (M2.13
  // added the first two; M2.11's review round 2 added the third.)
  final stateRows = await db.query(
    'sync_state',
    columns: const ['key', 'value'],
    where: 'key IN (?, ?, ?)',
    whereArgs: [
      datasetBootstrapStatusKey,
      divergedAuthorLogsStateKey,
      rootFolderAmbiguityStateKey,
    ],
  );
  String? valueFor(String key) => stateRows
      .where((row) => row['key'] == key)
      .map((row) => row['value'] as String?)
      .firstOrNull;

  if (valueFor(datasetBootstrapStatusKey) == needsResetStatusValue) {
    issues.add(
      const SyncHealthIssue(
        kind: SyncHealthIssueKind.datasetMissing,
        count: 1,
        detail: '',
      ),
    );
  }

  final ambiguity = RootFolderAmbiguity.fromJsonString(
    valueFor(rootFolderAmbiguityStateKey),
  );
  if (ambiguity != null) {
    issues.add(
      SyncHealthIssue(
        kind: SyncHealthIssueKind.rootFolderAmbiguous,
        count: ambiguity.candidateCount,
        // The folder NAME, structured as the issue's detail so the screen can
        // render the localized sentence around it. Not a pre-rendered
        // sentence, for the reason `LastSyncOutcome.detail` is not one.
        detail: ambiguity.folderName,
      ),
    );
  }

  final divergedRaw = valueFor(divergedAuthorLogsStateKey);
  if (divergedRaw != null && divergedRaw.isNotEmpty) {
    List<String> diverged;
    try {
      diverged = [
        for (final entry in jsonDecode(divergedRaw) as List<dynamic>)
          entry as String,
      ];
    } catch (_) {
      // A corrupt row must not break the settings screen — same stance as
      // `SyncHealth.fromJsonString`.
      diverged = const [];
    }
    if (diverged.isNotEmpty) {
      issues.add(
        SyncHealthIssue(
          kind: SyncHealthIssueKind.deviceLogDiverged,
          count: diverged.length,
          subjects: List.unmodifiable(diverged),
          detail: diverged.join(', '),
        ),
      );
    }
  }

  // ── 2/4: tables gated out of minting ─────────────────────────────────
  //
  // **Only reported when the user actually HAS rows there.** Eight of the
  // fourteen sync-scope tables cannot be built by a receiving device, so an
  // unconditional report would mark every device on earth permanently
  // degraded — which would train people to ignore the warning and defeat
  // the entire point of building it. "You have data that is not syncing" is
  // actionable; "this app does not sync attachments yet" is a release note.
  final gated = <String>[];
  for (final scope in DatabaseService.syncEntityCaptureScopes) {
    final syncability = await entitySyncability(db, scope);
    if (syncability.canSync) continue;
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM ${scope.table}'),
        ) ??
        0;
    if (count == 0) continue;
    gated.add(scope.table);
    // The technical reason belongs in the log, not on a settings screen —
    // "unresolvable column noteId" tells an engineer everything and a user
    // nothing.
    LoggerService.info(
      'SyncHealth: ${scope.table} holds $count row(s) that cannot sync '
      '(${syncability.reasonLabel})',
    );
  }
  if (gated.isNotEmpty) {
    issues.add(
      SyncHealthIssue(
        kind: SyncHealthIssueKind.tablesNotSynced,
        count: gated.length,
        // Raw table names, kept structured so the UI can localize them.
        subjects: List.unmodifiable(gated),
        detail: gated.join(', '),
      ),
    );
  }

  // ── 3/4: operations parked after a failure ───────────────────────────
  // Read from the queue rather than trusting only this round's transient
  // list: a parked operation stays parked, but `failedOperations` is
  // non-empty for exactly the one round that parked it.
  final failedRows = await db.query(
    'sync_materialize_queue',
    where: 'blockingReason = ?',
    whereArgs: [operationFailedBlockingReason],
  );
  if (failedRows.isNotEmpty ||
      failedOperations.isNotEmpty ||
      unreadableCommits.isNotEmpty) {
    final dots = <String>{
      for (final row in failedRows) (row['blockingKey'] as String?) ?? '?',
      for (final failure in failedOperations) '${failure.$1}#${failure.$2}',
      // M2.12: commits whose envelope version this build cannot read. Named
      // by COMMIT POSITION (`log@N`), deliberately distinguishable at a
      // glance from the `authorId#authorSeq` dots above — they are not
      // operations, and nothing inside them was ever decoded. Folded into
      // the same issue kind rather than a new one because the user-facing
      // meaning is identical ("something from another device did not get
      // through, and here is what") and a new kind would need its own
      // localized string for a case that only arises when a peer is running
      // a newer build.
      for (final commit in unreadableCommits) '${commit.$1}@${commit.$2}',
    };
    issues.add(
      SyncHealthIssue(
        kind: SyncHealthIssueKind.operationsFailed,
        count: dots.length,
        detail: dots.take(5).join(', '),
      ),
    );
  }

  // ── 4/4: the materialize-queue backlog, split by what it is waiting on
  Future<void> addQueueIssue(String reason, SyncHealthIssueKind kind) async {
    final rows = await db.query(
      'sync_materialize_queue',
      columns: const ['entityTable', 'entityId', 'enqueuedAt'],
      where: 'blockingReason = ?',
      whereArgs: [reason],
    );
    if (rows.isEmpty) return;
    final subjects = <String>{
      for (final row in rows) '${row['entityTable']}/${row['entityId']}',
    };
    // The aging signal `enqueuedAt` has always recorded and nothing has ever
    // read — see [SyncHealthIssue.oldestEntryAt].
    final oldestMs = rows
        .map((row) => row['enqueuedAt'] as int? ?? 0)
        .where((ms) => ms > 0)
        .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
    issues.add(
      SyncHealthIssue(
        kind: kind,
        count: rows.length,
        detail: subjects.take(5).join(', '),
        oldestEntryAt: oldestMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(oldestMs),
      ),
    );
  }

  await addQueueIssue(
    missingExistsBlockingReason,
    SyncHealthIssueKind.waitingOnMissingEntity,
  );
  await addQueueIssue(
    missingReferencedDotBlockingReason,
    SyncHealthIssueKind.waitingOnMissingDot,
  );
  await addQueueIssue(
    unfillableMembershipColumnBlockingReason,
    SyncHealthIssueKind.membershipNotBuilt,
  );

  final health = SyncHealth(issues: List.unmodifiable(issues));
  await db.insert('sync_state', {
    'key': syncHealthStateKey,
    'value': health.toJsonString(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  return health;
}

/// Reads the last persisted [SyncHealth] without recomputing.
Future<SyncHealth> readSyncHealth(DatabaseService databaseService) async {
  final db = await databaseService.database;
  final rows = await db.query(
    'sync_state',
    columns: const ['value'],
    where: 'key = ?',
    whereArgs: [syncHealthStateKey],
    limit: 1,
  );
  if (rows.isEmpty) return SyncHealth.healthy;
  return SyncHealth.fromJsonString(rows.first['value'] as String?);
}
