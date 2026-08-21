// Phase A — push, per owned `authorId` namespace — M2.6, § Architecture 11.7
// of the CRDT-cloud-sync design (`plan-and-propse-the-glistening-dolphin.md`).
//
// This milestone pushes for the ORDINARY device namespace only, consistent
// with M2.4's own scope ("no `seed:`/`external:` authorId namespace minting"
// — `outbox_drainer.dart`): since nothing mints into those namespaces yet,
// there is nothing to push for them regardless of what this file could do.
//
// **Step 0's resume procedure and step 2's ordinary push share one
// underlying primitive, [_resolveOnePublish], deliberately — not two
// independently-maintained code paths.** § 11.7 states step 2's `Ambiguous`
// outcome must be "resolved exactly as step 0's resume procedure does," i.e.
// step 0's resume check (readCommits-then-recheck, retry `appendCommit`
// under the identical `publishIntentId` on a genuine miss) is not merely
// *similar* to what an ambiguous step-2 attempt needs — it is the SAME
// procedure, recursively. [_resolveOnePublish] implements that procedure
// once; step 0's scan calls it directly for each pre-existing pending
// intent, and step 2's loop falls into it only on `Ambiguous` (a fresh op's
// first `appendCommit` attempt is not preceded by a redundant readCommits
// check — nothing has been attempted yet — matching § 11.7's step 2 text
// literally).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import 'sync_backend.dart';
import 'wire_format.dart';

/// § 11.7 Phase A step 3: "`ParentMismatch` on a device's own log is not an
/// expected steady-state event... open for sync-engine design review, no
/// reconciliation flow for it designed yet" — this milestone surfaces it as
/// a real, unresolved, thrown error per that explicit instruction, rather
/// than inventing a reconciliation flow the design doc itself declines to
/// specify.
class PushParentMismatchException implements Exception {
  final String authorId;
  final int deviceSeq;
  final String actualTipHash;
  final int publishedBeforeHalt;
  const PushParentMismatchException({
    required this.authorId,
    required this.deviceSeq,
    required this.actualTipHash,
    required this.publishedBeforeHalt,
  });
  @override
  String toString() =>
      'PushParentMismatchException(authorId: $authorId, deviceSeq: $deviceSeq, '
      'actualTipHash: $actualTipHash, publishedBeforeHalt: $publishedBeforeHalt)';
}

/// The resume/retry procedure (readCommits-check, then `appendCommit` retry)
/// kept returning `Ambiguous` past [_maxAmbiguousResolutionAttempts]
/// attempts within one call to [PushPhase.push] — a real, surfaced failure
/// rather than an unbounded retry loop against a persistently-unreachable or
/// persistently-flaky backend.
class PushAmbiguousUnresolvedException implements Exception {
  final String authorId;
  final int deviceSeq;
  const PushAmbiguousUnresolvedException({
    required this.authorId,
    required this.deviceSeq,
  });
  @override
  String toString() =>
      'PushAmbiguousUnresolvedException(authorId: $authorId, deviceSeq: $deviceSeq)';
}

class PushResult {
  const PushResult({required this.publishedCount, required this.resumedCount});

  /// Total ops (new + resumed) confirmed published by this call.
  final int publishedCount;

  /// Of [publishedCount], how many were resolved by step 0's resume check
  /// (a pending intent left over from an earlier, interrupted session) —
  /// informational, for tests/diagnostics.
  final int resumedCount;
}

/// § 11.7 Phase A. One instance is stateless/reusable; every method takes
/// the backend and namespace explicitly.
class PushPhase {
  PushPhase(this._databaseService);

  final DatabaseService _databaseService;

  static const int _maxAmbiguousResolutionAttempts = 5;

  static String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  static String _payloadHash(Uint8List commitBytes) => _sha256Hex(commitBytes);

  static String _intentHash(String? parentCommitHash, String payloadHash) =>
      _sha256Hex(utf8.encode('${parentCommitHash ?? ''}|$payloadHash'));

  /// Runs § 11.7 Phase A in full for [authorId]: step 0's resume check,
  /// then step 2's ordinary push of whatever remains pending. Throws
  /// [PushParentMismatchException] (step 3's "halt-not-retarget," a real
  /// unresolved error) or [PushAmbiguousUnresolvedException] (an
  /// unresolvable-within-this-call `Ambiguous` outcome) — both leave
  /// whatever was already durably confirmed before the failure exactly as
  /// confirmed; nothing is rolled back, matching this procedure's own
  /// crash-safety design (each op's publish is its own atomic local
  /// transaction, independent of every other op's).
  Future<PushResult> push({
    required SyncBackend backend,
    required String authorId,
  }) async {
    final db = await _databaseService.database;
    var resumed = 0;
    var published = 0;

    // Step 0 — resume check.
    final pendingIntents = await db.query(
      'sync_publish_intent',
      where: 'status = ? AND authorId = ?',
      whereArgs: ['pending', authorId],
      orderBy: 'deviceSeq ASC',
    );
    for (final intentRow in pendingIntents) {
      final deviceSeq = intentRow['deviceSeq'] as int?;
      if (deviceSeq == null) {
        // A pre-M2.6 row (authorId/deviceSeq both null) — cannot belong to
        // this namespace's scan (the WHERE clause already requires
        // authorId = ?), so this branch is defensive-only, not expected to
        // ever execute against a real database.
        continue;
      }
      final opRow = await _readPendingOp(db, authorId, deviceSeq);
      if (opRow == null) {
        throw StateError(
          'sync_publish_intent has a pending row for authorId=$authorId deviceSeq=$deviceSeq '
          'with no matching sync_pending_ops row — an internal-consistency violation, since '
          'every intent is recorded from an existing pending op in the same push() call',
        );
      }
      final commitBytes = encodeCommitBytes(
        WireOperation.fromPendingOpsRow(opRow),
      );
      final payloadHash = _payloadHash(commitBytes);
      final recordedPayloadHash = intentRow['payloadHash'] as String;
      if (payloadHash != recordedPayloadHash) {
        // Re-encoding the same sync_pending_ops row must be byte-identical
        // to what was originally encoded (the wire format is a pure
        // function of the row's own columns) — a mismatch here means the
        // row was mutated after its intent was recorded, which never
        // happens by construction (sync_pending_ops rows are immutable
        // once minted, aside from publishedAt). Surfaced loudly rather than
        // silently re-publishing under a stale hash.
        throw StateError(
          'sync_pending_ops row for authorId=$authorId deviceSeq=$deviceSeq re-encodes to a '
          'different payloadHash than its recorded sync_publish_intent — data corruption '
          'or a mutated pending-op row',
        );
      }

      await _resolveOnePublish(
        db: db,
        backend: backend,
        authorId: authorId,
        deviceSeq: deviceSeq,
        intentHash: intentRow['intentHash'] as String,
        parentCommitHash: intentRow['parentCommitHash'] as String?,
        payloadHash: payloadHash,
        commitBytes: commitBytes,
        attempt: 0,
        publishedSoFar: published,
      );
      resumed++;
      published++;
    }

    // Step 1 — this namespace's current tip, freshly read (step 0 may have
    // just advanced it).
    var parentCommitHash = await _readTip(db, authorId);

    // Step 2 — ordinary push of whatever remains pending. Rows step 0
    // resolved already have publishedAt stamped (by _confirmAndAdvance
    // inside _resolveOnePublish), so this query naturally excludes them —
    // no separate bookkeeping needed to avoid double-processing.
    final newOps = await db.query(
      'sync_pending_ops',
      where: 'authorId = ? AND publishedAt IS NULL',
      whereArgs: [authorId],
      orderBy: 'authorSeq ASC',
    );
    for (final opRow in newOps) {
      final deviceSeq = opRow['authorSeq'] as int;
      final commitBytes = encodeCommitBytes(
        WireOperation.fromPendingOpsRow(opRow),
      );
      final payloadHash = _payloadHash(commitBytes);
      final intentHash = _intentHash(parentCommitHash, payloadHash);

      // Record/reuse the intent row BEFORE calling appendCommit — a crash
      // here is exactly what step 0's resume check recovers from on the
      // next attempt.
      await _recordIntent(
        db,
        intentHash: intentHash,
        parentCommitHash: parentCommitHash,
        payloadHash: payloadHash,
        authorId: authorId,
        deviceSeq: deviceSeq,
      );

      final outcome = await backend.appendCommit(
        deviceLogId: authorId,
        deviceSeq: deviceSeq,
        publishIntentId: intentHash,
        parentCommitHash: parentCommitHash,
        commitBytes: commitBytes,
      );

      switch (outcome) {
        case AppendCommitSucceeded(:final commitHash):
          await _confirmAndAdvance(
            db,
            authorId: authorId,
            deviceSeq: deviceSeq,
            commitHash: commitHash,
            intentHash: intentHash,
          );
          parentCommitHash = commitHash;
          published++;
        case AppendCommitParentMismatch(:final actualTipHash):
          throw PushParentMismatchException(
            authorId: authorId,
            deviceSeq: deviceSeq,
            actualTipHash: actualTipHash,
            publishedBeforeHalt: published,
          );
        case AppendCommitAmbiguous():
          final commitHash = await _resolveOnePublish(
            db: db,
            backend: backend,
            authorId: authorId,
            deviceSeq: deviceSeq,
            intentHash: intentHash,
            parentCommitHash: parentCommitHash,
            payloadHash: payloadHash,
            commitBytes: commitBytes,
            attempt: 0,
            publishedSoFar: published,
          );
          parentCommitHash = commitHash;
          published++;
      }
    }

    return PushResult(publishedCount: published, resumedCount: resumed);
  }

  /// § 11.7 Phase A step 0's resume procedure, exactly as written — and,
  /// per step 3's explicit "resolve exactly as step 0's resume procedure
  /// does," also what a step-2 `Ambiguous` outcome falls into. Checks
  /// whether the commit already landed via `readCommits`; if not, retries
  /// `appendCommit` under the identical [intentHash] and recurses on a
  /// further `Ambiguous` (bounded by [_maxAmbiguousResolutionAttempts]).
  /// Returns the confirmed `commitHash`. Throws [PushParentMismatchException]
  /// or [PushAmbiguousUnresolvedException] on an unresolvable outcome.
  Future<String> _resolveOnePublish({
    required Database db,
    required SyncBackend backend,
    required String authorId,
    required int deviceSeq,
    required String intentHash,
    required String? parentCommitHash,
    required String payloadHash,
    required Uint8List commitBytes,
    required int attempt,
    required int publishedSoFar,
  }) async {
    final page = await backend.readCommits(
      deviceLogId: authorId,
      afterSeq: deviceSeq - 1,
      limit: 1,
    );
    for (final commit in page.commits) {
      if (commit.deviceSeq == deviceSeq &&
          _sha256Hex(commit.commitBytes) == payloadHash) {
        // The earlier appendCommit actually landed.
        await _confirmAndAdvance(
          db,
          authorId: authorId,
          deviceSeq: deviceSeq,
          commitHash: commit.commitHash,
          intentHash: intentHash,
        );
        return commit.commitHash;
      }
    }

    if (attempt >= _maxAmbiguousResolutionAttempts) {
      throw PushAmbiguousUnresolvedException(
        authorId: authorId,
        deviceSeq: deviceSeq,
      );
    }

    final outcome = await backend.appendCommit(
      deviceLogId: authorId,
      deviceSeq: deviceSeq,
      publishIntentId: intentHash,
      parentCommitHash: parentCommitHash,
      commitBytes: commitBytes,
    );

    switch (outcome) {
      case AppendCommitSucceeded(:final commitHash):
        await _confirmAndAdvance(
          db,
          authorId: authorId,
          deviceSeq: deviceSeq,
          commitHash: commitHash,
          intentHash: intentHash,
        );
        return commitHash;
      case AppendCommitParentMismatch(:final actualTipHash):
        throw PushParentMismatchException(
          authorId: authorId,
          deviceSeq: deviceSeq,
          actualTipHash: actualTipHash,
          publishedBeforeHalt: publishedSoFar,
        );
      case AppendCommitAmbiguous():
        return _resolveOnePublish(
          db: db,
          backend: backend,
          authorId: authorId,
          deviceSeq: deviceSeq,
          intentHash: intentHash,
          parentCommitHash: parentCommitHash,
          payloadHash: payloadHash,
          commitBytes: commitBytes,
          attempt: attempt + 1,
          publishedSoFar: publishedSoFar,
        );
    }
  }

  Future<Map<String, Object?>?> _readPendingOp(
    DatabaseExecutor db,
    String authorId,
    int deviceSeq,
  ) async {
    final rows = await db.query(
      'sync_pending_ops',
      where: 'authorId = ? AND authorSeq = ?',
      whereArgs: [authorId, deviceSeq],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<String?> _readTip(DatabaseExecutor db, String authorId) async {
    final rows = await db.query(
      'sync_state',
      where: 'key = ?',
      whereArgs: ['tip:$authorId'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// Records a `sync_publish_intent` row as its own, quick, local
  /// transaction — deliberately NOT wrapped around the subsequent
  /// `appendCommit` network call (holding a SQLite write transaction open
  /// across an awaited network round-trip would serialize local DB access
  /// for an unbounded time). `intentHash` is `UNIQUE`; `ConflictAlgorithm.
  /// ignore` makes re-recording an already-present intent (e.g. a second
  /// `push()` call within the same process before the first's outcome is
  /// known) a safe no-op rather than a thrown constraint violation.
  Future<void> _recordIntent(
    Database db, {
    required String intentHash,
    required String? parentCommitHash,
    required String payloadHash,
    required String authorId,
    required int deviceSeq,
  }) async {
    await db.insert('sync_publish_intent', {
      'intentHash': intentHash,
      'parentCommitHash': parentCommitHash,
      'payloadHash': payloadHash,
      'authorId': authorId,
      'deviceSeq': deviceSeq,
      'status': 'pending',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'confirmedAt': null,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Marks the intent confirmed, stamps `sync_pending_ops.publishedAt`, and
  /// advances `sync_state['tip:<authorId>']` — all three in one local
  /// transaction, so a crash partway through this call is impossible to
  /// observe as "confirmed but not published" or "tip advanced but intent
  /// still pending."
  Future<void> _confirmAndAdvance(
    Database db, {
    required String authorId,
    required int deviceSeq,
    required String commitHash,
    required String intentHash,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.update(
        'sync_publish_intent',
        {'status': 'confirmed', 'confirmedAt': now},
        where: 'intentHash = ?',
        whereArgs: [intentHash],
      );
      await txn.update(
        'sync_pending_ops',
        {'publishedAt': now},
        where: 'authorId = ? AND authorSeq = ?',
        whereArgs: [authorId, deviceSeq],
      );
      await txn.insert('sync_state', {
        'key': 'tip:$authorId',
        'value': commitHash,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }
}
