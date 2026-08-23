// Content-addressed blob transport — M3.1, § Architecture 4 of the
// CRDT-cloud-sync design (`plan-and-propse-the-glistening-dolphin.md`).
//
// ---------------------------------------------------------------------
// **The gap this closes.**
// ---------------------------------------------------------------------
// M2.14 made `attachments` and `conversation_attachments` round-trip, so a
// second device now receives the attachment ROW — its name, its type, its
// path — and not one byte of the file it names. The user sees the existing
// per-item "file not found" state on every attachment they own. That was
// disclosed rather than hidden, and it was always M3's job to close.
//
// This file is the transport: a file's bytes travel once, addressed by the
// hash of their content, and every row that names the same content shares
// one upload.
//
// ---------------------------------------------------------------------
// **Why almost nothing new was needed, and what that says about the design.**
// ---------------------------------------------------------------------
// The pieces were built and left unused, in three separate milestones:
//
//  * `SyncBackend.blobExists`/`uploadBlob`/`downloadBlob` (M2.1), with
//    `MockSyncBackend`'s fault injection and the conformance suite already
//    exercising torn writes, post-write corruption and quota errors;
//  * `Operation.blobHash` — a first-class field in § Architecture 1's
//    canonical encoding, carried by both the v1 and v2 wire envelopes
//    (`wire_format.dart`) and by `IncomingOperation`, and stored on the
//    winning register by `field_conflict_resolver.dart`;
//  * `sync_blob_refs` (M1.1), the GC bookkeeping § Architecture 4's
//    policy-based grace-period mechanism will use.
//
// So there is **no schema change here and no wire-format change**: the
// register already has a `blobHash` column, and a field operation already
// has somewhere to put one. What was missing is only the two ends — nobody
// ever computed a hash when minting, and nobody ever fetched the bytes when
// materializing.
//
// ---------------------------------------------------------------------
// **The one real design decision: `blobHash` travels BESIDE `valueJson`,
// not instead of it.**
// ---------------------------------------------------------------------
// § Architecture 1's operation encoding presents `valueJson` and `blobHash`
// as alternatives ("`valueJson | blobHash`"). For an attachment they are
// not: the column's value is a *path*, which the receiving device genuinely
// needs (it is what every read path in the app resolves), and the bytes are
// a *separate* artifact that path names. Sending only the hash would leave
// the row unbuildable; sending only the path leaves it dangling, which is
// exactly today's bug.
//
// So a blob-backed field operation carries both, and they mean different
// things: `valueJson` is the register's value and takes part in conflict
// resolution unchanged, while `blobHash` is an attachment to that value —
// consulted only by this file, and only to decide whether bytes need to
// move. A device that has the bytes already (the same file attached twice,
// or a re-download after a reinstall) moves nothing.
//
// **Consequence, stated because it is not obvious**: two devices that
// attach the *same* file under different names produce different
// `valueJson` and the same `blobHash`. They conflict on the path, as they
// should, and share one upload, as they should. Two devices that attach
// *different* files under the same name produce the same `valueJson` and
// different `blobHash`es — the field conflict resolves the path, and the
// losing side's bytes are still uploaded (they are referenced by that
// device's own row until it materializes the winner). That is deliberate:
// § Architecture 4's GC, not the upload path, is what eventually reclaims
// an unreferenced blob, and uploading a blob nobody ends up naming is
// wasted bytes rather than lost data.
//
// ---------------------------------------------------------------------
// **Fetching is a PHASE, not part of materialization.**
// ---------------------------------------------------------------------
// Materialization runs inside a database transaction. Downloading a file
// inside one would hold a write lock across the network — on a phone, for
// as long as the slowest attachment takes — and a failed download would
// roll back the row that names it. So materialization does what it has
// always done (writes the register and the row) and this phase runs
// afterwards, reading the register to find files that are named but absent.
//
// That also makes the work **restartable for free**: the register is
// durable, so an interrupted fetch simply finds the same missing file next
// round. There is no queue to keep consistent, no retry counter to age, and
// nothing to leak — the absence of the file IS the outstanding work. This
// is the same "derive it, do not record it" preference § Architecture 6
// applies to orphan messages and empty conversations, and it is why this
// milestone adds no table.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../utils/file_utils.dart';
import '../database_service.dart';
import '../logger_service.dart';
import 'sync_backend.dart';

/// The sync-scope columns whose value NAMES A LOCAL FILE, per table.
///
/// Both entries are the attachment tables M2.14 taught to round-trip. The
/// column holds a path (relative to the app documents directory when the
/// row's `isRelativePath` is set), and the bytes at that path are what this
/// file moves.
///
/// **Deliberately a map and not a `PRAGMA`-derived predicate**, unlike
/// `existsCarriedColumns` next door. Nothing in a SQLite schema marks a
/// TEXT column as "this names a file" — `attachments.filePath` and
/// `attachments.fileName` are the same declared type — so a derivation
/// would have to key on the column's *name*, which is a convention, not a
/// constraint. An explicit list is honest about being a list, and a table
/// added without an entry here syncs its rows exactly as it does today
/// rather than silently acquiring a transport.
const Map<String, String> syncBlobBackedColumns = {
  'attachments': 'filePath',
  'conversation_attachments': 'filePath',
};

/// The companion column recording whether the path is relative to the app
/// documents directory. Absent means "always relative".
const Map<String, String> syncBlobPathIsRelativeColumns = {
  'attachments': 'isRelativePath',
  'conversation_attachments': 'isRelativePath',
};

/// Resolves a stored attachment path to an absolute one, and does the file
/// I/O. Injected so tests can drive the whole phase without `path_provider`
/// or a real documents directory.
abstract class BlobFileResolver {
  Future<String> absolutePath(String storedPath, bool isRelative);
}

/// The production resolver: the same `FileUtils.getFullFilePath` every read
/// path in the app already uses, so a file this phase writes is a file the
/// note detail screen finds.
class AppDocumentsBlobFileResolver implements BlobFileResolver {
  const AppDocumentsBlobFileResolver();

  @override
  Future<String> absolutePath(String storedPath, bool isRelative) =>
      FileUtils.getFullFilePath(storedPath, isRelative);
}

/// What one blob phase did — diagnostics, and the input to the health
/// surface's "files still missing" report.
class BlobSyncResult {
  const BlobSyncResult({
    this.uploaded = 0,
    this.alreadyOnBackend = 0,
    this.downloaded = 0,
    this.missingLocally = const [],
    this.failed = const [],
  });

  /// Blobs whose bytes this device sent.
  final int uploaded;

  /// Blobs the backend already had, so nothing was sent. Counted separately
  /// because it is the measure of whether content addressing is earning its
  /// keep — a second device attaching the same file should upload nothing.
  final int alreadyOnBackend;

  final int downloaded;

  /// Blob hashes referenced by a local row whose file this device does not
  /// have and could not upload. Distinct from [failed]: nothing went wrong
  /// on the network, the bytes simply are not here (the row arrived from a
  /// peer whose upload has not happened yet, or the user deleted the file
  /// out from under the row).
  final List<String> missingLocally;

  /// Blob hashes whose transfer threw. Reported, never silently swallowed —
  /// the failure class M2.10's health spine exists for.
  final List<String> failed;

  bool get isClean => missingLocally.isEmpty && failed.isEmpty;
}

/// One blob-backed field reference: a row that names a file, and the hash
/// of the bytes it should contain.
class BlobReference {
  const BlobReference({
    required this.blobHash,
    required this.entityTable,
    required this.entityId,
    required this.storedPath,
    required this.isRelative,
  });

  final String blobHash;
  final String entityTable;
  final String entityId;
  final String storedPath;
  final bool isRelative;
}

/// Uploads blobs referenced by outgoing operations, and fetches blobs
/// referenced by rows this device has but whose bytes it lacks.
class BlobSyncPhase {
  BlobSyncPhase(
    this._databaseService, {
    BlobFileResolver resolver = const AppDocumentsBlobFileResolver(),
  }) : _resolver = resolver;

  final DatabaseService _databaseService;
  final BlobFileResolver _resolver;

  /// sha256 of a file's bytes, streamed.
  ///
  /// **Over the plaintext, always** — § Architecture 4 requires it, and the
  /// reason is dedup rather than tidiness: `blobExists` only saves an upload
  /// if two devices that hold identical bytes compute the identical address,
  /// which hashing after a non-deterministic AEAD could never guarantee.
  /// When § 8.5's encryption lands, the ciphertext is what is stored at this
  /// address, not what defines it.
  static Future<String> hashFile(File file) async {
    final digest = await file.openRead().transform(sha256).first;
    return digest.toString();
  }

  /// The blob hash for a field about to be minted, or null when the column
  /// is not blob-backed or the file is not there.
  ///
  /// Returning null for a missing file is deliberate and is NOT an error:
  /// this codebase has rows whose file was removed out from under them (the
  /// note detail screen's "file not found" state predates sync entirely), and
  /// refusing to mint the row's other columns because one file is absent
  /// would withhold the user's own metadata from their other device. The row
  /// syncs; the bytes are reported missing.
  Future<String?> blobHashForMint({
    required String entityTable,
    required String fieldName,
    required Object? value,
    required bool isRelative,
  }) async {
    if (syncBlobBackedColumns[entityTable] != fieldName) return null;
    if (value is! String || value.isEmpty) return null;
    try {
      final path = await _resolver.absolutePath(value, isRelative);
      final file = File(path);
      if (!await file.exists()) return null;
      return await hashFile(file);
    } catch (e) {
      // A resolver failure must not take the mint down with it.
      LoggerService.warning('BlobSyncPhase: cannot hash $entityTable/$value: $e');
      return null;
    }
  }

  /// Uploads every blob referenced by [blobHashes] that the backend does not
  /// already hold.
  ///
  /// Called by the push phase BEFORE the commit that references them is
  /// appended — § Architecture 4's "uploaded blobs are verified before any
  /// referencing commit is written". The ordering is the whole point: a
  /// commit naming bytes nobody can fetch is a permanent dangling reference
  /// on every peer, while bytes nobody references yet are merely unreclaimed
  /// storage that § Architecture 4's GC already exists to sweep.
  /// **Takes the references, not just the hashes, and the difference is the
  /// bug this shape exists to prevent.** An earlier version looked the local
  /// file up by joining `sync_field_state` on the hash — which is empty on
  /// the SENDING device, because a register is written when the operation is
  /// minted and the hash is stamped afterwards (see `_stampBlobHashes`). The
  /// sender therefore found no file for its own blob and reported every one
  /// of them as missing, uploading nothing, while every test that only
  /// checked "a hash was computed" passed. The path travels with the pending
  /// operation, so that is where the uploader reads it from.
  Future<BlobSyncResult> uploadReferenced(
    SyncBackend backend,
    Iterable<BlobReference> references,
  ) async {
    if (references.isEmpty) return const BlobSyncResult();

    var uploaded = 0;
    var present = 0;
    final missing = <String>[];
    final failed = <String>[];
    final seen = <String>{};

    for (final reference in references) {
      final hash = reference.blobHash;
      if (!seen.add(hash)) continue; // one upload per content, by definition
      try {
        if (await backend.blobExists(hash)) {
          present++;
          continue;
        }
        final path = await _resolver.absolutePath(
          reference.storedPath,
          reference.isRelative,
        );
        final file = File(path);
        if (!await file.exists()) {
          missing.add(hash);
          continue;
        }
        await backend.uploadBlob(
          contentHash: hash,
          data: file.openRead(),
          length: await file.length(),
        );
        uploaded++;
      } catch (e) {
        LoggerService.error('BlobSyncPhase: upload of $hash failed: $e');
        failed.add(hash);
      }
    }
    return BlobSyncResult(
      uploaded: uploaded,
      alreadyOnBackend: present,
      missingLocally: List.unmodifiable(missing),
      failed: List.unmodifiable(failed),
    );
  }

  /// Downloads the bytes for every blob-backed row this device holds whose
  /// file is absent.
  ///
  /// Runs after the pull, outside any transaction. The outstanding work is
  /// derived from durable state (a register with a `blobHash`, a row with a
  /// path, no file at that path), so an interrupted run resumes by simply
  /// finding the same gap next round — see this file's header for why that
  /// is preferred over a queue.
  Future<BlobSyncResult> fetchMissing(SyncBackend backend) async {
    final wanted = await outstandingReferences();
    if (wanted.isEmpty) return const BlobSyncResult();

    var downloaded = 0;
    final failed = <String>[];
    final stillMissing = <String>[];

    for (final reference in wanted) {
      try {
        final path = await _resolver.absolutePath(
          reference.storedPath,
          reference.isRelative,
        );
        // **Asked, not inferred from an exception type.** No backend in this
        // codebase declares a "blob absent" exception — `downloadBlob`'s
        // contract only promises it never returns bytes that mismatch the
        // hash — so classifying absence by catching some particular type
        // would be reading a convention no interface actually states, and it
        // would silently reclassify a genuine transport failure the day a
        // backend changed what it throws. The extra request costs one round
        // trip per still-missing blob per round, and only while a peer's
        // upload is genuinely outstanding.
        if (!await backend.blobExists(reference.blobHash)) {
          stillMissing.add(reference.blobHash);
          continue;
        }
        final stream = await backend.downloadBlob(reference.blobHash);
        // Written to a sibling temp file and renamed, so an interrupted
        // download can never leave a truncated file sitting at a path the
        // app treats as present — which would be indistinguishable from a
        // real attachment and would fail at open time instead of here.
        final target = File(path);
        await target.parent.create(recursive: true);
        final temp = File('$path.part');
        final sink = temp.openWrite();
        try {
          await sink.addStream(stream);
          await sink.flush();
        } finally {
          await sink.close();
        }
        await temp.rename(path);
        downloaded++;
      } catch (e) {
        LoggerService.error(
          'BlobSyncPhase: download of ${reference.blobHash} failed: $e',
        );
        failed.add(reference.blobHash);
      }
    }
    return BlobSyncResult(
      downloaded: downloaded,
      missingLocally: List.unmodifiable(stillMissing),
      failed: List.unmodifiable(failed),
    );
  }

  /// Blob-backed rows whose file this device does not have.
  ///
  /// Public because the health surface reports the same set — one query, one
  /// definition of "still missing", so the number the user sees and the work
  /// the fetch does cannot drift apart.
  Future<List<BlobReference>> outstandingReferences() async {
    final all = await _allReferences();
    final outstanding = <BlobReference>[];
    for (final reference in all) {
      try {
        final path = await _resolver.absolutePath(
          reference.storedPath,
          reference.isRelative,
        );
        if (!await File(path).exists()) outstanding.add(reference);
      } catch (_) {
        outstanding.add(reference);
      }
    }
    return outstanding;
  }

  /// Every (row, blobHash) pair this device knows about, read from the
  /// winning registers joined to the real rows.
  Future<List<BlobReference>> _allReferences() async {
    final db = await _databaseService.database;
    final references = <BlobReference>[];

    for (final entry in syncBlobBackedColumns.entries) {
      final table = entry.key;
      final column = entry.value;
      final relativeColumn = syncBlobPathIsRelativeColumns[table];
      final scope = DatabaseService.syncEntityCaptureScopes
          .where((s) => s.table == table)
          .firstOrNull;
      if (scope == null) continue;

      final rows = await db.rawQuery(
        'SELECT s.blobHash AS blobHash, '
        'CAST(t.${scope.idColumn} AS TEXT) AS entityId, '
        't.$column AS storedPath'
        '${relativeColumn == null ? '' : ', t.$relativeColumn AS isRelative'} '
        'FROM sync_field_state s '
        'JOIN $table t ON CAST(t.${scope.idColumn} AS TEXT) = s.entityId '
        'WHERE s.entityTable = ? AND s.fieldName = ? '
        'AND s.blobHash IS NOT NULL',
        [table, column],
      );
      for (final row in rows) {
        final storedPath = row['storedPath'] as String?;
        if (storedPath == null || storedPath.isEmpty) continue;
        references.add(
          BlobReference(
            blobHash: row['blobHash'] as String,
            entityTable: table,
            entityId: row['entityId'] as String,
            storedPath: storedPath,
            isRelative: relativeColumn == null
                ? true
                : ((row['isRelative'] as int?) ?? 1) != 0,
          ),
        );
      }
    }
    return references;
  }

  /// The blob references carried by a set of `sync_pending_ops` rows — the
  /// push phase's input. Each row already holds both halves: `blobHash` (the
  /// content) and `valueJson` (the path to read it from).
  static List<BlobReference> referencesInPendingOps(
    List<Map<String, Object?>> rows,
  ) {
    final references = <BlobReference>[];
    for (final row in rows) {
      final hash = row['blobHash'];
      if (hash is! String) continue;
      final value = decodeValue(row['valueJson'] as String?);
      if (value is! String || value.isEmpty) continue;
      references.add(
        BlobReference(
          blobHash: hash,
          entityTable: row['entityTable'] as String? ?? '',
          entityId: row['entityId'] as String? ?? '',
          storedPath: value,
          isRelative: !value.startsWith('/'),
        ),
      );
    }
    return references;
  }

  /// Decodes a `sync_pending_ops.valueJson` back to its raw value, for the
  /// mint-time hash lookup. Kept here so the one place that knows a
  /// blob-backed column holds a path also knows how it is stored.
  static Object? decodeValue(String? valueJson) {
    if (valueJson == null) return null;
    try {
      return jsonDecode(valueJson);
    } catch (_) {
      return null;
    }
  }
}
