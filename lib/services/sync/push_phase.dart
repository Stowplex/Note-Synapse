// Phase A — push, per owned `authorId` namespace — M2.6, § Architecture 11.7
// of the CRDT-cloud-sync design (`plan-and-propse-the-glistening-dolphin.md`),
// with M2.12's commit batching.
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
// intent, and step 2's loop falls into it only on `Ambiguous` (a fresh
// batch's first `appendCommit` attempt is not preceded by a redundant
// readCommits check — nothing has been attempted yet — matching § 11.7's
// step 2 text literally).
//
// ===========================================================================
// M2.12: `deviceSeq` and `authorSeq` are now two different things.
// ===========================================================================
//
// They used to be numerically equal, because every commit carried exactly one
// operation. That equality was never part of the design — § Architecture 3
// defines `deviceSeq` as a position in a device log's hash-linked chain and
// § Architecture 2 defines `authorSeq` as the second component of a causal
// dot — and this file relied on it in three places, all of which are now
// explicit:
//
//   * **`deviceSeq` — the commit-chain position.** Owned by this file,
//     advanced once per COMMIT, persisted as `sync_state['commit_seq:<
//     authorId>']` in the same transaction that advances
//     `sync_state['tip:<authorId>']`. It is what `appendCommit`,
//     `parentCommitHash`, the hash chain, `readCommits(afterSeq:)` and
//     `sync_publish_intent.deviceSeq` all mean. It never appears inside
//     `commitBytes`.
//   * **`authorSeq` — the dot.** Owned by `SeqCounter`, advanced once per
//     OPERATION, carried inside `commitBytes` on each operation
//     individually, and used by nothing in this file except to identify
//     which `sync_pending_ops` rows a commit covers. The dot space is
//     completely unchanged by batching: the same operations get the same
//     dots they always would have.
//
// The three former conflation points, and what each became:
//   1. `final deviceSeq = opRow['authorSeq'] as int;` in step 2 — replaced
//      by [_readCommitSeq]'s own commit counter.
//   2. Step 0's `_readPendingOp(db, authorId, deviceSeq)`, which looked a
//      pending op up BY `authorSeq = deviceSeq` — replaced by
//      [_reconstructBatch], which reads the operations an intent covers from
//      `sync_publish_intent.opAuthorSeqsJson` (schema v61) and verifies them
//      against its recorded `payloadHash` (see that method).
//   3. `decodeCommitBytes(expectedAuthorSeq: commit.deviceSeq)` on the pull
//      side — replaced by `decodeCommitOperations` (`wire_format.dart`),
//      which applies that check for v1 only, where it remains correct.
//
// **Existing v1 logs keep working without a migration.** [_readCommitSeq]
// falls back to `MAX(sync_publish_intent.deviceSeq)` when no `commit_seq:`
// row exists yet — which, for a log written entirely by the pre-M2.12 build,
// is exactly the last commit position, because back then every intent's
// `deviceSeq` was one commit. The chain therefore continues from wherever it
// actually is, with v2 commits appended after v1 ones in the same log.
//
// ===========================================================================
// Batch size, and why it is two limits rather than one.
// ===========================================================================
//
// [maxOperationsPerCommit] = 64 and [maxPayloadBytesPerCommit] = 256 KiB,
// whichever binds first; a single operation larger than the byte limit is
// always sent alone rather than being split (operations are atomic).
//
//   * **Drive request size.** `GoogleDriveBackend` uploads a commit as a
//     `multipart/related` create, i.e. one non-resumable request. Google
//     documents 5 MB as the multipart-upload ceiling. 256 KiB leaves ~20x
//     headroom, which matters because the limit is on the SUM and one
//     `notes.content` can be megabytes on its own — the byte limit is what
//     stops a batch of ten large notes from turning a working push into a
//     413.
//
//     **The budget is measured in real bytes, not characters, and on this
//     app that is not pedantry.** `LENGTH(valueJson)` on a TEXT column
//     counts CHARACTERS; Note Synapse ships a Chinese localization and CJK
//     content is an ordinary case, at roughly 3 UTF-8 bytes per character.
//     Budgeting by character count would have let a wholly-Chinese batch
//     reach ~768 KiB of real payload against a "256 KiB" limit — still
//     safe, but the documented headroom would have been ~6x rather than the
//     ~20x claimed, and the discrepancy would have been invisible. Planning
//     uses `LENGTH(CAST(valueJson AS BLOB))`, which is SQLite's byte
//     length, so the number means what it says in every language.
//   * **Memory.** A commit is built, hashed, and held in memory whole, on a
//     phone, while the request is in flight; and on the receiving side
//     `readCommits` downloads it whole. Both scale with this number.
//   * **Resume granularity.** A commit is the atomic unit of durable
//     progress: a push interrupted mid-flight re-derives and re-sends at
//     most one commit's worth of work. 64 operations is roughly four
//     entities on the measured dataset — small enough that an interrupted
//     first sync loses no meaningful ground, large enough that the same
//     dataset's 152 operations fit in 3 commits instead of 152.
//   * **Why not "one commit per push".** Progress would stop being durable
//     until the very end, a single failure would cost the whole round, and
//     the payload would be unbounded in exactly the two dimensions above.
//
// The planning pass ([_planBatches]) deliberately reads only `authorSeq` and
// the value's byte length — never the values themselves — so deciding the
// batch layout for a large outbox costs one small query rather than loading
// every `notes.content` in `sync_pending_ops` into memory at once (which is
// what the pre-M2.12 `db.query('sync_pending_ops', ...)` did before the
// loop).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import 'blob_sync.dart';
import 'sync_backend.dart';
import 'sync_crypto.dart';
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

/// Progress for one [PushPhase.push] call, emitted once per commit
/// confirmed.
///
/// **M2.12 exists partly because this type did not.** During push the
/// settings screen kept showing the SEED phase's last message ("Preparing
/// existing data — message_parents (19 of 19 tables), 441 operations so
/// far") for the entire, much longer push, so the phase that actually took
/// minutes looked like a hang on a phase that had already finished. Routed
/// through the same callback plumbing M2.10 built for
/// `SeedScanProgress` — `SyncSession.onPushProgress` ->
/// `CloudSyncService.syncNow(onPushProgress:)` -> the same single live-status
/// line in `cloud_sync_screen.dart`.
class PushProgress {
  const PushProgress({
    required this.authorId,
    required this.commitsSent,
    required this.commitsTotal,
    required this.operationsPublished,
  });

  /// Which namespace is being pushed — the ordinary device id or
  /// `seed:<deviceId>`, since `SyncSession` runs Phase A once per owned
  /// namespace.
  final String authorId;

  final int commitsSent;

  /// Planned commits for this namespace, computed once from the outbox
  /// before the first append. An estimate in exactly one respect: a resumed
  /// intent from an interrupted earlier session may have grouped its
  /// operations differently, so [commitsSent] can end slightly under
  /// [commitsTotal]. Progress text, not a correctness signal.
  final int commitsTotal;

  final int operationsPublished;
}

class PushResult {
  const PushResult({
    required this.publishedCount,
    required this.resumedCount,
    this.commitCount = 0,
  });

  /// Total ops (new + resumed) confirmed published by this call.
  final int publishedCount;

  /// Of [publishedCount], how many were resolved by step 0's resume check
  /// (a pending intent left over from an earlier, interrupted session) —
  /// informational, for tests/diagnostics.
  final int resumedCount;

  /// M2.12: how many COMMITS carried those [publishedCount] operations.
  /// Equal to `publishedCount` before batching existed; the ratio between
  /// the two is the traffic saving, and a test pins it.
  final int commitCount;
}

/// One commit's worth of operations, planned and encoded.
class _CommitBatch {
  const _CommitBatch({
    required this.authorSeqs,
    required this.bytes,
    required this.payloadHash,
  });

  /// The `sync_pending_ops.authorSeq` values this commit covers, ascending.
  /// Stamping `publishedAt` for exactly these is what makes a commit's
  /// confirmation atomic with respect to the outbox.
  final List<int> authorSeqs;
  final Uint8List bytes;
  final String payloadHash;

  int get operationCount => authorSeqs.length;
}

/// § 11.7 Phase A. One instance is stateless/reusable; every method takes
/// the backend and namespace explicitly.
class PushPhase {
  PushPhase(
    this._databaseService, {
    this.maxOperationsPerCommit = defaultMaxOperationsPerCommit,
    this.maxPayloadBytesPerCommit = defaultMaxPayloadBytesPerCommit,
    BlobSyncPhase? blobs,
    DatasetCrypto crypto = const DatasetCrypto.plaintext(),
  }) : _blobs = blobs ?? BlobSyncPhase(_databaseService),
       _crypto = crypto;

  final DatabaseService _databaseService;
  final BlobSyncPhase _blobs;

  /// **Sealing happens at the `appendCommit` call site, not in
  /// [_encodeBatch], and `payloadHash` is taken over the PLAINTEXT.**
  ///
  /// AES-GCM uses a fresh nonce per encryption, so sealing the same batch
  /// twice produces different bytes. Hashing the sealed form would therefore
  /// make step 0's resume unable to recognise its own recorded intent — the
  /// re-encode would hash differently every attempt, and a push interrupted
  /// mid-flight could never be resolved. Hashing the plaintext keeps the
  /// intent's identity a pure function of what the operations say, which is
  /// what it was always meant to be.
  final DatasetCrypto _crypto;

  /// Blobs uploaded (or found already present) by the most recent [push].
  BlobSyncResult lastBlobResult = const BlobSyncResult();

  static const int _maxAmbiguousResolutionAttempts = 5;

  /// See the batch-size section of this file's top doc comment.
  static const int defaultMaxOperationsPerCommit = 64;

  /// Budget over the summed BYTE length of a commit's operations'
  /// `sync_pending_ops.valueJson` — a planning proxy for the encoded payload
  /// size, which is dominated by values (`notes.content`,
  /// `conversation_messages.metadata`). Deliberately compared against a
  /// cheap `LENGTH(CAST(... AS BLOB))` rather than the real encoded size so
  /// planning never has to load the values; see the batch-size section of
  /// this file's top doc comment for why the `CAST` (and not a bare
  /// `LENGTH`) is load-bearing on a CJK-capable app.
  static const int defaultMaxPayloadBytesPerCommit = 256 * 1024;

  /// Overridable per instance so a test can pin the *equivalence* of
  /// batching rather than only its effect: running the identical multi-device
  /// scenario at `maxOperationsPerCommit: 1` reproduces the pre-M2.12
  /// one-operation-per-commit shape, and the resolved state must come out
  /// byte-identical either way. Production never passes these.
  ///
  /// **Lowering either of these in a future release is safe**, and was not
  /// before the v61 `opAuthorSeqsJson` column existed — see
  /// [_reconstructBatch] for the permanent-wedge that column removes.
  final int maxOperationsPerCommit;
  final int maxPayloadBytesPerCommit;

  static String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  static String _payloadHash(Uint8List commitBytes) => _sha256Hex(commitBytes);

  static String _intentHash(String? parentCommitHash, String payloadHash) =>
      _sha256Hex(utf8.encode('${parentCommitHash ?? ''}|$payloadHash'));

  /// `sync_state` key holding this namespace's last confirmed commit-chain
  /// position — see this file's top doc comment on `deviceSeq` vs
  /// `authorSeq`.
  static String commitSeqKey(String authorId) => 'commit_seq:$authorId';

  /// Runs § 11.7 Phase A in full for [authorId]: step 0's resume check,
  /// then step 2's ordinary push of whatever remains pending. Throws
  /// [PushParentMismatchException] (step 3's "halt-not-retarget," a real
  /// unresolved error) or [PushAmbiguousUnresolvedException] (an
  /// unresolvable-within-this-call `Ambiguous` outcome) — both leave
  /// whatever was already durably confirmed before the failure exactly as
  /// confirmed; nothing is rolled back, matching this procedure's own
  /// crash-safety design (each COMMIT's publish is its own atomic local
  /// transaction, independent of every other commit's).
  Future<PushResult> push({
    required SyncBackend backend,
    required String authorId,
    void Function(PushProgress)? onProgress,
  }) async {
    final db = await _databaseService.database;
    var resumed = 0;
    var published = 0;
    var commits = 0;

    // ── Blobs first — M3.1, § Architecture 4 ───────────────────────────
    //
    // "Uploaded blobs are verified before any referencing commit is
    // written." The ordering is the whole guarantee: a commit naming bytes
    // no peer can fetch is a permanent dangling reference on every device,
    // whereas bytes nobody references yet are unreclaimed storage that
    // § Architecture 4's GC already exists to sweep. Cheap direction first.
    //
    // The hash is STAMPED ONTO THE PENDING ROW rather than computed while
    // encoding, and that is load-bearing rather than tidy: `_encodeBatch`
    // must be able to re-encode a recorded intent to the byte-identical
    // payload during step 0's resume, and a file the user edited between
    // the two attempts would hash differently. Storing it once makes the
    // re-encode a pure function of durable state, which is what the
    // intent's `payloadHash` check already assumes.
    await _stampBlobHashes(db, authorId);
    lastBlobResult = await _blobs.uploadReferenced(
      backend,
      await _pendingBlobReferences(db, authorId),
    );

    // Planned once, over EVERY unpublished operation (including the ones a
    // pending intent already covers, which are still unpublished by
    // definition) — so the total a progress UI shows does not jump when
    // step 0 hands over to step 2.
    final commitsTotal = (await _planBatches(db, authorId)).length;

    void report() => onProgress?.call(
      PushProgress(
        authorId: authorId,
        commitsSent: commits,
        commitsTotal: commitsTotal,
        operationsPublished: published,
      ),
    );

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
      final recordedPayloadHash = intentRow['payloadHash'] as String;
      final batch = await _reconstructBatch(
        db,
        authorId: authorId,
        deviceSeq: deviceSeq,
        payloadHash: recordedPayloadHash,
        opAuthorSeqsJson: intentRow['opAuthorSeqsJson'] as String?,
      );
      if (batch == null) {
        // The operations this intent names do not re-encode to the
        // payloadHash it recorded (or, for a pre-v61 intent, the single
        // operation at `authorSeq == deviceSeq` does not). Since
        // `sync_pending_ops` rows are immutable once minted (aside from
        // `publishedAt`) and the covered set is now recorded rather than
        // guessed, the only ways to reach here are real corruption or a
        // mutated row. Surfaced loudly rather than silently re-publishing
        // something else under a stale hash — the same stance the
        // pre-M2.12 code took for its own narrower version of this check.
        throw StateError(
          'sync_publish_intent has a pending row for authorId=$authorId '
          'deviceSeq=$deviceSeq whose recorded payloadHash does not match a '
          're-encoding of the operations it names — data corruption or a '
          'mutated pending-op row',
        );
      }

      await _resolveOnePublish(
        db: db,
        backend: backend,
        authorId: authorId,
        deviceSeq: deviceSeq,
        intentHash: intentRow['intentHash'] as String,
        parentCommitHash: intentRow['parentCommitHash'] as String?,
        batch: batch,
        attempt: 0,
        publishedSoFar: published,
      );
      resumed += batch.operationCount;
      published += batch.operationCount;
      commits++;
      report();
    }

    // Step 1 — this namespace's current tip and commit-chain position,
    // freshly read (step 0 may have just advanced both).
    var parentCommitHash = await _readTip(db, authorId);
    var commitSeq = await _readCommitSeq(db, authorId);

    // Step 2 — ordinary push of whatever remains pending. Operations step 0
    // resolved already have publishedAt stamped (by _confirmAndAdvance
    // inside _resolveOnePublish), so this plan naturally excludes them —
    // no separate bookkeeping needed to avoid double-processing.
    for (final authorSeqs in await _planBatches(db, authorId)) {
      final batch = await _encodeBatch(db, authorId, authorSeqs);
      commitSeq++;
      final intentHash = _intentHash(parentCommitHash, batch.payloadHash);

      // Record/reuse the intent row BEFORE calling appendCommit — a crash
      // here is exactly what step 0's resume check recovers from on the
      // next attempt.
      await _recordIntent(
        db,
        intentHash: intentHash,
        parentCommitHash: parentCommitHash,
        payloadHash: batch.payloadHash,
        authorId: authorId,
        deviceSeq: commitSeq,
        authorSeqs: batch.authorSeqs,
      );

      final outcome = await backend.appendCommit(
        deviceLogId: authorId,
        deviceSeq: commitSeq,
        publishIntentId: intentHash,
        parentCommitHash: parentCommitHash,
        commitBytes: await _crypto.seal(batch.bytes, 'commit'),
      );

      switch (outcome) {
        case AppendCommitSucceeded(:final commitHash):
          await _confirmAndAdvance(
            db,
            authorId: authorId,
            deviceSeq: commitSeq,
            authorSeqs: batch.authorSeqs,
            commitHash: commitHash,
            intentHash: intentHash,
          );
          parentCommitHash = commitHash;
        case AppendCommitParentMismatch(:final actualTipHash):
          throw PushParentMismatchException(
            authorId: authorId,
            deviceSeq: commitSeq,
            actualTipHash: actualTipHash,
            publishedBeforeHalt: published,
          );
        case AppendCommitAmbiguous():
          final commitHash = await _resolveOnePublish(
            db: db,
            backend: backend,
            authorId: authorId,
            deviceSeq: commitSeq,
            intentHash: intentHash,
            parentCommitHash: parentCommitHash,
            batch: batch,
            attempt: 0,
            publishedSoFar: published,
          );
          parentCommitHash = commitHash;
      }
      published += batch.operationCount;
      commits++;
      report();
    }

    return PushResult(
      publishedCount: published,
      resumedCount: resumed,
      commitCount: commits,
    );
  }

  // ── Batch planning / encoding ────────────────────────────────────────

  /// Groups this namespace's unpublished operations into commits, reading
  /// only each operation's `authorSeq` and its value's BYTE length — never
  /// its value. See the batch-size section of this file's top doc comment,
  /// including why the length is taken over a `CAST(... AS BLOB)`.
  Future<List<List<int>>> _planBatches(
    DatabaseExecutor db,
    String authorId,
  ) async {
    final rows = await db.rawQuery(
      'SELECT authorSeq, '
      'COALESCE(LENGTH(CAST(valueJson AS BLOB)), 0) AS valueBytes '
      'FROM sync_pending_ops '
      'WHERE authorId = ? AND publishedAt IS NULL '
      'ORDER BY authorSeq ASC',
      [authorId],
    );

    final batches = <List<int>>[];
    var current = <int>[];
    var currentBytes = 0;
    for (final row in rows) {
      final authorSeq = row['authorSeq'] as int;
      final valueBytes = (row['valueBytes'] as int?) ?? 0;
      final wouldOverflow =
          current.length >= maxOperationsPerCommit ||
          (current.isNotEmpty &&
              currentBytes + valueBytes > maxPayloadBytesPerCommit);
      if (wouldOverflow) {
        batches.add(current);
        current = <int>[];
        currentBytes = 0;
      }
      current.add(authorSeq);
      currentBytes += valueBytes;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  /// Reads the named operations in full and encodes them as one `v: 2`
  /// commit payload.
  /// Fills in `sync_pending_ops.blobHash` for every unpublished, blob-backed
  /// field operation of this namespace that does not have one yet.
  ///
  /// Runs OUTSIDE any transaction, deliberately: hashing streams a whole file
  /// off disk, and doing that while holding SQLite's write lock would block
  /// every other writer for the length of the largest attachment. The mint
  /// path is where a hash would most naturally belong and is exactly where it
  /// cannot go, because minting happens inside the same transaction as the
  /// touch-log bookkeeping it must be atomic with.
  ///
  /// A row whose file is absent is left with a null `blobHash` and syncs as
  /// it does today — the metadata travels, the bytes are reported missing.
  /// Withholding the row would be withholding the user's own data from their
  /// other device because of a file the app already renders as "not found".
  Future<void> _stampBlobHashes(DatabaseExecutor db, String authorId) async {
    final tables = {
      ...syncBlobBackedColumns.keys,
      ...syncContentBlobColumns.keys,
    }.toList();
    if (tables.isEmpty) return;
    final placeholders = List.filled(tables.length, '?').join(',');
    final rows = await db.query(
      'sync_pending_ops',
      columns: const ['authorSeq', 'entityTable', 'fieldName', 'valueJson'],
      where:
          'authorId = ? AND publishedAt IS NULL AND blobHash IS NULL '
          'AND kind = ? AND entityTable IN ($placeholders)',
      whereArgs: [authorId, 'field', ...tables],
    );
    for (final row in rows) {
      final entityTable = row['entityTable'] as String;
      final fieldName = row['fieldName'] as String?;

      // Content-backed (`app_revisions.appCode`): the column's own value IS
      // the blob, so the hash is over the value the operation already holds
      // — no file to resolve, nothing to read off disk.
      if (isContentBlobColumn(entityTable, fieldName)) {
        final value = BlobSyncPhase.decodeValue(row['valueJson'] as String?);
        if (value is! String || value.isEmpty) continue;
        await db.update(
          'sync_pending_ops',
          {'blobHash': BlobSyncPhase.hashString(value)},
          where: 'authorId = ? AND authorSeq = ?',
          whereArgs: [authorId, row['authorSeq']],
        );
        continue;
      }

      if (syncBlobBackedColumns[entityTable] != fieldName) continue;
      final value = BlobSyncPhase.decodeValue(row['valueJson'] as String?);
      final hash = await _blobs.blobHashForMint(
        entityTable: entityTable,
        fieldName: fieldName!,
        value: value,
        // Read off the path itself rather than joined from the row's own
        // `isRelativePath` column. The two agree — `FileUtils
        // .resolvePortableAttachmentPath` already classifies by leading `/`
        // for exactly this reason — and the path is the thing that will be
        // resolved, so deriving from it cannot disagree with what the
        // resolver does, whereas a stale flag on the row could.
        isRelative: !(value is String && value.startsWith('/')),
      );
      if (hash == null) continue;
      await db.update(
        'sync_pending_ops',
        {'blobHash': hash},
        where: 'authorId = ? AND authorSeq = ?',
        whereArgs: [authorId, row['authorSeq']],
      );
    }
  }

  /// Replaces a content-backed column's inline value with null, so the bytes
  /// travel once as a blob rather than in every commit that touches the row.
  ///
  /// **Done at encode time and NOT by mutating the stored row**, which is
  /// what keeps step 0's resume sound: stripping is a pure function of
  /// `(entityTable, fieldName)`, so re-encoding a recorded intent from the
  /// same rows produces byte-identical output, while the local row keeps the
  /// content the uploader reads from. Mutating the row would have made the
  /// upload's source disappear.
  Map<String, Object?> _withoutInlinedBlobContent(Map<String, Object?> row) {
    if (!isContentBlobColumn(
      row['entityTable'] as String? ?? '',
      row['fieldName'] as String?,
    )) {
      return row;
    }
    if (row['blobHash'] == null) {
      // No hash means the upload never happened (an empty value, or a
      // failure). Sending the value inline is the honest fallback: the row
      // still syncs, at the cost of the bytes travelling in the commit.
      return row;
    }
    return {...row, 'valueJson': null};
  }

  /// Blob references carried by this namespace's still-unpublished
  /// operations — both the content hash and the path to read it from, since
  /// the register does not yet hold either on the sending device.
  Future<List<BlobReference>> _pendingBlobReferences(
    DatabaseExecutor db,
    String authorId,
  ) async => BlobSyncPhase.referencesInPendingOps(
    await db.query(
      'sync_pending_ops',
      // `fieldName` is load-bearing, not decorative: it is what
      // `referencesInPendingOps` uses to tell a content-backed column from a
      // file-backed one. Omitting it silently classified every `appCode` as
      // a PATH and sent the uploader looking for a file named after the
      // source code, which failed as "missing locally" and uploaded nothing.
      columns: const [
        'blobHash',
        'valueJson',
        'entityTable',
        'entityId',
        'fieldName',
      ],
      where: 'authorId = ? AND publishedAt IS NULL AND blobHash IS NOT NULL',
      whereArgs: [authorId],
    ),
  );

  Future<_CommitBatch> _encodeBatch(
    DatabaseExecutor db,
    String authorId,
    List<int> authorSeqs,
  ) async {
    final placeholders = List.filled(authorSeqs.length, '?').join(',');
    final rows = await db.query(
      'sync_pending_ops',
      where: 'authorId = ? AND authorSeq IN ($placeholders)',
      whereArgs: [authorId, ...authorSeqs],
      orderBy: 'authorSeq ASC',
    );
    if (rows.length != authorSeqs.length) {
      throw StateError(
        'sync_pending_ops is missing rows for authorId=$authorId at '
        '${authorSeqs.where((s) => !rows.any((r) => r['authorSeq'] == s)).toList()} '
        '— pending operations are immutable once minted',
      );
    }
    final bytes = encodeCommitBatchBytes([
      for (final row in rows)
        WireOperation.fromPendingOpsRow(_withoutInlinedBlobContent(row)),
    ]);
    return _CommitBatch(
      authorSeqs: [for (final row in rows) row['authorSeq'] as int],
      bytes: bytes,
      payloadHash: _payloadHash(bytes),
    );
  }

  /// Rebuilds exactly the commit a recorded, still-pending intent covers.
  ///
  /// **The intent RECORDS which operations it covers
  /// (`sync_publish_intent.opAuthorSeqsJson`, added by schema v61), so this
  /// method verifies rather than searches.** An earlier version of this file
  /// carried no such column and instead re-derived the batch by trying
  /// candidate layouts — the batch today's constants would form, then every
  /// shorter prefix — accepting whichever re-encoding hashed to
  /// [payloadHash]. That worked only for batches no LARGER than today's
  /// constants produce. A future release that ever LOWERED
  /// [maxOperationsPerCommit] or [maxPayloadBytesPerCommit], meeting a push
  /// interrupted by the build that preceded it, would find no candidate at
  /// all, throw, and throw again on every subsequent `push()` — the
  /// namespace could never publish again without manual database surgery.
  /// Nothing would be lost, but it is exactly the permanent-wedge class
  /// M2.10 exists to have removed. Recording the answer costs one nullable
  /// column and removes the failure mode outright; it also removes the
  /// search's cost, which was up to [maxOperationsPerCommit] full
  /// `_encodeBatch` calls, each loading every covered row's `valueJson` —
  /// megabytes of `notes.content`, on a phone, per resumed intent.
  ///
  /// The recorded `authorSeq` list is still not trusted blindly: the batch is
  /// re-encoded from the named rows and its hash must equal [payloadHash]
  /// before it is used. That check is what makes a match PROOF (the encoding
  /// is a pure function of the rows' own immutable columns) rather than
  /// inference.
  ///
  /// [opAuthorSeqsJson] is null for an intent written before v61 — a
  /// pre-M2.12, one-operation-per-commit intent, and the one case where
  /// `deviceSeq` really does name an `authorSeq`. Those must still resume
  /// correctly for a user who already has v1 commits on a backend, so they
  /// fall back to re-encoding that single operation in the v1 envelope.
  /// Looked up WITHOUT a `publishedAt IS NULL` filter, matching the
  /// pre-M2.12 code's own query, so an operation stamped published by a
  /// partially-completed earlier attempt is still findable.
  ///
  /// Returns null if nothing verifies — the caller treats that as corruption.
  Future<_CommitBatch?> _reconstructBatch(
    DatabaseExecutor db, {
    required String authorId,
    required int deviceSeq,
    required String payloadHash,
    required String? opAuthorSeqsJson,
  }) async {
    if (opAuthorSeqsJson != null) {
      final authorSeqs = [
        for (final seq in jsonDecode(opAuthorSeqsJson) as List<dynamic>)
          seq as int,
      ];
      if (authorSeqs.isEmpty) return null;
      final batch = await _encodeBatch(db, authorId, authorSeqs);
      return batch.payloadHash == payloadHash ? batch : null;
    }

    final legacyRows = await db.query(
      'sync_pending_ops',
      where: 'authorId = ? AND authorSeq = ?',
      whereArgs: [authorId, deviceSeq],
      limit: 1,
    );
    if (legacyRows.isNotEmpty) {
      final bytes = encodeCommitBytes(
        WireOperation.fromPendingOpsRow(legacyRows.first),
      );
      if (_payloadHash(bytes) == payloadHash) {
        return _CommitBatch(
          authorSeqs: [deviceSeq],
          bytes: bytes,
          payloadHash: payloadHash,
        );
      }
    }

    return null;
  }

  // ── The resume/retry primitive ───────────────────────────────────────

  /// § 11.7 Phase A step 0's resume procedure, exactly as written — and,
  /// per step 3's explicit "resolve exactly as step 0's resume procedure
  /// does," also what a step-2 `Ambiguous` outcome falls into. Checks
  /// whether the commit already landed via `readCommits`; if not, retries
  /// `appendCommit` under the identical [intentHash] and recurses on a
  /// further `Ambiguous` (bounded by [_maxAmbiguousResolutionAttempts]).
  /// Returns the confirmed `commitHash`. Throws [PushParentMismatchException]
  /// or [PushAmbiguousUnresolvedException] on an unresolvable outcome.
  ///
  /// **Unchanged in shape by batching, and that is the point:** the
  /// procedure compares the payload hash of what is stored at [deviceSeq]
  /// against the payload hash of what it is trying to publish. A payload
  /// carrying N operations is compared exactly as a payload carrying 1 was;
  /// only [_confirmAndAdvance]'s bookkeeping had to learn that a
  /// confirmation stamps N rows rather than one.
  Future<String> _resolveOnePublish({
    required Database db,
    required SyncBackend backend,
    required String authorId,
    required int deviceSeq,
    required String intentHash,
    required String? parentCommitHash,
    required _CommitBatch batch,
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
          _sha256Hex(commit.commitBytes) == batch.payloadHash) {
        // The earlier appendCommit actually landed.
        await _confirmAndAdvance(
          db,
          authorId: authorId,
          deviceSeq: deviceSeq,
          authorSeqs: batch.authorSeqs,
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
      commitBytes: batch.bytes,
    );

    switch (outcome) {
      case AppendCommitSucceeded(:final commitHash):
        await _confirmAndAdvance(
          db,
          authorId: authorId,
          deviceSeq: deviceSeq,
          authorSeqs: batch.authorSeqs,
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
          batch: batch,
          attempt: attempt + 1,
          publishedSoFar: publishedSoFar,
        );
    }
  }

  // ── Local bookkeeping ────────────────────────────────────────────────

  Future<String?> _readTip(DatabaseExecutor db, String authorId) async {
    final rows = await db.query(
      'sync_state',
      where: 'key = ?',
      whereArgs: ['tip:$authorId'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// This namespace's last confirmed commit-chain position.
  ///
  /// The `commit_seq:` row is written by [_confirmAndAdvance]. When it is
  /// absent the log either has no commits at all (-> 0) or was written
  /// entirely by the pre-M2.12 build, where one commit == one operation and
  /// `sync_publish_intent.deviceSeq` recorded that commit's position
  /// directly — so `MAX(deviceSeq)` over this namespace's intents is exactly
  /// the last position used, and the chain continues from there. No
  /// migration, and no round trip to the backend, is needed to find it.
  Future<int> _readCommitSeq(DatabaseExecutor db, String authorId) async {
    final rows = await db.query(
      'sync_state',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [commitSeqKey(authorId)],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final parsed = int.tryParse(rows.first['value'] as String? ?? '');
      if (parsed != null) return parsed;
    }
    final legacy = await db.rawQuery(
      'SELECT MAX(deviceSeq) AS maxSeq FROM sync_publish_intent '
      'WHERE authorId = ?',
      [authorId],
    );
    return (legacy.first['maxSeq'] as int?) ?? 0;
  }

  /// Records a `sync_publish_intent` row as its own, quick, local
  /// transaction — deliberately NOT wrapped around the subsequent
  /// `appendCommit` network call (holding a SQLite write transaction open
  /// across an awaited network round-trip would serialize local DB access
  /// for an unbounded time). `intentHash` is `UNIQUE`; `ConflictAlgorithm.
  /// ignore` makes re-recording an already-present intent (e.g. a second
  /// `push()` call within the same process before the first's outcome is
  /// known) a safe no-op rather than a thrown constraint violation.
  ///
  /// [authorSeqs] is what makes the resume procedure a verification rather
  /// than a search — see [_reconstructBatch]. Recorded here, before the
  /// network call, for the same reason everything else on this row is: the
  /// crash this whole mechanism exists for can happen the instant after
  /// this insert commits.
  Future<void> _recordIntent(
    Database db, {
    required String intentHash,
    required String? parentCommitHash,
    required String payloadHash,
    required String authorId,
    required int deviceSeq,
    required List<int> authorSeqs,
  }) async {
    await db.insert('sync_publish_intent', {
      'intentHash': intentHash,
      'parentCommitHash': parentCommitHash,
      'payloadHash': payloadHash,
      'authorId': authorId,
      'deviceSeq': deviceSeq,
      'opAuthorSeqsJson': jsonEncode(authorSeqs),
      'status': 'pending',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'confirmedAt': null,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Marks the intent confirmed, stamps `sync_pending_ops.publishedAt` for
  /// **every operation the commit carried**, and advances both
  /// `sync_state['tip:<authorId>']` and
  /// `sync_state['commit_seq:<authorId>']` — all in one local transaction,
  /// so a crash partway through this call is impossible to observe as
  /// "confirmed but not published", "tip advanced but intent still pending",
  /// or (new with batching) "half the commit's operations published".
  Future<void> _confirmAndAdvance(
    Database db, {
    required String authorId,
    required int deviceSeq,
    required List<int> authorSeqs,
    required String commitHash,
    required String intentHash,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final placeholders = List.filled(authorSeqs.length, '?').join(',');
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
        where: 'authorId = ? AND authorSeq IN ($placeholders)',
        whereArgs: [authorId, ...authorSeqs],
      );
      await txn.insert('sync_state', {
        'key': 'tip:$authorId',
        'value': commitHash,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('sync_state', {
        'key': commitSeqKey(authorId),
        'value': '$deviceSeq',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }
}
