// Blob garbage collection — M3.6, § Architecture 4's policy-based mechanism
// and requirement 10's manual-only purge.
//
// ---------------------------------------------------------------------
// **What accumulates, and why nothing reclaimed it.**
// ---------------------------------------------------------------------
// M3.1/M3.2 gave attachments and mini-app sources a content-addressed
// transport. Content addressing never overwrites — a new attachment is a new
// address — so a dataset's blob storage only ever grows. Delete a note with a
// 40 MB video attached and the row tombstones, the reference goes away, and
// the 40 MB stays in Drive forever.
//
// ---------------------------------------------------------------------
// **The safety problem, restated from § Architecture 4's own root-cause
// finding, because it is what shapes everything below.**
// ---------------------------------------------------------------------
// Round 8 of the design review established that a compaction certificate
// proves a PAST-looking fact ("every active member had, as of construction,
// incorporated snapshot S") and cannot prove a FUTURE-looking one ("nothing
// will ever newly reference this blob"). A device that has been offline for
// a week can come back and publish a commit referencing a blob this device
// considers dead. No finite backward-looking evidence rules that out.
//
// So § Architecture 4 does not try to prove it. It requires a certificate as
// a NECESSARY precondition, then a grace period, then a fresh recheck, then
// explicit user confirmation — bounded risk reduction, disclosed as such.
//
// ---------------------------------------------------------------------
// **What this milestone can and cannot do, stated before the code rather
// than discovered after it.**
// ---------------------------------------------------------------------
// **Certificates do not exist yet.** They need snapshots, which need
// device-membership acknowledgment; `sync_ack_frontier` is written by
// `pull_phase.dart` and read by nothing. Building that is its own milestone.
//
// Shipping the grace-period flow WITHOUT the certificate would be exactly
// the mistake round 8 caught: a mechanism that looks safe, reads as safe,
// and rests on evidence that does not exist. So this milestone does not do
// that either.
//
// **What it does instead is the one case where the future-looking question
// has a real answer**: a dataset whose only member is this device. If
// `listDeviceLogIds()` returns nothing but this device's own namespaces,
// then no other device can publish a reference, because there is no other
// device — the property a certificate exists to approximate is here simply
// true, and checkable in one call. That covers a single-device user, and a
// user whose other device is gone and who reset it away.
//
// A multi-device dataset reports its reclaimable bytes and refuses to delete
// them, naming why. That is a smaller feature than § Architecture 4
// describes, and it is the part that can be made honest today.

import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import '../logger_service.dart';
import 'blob_sync.dart';
import 'sync_backend.dart';

/// § Architecture 4's policy knobs. Not user-configurable: a grace period a
/// user can shorten is a grace period that stops meaning anything.
class BlobGcPolicy {
  /// How long a blob must sit unreferenced before it is even offered for
  /// deletion. § Architecture 4's example figure, and deliberately generous
  /// — the whole point is to give an unreachable device time to publish a
  /// reference that takes the blob out of candidacy again.
  static const Duration gracePeriod = Duration(days: 30);
}

/// Why a dataset cannot currently reclaim anything.
enum BlobGcBlocker {
  /// Other devices are members, so a reference could still arrive from one
  /// of them. Needs § Architecture 6's compaction certificate, which needs
  /// snapshots, which do not exist yet.
  multiDeviceWithoutCertificate,
}

/// One blob no live row references any more.
class BlobGcCandidate {
  const BlobGcCandidate({
    required this.blobHash,
    required this.candidateSince,
    required this.eligible,
  });

  final String blobHash;

  /// When this blob was first observed unreferenced — the start of its grace
  /// period, recorded durably so the clock cannot be restarted by a restart.
  final DateTime candidateSince;

  /// Whether the grace period has elapsed. Eligible blobs are the ones the
  /// UI may offer; the rest are shown as pending, per § Architecture 9's
  /// "shows the grace-period-pending and now-eligible sets separately".
  final bool eligible;
}

/// What a scan found.
class BlobGcReport {
  const BlobGcReport({
    required this.candidates,
    required this.blocker,
  });

  final List<BlobGcCandidate> candidates;

  /// Non-null when nothing may be deleted regardless of grace periods.
  final BlobGcBlocker? blocker;

  List<BlobGcCandidate> get eligible =>
      [for (final c in candidates) if (c.eligible) c];

  bool get canDelete => blocker == null && eligible.isNotEmpty;
}

/// Finds unreferenced blobs, ages them, and — only where it can be proved
/// safe — deletes them on explicit confirmation.
class BlobGc {
  BlobGc(this._databaseService, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DatabaseService _databaseService;
  final DateTime Function() _now;

  /// Scans for candidates and advances their grace periods.
  ///
  /// **Reads liveness from the same place the fetch phase does** — the
  /// `blobHash` recorded on winning registers, joined to real rows — so
  /// "referenced" means exactly what it means everywhere else in the engine.
  /// A blob referenced by a row that is merely TOMBSTONED still counts as
  /// live: `__deleted__` is reversible by design (§ Architecture 6's
  /// undelete), and reclaiming the bytes behind an undeletable tombstone
  /// would turn a recoverable delete into a permanent one.
  Future<BlobGcReport> scan(SyncBackend backend) async {
    final db = await _databaseService.database;
    final now = _now();

    final referenced = <String>{
      for (final reference in await BlobSyncPhase(
        _databaseService,
      ).allReferences())
        reference.blobHash,
    };

    // Everything this device has ever uploaded or fetched, from the M1.1
    // bookkeeping table nothing had written to until now.
    final known = await db.query('sync_blob_refs');
    final candidates = <BlobGcCandidate>[];

    for (final row in known) {
      final hash = row['blobHash'] as String;
      if (referenced.contains(hash)) {
        // Back to live — § Architecture 4's "if the blob has since become
        // referenced, it's dropped from candidacy". Restarting the clock is
        // the point: a blob that flickers in and out of reference must earn
        // a full grace period each time.
        if (row['status'] != 'live') {
          await db.update(
            'sync_blob_refs',
            {'status': 'live', 'candidateSince': null, 'lastCheckedAt': now.millisecondsSinceEpoch},
            where: 'blobHash = ?',
            whereArgs: [hash],
          );
        }
        continue;
      }

      var since = row['candidateSince'] as int?;
      if (since == null) {
        since = now.millisecondsSinceEpoch;
        await db.update(
          'sync_blob_refs',
          {'status': 'candidate', 'candidateSince': since, 'lastCheckedAt': since},
          where: 'blobHash = ?',
          whereArgs: [hash],
        );
      }
      final candidateSince = DateTime.fromMillisecondsSinceEpoch(since);
      candidates.add(
        BlobGcCandidate(
          blobHash: hash,
          candidateSince: candidateSince,
          eligible:
              now.difference(candidateSince) >= BlobGcPolicy.gracePeriod,
        ),
      );
    }

    return BlobGcReport(
      candidates: candidates,
      blocker: await _blockerFor(backend),
    );
  }

  /// Deletes the eligible candidates the caller confirmed.
  ///
  /// **Re-scans immediately before deleting rather than trusting the report**
  /// — § Architecture 4's "at the END of the grace period, GC performs a
  /// fresh recheck against the latest available state". A user can sit on a
  /// confirmation dialog for a long time, and a sync in between can bring
  /// back the very reference that makes a candidate live again.
  Future<int> deleteConfirmed(
    SyncBackend backend,
    List<String> blobHashes,
  ) async {
    if (blobHashes.isEmpty) return 0;
    final fresh = await scan(backend);
    if (fresh.blocker != null) {
      throw StateError(
        'BlobGc: refusing to delete — ${fresh.blocker}. This is the fresh '
        'recheck § Architecture 4 requires, not a redundant one: membership '
        'can change between a scan and a confirmation.',
      );
    }
    final stillEligible = {for (final c in fresh.eligible) c.blobHash};

    final db = await _databaseService.database;
    var deleted = 0;
    for (final hash in blobHashes) {
      if (!stillEligible.contains(hash)) {
        LoggerService.info(
          'BlobGc: $hash became referenced (or restarted its grace period) '
          'between the scan and the confirmation — left in place',
        );
        continue;
      }
      final outcome = await backend.deleteConditionally(
        ref: BlobRef(hash),
        precondition: const Unconditional(),
      );
      if (outcome is DeleteSucceeded) {
        await db.update(
          'sync_blob_refs',
          {
            'status': 'deleted',
            'lastCheckedAt': _now().millisecondsSinceEpoch,
          },
          where: 'blobHash = ?',
          whereArgs: [hash],
        );
        deleted++;
      }
    }
    return deleted;
  }

  /// Records a blob this device has put on, or taken off, the backend, so a
  /// later scan has something to age. Called by the blob transport.
  Future<void> noteBlobPresent(String blobHash) async {
    final db = await _databaseService.database;
    await db.insert('sync_blob_refs', {
      'blobHash': blobHash,
      'status': 'live',
      'createdAt': _now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// The one precondition this milestone can actually prove.
  ///
  /// A certificate approximates "no other device will reference this". When
  /// the dataset has no other device, that is not an approximation — it is
  /// the literal truth, established by one `listDeviceLogIds` call. Anything
  /// else waits for § Architecture 6's certificate machinery, and says so
  /// rather than guessing.
  Future<BlobGcBlocker?> _blockerFor(SyncBackend backend) async {
    final ownDeviceId = await _readOwnDeviceId();
    final logs = await backend.listDeviceLogIds();
    final others = logs.where((id) {
      final physical = id.startsWith('seed:')
          ? id.substring('seed:'.length)
          : id.startsWith('external:')
          ? id.substring('external:'.length)
          : id;
      return physical != ownDeviceId;
    });
    return others.isEmpty ? null : BlobGcBlocker.multiDeviceWithoutCertificate;
  }

  Future<String?> _readOwnDeviceId() async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'sync_state',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: ['device_id'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }
}
