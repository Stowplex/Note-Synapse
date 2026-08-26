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
import 'dart:typed_data';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../utils/file_utils.dart';
import '../data_change_notifier.dart';
import '../database_service.dart';
import '../logger_service.dart';
import 'blob_gc.dart';
import 'large_row_reader.dart';
import 'sync_backend.dart';
import 'sync_change_publisher.dart';
import 'sync_crypto.dart';

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

/// Columns whose OWN CONTENT is the blob — as opposed to
/// [syncBlobBackedColumns], where the content is a path naming a file.
///
/// `app_revisions.appCode` is an entire mini-app's HTML/JS source living in
/// a `TEXT NOT NULL` column. It is the last thing blocking `app_revisions`
/// from syncing at all, and it is exactly the content class CLAUDE.md's
/// "Database Columns (Large Data)" note singles out and § Architecture 4's
/// blob mechanism exists for.
///
/// **The two kinds share a transport and differ in one place only: where
/// the bytes live locally.** A file-backed column reads and writes a file;
/// a content-backed column reads and writes the database column itself. Both
/// address the bytes by their hash, both upload once per distinct content,
/// and both leave the row usable before the bytes arrive — an attachment
/// renders as "file not found", a revision renders as "code hasn't arrived
/// on this device".
///
/// **The value does not travel inline.** A content-backed column's operation
/// carries its `blobHash` and a null value, stripped deterministically at
/// encode time (`push_phase.dart`'s `_encodeBatch`) rather than by mutating
/// the stored row — so step 0's resume re-encodes the identical bytes while
/// the local row keeps the content the upload reads from.
const Map<String, String> syncContentBlobColumns = {
  'app_revisions': 'appCode',
  // **M3.8, found while fixing the CursorWindow failure.** `htmlContent` is
  // a mini app's whole HTML — CLAUDE.md says the column "should NOT be
  // used" and M2.14 recorded it as always `''` — but it has been in
  // `user_apps`' sync scope since M2.4, so a legacy app that still holds
  // content there shipped megabytes inline in the commit log and was one
  // half of the row that would not fit through Android's CursorWindow.
  //
  // Blobbed rather than dropped from scope: excluding it would stop a
  // legacy app's content reaching a second device at all, which is a
  // silent data loss for exactly the users who have it. As a blob it
  // travels once, addressed by content, and never touches a commit.
  'user_apps': 'htmlContent',
};

/// Whether [fieldName] on [entityTable] is a column whose value is replaced
/// by a blob reference on the wire.
bool isContentBlobColumn(String entityTable, String? fieldName) =>
    fieldName != null && syncContentBlobColumns[entityTable] == fieldName;

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
    this.storedPath,
    this.isRelative = true,
    this.contentColumn,
    this.inlineContent,
  });

  final String blobHash;
  final String entityTable;
  final String entityId;

  /// File-backed only: the path stored in the row.
  final String? storedPath;
  final bool isRelative;

  /// Content-backed only: the column whose value IS the blob.
  final String? contentColumn;

  /// Content-backed only, and only while pushing: the bytes as the pending
  /// operation still holds them, so the uploader never has to go back to the
  /// entity row for content the operation already carries.
  final String? inlineContent;

  bool get isContentBacked => contentColumn != null;
}

/// Uploads blobs referenced by outgoing operations, and fetches blobs
/// referenced by rows this device has but whose bytes it lacks.
class BlobSyncPhase {
  BlobSyncPhase(
    this._databaseService, {
    BlobFileResolver resolver = const AppDocumentsBlobFileResolver(),
    DatasetCrypto crypto = const DatasetCrypto.plaintext(),
    BlobGc? gc,
    DataChangeNotifier? changeNotifier,
  }) : _resolver = resolver,
       _crypto = crypto,
       _changes = SyncChangePublisher(changeNotifier: changeNotifier),
       _gc = gc ?? BlobGc(_databaseService);

  final DatabaseService _databaseService;
  final BlobFileResolver _resolver;

  /// Announces the rows whose bytes [fetchMissing] just landed — see that
  /// method for why an arriving FILE is a change even though its row arrived
  /// rounds earlier.
  final SyncChangePublisher _changes;

  /// **M3.4.** Blob bytes are sealed on upload and opened on download, while
  /// the ADDRESS stays the plaintext hash — see this file's header for why
  /// content addressing cannot survive hashing ciphertext.
  ///
  /// The verification § Architecture 4 requires does not disappear when the
  /// backend can no longer perform it; it moves here, and gets stronger:
  /// AEAD authentication rejects any modified byte before the plaintext hash
  /// is computed at all, so a tampered blob fails on the tag rather than on
  /// a hash comparison.
  final DatasetCrypto _crypto;

  /// Records every blob this device puts on or takes off the backend, so
  /// `blob_gc.dart` has something to age. Nullable only so a test can turn
  /// the bookkeeping off; production always has one.
  final BlobGc? _gc;

  /// sha256 of a file's bytes, streamed.
  ///
  /// **Over the plaintext, always** — § Architecture 4 requires it, and the
  /// reason is dedup rather than tidiness: `blobExists` only saves an upload
  /// if two devices that hold identical bytes compute the identical address,
  /// which hashing after a non-deterministic AEAD could never guarantee.
  /// When § 8.5's encryption lands, the ciphertext is what is stored at this
  /// address, not what defines it.
  /// sha256 of a string's UTF-8 bytes — the content-backed counterpart of
  /// [hashFile], used for `app_revisions.appCode`.
  static String hashString(String content) =>
      sha256.convert(utf8.encode(content)).toString();

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
          // Already on the backend — still this dataset's blob, so it needs
          // a `sync_blob_refs` row or GC would have nothing to age.
          await _gc?.noteBlobPresent(hash);
          continue;
        }
        if (reference.isContentBacked) {
          final content = reference.inlineContent;
          if (content == null) {
            missing.add(hash);
            continue;
          }
          final bytes = await _crypto.seal(utf8.encode(content), 'blob');
          await backend.uploadBlob(
            contentHash: hash,
            data: Stream.value(bytes),
            length: bytes.length,
            sealed: _crypto.isEncrypted,
          );
          uploaded++;
          await _gc?.noteBlobPresent(hash);
          continue;
        }
        final path = await _resolver.absolutePath(
          reference.storedPath!,
          reference.isRelative,
        );
        final file = File(path);
        if (!await file.exists()) {
          missing.add(hash);
          continue;
        }
        if (_crypto.isEncrypted) {
          // Read whole rather than streamed: AEAD authenticates a message as
          // a unit, so a streaming seal would need a chunked construction
          // this milestone does not define. Attachments are phone-sized;
          // when that stops being true the fix is a framed multi-chunk
          // format, not a lazier tag.
          final sealed = await _crypto.seal(await file.readAsBytes(), 'blob');
          await backend.uploadBlob(
            contentHash: hash,
            data: Stream.value(sealed),
            length: sealed.length,
            sealed: true,
          );
        } else {
          await backend.uploadBlob(
            contentHash: hash,
            data: file.openRead(),
            length: await file.length(),
          );
        }
        uploaded++;
        await _gc?.noteBlobPresent(hash);
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
  ///
  /// **Announces what it landed** (`sync_change_publisher.dart`), for the
  /// same reason `PullPhase.pull` does — and it is a genuinely separate
  /// announcement, not a duplicate of the pull's. An `attachments` ROW
  /// arrives in Phase B, at which point this device has a PDF it cannot read:
  /// the reindex the pull announces runs the pdf_text/ocr/figures stages
  /// against a file that is not there yet. The bytes land here, in Phase C,
  /// with nothing else in the round left to notice. Without this, an
  /// attachment pulled from a peer would never be text-extracted, OCR'd or
  /// figure-cropped until something else edited its note.
  Future<BlobSyncResult> fetchMissing(SyncBackend backend) async {
    final wanted = await outstandingReferences();
    if (wanted.isEmpty) return const BlobSyncResult();
    final changes = SyncChangeCollector();

    var downloaded = 0;
    final failed = <String>[];
    final stillMissing = <String>[];

    for (final reference in wanted) {
      try {
        if (reference.isContentBacked) {
          if (!await backend.blobExists(reference.blobHash)) {
            stillMissing.add(reference.blobHash);
            continue;
          }
          final stream = await backend.downloadBlob(
            reference.blobHash,
            sealed: _crypto.isEncrypted,
          );
          final bytes = await _openAndVerify(stream, reference.blobHash);
          // Written straight into the column. `downloadBlob`'s contract is
          // that it never returns bytes that mismatch the hash, so what
          // lands here is exactly what the authoring device had.
          final db = await _databaseService.database;
          await db.update(
            reference.entityTable,
            {reference.contentColumn!: utf8.decode(bytes)},
            where: '${_idColumnFor(reference.entityTable)} = ?',
            whereArgs: [reference.entityId],
          );
          downloaded++;
          changes.recordRow(reference.entityTable, reference.entityId);
          await _gc?.noteBlobPresent(reference.blobHash);
          continue;
        }
        final path = await _resolver.absolutePath(
          reference.storedPath!,
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
        final stream = await backend.downloadBlob(
          reference.blobHash,
          sealed: _crypto.isEncrypted,
        );
        // Written to a sibling temp file and renamed, so an interrupted
        // download can never leave a truncated file sitting at a path the
        // app treats as present — which would be indistinguishable from a
        // real attachment and would fail at open time instead of here.
        final target = File(path);
        await target.parent.create(recursive: true);
        final temp = File('$path.part');
        await temp.writeAsBytes(
          await _openAndVerify(stream, reference.blobHash),
          flush: true,
        );
        await temp.rename(path);
        downloaded++;
        // Recorded only after the atomic rename: a `.part` file that never
        // made it into place is not an arrival.
        changes.recordRow(reference.entityTable, reference.entityId);
        await _gc?.noteBlobPresent(reference.blobHash);
      } catch (e) {
        LoggerService.error(
          'BlobSyncPhase: download of ${reference.blobHash} failed: $e',
        );
        failed.add(reference.blobHash);
      }
    }
    await _changes.publish(await _databaseService.database, changes);
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
        if (reference.isContentBacked) {
          // The shell row wrote `shellRowPlaceholderValue` ('' for TEXT) and
          // the field write was skipped because the operation carries no
          // inline value — so an empty column IS the outstanding work, with
          // nothing to record and nothing to age. Deliberately not a hash
          // comparison: `appCode` is megabytes, and re-hashing every
          // revision on every health recompute would cost more than the
          // download it is checking for.
          if (await _contentColumnIsEmpty(reference)) outstanding.add(reference);
          continue;
        }
        final path = await _resolver.absolutePath(
          reference.storedPath!,
          reference.isRelative,
        );
        if (!await File(path).exists()) outstanding.add(reference);
      } catch (_) {
        outstanding.add(reference);
      }
    }
    return outstanding;
  }

  /// Collects a downloaded stream, decrypts it if the dataset is encrypted,
  /// and verifies the PLAINTEXT hash.
  ///
  /// This is the verification § Architecture 4 assigns to `downloadBlob`,
  /// relocated to the only layer that can perform it once the stored bytes
  /// are ciphertext. It is not a weakening: for an encrypted dataset the AEAD
  /// tag has already rejected any modified byte before this hash is computed,
  /// so a tampered blob fails earlier and more precisely than a hash
  /// comparison would have caught it.
  Future<List<int>> _openAndVerify(
    Stream<List<int>> stream,
    String expectedHash,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    final opened = await _crypto.open(builder.toBytes(), 'blob $expectedHash');
    if (_crypto.isEncrypted) {
      final actual = sha256.convert(opened).toString();
      if (actual != expectedHash) {
        throw SyncDecryptionFailedException(
          'blob $expectedHash (decrypted bytes hash to $actual)',
        );
      }
    }
    return opened;
  }

  static String _idColumnFor(String table) =>
      DatabaseService.syncEntityCaptureScopes
          .firstWhere((s) => s.table == table)
          .idColumn;

  /// **Asks for the LENGTH, never the value** (M3.8). This decides "is
  /// `appCode` still the empty placeholder?", and reading the column to
  /// answer it means pulling a whole vendored WebAssembly build through
  /// Android's CursorWindow in order to compare it against `''` — the
  /// failure a real device reported.
  Future<bool> _contentColumnIsEmpty(BlobReference reference) async {
    final db = await _databaseService.database;
    return await syncColumnLength(
          db,
          table: reference.entityTable,
          column: reference.contentColumn!,
          idColumn: _idColumnFor(reference.entityTable),
          entityId: reference.entityId,
        ) ==
        0;
  }

  /// Every (row, blobHash) pair this device knows about, read from the
  /// winning registers joined to the real rows.
  /// Every (row, blobHash) pair this device knows about — public so
  /// `blob_gc.dart` decides "referenced" with the same query the fetch phase
  /// uses. Two definitions of liveness is how a GC deletes something that
  /// was in use.
  Future<List<BlobReference>> allReferences() => _allReferences();

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

    for (final entry in syncContentBlobColumns.entries) {
      final table = entry.key;
      final column = entry.value;
      final scope = DatabaseService.syncEntityCaptureScopes
          .where((s) => s.table == table)
          .firstOrNull;
      if (scope == null) continue;
      final rows = await db.rawQuery(
        'SELECT s.blobHash AS blobHash, '
        'CAST(t.${scope.idColumn} AS TEXT) AS entityId '
        'FROM sync_field_state s '
        'JOIN $table t ON CAST(t.${scope.idColumn} AS TEXT) = s.entityId '
        'WHERE s.entityTable = ? AND s.fieldName = ? '
        'AND s.blobHash IS NOT NULL',
        [table, column],
      );
      for (final row in rows) {
        references.add(
          BlobReference(
            blobHash: row['blobHash'] as String,
            entityTable: table,
            entityId: row['entityId'] as String,
            contentColumn: column,
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
      final entityTable = row['entityTable'] as String? ?? '';
      final fieldName = row['fieldName'] as String?;
      if (isContentBlobColumn(entityTable, fieldName)) {
        references.add(
          BlobReference(
            blobHash: hash,
            entityTable: entityTable,
            entityId: row['entityId'] as String? ?? '',
            contentColumn: fieldName,
            inlineContent: value,
          ),
        );
        continue;
      }
      references.add(
        BlobReference(
          blobHash: hash,
          entityTable: entityTable,
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
