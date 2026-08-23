// `GoogleDriveBackend` — M2.2: the first real `SyncBackend` implementation,
// against the Google Drive REST API v3, `drive.file` OAuth scope. See
// `plan-and-propse-the-glistening-dolphin.md` § Architecture 8 in full —
// especially § 8.1 (interface), § 8.3 (auth/token-refresh), § 8.4 (Drive's
// lack of atomic create-if-absent and the existence-check-before-create
// mitigation), § 8.5 (encryption format, NOT implemented here), § 8.6
// (testing strategy). This file implements what those sections already
// settled on conceptually; it does not re-derive the design.
//
// **`drive.file` scope, and what it means for this file's shape:** this
// app can only see/manage Drive files/folders IT created (or that the user
// explicitly opened via a picker, which this milestone doesn't build — see
// "What NOT to build" in the M2.2 brief). That rules out "list everything
// in some well-known folder a human set up" — instead, this backend
// creates and owns a single root folder (§ [_ensureRootFolder]) the first
// time it runs, then tags every object it creates with `appProperties` so
// `files.list` queries (which `drive.file` scope permits against the app's
// own visible files) can find them again. Nothing here is discoverable by
// name alone; `appProperties` is the actual index.
//
// **Drive's non-atomic create, and the existence-check-before-create
// mitigation this file implements for every write-once object type
// (dataset marker, commits, blobs, snapshots) — reusing, not re-deriving,
// the reasoning already worked out in `MockSyncBackend._appendCommitDurable`
// (`test/sync_backend/mock_sync_backend.dart`):** `files.create` has no
// native "create if absent by name/tag" atomicity. Every create-once method
// below therefore does existence-check-then-create as two separate Drive
// round-trips, not one atomic operation. This is a **disclosed, not
// eliminated, race**: two concurrent callers under the identical
// `publishIntentId` (a crash-and-retry racing a second manual retry, or a
// double-tap) can both pass the existence check before either finishes
// creating, producing two distinct stored Drive objects for what should be
// one logical write. What this implementation guarantees despite that: (1)
// the ordinary, non-racing retry path (by far the common case — a caller
// retries *after* the first attempt's response, not concurrently with it)
// is fully idempotent, since the existence check will find the
// already-created object; (2) even under the race, the *read* path
// (`readCommits`, `blobExists`+`downloadBlob`, `latestSnapshotRef`)
// deterministically converges on exactly one of the duplicates (the
// earliest-created, by Drive's own `createdTime`), so a caller never
// observes two commits at the same `(deviceLogId, deviceSeq)` even if Drive
// is physically storing two objects there. See
// `test/sync_backend/google_drive_backend_test.dart` for the test that
// deliberately reproduces this race and asserts both of these guarantees
// hold. A full fix (server-side atomic rename, app-level distributed
// locking, or a reconciliation pass that detects and collapses same-slot
// duplicates after the fact) is out of scope for this milestone.
//
// **What this file does NOT prove — read before trusting any "Drive
// backend is conformant" claim:** every test exercising this class runs
// against `FakeDriveHttpTransport` (`test/sync_backend/`), a hand-written
// model of Drive's REST API v3 surface — not the real API. § 8.6's exit
// criteria explicitly requires "the Drive auth flow verified end-to-end
// against real Google endpoints in at least one manual smoke test" before
// this backend is considered fully conformant. **That smoke test has not
// been performed** (no real Google Cloud OAuth client is configured for
// this project) and cannot be automated from this environment. Treat this
// class as translation-logic-tested, not field-tested, until that gap is
// closed.
//
// **Encryption (§ 8.5):** not implemented here, by design (no AEAD library
// is chosen yet — a correctness-blocking open item the plan document
// itself flags as unresolved). Every object this backend writes is
// plaintext-on-the-wire and plaintext-at-rest-on-Drive. Nothing here
// structurally precludes adding it later: `commitBytes`/blob bytes/
// snapshot bytes are all opaque `Uint8List`s as far as this class is
// concerned, and `DatasetInitMarker.kdfSalt`/`passphraseCanary` already
// round-trip through `_encodeMarker`/`_decodeMarker` even though they're
// always null today (no caller populates them yet).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../oauth_token_manager.dart';
import 'sync_backend.dart';
import 'sync_backend_exceptions.dart';

/// Residual bucket for Drive API error shapes that don't map onto any of
/// `sync_backend_exceptions.dart`'s typed exceptions — e.g. a 400 Bad
/// Request from a malformed query (a real implementation bug, not a
/// transient/ambiguous condition `SyncNetworkException` is meant to model).
/// Deliberately NOT one of the `Sync*Exception` types: those model
/// conditions the interface's own contract anticipates and names; this
/// models "something Drive-specific went wrong that this translation layer
/// doesn't have a more specific answer for."
class GoogleDriveApiException implements Exception {
  final int? statusCode;
  final String message;
  const GoogleDriveApiException(this.message, {this.statusCode});
  @override
  String toString() => 'GoogleDriveApiException(status: $statusCode): $message';
}

/// Lightweight typed view over one Drive `files` resource, as returned by
/// `files.list`/`files.create`/`files.get` with the `fields` this backend
/// always requests. Internal to this file — never exposed through
/// `SyncBackend`.
class _DriveFile {
  final String id;
  final Map<String, String> appProperties;
  final DateTime createdTime;
  final String? md5Checksum;

  const _DriveFile({
    required this.id,
    required this.appProperties,
    required this.createdTime,
    this.md5Checksum,
  });

  factory _DriveFile.fromJson(Map<String, dynamic> json) {
    final rawProps = json['appProperties'] as Map<String, dynamic>? ?? const {};
    return _DriveFile(
      id: json['id'] as String,
      appProperties: rawProps.map((k, v) => MapEntry(k, v as String)),
      createdTime: DateTime.parse(json['createdTime'] as String),
      md5Checksum: json['md5Checksum'] as String?,
    );
  }
}

/// Real `SyncBackend` implementation against Google Drive REST API v3,
/// `drive.file` scope. See the file-level doc comment above for the design
/// decisions this class embodies; doc comments on individual members below
/// cover method-specific detail only.
class GoogleDriveBackend implements SyncBackend {
  GoogleDriveBackend({
    required OAuthTokenManager tokenManager,
    required http.Client httpClient,
    String rootFolderName = 'Note Synapse Sync',
  }) : _tokenManager = tokenManager,
       _http = httpClient,
       _rootFolderName = rootFolderName;

  final OAuthTokenManager _tokenManager;
  final http.Client _http;
  final String _rootFolderName;

  static const _apiBase = 'https://www.googleapis.com/drive/v3';
  static const _uploadBase = 'https://www.googleapis.com/upload/drive/v3';
  static const _listFields =
      'nextPageToken,files(id,name,appProperties,createdTime,modifiedTime,md5Checksum,size)';
  static const _singleFileFields =
      'id,name,appProperties,createdTime,modifiedTime,md5Checksum,size';

  /// Cached after first resolution for the lifetime of this instance — one
  /// `SyncBackend` instance is already scoped to "one dataset" (§ 8.1), and
  /// the root folder is this dataset's single root location on Drive, so
  /// there is no reason to re-resolve it on every call.
  String? _rootFolderId;

  /// M2.12: per-`deviceLogId` in-session tip cache — see [appendCommit]'s
  /// own doc comment for exactly which appends it skips queries for and
  /// which still pay for them.
  final Map<String, ({int deviceSeq, String commitHash})> _tipCache = {};

  int _uploadCounter = 0;

  @override
  final SyncBackendCapabilities capabilities = const SyncBackendCapabilities(
    supportsConditionalDelete: false,
    supportsPersistentExternalFolder: false,
  );

  // ===========================================================================
  // Low-level HTTP / auth plumbing
  // ===========================================================================

  /// Every Drive call funnels through here. Attaches the current access
  /// token; on a 401, forces a refresh via [OAuthTokenManager.refreshNow]
  /// (§ 8.3's new refresh-on-401 support — see that method's doc comment
  /// for why the retry loop lives here and not inside `OAuthTokenManager`
  /// itself) and retries the exact same request once with the new token
  /// before surfacing a real auth error. [build] must construct a *fresh*
  /// `http.BaseRequest` each time it's called — an `http.Request` cannot be
  /// resent once sent.
  Future<http.Response> _authorizedRequest(
    http.BaseRequest Function(String bearerToken) build,
  ) async {
    final token = await _tokenManager.getAccessToken();
    if (token == null) {
      throw const SyncAuthExpiredException(
        'no Drive access token available; complete the Drive OAuth consent flow first',
      );
    }

    var response = await _send(build(token));
    if (response.statusCode != 401) return response;

    final refreshed = await _forceRefreshOrThrow();
    response = await _send(build(refreshed));
    if (response.statusCode == 401) {
      throw const SyncAuthExpiredException(
        'Drive API returned 401 even after a forced token refresh and a single retry',
      );
    }
    return response;
  }

  Future<String> _forceRefreshOrThrow() async {
    try {
      return await _tokenManager.refreshNow();
    } on OAuthRefreshFailedException catch (e) {
      if (e.requiresReauthorization) {
        throw const SyncRefreshTokenRevokedException();
      }
      throw SyncNetworkException('Drive token refresh failed: ${e.message}');
    }
  }

  Future<http.Response> _send(http.BaseRequest request) async {
    try {
      final streamed = await _http.send(request);
      return await http.Response.fromStream(streamed);
    } on http.ClientException catch (e) {
      throw SyncNetworkException('Drive request failed: $e');
    }
  }

  /// Throws iff [response] is not a 2xx — mapping Drive's actual HTTP error
  /// shapes onto this project's typed `SyncBackend` exceptions rather than
  /// letting raw `http`/Drive-JSON error bodies leak through the interface
  /// boundary (per the M2.2 brief's error-mapping requirement). 401 is
  /// deliberately handled entirely inside [_authorizedRequest] before a
  /// response ever reaches here — this method's own 401 branch exists only
  /// as defense-in-depth for any future call path that bypasses
  /// [_authorizedRequest].
  void _throwIfError(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw _mapDriveError(response);
  }

  Exception _mapDriveError(http.Response response) {
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      // Non-JSON error body — fall through to the generic mapping below.
    }
    final error = body?['error'] as Map<String, dynamic>?;
    final errors =
        (error?['errors'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
        const [];
    final reason = errors.isNotEmpty ? errors.first['reason'] as String? : null;
    final message = error?['message'] as String? ?? response.body;
    final status = response.statusCode;

    if (status == 401) {
      return const SyncAuthExpiredException('Drive returned 401');
    }
    if (status == 429) {
      return SyncRateLimitedException(retryAfter: _retryAfter(response));
    }
    if (status == 403 &&
        (reason == 'rateLimitExceeded' || reason == 'userRateLimitExceeded')) {
      return SyncRateLimitedException(retryAfter: _retryAfter(response));
    }
    if (status == 403 &&
        (reason == 'storageQuotaExceeded' || reason == 'quotaExceeded')) {
      return SyncQuotaExceededException(message);
    }
    // 507 Insufficient Storage is not a status Drive documents returning
    // itself, but the M2.2 brief names it explicitly alongside
    // 403-with-a-quota-reason as a quota-shaped error this backend must
    // map — included for forward/defensive compatibility.
    if (status == 507) {
      return SyncQuotaExceededException(
        'Drive reported insufficient storage: $message',
      );
    }
    if (status >= 500) {
      return SyncNetworkException('Drive server error $status: $message');
    }
    return GoogleDriveApiException(message, statusCode: status);
  }

  Duration? _retryAfter(http.Response response) {
    final header = response.headers['retry-after'];
    if (header == null) return null;
    final seconds = int.tryParse(header);
    return seconds == null ? null : Duration(seconds: seconds);
  }

  // ===========================================================================
  // Drive primitives: list / create (metadata-only) / create (with content)
  // / download / delete
  // ===========================================================================

  Future<List<_DriveFile>> _listAll(String query) async {
    final results = <_DriveFile>[];
    String? pageToken;
    do {
      final params = <String, String>{
        'q': query,
        'fields': _listFields,
        'pageSize': '100',
        'spaces': 'drive',
        if (pageToken != null) 'pageToken': pageToken,
      };
      final uri = Uri.parse('$_apiBase/files').replace(queryParameters: params);
      final response = await _authorizedRequest(
        (token) =>
            http.Request('GET', uri)
              ..headers['Authorization'] = 'Bearer $token',
      );
      _throwIfError(response);
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final files = (data['files'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>();
      results.addAll(files.map(_DriveFile.fromJson));
      pageToken = data['nextPageToken'] as String?;
    } while (pageToken != null);
    return results;
  }

  Future<_DriveFile> _createMetadataOnly(Map<String, dynamic> metadata) async {
    final uri = Uri.parse(
      '$_apiBase/files',
    ).replace(queryParameters: {'fields': _singleFileFields});
    final response = await _authorizedRequest(
      (token) => http.Request('POST', uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..headers['Content-Type'] = 'application/json; charset=UTF-8'
        ..body = jsonEncode(metadata),
    );
    _throwIfError(response);
    return _DriveFile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<_DriveFile> _createWithContent({
    required Map<String, dynamic> metadata,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    final uri = Uri.parse('$_uploadBase/files').replace(
      queryParameters: {'uploadType': 'multipart', 'fields': _singleFileFields},
    );
    final boundary =
        'synapse-${DateTime.now().microsecondsSinceEpoch}-${_uploadCounter++}';
    final body = _buildMultipartRelated(
      boundary: boundary,
      metadata: metadata,
      mediaBytes: bytes,
      mediaContentType: mimeType,
    );
    final response = await _authorizedRequest(
      (token) => http.Request('POST', uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..headers['Content-Type'] = 'multipart/related; boundary=$boundary'
        ..bodyBytes = body,
    );
    _throwIfError(response);
    return _DriveFile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// Drive's "multipart upload" wants `multipart/related` (a JSON metadata
  /// part plus a media part) — NOT `multipart/form-data`, which is what
  /// `package:http`'s own `MultipartRequest` builds. Hand-rolled for
  /// exactly that reason.
  Uint8List _buildMultipartRelated({
    required String boundary,
    required Map<String, dynamic> metadata,
    required Uint8List mediaBytes,
    required String mediaContentType,
  }) {
    final builder = BytesBuilder();
    void writeLine(String s) => builder.add(utf8.encode('$s\r\n'));
    writeLine('--$boundary');
    writeLine('Content-Type: application/json; charset=UTF-8');
    writeLine('');
    writeLine(jsonEncode(metadata));
    writeLine('--$boundary');
    writeLine('Content-Type: $mediaContentType');
    writeLine('');
    builder.add(mediaBytes);
    builder.add(utf8.encode('\r\n'));
    writeLine('--$boundary--');
    return builder.toBytes();
  }

  Future<Uint8List> _downloadContent(String fileId) async {
    final uri = Uri.parse(
      '$_apiBase/files/$fileId',
    ).replace(queryParameters: {'alt': 'media'});
    final response = await _authorizedRequest(
      (token) =>
          http.Request('GET', uri)..headers['Authorization'] = 'Bearer $token',
    );
    _throwIfError(response);
    return response.bodyBytes;
  }

  /// Returns `false` (not an error) if the object was already gone —
  /// callers decide whether that's `DeleteNotFound` or fine to ignore.
  Future<bool> _deleteFile(String fileId) async {
    final uri = Uri.parse('$_apiBase/files/$fileId');
    final response = await _authorizedRequest(
      (token) =>
          http.Request('DELETE', uri)
            ..headers['Authorization'] = 'Bearer $token',
    );
    if (response.statusCode == 404) return false;
    _throwIfError(response);
    return true;
  }

  static String _escapeQueryValue(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");

  static String _sanitizeName(String raw) =>
      raw.replaceAll(RegExp(r'[^A-Za-z0-9_.:-]'), '_');

  static Future<Uint8List> _collectStream(Stream<List<int>> data) async {
    final builder = BytesBuilder();
    await for (final chunk in data) {
      builder.add(chunk);
    }
    return builder.toBytes();
  }

  /// This backend's own commit-hash algorithm — opaque to every
  /// `SyncBackend` caller beyond "chain onto this next" (§ 8.1), so there
  /// is no requirement it match `MockSyncBackend`'s algorithm, only that it
  /// be deterministic and collision-resistant for a given
  /// (deviceLogId, deviceSeq, parent, bytes) tuple. Matches
  /// `MockSyncBackend._hashCommit`'s framing anyway, for no reason beyond
  /// consistency being easier to reason about across the two
  /// implementations while reading test output side by side.
  static String _hashCommit(
    String deviceLogId,
    int deviceSeq,
    String? parentCommitHash,
    Uint8List bytes,
  ) {
    final framing = '$deviceLogId|$deviceSeq|${parentCommitHash ?? ''}|';
    return sha256.convert(utf8.encode(framing) + bytes).toString();
  }

  // ===========================================================================
  // Root folder (§ file-level doc comment: the app-owned, app-created
  // "dataset root" — required by `drive.file` scope, since this app cannot
  // browse an arbitrary pre-existing folder without a picker flow, which
  // this milestone deliberately does not build).
  // ===========================================================================

  static const _rootTagKey = 'synapseObjectType';
  static const _rootTagValue = 'datasetRoot';

  /// Resolves the root folder **without creating it** — `null` when the user
  /// has no such folder.
  ///
  /// **Split out from [_ensureRootFolder] for M2.13, review finding F6.**
  /// `readDatasetInitMarker` called `_ensureRootFolder`, which creates the
  /// folder when absent. That was harmless while the only caller was the
  /// bootstrap sequence (which is about to create it anyway), and stopped
  /// being harmless when M2.13 put `verifyDatasetStillExists` — one
  /// `readDatasetInitMarker` — on every `syncNow()`: a user who had
  /// deliberately deleted `Note Synapse Sync` from their Drive got an empty
  /// one silently recreated by the very sync that was supposed to be telling
  /// them the dataset was gone. "Is there a marker?" is a read; it must not
  /// have a write as a side effect. Deliberately NOT expanded into M2.11's
  /// folder-identity work — the folder is still name-and-tag addressed here,
  /// exactly as before.
  Future<String?> _findRootFolder() async {
    final cached = _rootFolderId;
    if (cached != null) return cached;

    final query =
        "mimeType = 'application/vnd.google-apps.folder' and trashed = false "
        "and name = '${_escapeQueryValue(_rootFolderName)}' and "
        "appProperties has { key='$_rootTagKey' and value='$_rootTagValue' }";
    final existing = await _listAll(query);
    if (existing.isEmpty) return null;
    // Same existence-check-before-create race as everything else in this
    // file — oldest-wins keeps this deterministic across every device
    // that might independently race to create the root folder on first
    // run, without needing a second reconciliation pass.
    existing.sort((a, b) => a.createdTime.compareTo(b.createdTime));
    _rootFolderId = existing.first.id;
    return _rootFolderId!;
  }

  Future<String> _ensureRootFolder() async {
    final found = await _findRootFolder();
    if (found != null) return found;

    final created = await _createMetadataOnly({
      'name': _rootFolderName,
      'mimeType': 'application/vnd.google-apps.folder',
      'appProperties': {_rootTagKey: _rootTagValue},
    });
    _rootFolderId = created.id;
    return _rootFolderId!;
  }

  // ===========================================================================
  // Dataset lifecycle
  // ===========================================================================

  static const _markerObjectType = 'datasetInitMarker';

  @override
  Future<void> initializeDatasetOnce(DatasetInitMarker marker) async {
    final rootId = await _ensureRootFolder();
    final existing = await _listAll(_markerQuery(rootId));
    if (existing.isNotEmpty) {
      // First-writer-wins, racily — the disclosed existence-check race
      // applies here exactly as it does to appendCommit; see the
      // file-level doc comment.
      return;
    }
    await _createWithContent(
      metadata: {
        'name': 'dataset-init-marker.json',
        'parents': [rootId],
        'appProperties': {_rootTagKey: _markerObjectType},
      },
      bytes: _encodeMarker(marker),
      mimeType: 'application/json',
    );
  }

  @override
  Future<DatasetInitMarker?> readDatasetInitMarker() async {
    // Read-only resolution: no folder means no marker, and asking the
    // question must not create the thing being asked about. See
    // [_findRootFolder] (M2.13, review finding F6).
    final rootId = await _findRootFolder();
    if (rootId == null) return null;
    final existing = await _listAll(_markerQuery(rootId));
    if (existing.isEmpty) return null;
    existing.sort((a, b) => a.createdTime.compareTo(b.createdTime));
    final bytes = await _downloadContent(existing.first.id);
    return _decodeMarker(bytes);
  }

  String _markerQuery(String rootId) =>
      "'$rootId' in parents and trashed = false and "
      "appProperties has { key='$_rootTagKey' and value='$_markerObjectType' }";

  static Uint8List _encodeMarker(DatasetInitMarker marker) {
    final json = <String, dynamic>{
      'encryptionEnabled': marker.encryptionEnabled,
      'kdfSalt': marker.kdfSalt == null ? null : base64Encode(marker.kdfSalt!),
      'passphraseCanary': marker.passphraseCanary == null
          ? null
          : base64Encode(marker.passphraseCanary!),
      'createdByDeviceId': marker.createdByDeviceId,
      'createdAt': marker.createdAt.toIso8601String(),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  static DatasetInitMarker _decodeMarker(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return DatasetInitMarker(
      encryptionEnabled: json['encryptionEnabled'] as bool,
      kdfSalt: json['kdfSalt'] == null
          ? null
          : base64Decode(json['kdfSalt'] as String),
      passphraseCanary: json['passphraseCanary'] == null
          ? null
          : base64Decode(json['passphraseCanary'] as String),
      createdByDeviceId: json['createdByDeviceId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  // ===========================================================================
  // Per-device, hash-linked, append-only commit log
  // ===========================================================================

  static const _commitObjectType = 'commit';

  String _commitsQuery(String rootId, String deviceLogId) =>
      "'$rootId' in parents and trashed = false and "
      "appProperties has { key='$_rootTagKey' and value='$_commitObjectType' } and "
      "appProperties has { key='deviceLogId' and value='${_escapeQueryValue(deviceLogId)}' }";

  Future<_DriveFile?> _findCommitAt(
    String rootId,
    String deviceLogId,
    int deviceSeq,
  ) async {
    final query =
        '${_commitsQuery(rootId, deviceLogId)} and '
        "appProperties has { key='deviceSeq' and value='$deviceSeq' }";
    final matches = await _listAll(query);
    if (matches.isEmpty) return null;
    matches.sort((a, b) => a.createdTime.compareTo(b.createdTime));
    return matches.first; // oldest wins under a duplicate-create race.
  }

  /// Collapses a raw listing down to (at most) one file per `deviceSeq`,
  /// keeping the earliest-created — the read-side half of the
  /// existence-check-before-create race's mitigation (§ file-level doc
  /// comment): even if the race produced two stored objects at the same
  /// slot, every ordinary read converges on one of them, deterministically.
  List<_DriveFile> _dedupeBySeq(List<_DriveFile> files) {
    final sorted = [...files]
      ..sort((a, b) => a.createdTime.compareTo(b.createdTime));
    final bySeq = <int, _DriveFile>{};
    for (final f in sorted) {
      final seq = int.parse(f.appProperties['deviceSeq']!);
      bySeq.putIfAbsent(seq, () => f);
    }
    return bySeq.values.toList();
  }

  Future<_DriveFile?> _findTip(String rootId, String deviceLogId) async {
    final all = await _listAll(_commitsQuery(rootId, deviceLogId));
    if (all.isEmpty) return null;
    final deduped = _dedupeBySeq(all)
      ..sort(
        (a, b) => int.parse(
          a.appProperties['deviceSeq']!,
        ).compareTo(int.parse(b.appProperties['deviceSeq']!)),
      );
    return deduped.last;
  }

  /// Appends one commit.
  ///
  /// **M2.12 — the in-session tip cache: 3 Drive round trips per commit down
  /// to 1, without weakening the § 8.4 mitigation for any case that
  /// actually depends on it.**
  ///
  /// The unconditional shape was `_findCommitAt` (files.list) + `_findTip`
  /// (files.list) + `_createWithContent`. Both listings are redundant for a
  /// caller that is walking its own log forward, which `PushPhase` provably
  /// is: it tracks `parentCommitHash` locally and advances it on each
  /// success, and each `deviceLogId` is single-writer by design (§
  /// Architecture 1 gives every namespace exactly one owning device). So
  /// after this instance has itself created the commit at `deviceSeq`, the
  /// slot at `deviceSeq + 1` cannot have been taken by anyone else, and the
  /// tip cannot be anything but what it just wrote.
  ///
  /// The fast path is therefore taken **only** when all three hold:
  ///   1. this instance has a cached tip for [deviceLogId] — meaning it
  ///      either created that commit itself in this session, or read the tip
  ///      from Drive during a slow-path append in this session;
  ///   2. [parentCommitHash] equals that cached tip's hash; and
  ///   3. [deviceSeq] equals that cached tip's `deviceSeq + 1`.
  /// Any other combination is exactly a case where the caller's belief and
  /// this instance's knowledge disagree, so it falls through to the full,
  /// unchanged two-listing path.
  ///
  /// **Which appends still query Drive, and why each one has to:**
  ///   * **The first append of a session for a log** — no cache entry
  ///     exists. This is the one that must never be optimized away: it is
  ///     also the resume/retry case, where a previous session may have
  ///     created a commit whose response never arrived, and the existence
  ///     check under the identical `publishIntentId` is precisely what makes
  ///     that retry idempotent on a backend with no atomic create-if-absent.
  ///   * **Any append after a failure.** [_tipCache] is dropped for the log
  ///     on any thrown exception (a timeout, a 5xx, a dropped connection —
  ///     Drive's shape of "ambiguous"), because after one of those this
  ///     instance genuinely does not know whether its create landed. The
  ///     subsequent retry therefore re-queries and finds its own earlier
  ///     write if it exists.
  ///   * **Any append whose parent/seq does not chain onto the cached tip**
  ///     — including every `ParentMismatch`, which additionally drops the
  ///     cache so the next call re-derives the truth rather than compounding
  ///     a stale belief.
  ///   * **Every non-append path**, unchanged: `readCommits`,
  ///     `listDeviceLogIds`, blob and snapshot operations all still go to
  ///     Drive.
  ///
  /// **Disclosed residual — out-of-band deletion, which "single-writer by
  /// design" does not cover.** That justification is about other *writers*;
  /// it says nothing about the user opening the Drive web UI and deleting
  /// commit files between two appends of the same process. Before the cache,
  /// the per-append `_findTip` would have noticed and returned
  /// `ParentMismatch`; on the fast path it does not, and this backend
  /// appends into a hole — a chain that references a parent Drive no longer
  /// stores. The condition is still DETECTED, just later and by a different
  /// mechanism: `readCommits` reports the resulting `hasGap`, and
  /// `pull_phase.dart` stops applying at it rather than skipping past. The
  /// window is one process lifetime, and the trade is deliberate: paying two
  /// listings on every commit forever to shorten the detection window for a
  /// user manually deleting the sync folder's internals mid-sync is not a
  /// trade worth making.
  @override
  Future<AppendCommitOutcome> appendCommit({
    required String deviceLogId,
    required int deviceSeq,
    required String publishIntentId,
    required String? parentCommitHash,
    required Uint8List commitBytes,
  }) async {
    try {
      return await _appendCommitInner(
        deviceLogId: deviceLogId,
        deviceSeq: deviceSeq,
        publishIntentId: publishIntentId,
        parentCommitHash: parentCommitHash,
        commitBytes: commitBytes,
      );
    } catch (_) {
      // The write's outcome is unknown (§ 8.2 items 1-2 / the `Ambiguous`
      // condition, which this backend surfaces as a thrown
      // `SyncNetworkException` rather than an outcome value). Anything the
      // cache claims about this log is now a guess, and the next attempt
      // must re-establish it from Drive — which is also what makes the
      // caller's retry-under-the-same-publishIntentId land on the
      // existence check.
      _tipCache.remove(deviceLogId);
      rethrow;
    }
  }

  Future<AppendCommitOutcome> _appendCommitInner({
    required String deviceLogId,
    required int deviceSeq,
    required String publishIntentId,
    required String? parentCommitHash,
    required Uint8List commitBytes,
  }) async {
    final rootId = await _ensureRootFolder();

    final cachedTip = _tipCache[deviceLogId];
    final chainsOntoCachedTip =
        cachedTip != null &&
        parentCommitHash == cachedTip.commitHash &&
        deviceSeq == cachedTip.deviceSeq + 1;

    if (!chainsOntoCachedTip) {
      // 1. Existence check at this exact (deviceLogId, deviceSeq) slot — the
      //    §8.4 existence-check-before-create mitigation, keyed off the slot
      //    itself (not a global publishIntentId lookup — see the M2.2 brief
      //    and the file-level doc comment for why this differs from
      //    MockSyncBackend's cheaper in-memory global lookup).
      final existing = await _findCommitAt(rootId, deviceLogId, deviceSeq);
      if (existing != null) {
        final existingIntent = existing.appProperties['publishIntentId'];
        if (existingIntent == publishIntentId) {
          // Idempotent replay: this is the resolution path for a retried
          // appendCommit under the identical intent (§ 8.2 item 7), and for
          // AppendCommitAmbiguous being resolved via re-issue rather than a
          // readCommits round-trip.
          final commitHash = existing.appProperties['commitHash']!;
          _rememberTip(deviceLogId, deviceSeq, commitHash);
          return AppendCommitSucceeded(commitHash);
        }
        // The slot is occupied by someone else's write — the caller's belief
        // that (deviceLogId, deviceSeq) was free is stale. Report it as a
        // tip mismatch against the actual current tip, same as any other
        // halt-not-retarget case.
        _tipCache.remove(deviceLogId);
        final tip = await _findTip(rootId, deviceLogId);
        return AppendCommitParentMismatch(
          tip == null ? '' : tip.appProperties['commitHash']!,
        );
      }

      // 2. Halt-not-retarget (§ Architecture 3): confirm the caller's
      //    parentCommitHash/deviceSeq against the actual current tip before
      //    writing anything.
      final tip = await _findTip(rootId, deviceLogId);
      final expectedParent = tip?.appProperties['commitHash'];
      final expectedSeq = tip == null
          ? 1
          : int.parse(tip.appProperties['deviceSeq']!) + 1;
      if (parentCommitHash != expectedParent || deviceSeq != expectedSeq) {
        _tipCache.remove(deviceLogId);
        return AppendCommitParentMismatch(expectedParent ?? '');
      }
    }

    // 3. Create. The disclosed non-atomic-create race window is exactly
    //    the gap between step 1's existence check and this create — see
    //    the file-level doc comment.
    final commitHash = _hashCommit(
      deviceLogId,
      deviceSeq,
      parentCommitHash,
      commitBytes,
    );
    await _createWithContent(
      metadata: {
        'name': 'commit-${_sanitizeName(deviceLogId)}-$deviceSeq',
        'parents': [rootId],
        'appProperties': {
          _rootTagKey: _commitObjectType,
          'deviceLogId': deviceLogId,
          'deviceSeq': '$deviceSeq',
          'publishIntentId': publishIntentId,
          'commitHash': commitHash,
          if (parentCommitHash != null) 'parentCommitHash': parentCommitHash,
        },
      },
      bytes: commitBytes,
      mimeType: 'application/octet-stream',
    );
    _rememberTip(deviceLogId, deviceSeq, commitHash);
    return AppendCommitSucceeded(commitHash);
  }

  /// Records what this instance now knows to be [deviceLogId]'s tip.
  /// Monotonic: a lower `deviceSeq` never overwrites a higher one, so an
  /// idempotent-replay confirmation of an older slot cannot walk the cache
  /// backwards.
  void _rememberTip(String deviceLogId, int deviceSeq, String commitHash) {
    final existing = _tipCache[deviceLogId];
    if (existing != null && existing.deviceSeq > deviceSeq) return;
    _tipCache[deviceLogId] = (deviceSeq: deviceSeq, commitHash: commitHash);
  }

  @override
  Future<List<String>> listDeviceLogIds() async {
    final rootId = await _ensureRootFolder();
    final query =
        "'$rootId' in parents and trashed = false and "
        "appProperties has { key='$_rootTagKey' and value='$_commitObjectType' }";
    final all = await _listAll(query);
    final ids = <String>{};
    for (final f in all) {
      final id = f.appProperties['deviceLogId'];
      if (id != null) ids.add(id);
    }
    return ids.toList();
  }

  @override
  Future<CommitPage> readCommits({
    required String deviceLogId,
    required int afterSeq,
    int? limit,
  }) async {
    final rootId = await _ensureRootFolder();
    final all = await _listAll(_commitsQuery(rootId, deviceLogId));
    final deduped = _dedupeBySeq(all)
      ..sort(
        (a, b) => int.parse(
          a.appProperties['deviceSeq']!,
        ).compareTo(int.parse(b.appProperties['deviceSeq']!)),
      );

    var filtered = deduped
        .where((f) => int.parse(f.appProperties['deviceSeq']!) > afterSeq)
        .toList();

    // hasGap (§ Architecture 2/3's no-gap-skipping property): true iff the
    // page isn't a contiguous run starting at afterSeq+1. This is also
    // this backend's mechanism for surfacing Drive's own eventually-
    // consistent listing (§ 8.2 item 6) — if a commit that was durably
    // created hasn't yet appeared in this `files.list` call's index view,
    // it manifests here as exactly this kind of hole, with no special-case
    // handling required: a hole is a hole regardless of *why* an object
    // didn't show up in the listing.
    var hasGap =
        filtered.isNotEmpty &&
        int.parse(filtered.first.appProperties['deviceSeq']!) != afterSeq + 1;
    for (var i = 1; i < filtered.length && !hasGap; i++) {
      final prevSeq = int.parse(filtered[i - 1].appProperties['deviceSeq']!);
      final curSeq = int.parse(filtered[i].appProperties['deviceSeq']!);
      if (curSeq != prevSeq + 1) hasGap = true;
    }

    if (limit != null && filtered.length > limit) {
      filtered = filtered.sublist(0, limit);
    }

    final commits = <StoredCommit>[];
    for (final f in filtered) {
      final bytes = await _downloadContent(f.id);
      commits.add(
        StoredCommit(
          deviceSeq: int.parse(f.appProperties['deviceSeq']!),
          commitHash: f.appProperties['commitHash']!,
          parentCommitHash: f.appProperties['parentCommitHash'],
          commitBytes: bytes,
        ),
      );
    }
    return CommitPage(commits: commits, hasGap: hasGap);
  }

  // ===========================================================================
  // Content-addressed blobs
  // ===========================================================================

  static const _blobObjectType = 'blob';

  Future<_DriveFile?> _findBlob(String rootId, String contentHash) async {
    final query =
        "'$rootId' in parents and trashed = false and "
        "appProperties has { key='$_rootTagKey' and value='$_blobObjectType' } and "
        "appProperties has { key='contentHash' and value='${_escapeQueryValue(contentHash)}' }";
    final matches = await _listAll(query);
    if (matches.isEmpty) return null;
    matches.sort((a, b) => a.createdTime.compareTo(b.createdTime));
    return matches.first;
  }

  @override
  Future<bool> blobExists(String contentHash) async {
    final rootId = await _ensureRootFolder();
    return await _findBlob(rootId, contentHash) != null;
  }

  @override
  Future<void> uploadBlob({
    required String contentHash,
    required Stream<List<int>> data,
    required int length,
  }) async {
    final bytes = await _collectStream(data);
    if (bytes.length != length) {
      throw ArgumentError(
        'uploadBlob: declared length $length does not match actual stream length ${bytes.length}',
      );
    }

    // Hash the bytes we're about to send *before* any Drive interaction —
    // "re-hash the actual bytes sent and verify against the declared
    // contentHash before considering the upload successful" (M2.2 brief),
    // matching MockSyncBackend's pattern. Catches a caller bug (wrong hash
    // declared for the bytes actually provided) without ever touching the
    // network.
    final actualHash = sha256.convert(bytes).toString();
    if (actualHash != contentHash) {
      throw SyncHashMismatchException(
        expectedHash: contentHash,
        actualHash: actualHash,
      );
    }

    final rootId = await _ensureRootFolder();
    final existing = await _findBlob(rootId, contentHash);
    if (existing != null) {
      // Content-addressed idempotency: an object already stored at this
      // hash is, by definition, identical content — re-uploading would
      // only create a duplicate object under the existence-check race, for
      // zero benefit. Same reasoning as the commit-log mitigation, applied
      // to blobs.
      return;
    }

    final localMd5 = md5.convert(bytes).toString();
    final created = await _createWithContent(
      metadata: {
        'name': 'blob-$contentHash',
        'parents': [rootId],
        'appProperties': {
          _rootTagKey: _blobObjectType,
          'contentHash': contentHash,
        },
      },
      bytes: bytes,
      mimeType: 'application/octet-stream',
    );

    // Post-write verification: "never trust a Drive-reported checksum
    // alone — re-derive locally." We already derived our own hash above
    // (from the bytes we sent); this cross-checks Drive's own reported
    // md5Checksum for the object it says it stored against an
    // independently-computed local md5 of those same bytes, catching
    // transit/storage corruption between "what we sent" and "what Drive
    // says it has" (§ 8.2 item 2, torn write) without paying for a second
    // full re-download on every upload. `downloadBlob`'s own independent
    // sha256 re-hash on every read is the belt-and-suspenders check for
    // read-time corruption/tampering (§ 8.2 items 2/9/15a).
    final reportedMd5 = created.md5Checksum;
    if (reportedMd5 != null) {
      if (reportedMd5 != localMd5) {
        await _bestEffortDelete(created.id);
        throw SyncHashMismatchException(
          expectedHash: contentHash,
          actualHash: null,
        );
      }
      return;
    }

    // Drive's create response omitted md5Checksum entirely. This is not
    // known to happen for an ordinary binary upload against the real API,
    // but this translation layer must not treat "we don't know" as "it
    // passed" — an absent field is not evidence of success, and silently
    // trusting it would reopen exactly the "trust a Drive-reported
    // checksum" failure mode this whole check exists to close (this was a
    // real gap in an earlier version of this method, caught in review: it
    // had no test coverage because `FakeDriveHttpTransport` always
    // populated the field). Fall back to a genuine independent
    // verification instead of either silently accepting or unconditionally
    // failing: re-download the object we just created and re-hash it
    // against the declared `contentHash` directly — strictly stronger than
    // the md5 cross-check above (it verifies the real invariant, not a
    // proxy for it), just more expensive, which is why it isn't the
    // default path.
    final downloaded = await _downloadContent(created.id);
    final downloadedHash = sha256.convert(downloaded).toString();
    if (downloadedHash != contentHash) {
      await _bestEffortDelete(created.id);
      throw SyncHashMismatchException(
        expectedHash: contentHash,
        actualHash: downloadedHash,
      );
    }
  }

  /// Best-effort cleanup of an object this backend itself just determined
  /// is corrupt/mislabeled — not load-bearing for correctness (a future GC
  /// pass would also eventually catch an orphaned/corrupt object no commit
  /// ever references), so a failure here must never mask the real
  /// [SyncHashMismatchException] the caller is about to see.
  Future<void> _bestEffortDelete(String fileId) async {
    try {
      await _deleteFile(fileId);
    } catch (_) {
      // Intentionally swallowed — see doc comment above.
    }
  }

  @override
  Future<Stream<List<int>>> downloadBlob(String contentHash) async {
    final rootId = await _ensureRootFolder();
    final blob = await _findBlob(rootId, contentHash);
    if (blob == null) {
      throw ArgumentError(
        'downloadBlob: no blob stored for contentHash $contentHash',
      );
    }
    final bytes = await _downloadContent(blob.id);
    final actualHash = sha256.convert(bytes).toString();
    if (actualHash != contentHash) {
      // "Downloaded blobs are always hash-verified" — catches ordinary
      // corruption and external tampering alike (§ 8.2 items 2/9/15a),
      // indistinguishable from this side, exactly as documented on
      // `SyncBackend.downloadBlob`.
      throw SyncHashMismatchException(
        expectedHash: contentHash,
        actualHash: actualHash,
      );
    }
    return Stream.value(bytes);
  }

  // ===========================================================================
  // Conditional deletion — Drive has no native conditional-delete
  // primitive (§ 8.4, `capabilities.supportsConditionalDelete == false`).
  // Implemented as fetch-then-delete: the recheck immediately before the
  // delete call is the *only* mitigation Drive offers here, and it does
  // not close the race — something else can still write in the gap
  // between the recheck and the DELETE call actually landing. This is the
  // literal "recheck-before-delete is the primary mitigation" residual
  // § Architecture 4 already accepts for Drive, not a bug in this
  // implementation.
  // ===========================================================================

  @override
  Future<DeleteOutcome> deleteConditionally({
    required BackendRef ref,
    required DeletePrecondition precondition,
  }) async {
    if (precondition is IfUnmodifiedSince) {
      throw StateError(
        'deleteConditionally called with IfUnmodifiedSince against GoogleDriveBackend, which '
        'has capabilities.supportsConditionalDelete == false — Drive has no native '
        'conditional-delete primitive (§ 8.4). The caller must use the recheck-before-delete '
        'fallback and Unconditional, per § Architecture 4.',
      );
    }

    final rootId = await _ensureRootFolder();
    switch (ref) {
      case BlobRef(:final contentHash):
        final blob = await _findBlob(rootId, contentHash);
        if (blob == null) return const DeleteNotFound();
        final found = await _deleteFile(blob.id);
        return found ? const DeleteSucceeded() : const DeleteNotFound();

      case DeviceLogPrefixRef(:final deviceLogId, :final throughSeq):
        // Pruning removes commits from this log; whatever the tip cache
        // believes about it is no longer something this instance verified.
        _tipCache.remove(deviceLogId);
        final all = await _listAll(_commitsQuery(rootId, deviceLogId));
        final toDelete = _dedupeBySeq(all)
            .where(
              (f) => int.parse(f.appProperties['deviceSeq']!) <= throughSeq,
            )
            .toList();
        if (toDelete.isEmpty) return const DeleteNotFound();
        var anyDeleted = false;
        for (final f in toDelete) {
          final found = await _deleteFile(f.id);
          anyDeleted = anyDeleted || found;
        }
        return anyDeleted ? const DeleteSucceeded() : const DeleteNotFound();
    }
  }

  // ===========================================================================
  // Certified snapshots
  // ===========================================================================

  static const _snapshotObjectType = 'snapshot';

  Future<_DriveFile?> _findSnapshot(String rootId, String snapshotHash) async {
    final query =
        "'$rootId' in parents and trashed = false and "
        "appProperties has { key='$_rootTagKey' and value='$_snapshotObjectType' } and "
        "appProperties has { key='snapshotHash' and value='${_escapeQueryValue(snapshotHash)}' }";
    final matches = await _listAll(query);
    if (matches.isEmpty) return null;
    matches.sort((a, b) => a.createdTime.compareTo(b.createdTime));
    return matches.first;
  }

  @override
  Future<void> publishSnapshot(
    String snapshotHash,
    Uint8List snapshotBytes,
  ) async {
    final rootId = await _ensureRootFolder();
    final existing = await _findSnapshot(rootId, snapshotHash);
    if (existing != null) {
      // Content-addressed idempotency, as for blobs.
      return;
    }
    await _createWithContent(
      metadata: {
        'name': 'snapshot-$snapshotHash',
        'parents': [rootId],
        'appProperties': {
          _rootTagKey: _snapshotObjectType,
          'snapshotHash': snapshotHash,
        },
      },
      bytes: snapshotBytes,
      mimeType: 'application/octet-stream',
    );
  }

  @override
  Future<SnapshotRef?> latestSnapshotRef() async {
    final rootId = await _ensureRootFolder();
    final query =
        "'$rootId' in parents and trashed = false and "
        "appProperties has { key='$_rootTagKey' and value='$_snapshotObjectType' }";
    final all = await _listAll(query);
    if (all.isEmpty) return null;
    all.sort((a, b) => a.createdTime.compareTo(b.createdTime));
    final latest = all.last;
    return SnapshotRef(
      snapshotHash: latest.appProperties['snapshotHash']!,
      publishedAt: latest.createdTime,
    );
  }

  @override
  Future<Uint8List> readSnapshot(String snapshotHash) async {
    final rootId = await _ensureRootFolder();
    final snap = await _findSnapshot(rootId, snapshotHash);
    if (snap == null) {
      throw ArgumentError(
        'readSnapshot: no snapshot stored for hash $snapshotHash',
      );
    }
    final bytes = await _downloadContent(snap.id);
    final actualHash = sha256.convert(bytes).toString();
    if (actualHash != snapshotHash) {
      throw SyncHashMismatchException(
        expectedHash: snapshotHash,
        actualHash: actualHash,
      );
    }
    return bytes;
  }
}
