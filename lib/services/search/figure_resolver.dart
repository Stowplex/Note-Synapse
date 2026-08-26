// Figure URI resolution for the markdown renderer (plan §4.3, Step 16).
//
// ─── THE FIGURE URI CONTRACT (Steps 14 and 15 conform to THIS) ──────────────
//
// URI form:
//   synapseresource://figure/<figureId>
//   figureId = "<chunkKey>~<first 12 hex chars of the ROW's contentHash>"
//              (built by [FigureResolver.buildFigureId]).
//
// - `chunkKey` is the key of a `search_chunks` row whose `sourceType` is
//   `figure` — i.e. the ChunkDraft key format
//   `{noteId}:{sourceType}:{sourceId|-}:{seq}`. It CONTAINS colons (legal in a
//   URI path segment) and never contains `~`, so the figureId is split on its
//   LAST `~` ([FigureResolver.parseFigureId]).
//
// - The hash half is the figure chunk's `search_chunks.contentHash` COLUMN,
//   and nothing else. Mint it as
//   `FigureResolver.buildFigureId(chunkKey, row.contentHash)`.
//   It is NEVER the derived PNG's sha256 (`DerivedFigure.contentHash`):
//     * ChunkDraft computes `contentHash` in its constructor as
//       `sha256(text)` — or `sha256("text\0meta")` when meta is present —
//       with no override hook (services/search/note_chunker.dart), and the
//       indexer writes exactly that value into the column
//       (services/search/note_index_service.dart). A resolver that expected
//       the PNG hash in that column would fail to verify 100% of real URIs.
//     * PNG bytes are renderer-dependent: `FigureRegionExtractor.renderRegion`
//       documents that the same region re-encodes to different bytes across
//       pdfrx/pdfium versions, so a pixel hash would dangle every embedded
//       figure URI on a dependency bump.
//
// - What makes the row hash a stable REGION-IDENTITY hash is what Step 14 puts
//   in `meta` (the hash covers `text` + `meta`). Step 14 MUST write:
//       page, rect{l,t,r,b}, confidence, source   (FigureRegion.toJson)
//       caption            — when the region has one
//       derivedAssetPath   — 'attachments/derived/<attId>_p<N>_f<i>.png'
//       figureIndex        — MANDATORY, 0-based index of the region on its
//                            page (the `<i>` of the file name)
//   and MUST NOT write any renderer-version-dependent value — in particular
//   NOT the derived PNG's hash. Consequence: the row hash changes exactly when
//   the region's identity changes (rect/page/caption/index move), and survives
//   pdfium upgrades untouched. Re-extraction that renumbers or moves a region
//   therefore invalidates old URIs (they dangle) instead of silently resolving
//   to a DIFFERENT figure.
//
// Resolution algorithm ([FigureResolver.resolve]):
//   1. Split the figureId on its last `~` → (chunkKey, hashPrefix).
//   2. SELECT * FROM search_chunks WHERE chunkKey = ? AND sourceType='figure'.
//      No row → [FigureResolutionStatus.unknownFigure] (dangling).
//   3. Verify `row.contentHash` starts with `hashPrefix` (case-insensitive
//      hex). Mismatch → [FigureResolutionStatus.staleFigure] (dangling). A
//      mismatch NEVER falls through to rendering the row's current asset.
//   4. Verify the owning note still exists (title is read here for the
//      provenance bar). Missing → [FigureResolutionStatus.unknownFigure].
//      Steps 1-4 are all [FigureResolver.resolveTarget] does: it yields the
//      navigation target (note / attachment / page / caption) WITHOUT touching
//      the derived asset. Link taps and the provenance chip use it, so a
//      missing regenerable crop never blocks navigation.
//   5. Parse `meta` JSON:
//        meta.derivedAssetPath  — path relative to the app documents dir,
//                                 resolved via FileUtils.getFullFilePath(path,
//                                 true); absolute paths are used as-is.
//        meta.caption           — figure caption (optional).
//        meta.page / row.page   — 1-based page. meta wins (it is the page the
//                                 rect is expressed in, and the page
//                                 renderRegion writes the file name from); a
//                                 divergence between the two is logged as an
//                                 index inconsistency.
//        row.sourceId           — the owning attachment id (meta.attachmentId
//                                 is accepted as a fallback).
//        meta.figureIndex       — mandatory per above. When absent it is
//                                 parsed back out of the derived path's
//                                 `_f<i>` suffix; when that fails too the
//                                 index is UNKNOWN and is never guessed —
//                                 rendering with a wrong index would make
//                                 renderRegion overwrite a SIBLING region's
//                                 asset (it writes unconditionally), and the
//                                 sibling would then resolve fine while
//                                 displaying the wrong image.
//        the rest of `meta`     — a [FigureRegion] JSON payload (`page`,
//                                 `rect{l,t,r,b}`, `confidence`, `source`,
//                                 optional `caption`), exactly what
//                                 FigureRegion.toJson emits, so the region can
//                                 be re-rendered.
//   6. Probe for the asset on disk. EVERY plausible location is probed before
//      any re-render, because the probe and the regeneration target must not
//      be able to disagree (they used to: probing `row.page` while renderRegion
//      wrote `meta.page` re-rasterized the same figure on every single
//      resolve, forever):
//        a. meta.derivedAssetPath as stored;
//        b. for an absolute stored path, its basename re-rooted under the
//           CURRENT `attachments/derived/` (an app-container UUID from an old
//           install changes the absolute path but not the file);
//        c. the canonical `attachments/derived/<attId>_p<N>_f<i>.png`, when
//           attachmentId + figureIndex are known. `<N>` is the SAME page
//           renderRegion names its output from (meta's), never the row's:
//           probing the row's page too would, on a divergence, hand back a
//           SIBLING region's crop — worse than the loop it fixes.
//   7. Still missing → regenerate with FigureRegionExtractor.renderRegion(
//      pdfPath, attachmentId:, region:, figureIndex:) using the owning
//      attachment's PDF, and then use THE PATH renderRegion says it wrote
//      (never the probed guess). The regenerated PNG is NOT required to hash
//      back to anything; step 3 already proved this row is the right region.
//      Unknown figureIndex, missing attachment/PDF, unusable region JSON or a
//      render failure → [FigureResolutionStatus.assetUnavailable] (dangling
//      IMAGE, but [FigureResolution.target] still carries the navigation
//      target — this is the NORMAL state after a restore, since derived assets
//      are excluded from export/backup).
//      Concurrent resolutions of the same asset share ONE regeneration future
//      (process-global, keyed by the asset the render will write): two widget
//      states showing the same figure would otherwise open pdfium twice and
//      truncate-write the same path twice, letting a reader decode a
//      half-written PNG.
//
// Raster IMAGE attachments are not figure chunks: they keep
// `synapseresource://attachment/<id>` and are resolved by
// [AttachmentLinkService] (no noteId required — see interactive_checkbox_
// markdown.dart). `synapseresource://attachment/<id>?page=N` is a whole PDF
// page and stays a tap-link, never an inline image.
//
// This class is DATABASE-READ-ONLY: it never writes chunks, never re-indexes,
// and its only side effect is (re)writing a regenerable derived PNG.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../utils/file_utils.dart';
import '../database_service.dart';
import '../logger_service.dart';
import 'figure_region_extractor.dart';

/// Why a figure URI did (not) resolve.
enum FigureResolutionStatus {
  /// The derived asset is on disk (possibly just regenerated).
  resolved,

  /// Malformed figureId, no `figure` chunk with that chunkKey, or the owning
  /// note is gone. Dangling: the figure or its note was removed.
  unknownFigure,

  /// The chunk exists but its contentHash does not start with the URI's hash
  /// prefix — the region was re-extracted/renumbered. Dangling: rendering the
  /// row's current asset could show a DIFFERENT figure, so we never do.
  staleFigure,

  /// Chunk + hash verified, but the derived asset is missing and could not be
  /// regenerated (attachment or source PDF gone, unusable region, unknown
  /// figure index, render failure). The FIGURE is fine — only its regenerable
  /// crop is unavailable, so [FigureResolution.target] is still populated and
  /// navigation still works.
  assetUnavailable,
}

/// Where a verified figure URI POINTS — its owning note, attachment and page —
/// independent of whether the derived crop is on disk.
///
/// Returned by [FigureResolver.resolveTarget], and carried by
/// [FigureResolution] whenever the chunk verified.
class FigureTarget {
  const FigureTarget({
    required this.chunkKey,
    required this.contentHash,
    required this.noteId,
    this.noteTitle,
    this.attachmentId,
    this.caption,
    this.page,
  });

  /// The `search_chunks.chunkKey` this figure came from.
  final String chunkKey;

  /// The verified `search_chunks.contentHash`.
  final String contentHash;

  /// Owning note (provenance + navigation target).
  final String noteId;
  final String? noteTitle;

  /// Owning PDF/image attachment (provenance + navigation target).
  final String? attachmentId;

  final String? caption;

  /// 1-based page the region was cropped from.
  final int? page;
}

/// A figure URI that resolved to a real file on disk.
class ResolvedFigure {
  const ResolvedFigure({
    required this.assetPath,
    required this.target,
    this.regenerated = false,
  });

  /// Absolute path of the derived figure PNG.
  final String assetPath;

  /// Provenance / navigation target of this figure.
  final FigureTarget target;

  /// True when the asset was missing and re-rendered during this resolve.
  final bool regenerated;

  String get chunkKey => target.chunkKey;
  String get contentHash => target.contentHash;
  String get noteId => target.noteId;
  String? get noteTitle => target.noteTitle;
  String? get attachmentId => target.attachmentId;
  String? get caption => target.caption;
  int? get page => target.page;
}

/// Outcome of [FigureResolver.resolve]: either a [ResolvedFigure] or a typed
/// dangling reason.
class FigureResolution {
  const FigureResolution._(this.status, [this.figure, this.target]);

  const FigureResolution.unknownFigure()
    : this._(FigureResolutionStatus.unknownFigure);
  const FigureResolution.staleFigure()
    : this._(FigureResolutionStatus.staleFigure);

  /// The figure verified but its crop is unavailable; [target] still carries
  /// the navigation target when it is known.
  const FigureResolution.assetUnavailable([FigureTarget? target])
    : this._(FigureResolutionStatus.assetUnavailable, null, target);
  FigureResolution.resolved(ResolvedFigure figure)
    : this._(FigureResolutionStatus.resolved, figure, figure.target);

  final FigureResolutionStatus status;

  /// Non-null exactly when [status] is [FigureResolutionStatus.resolved].
  final ResolvedFigure? figure;

  /// Non-null whenever the chunk + hash + note verified — including
  /// [FigureResolutionStatus.assetUnavailable], so a figure whose regenerable
  /// crop is gone can still be navigated to.
  final FigureTarget? target;

  bool get isResolved => status == FigureResolutionStatus.resolved;

  /// Any non-resolved outcome renders the dangling-figure placeholder.
  bool get isDangling => !isResolved;

  /// True when the figure ITSELF is gone/renumbered (as opposed to only its
  /// regenerable asset being unavailable).
  bool get isMissingFigure =>
      status == FigureResolutionStatus.unknownFigure ||
      status == FigureResolutionStatus.staleFigure;

  @override
  String toString() => 'FigureResolution(${status.name})';
}

/// Outcome of [FigureResolver.resolveTarget] — the metadata-only lookup.
class FigureTargetResolution {
  const FigureTargetResolution._(this.status, [this.target]);

  const FigureTargetResolution.unknownFigure()
    : this._(FigureResolutionStatus.unknownFigure);
  const FigureTargetResolution.staleFigure()
    : this._(FigureResolutionStatus.staleFigure);
  const FigureTargetResolution.resolved(FigureTarget target)
    : this._(FigureResolutionStatus.resolved, target);

  /// Never [FigureResolutionStatus.assetUnavailable]: this lookup never looks
  /// at the asset. An unexpected failure reports [unknownFigure] — read it as
  /// "no navigable target", not as proof the figure was deleted.
  final FigureResolutionStatus status;

  /// Non-null exactly when [status] is [FigureResolutionStatus.resolved].
  final FigureTarget? target;

  bool get isResolved => status == FigureResolutionStatus.resolved;

  @override
  String toString() => 'FigureTargetResolution(${status.name})';
}

/// Resolves `synapseresource://figure/<figureId>` URIs against the search
/// index. See the file header for the full contract.
class FigureResolver {
  FigureResolver(this._db, {FigureRegionExtractor? extractor})
    : _extractor = extractor ?? FigureRegionExtractor();

  final DatabaseService _db;
  final FigureRegionExtractor _extractor;

  /// `sourceType` of the chunks this resolver reads.
  static const String figureSourceType = 'figure';

  /// Number of leading hex chars of the chunk contentHash carried in a
  /// figureId. Long enough that an unrelated chunk can't collide, short enough
  /// to keep AI-embedded URIs readable.
  static const int hashPrefixLength = 12;

  /// Directory (relative to the app documents dir) holding derived crops.
  static const String derivedAssetDir = 'attachments/derived';

  /// In-flight regenerations, keyed by the derived asset the render will
  /// write. PROCESS-GLOBAL on purpose: a [FigureResolver] is constructed per
  /// call and the widget-level caches are per-State, so the note preview, the
  /// open note and two chat bubbles showing the same figure would otherwise
  /// each open pdfium and truncate-write the same path concurrently — peak
  /// memory multiplies on a render the extractor documents as OOM-sensitive,
  /// and a reader can decode a half-written PNG and show a false "figure
  /// unavailable".
  ///
  /// Residual (deliberately not fixed here): the write inside
  /// [FigureRegionExtractor] is still a plain truncating write, so a reader in
  /// ANOTHER process (or a future isolate that does not share these statics)
  /// could still observe a partial file. Within the app process this map is
  /// sufficient, and making the write atomic belongs to the extractor.
  static final Map<String, Future<DerivedFigure?>> _inFlightRegenerations = {};

  /// Number of regenerations currently in flight (test observability).
  @visibleForTesting
  static int get inFlightRegenerationCount => _inFlightRegenerations.length;

  /// Drops any in-flight bookkeeping. Tests only — futures already handed out
  /// are unaffected.
  @visibleForTesting
  static void resetInFlightRegenerations() => _inFlightRegenerations.clear();

  /// Builds the content-addressed figureId for a `figure` chunk.
  ///
  /// [contentHash] MUST be the chunk row's `search_chunks.contentHash`, never
  /// a rendered PNG's hash (see the file header).
  static String buildFigureId(String chunkKey, String contentHash) {
    final prefix = contentHash.length <= hashPrefixLength
        ? contentHash
        : contentHash.substring(0, hashPrefixLength);
    return '$chunkKey~$prefix';
  }

  /// Splits a figureId on its LAST `~` (chunkKeys contain `:` but never `~`).
  /// Returns null when either half is empty or the separator is missing.
  static ({String chunkKey, String hashPrefix})? parseFigureId(
    String figureId,
  ) {
    final index = figureId.lastIndexOf('~');
    if (index <= 0 || index == figureId.length - 1) return null;
    return (
      chunkKey: figureId.substring(0, index),
      hashPrefix: figureId.substring(index + 1),
    );
  }

  /// Metadata-only resolution: verifies the chunk + hash + owning note and
  /// returns WHERE the figure came from, without touching, probing or
  /// regenerating the derived asset.
  ///
  /// This is what link taps and the provenance chip use: navigating to the
  /// source PDF needs an attachment id and a page, both of which are known
  /// from the index alone. Rasterizing a PDF page just to compute a route (and
  /// refusing to navigate when that render fails) is exactly the bug this
  /// exists to prevent. Never throws.
  Future<FigureTargetResolution> resolveTarget(String figureId) async {
    try {
      final record = await _load(figureId);
      final target = record.target;
      if (target == null) {
        return record.status == FigureResolutionStatus.staleFigure
            ? const FigureTargetResolution.staleFigure()
            : const FigureTargetResolution.unknownFigure();
      }
      return FigureTargetResolution.resolved(target);
    } catch (e) {
      LoggerService.warning(
        '[FigureResolver] resolveTarget($figureId) failed: $e',
      );
      return const FigureTargetResolution.unknownFigure();
    }
  }

  /// Resolves [figureId] to its derived asset, regenerating the asset on
  /// demand when it is missing. Never throws.
  Future<FigureResolution> resolve(String figureId) async {
    _FigureRecord? record;
    try {
      record = await _load(figureId);
      final target = record.target;
      if (target == null) {
        return record.status == FigureResolutionStatus.staleFigure
            ? const FigureResolution.staleFigure()
            : const FigureResolution.unknownFigure();
      }

      // Probe every location the asset could legitimately be at BEFORE
      // re-rendering: a probe that can miss a file the renderer would just
      // rewrite is an infinite re-render loop (see header, step 6).
      for (final candidate in record.assetCandidates()) {
        final absolute = await _absolutePath(candidate);
        if (await File(absolute).exists()) {
          return FigureResolution.resolved(
            ResolvedFigure(assetPath: absolute, target: target),
          );
        }
      }

      // Derived assets are regenerable (they are excluded from export/backup)
      // — re-render this one region from the owning PDF.
      final regenerated = await _regenerate(record);
      if (regenerated == null) return FigureResolution.assetUnavailable(target);
      // Use the path renderRegion actually wrote, never the probed guess.
      final absolute = await _absolutePath(regenerated.assetRelativePath);
      if (!await File(absolute).exists()) {
        return FigureResolution.assetUnavailable(target);
      }
      return FigureResolution.resolved(
        ResolvedFigure(assetPath: absolute, target: target, regenerated: true),
      );
    } catch (e) {
      LoggerService.warning('[FigureResolver] resolve($figureId) failed: $e');
      return FigureResolution.assetUnavailable(record?.target);
    }
  }

  /// Steps 1-4 of the contract: parse, load the `figure` row, verify the hash
  /// prefix, verify the owning note, decode `meta`.
  Future<_FigureRecord> _load(String figureId) async {
    final parsed = parseFigureId(figureId);
    if (parsed == null) {
      return const _FigureRecord.dangling(FigureResolutionStatus.unknownFigure);
    }

    final Database db = await _db.database;
    final rows = await db.query(
      'search_chunks',
      columns: ['noteId', 'sourceId', 'page', 'meta', 'contentHash'],
      where: 'chunkKey = ? AND sourceType = ?',
      whereArgs: [parsed.chunkKey, figureSourceType],
      limit: 1,
    );
    if (rows.isEmpty) {
      return const _FigureRecord.dangling(FigureResolutionStatus.unknownFigure);
    }

    final row = rows.first;
    final contentHash = (row['contentHash'] as String?) ?? '';
    // Content addressing: a re-extracted/renumbered region must dangle, not
    // silently render a different figure.
    if (!_hashMatches(contentHash, parsed.hashPrefix)) {
      return const _FigureRecord.dangling(FigureResolutionStatus.staleFigure);
    }

    final noteId = row['noteId'] as String;
    // `__deleted__ = 0`: deletion is a tombstone write, so the row survives —
    // a figure whose owning note was deleted must still dangle as unknown.
    final noteRows = await db.query(
      'notes',
      columns: ['title'],
      where: 'id = ? AND __deleted__ = 0',
      whereArgs: [noteId],
      limit: 1,
    );
    if (noteRows.isEmpty) {
      return const _FigureRecord.dangling(FigureResolutionStatus.unknownFigure);
    }

    final meta = _decodeMeta(row['meta'] as String?);
    final attachmentId =
        (row['sourceId'] as String?) ?? meta['attachmentId'] as String?;
    final rowPage = (row['page'] as int?);
    final metaPage = (meta['page'] as num?)?.toInt();
    if (rowPage != null && metaPage != null && rowPage != metaPage) {
      // Not recoverable here, but it means the index wrote two different pages
      // for one region; both are probed so this cannot silently become an
      // endless re-render.
      LoggerService.warning(
        '[FigureResolver] index inconsistency: ${parsed.chunkKey} has '
        'search_chunks.page=$rowPage but meta.page=$metaPage; using '
        'meta.page (renderRegion names the asset from it)',
      );
    }
    final storedPath = meta['derivedAssetPath'] as String?;

    return _FigureRecord(
      status: FigureResolutionStatus.resolved,
      target: FigureTarget(
        chunkKey: parsed.chunkKey,
        contentHash: contentHash,
        noteId: noteId,
        noteTitle: noteRows.first['title'] as String?,
        attachmentId: attachmentId,
        caption: meta['caption'] as String?,
        page: metaPage ?? rowPage,
      ),
      meta: meta,
      storedPath: storedPath,
      rowPage: rowPage,
      metaPage: metaPage,
      // Mandatory in meta (Step 14); tolerated from the derived file name.
      // Never guessed: see the header, step 5.
      figureIndex:
          (meta['figureIndex'] as num?)?.toInt() ??
          _figureIndexFromAssetPath(storedPath),
    );
  }

  /// Re-renders the region described by the record's meta from its owning PDF.
  /// Returns null when anything needed is missing (unknown figure index, no
  /// attachment, no PDF on disk, unusable region JSON, render failure).
  ///
  /// Concurrent callers targeting the same derived asset share one render.
  Future<DerivedFigure?> _regenerate(_FigureRecord record) async {
    final attachmentId = record.target?.attachmentId;
    final figureIndex = record.figureIndex;
    if (attachmentId == null || figureIndex == null) return null;
    final FigureRegion region;
    try {
      region = FigureRegion.fromJson(record.meta);
    } catch (_) {
      return null; // meta predates / diverges from the FigureRegion payload.
    }

    // Key on what renderRegion will write — the same derived file may be
    // reached through several figureIds/paths.
    final key =
        '$derivedAssetDir/'
        '${FigureRegionExtractor.derivedFigureFileName(attachmentId, region.page, figureIndex)}';
    final inFlight = _inFlightRegenerations[key];
    if (inFlight != null) return inFlight;

    final future = _renderRegion(
      attachmentId: attachmentId,
      region: region,
      figureIndex: figureIndex,
    );
    _inFlightRegenerations[key] = future;
    return future.whenComplete(() {
      if (identical(_inFlightRegenerations[key], future)) {
        _inFlightRegenerations.remove(key);
      }
    });
  }

  Future<DerivedFigure?> _renderRegion({
    required String attachmentId,
    required FigureRegion region,
    required int figureIndex,
  }) async {
    final attachment = await _db.getAttachmentById(attachmentId);
    if (attachment == null) return null;
    final pdfPath = await attachment.getAbsolutePath();
    if (!await File(pdfPath).exists()) return null;
    return _extractor.renderRegion(
      pdfPath,
      attachmentId: attachmentId,
      region: region,
      figureIndex: figureIndex,
    );
  }

  static bool _hashMatches(String contentHash, String prefix) {
    if (contentHash.isEmpty || prefix.isEmpty) return false;
    if (prefix.length > contentHash.length) return false;
    return contentHash.toLowerCase().startsWith(prefix.toLowerCase());
  }

  static Map<String, dynamic> _decodeMeta(String? metaJson) {
    if (metaJson == null || metaJson.isEmpty) return const {};
    try {
      final decoded = jsonDecode(metaJson);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  /// Recovers the figure index from a derived asset name
  /// (`<attId>_p<N>_f<i>.png`) when `meta.figureIndex` is absent.
  static int? _figureIndexFromAssetPath(String? path) {
    if (path == null) return null;
    final match = RegExp(r'_f(\d+)\.[A-Za-z0-9]+$').firstMatch(path);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  static Future<String> _absolutePath(String path) async {
    if (path.startsWith('/')) return path;
    return FileUtils.getFullFilePath(path, true);
  }
}

/// A verified figure chunk row plus everything derived from it — or a dangling
/// status with no target.
class _FigureRecord {
  const _FigureRecord({
    required this.status,
    required this.target,
    required this.meta,
    required this.storedPath,
    required this.rowPage,
    required this.metaPage,
    required this.figureIndex,
  });

  const _FigureRecord.dangling(this.status)
    : target = null,
      meta = const {},
      storedPath = null,
      rowPage = null,
      metaPage = null,
      figureIndex = null;

  final FigureResolutionStatus status;

  /// Null exactly when the chunk did not verify.
  final FigureTarget? target;

  final Map<String, dynamic> meta;
  final String? storedPath;
  final int? rowPage;
  final int? metaPage;

  /// 0-based index of the region on its page; null when unknown (never
  /// guessed — a wrong index makes renderRegion overwrite a sibling region's
  /// asset).
  final int? figureIndex;

  /// Every location the derived asset could legitimately live at, in
  /// preference order and de-duplicated. Probing all of them is what keeps the
  /// existence check and the regeneration target from disagreeing.
  Iterable<String> assetCandidates() {
    final candidates = <String>{};
    final stored = storedPath;
    if (stored != null && stored.isNotEmpty) {
      candidates.add(stored);
      if (stored.startsWith('/')) {
        // A stale absolute path (e.g. a previous iOS app-container UUID)
        // still names the right file inside today's container.
        final name = stored.split('/').last;
        if (name.isNotEmpty) {
          candidates.add('${FigureResolver.derivedAssetDir}/$name');
        }
      }
    }
    final attachmentId = target?.attachmentId;
    final index = figureIndex;
    // ONE canonical candidate, built from the same page renderRegion names the
    // file from (meta), so the probe and the regeneration target can never
    // disagree. Probing the row's page as well would be worse than the loop it
    // fixes: on a divergence it could hand back a SIBLING region's crop.
    final page = metaPage ?? rowPage;
    if (attachmentId != null && index != null && page != null) {
      candidates.add(
        '${FigureResolver.derivedAssetDir}/'
        '${FigureRegionExtractor.derivedFigureFileName(attachmentId, page, index)}',
      );
    }
    return candidates;
  }
}
