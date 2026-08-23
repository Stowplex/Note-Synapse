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
// ---------------------------------------------------------------------
// **M2.11: the root folder is addressed by ID, and what that turns on.**
// ---------------------------------------------------------------------
// Until M2.11 the root was resolved by NAME on every run, from a hardcoded
// string, with `existing.first` on a tie. `drive_folder_identity.dart`'s
// header states the three defects that produced; the resolution rules now
// live in [_findRootFolder]. What matters at this level: the Drive file id
// is the identity, it is persisted in `sync_state`, and a name is consulted
// exactly once per dataset (first setup, or the upgrade of an install that
// predates M2.11) and never again.
//
// **The one genuinely open question, and the honest state of it.** A second
// device joining an existing dataset has no persisted id, so it has to
// discover the folder by listing — which only works if files this app
// created for a user on device A are visible, via `files.list`, to the same
// app on device B after a separate OAuth consent. Google's published
// documentation does **not** state this either way. What it does say
// (verified 2026-08, https://developers.google.com/workspace/drive/api/
// guides/api-specific-auth): the scope grants access to files "that you
// open with an app", and the consent string in Drive v3's own discovery
// document is "See, edit, create, and delete only the specific Google Drive
// files you use with **this app**" — app-keyed language, not
// session-keyed. `files.list` is documented as accepting `drive.file`, and
// `appProperties has {...}` is a documented query form, so the mechanism
// this file already relies on is not in question — only the corpus it sees
// on a second device is.
//
// **The one explicit statement found, and why it is weaker support than it
// was originally presented as.** An earlier version of this comment cited:
//
//     "Authorization is bound to the app/project, not the token. So yes,
//      any time you get a new token during authorization or a refresh it'll
//      be good for the cumulative set of files authorized."
//     https://groups.google.com/g/google-apps-script-community/c/_W-NKbttfbo
//
// and attributed it to "Steven Bazyl, Drive API DevRel, 2019-07-30",
// calling the resulting claim medium-high confidence. Review round 2
// fetched that URL three times and **could not reproduce the
// attribution**: the thread renders as six posts ending 2019-06-11, and
// none of them is by that person — the Googler visible in it is Eric
// Koleda, Apps Script DevRel. The quote does appear associated with the
// thread in search indexes, so it is probably genuine text from somewhere
// in that discussion, but neither the author nor the date can be verified
// from the cited page, and the date given was later than the thread's last
// visible post. Worse for the use it was put to: the thread is an **Apps
// Script** discussion, where "the app/project" naturally means a *script
// project* — precisely the client-id-versus-GCP-project ambiguity the quote
// was cited to resolve, reintroduced by its own context. Treat it as a
// **weak** corroborating data point for a native OAuth client, not as an
// answer; the surrounding argument (the app-keyed consent string, the
// documented query form) is doing more work than the quote is.
//
// **The client-id wrinkle, and the honest state of the defusal.** The quote
// says "app/project" without disambiguating OAuth client id from GCP
// project, and nothing found settles it. It would matter a great deal for
// an app whose Android and iOS builds used different client ids — and M2.9
// settled that this app *is designed to* use a single **iOS-type** client
// for both platforms (`google_drive_client_config.dart`), so two release
// devices would present the identical client id and the ambiguity would be
// unreachable in production. **That is a property of the design, not an
// observed fact**: `GoogleDriveClientConfig.releaseClientId` is still the
// literal placeholder `replace-with-release-client-id`, no release client
// exists in any Google Cloud project, and no two devices have ever
// presented anything. The debug/release split is real and is the one place
// the ambiguity is deliberately reachable: those builds use distinct
// clients, so a debug build cannot expect to discover a release build's
// folder by name.
//
// **Nothing above has been tested against a real Google server** — no
// request in this entire effort ever has (see "What this file does NOT
// prove" below). So the join path is built not to depend on the answer:
// [adoptRootFolder] lets a user paste the folder id shown on the other
// device's settings screen, and a device that ends up CREATING a folder
// rather than joining one says so, rather than presenting an empty dataset
// as a successful join. If cross-device listing turns out not to work, name
// discovery finds nothing, that device creates its own folder, and the
// settings screen tells the user it created one — loud and diagnosable,
// with the paste-an-id remedy on the same screen.
//
// **That last clause was false as originally shipped, and what it took to
// make it true (review round 2, finding F1).** The remedy existed as an API
// and was unreachable as a flow: `cloud_sync_screen.dart` opened its folder
// dialog only while no id was recorded, "Set up dataset" is hidden once the
// device is Ready, "Reset sync" is offered only for a missing dataset or a
// diverged log, and a reset deliberately *preserves* the recorded id — so
// the very device this argument is about, the one that created a folder
// when it meant to join, could never be re-pointed at all. Three changes
// close it: the dialog re-opens pre-filled with the current name and id, a
// "Change folder" action reaches it from the Ready state (resetting first,
// with its own warning), and an emptied id field now clears the recorded id
// instead of being silently merged over. [inspectRootFolder] additionally
// shows *which* dataset a pasted folder holds before anything is recorded,
// so a valid-but-wrong paste is visible while cancelling is still free.
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
import 'drive_folder_identity.dart';
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

/// What a pasted folder id turns out to point at, read before anything is
/// recorded — see [GoogleDriveBackend.inspectRootFolder].
///
/// Deliberately not a `SyncBackend` concept: joining by pasting a
/// backend-native id is Drive-shaped, and § 8.1 keeps connection setup off
/// the interface entirely.
class DriveRootFolderPreview {
  const DriveRootFolderPreview({required this.identity, this.marker});

  /// The folder itself — id as pasted (trimmed), name as Drive reports it
  /// now, which is what lets the UI show the user a name they recognise
  /// instead of asking them to trust an opaque id.
  final DriveFolderIdentity identity;

  /// The dataset that folder holds, or null when it holds none yet. This is
  /// the field that distinguishes "the folder you meant" from "a valid
  /// Synapse folder that is not your dataset" — the case the tag check alone
  /// cannot see.
  final DatasetInitMarker? marker;
}

/// Lightweight typed view over one Drive `files` resource, as returned by
/// `files.list`/`files.create`/`files.get` with the `fields` this backend
/// always requests. Internal to this file — never exposed through
/// `SyncBackend`.
class _DriveFile {
  final String id;
  final String name;
  final Map<String, String> appProperties;
  final DateTime createdTime;
  final String? md5Checksum;

  /// Drive's own `trashed` flag. Only ever consulted for the root folder
  /// (M2.11): a trashed folder is still addressable by id and still returns
  /// 200 from `files.get`, so a device whose user "deleted" the sync folder
  /// the ordinary way — which moves it to Drive's trash rather than
  /// destroying it — would otherwise go on syncing into the bin.
  final bool trashed;

  const _DriveFile({
    required this.id,
    required this.name,
    required this.appProperties,
    required this.createdTime,
    this.md5Checksum,
    this.trashed = false,
  });

  factory _DriveFile.fromJson(Map<String, dynamic> json) {
    final rawProps = json['appProperties'] as Map<String, dynamic>? ?? const {};
    return _DriveFile(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      appProperties: rawProps.map((k, v) => MapEntry(k, v as String)),
      createdTime: DateTime.parse(json['createdTime'] as String),
      md5Checksum: json['md5Checksum'] as String?,
      trashed: json['trashed'] as bool? ?? false,
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
    String rootFolderName = defaultDriveRootFolderName,
    DriveFolderIdentityStore? folderIdentityStore,
  }) : _tokenManager = tokenManager,
       _http = httpClient,
       _fallbackRootFolderName = rootFolderName,
       _folderStore = folderIdentityStore ?? InMemoryDriveFolderIdentityStore();

  final OAuthTokenManager _tokenManager;
  final http.Client _http;

  /// The name to use when the durable store holds none — i.e. the default
  /// for a fresh install, and the literal an install that predates M2.11
  /// must be upgraded by. The user's own choice lives in
  /// [DriveFolderIdentity.folderName] and takes precedence over this.
  final String _fallbackRootFolderName;

  /// Durable home for the resolved folder id (M2.11). Defaults to an
  /// in-memory store, which reproduces this class's pre-M2.11 behaviour
  /// exactly: resolve once per instance, cache, forget on restart.
  final DriveFolderIdentityStore _folderStore;

  static const _apiBase = 'https://www.googleapis.com/drive/v3';
  static const _uploadBase = 'https://www.googleapis.com/upload/drive/v3';
  static const _listFields =
      'nextPageToken,files(id,name,appProperties,createdTime,modifiedTime,md5Checksum,size,trashed)';
  static const _singleFileFields =
      'id,name,appProperties,createdTime,modifiedTime,md5Checksum,size,trashed';

  /// Cached after first resolution for the lifetime of this instance — one
  /// `SyncBackend` instance is already scoped to "one dataset" (§ 8.1), and
  /// the root folder is this dataset's single root location on Drive, so
  /// there is no reason to re-resolve it on every call.
  String? _rootFolderId;

  /// Set when a durably-recorded folder id was resolved and Drive
  /// **definitively** reported it gone (404, or present-but-trashed) — M2.11.
  ///
  /// Kept as state rather than returned, because the two callers of
  /// [_findRootFolder] want opposite things from the same answer: a read
  /// ("is there a marker?") wants a plain `null`, which is what routes a
  /// vanished folder into M2.13's existing missing-dataset recovery; a write
  /// must not treat it as "no folder yet" and quietly create a replacement
  /// underneath a device that still believes it is Ready.
  ///
  /// Never set by a transport failure. Those throw out of [_findRootFolder]
  /// untouched — see [SyncRootFolderMissingException] for why that
  /// distinction is the whole point.
  String? _vanishedRootFolderId;

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

  /// Resolves the root folder **without creating it** — `null` when this
  /// dataset has no root folder the app can reach.
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
  /// have a write as a side effect.
  ///
  /// ---------------------------------------------------------------------
  /// **M2.11: three branches, and only the third one still looks at a name.**
  /// ---------------------------------------------------------------------
  /// 1. **In-memory cache** — one `SyncBackend` instance is scoped to one
  ///    dataset (§ 8.1), so the folder cannot change under it.
  /// 2. **A durably-recorded folder id** ([DriveFolderIdentity.folderId]).
  ///    Addressed by id via `files.get`, never by name — which is precisely
  ///    what makes renaming or moving the folder in Drive harmless, the
  ///    behaviour a user would expect and the third of the three defects
  ///    `drive_folder_identity.dart` opens by naming. A definitive 404 (or a
  ///    `trashed: true` answer) records [_vanishedRootFolderId] and returns
  ///    null so M2.13's missing-dataset recovery picks it up; **anything
  ///    else throws**, because "I could not reach Drive" is not "your data
  ///    was deleted".
  /// 3. **Name resolution, exactly once in this dataset's life** — first
  ///    setup, or the upgrade path for an install that predates M2.11 and
  ///    whose folder is still the name-resolved one. Whatever it finds is
  ///    persisted as an id immediately, so branch 3 never runs again. More
  ///    than one match throws [SyncAmbiguousRootFolderException] rather than
  ///    picking: see that type for why an arbitrary pick is a split-brain
  ///    rather than a cosmetic wart.
  Future<String?> _findRootFolder() async {
    final cached = _rootFolderId;
    if (cached != null) return cached;

    final stored = await _folderStore.read();
    final storedId = stored.folderId;
    if (storedId != null) {
      final folder = await _getFileIfPresent(storedId);
      if (folder == null || folder.trashed) {
        // Definitively gone. Recorded, not thrown, so that a plain read
        // ("is there a marker?") answers null and flows into M2.13's
        // existing recovery path instead of inventing a second one.
        _vanishedRootFolderId = storedId;
        return null;
      }
      _vanishedRootFolderId = null;
      _rootFolderId = storedId;
      // Refresh the recorded NAME from what Drive just said, when the two
      // disagree — M2.11 review round 2. Nothing resolves by the name any
      // more, but two things still read it: the settings screen shows it,
      // and a folder rebuilt after a deletion is created under it. Without
      // this, a folder renamed in Drive kept displaying its old name
      // forever, which contradicted [DriveFolderIdentity.folderName]'s own
      // documented meaning ("the name the folder was last seen under") and
      // would have re-created a deleted folder under a name the user had
      // deliberately moved away from. Conditional so the ordinary launch
      // still costs zero writes.
      if (folder.name.isNotEmpty && folder.name != stored.folderName) {
        await _folderStore.write(stored.copyWith(folderName: folder.name));
      }
      return storedId;
    }

    final name = stored.folderName ?? _fallbackRootFolderName;
    final existing = await _listAll(_rootFolderQuery(name));
    if (existing.isEmpty) return null;
    if (existing.length > 1) {
      // Pre-M2.11 this sorted by `createdTime` and took `existing.first`,
      // with a comment claiming oldest-wins "keeps this deterministic across
      // every device". It does not: it is deterministic per listing, and a
      // second device is free to see a different set (Drive's listing index
      // is eventually consistent, and the folders may not even all be
      // visible to it). Two devices picking two folders is a silent split-
      // brain, so this refuses instead.
      existing.sort(_oldestRootFolderFirst);
      throw SyncAmbiguousRootFolderException(
        folderName: name,
        candidateCount: existing.length,
        candidateIds: [for (final f in existing) f.id],
      );
    }
    await _rememberRootFolder(existing.single.id, existing.single.name);
    return _rootFolderId!;
  }

  /// `files.get` that answers `null` for a definitive not-found and rethrows
  /// everything else.
  ///
  /// **The narrowness is the point.** Only a 404 counts as absence. A 5xx, a
  /// 429, a timeout and a dropped connection all keep propagating as the
  /// `SyncNetworkException`/`SyncRateLimitedException` they already map to,
  /// so no transport failure can ever be rendered to a user as "your dataset
  /// was deleted" — the distinction M2.13 built
  /// `DatasetBootstrap.verifyDatasetStillExists` around, applied one layer
  /// down at the folder itself.
  ///
  /// **A disclosed ambiguity in Drive's own answer**, stated here rather
  /// than left to be discovered: under the `drive.file` scope a 404 also
  /// covers "this folder exists but this app can no longer see it". Google's
  /// documentation does not distinguish the two and the API gives the client
  /// nothing to tell them apart with. See this file's M2.11 note on
  /// `drive.file` visibility for when that case is believed to be reachable.
  Future<_DriveFile?> _getFileIfPresent(String fileId) async {
    final uri = Uri.parse(
      '$_apiBase/files/$fileId',
    ).replace(queryParameters: {'fields': _singleFileFields});
    final response = await _authorizedRequest(
      (token) =>
          http.Request('GET', uri)..headers['Authorization'] = 'Bearer $token',
    );
    if (response.statusCode == 404) return null;
    _throwIfError(response);
    return _DriveFile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// Caches and durably records a resolved/created root folder.
  Future<void> _rememberRootFolder(String folderId, String folderName) async {
    _rootFolderId = folderId;
    _vanishedRootFolderId = null;
    await _folderStore.write(
      DriveFolderIdentity(
        folderId: folderId,
        // Recorded even though nothing resolves by it any more: it is what
        // the settings screen shows the user, and what a folder created
        // after a reset is named so the user's choice is not silently lost.
        folderName: folderName.isEmpty ? null : folderName,
      ),
    );
  }

  /// Adopts an existing folder by its Drive id — M2.11's join path for a
  /// second device, and the escape hatch when name discovery cannot work.
  ///
  /// **Why this exists at all.** A second device has no recorded id, so it
  /// must *discover* the folder, which means listing by name. Whether that
  /// listing can succeed is a property of `drive.file` that this project has
  /// never been able to test against a real Google server (see this file's
  /// M2.11 note). If it works, this method is a convenience. If it does not,
  /// it is the only way to join a dataset at all — and the difference is
  /// visible to the user as "name discovery found nothing", not as a
  /// silently empty dataset, because a device that creates rather than joins
  /// says so on the settings screen.
  ///
  /// Validates before recording: an id that does not resolve throws
  /// [SyncRootFolderMissingException] here, at the moment the user pasted
  /// it, rather than being stored and turning into a fresh empty folder at
  /// the next bootstrap.
  /// A pasted id that resolves to something which is not one of this app's
  /// dataset roots — a commit file's id, a folder from some other feature —
  /// is refused with the same exception as an id that resolves to nothing,
  /// because from the user's position the two mean the same thing ("that is
  /// not the thing you meant to paste") and the remedy is identical.
  ///
  /// Implemented on top of [inspectRootFolder] so that what the settings
  /// screen SHOWED the user and what this then accepts cannot diverge — the
  /// alternative, two validation paths that "obviously" agree, is how a
  /// preview stops meaning anything. The cost is that a join driven from
  /// that screen reads the dataset marker twice (once to show it, once
  /// here): two extra Drive round trips, on an explicit one-time user
  /// action, in exchange for one definition of "usable folder".
  Future<DriveFolderIdentity> adoptRootFolder(String folderId) async {
    final preview = await inspectRootFolder(folderId);
    final identity = preview.identity;
    await _rememberRootFolder(identity.folderId!, identity.folderName ?? '');
    return identity;
  }

  /// Everything [adoptRootFolder] validates, **without recording anything** —
  /// M2.11 review round 2, finding F1.
  ///
  /// **Why validation alone was not enough.** [adoptRootFolder] checked that
  /// a pasted id resolves, is not trashed, and carries the `datasetRoot`
  /// tag. All three are true of a folder belonging to a completely different
  /// dataset — the user's own abandoned one, a second household member's —
  /// so a *valid but wrong* paste was accepted silently and only became
  /// visible afterwards, as an empty library. The dataset marker is the one
  /// thing that says WHICH dataset a folder holds, and reading it costs one
  /// listing plus one download on a path the user is already waiting on.
  ///
  /// [DriveRootFolderPreview.marker] is null when the folder is a legitimate
  /// Synapse root that simply has no dataset in it yet — a real and
  /// perfectly joinable state (the other device created the folder but has
  /// not finished bootstrap), and one worth showing rather than refusing,
  /// because the user is the only one who can say whether that is what they
  /// meant.
  Future<DriveRootFolderPreview> inspectRootFolder(String folderId) async {
    final trimmed = folderId.trim();
    final folder = await _getFileIfPresent(trimmed);
    if (folder == null ||
        folder.trashed ||
        folder.appProperties[_rootTagKey] != _rootTagValue) {
      throw SyncRootFolderMissingException(trimmed);
    }
    final markers = await _listAll(_markerQuery(trimmed));
    DatasetInitMarker? marker;
    if (markers.isNotEmpty) {
      markers.sort(_oldestRootFolderFirst);
      marker = _decodeMarker(await _downloadContent(markers.first.id));
    }
    return DriveRootFolderPreview(
      identity: DriveFolderIdentity(
        folderId: trimmed,
        folderName: folder.name.isEmpty ? null : folder.name,
      ),
      marker: marker,
    );
  }

  /// Resolves the root folder for an ordinary operation (append, read,
  /// upload, ...), creating it only when this dataset has never had one.
  ///
  /// **Creating when nothing is recorded is deliberate, not laziness**: the
  /// § 8.6 conformance suite calls `appendCommit` without ever calling
  /// `initializeDatasetOnce`, and that ordering is part of the interface's
  /// contract, not a test artifact.
  ///
  /// **Refusing to create after a vanish is the M2.11 half.** A recorded id
  /// that Drive says is gone means this device's dataset was deleted, not
  /// that it never existed; silently building a replacement underneath a
  /// device that still believes it is Ready is exactly the dead end M2.13
  /// removed from `DatasetBootstrap`. In the production flow the user never
  /// reaches this throw — `CloudSyncService.syncNow`'s pre-flight
  /// `verifyDatasetStillExists` sees the same vanished folder one call
  /// earlier and reports the missing dataset properly — so this is the
  /// backstop for every path that does not pre-flight.
  Future<String> _ensureRootFolder() async {
    final found = await _findRootFolder();
    if (found != null) return found;
    final vanished = _vanishedRootFolderId;
    if (vanished != null) throw SyncRootFolderMissingException(vanished);
    return _createRootFolder();
  }

  /// [_ensureRootFolder]'s create-anyway variant, for
  /// [initializeDatasetOnce] only.
  ///
  /// Bootstrap is the one caller entitled to build a replacement for a
  /// vanished folder, because `DatasetBootstrap.bootstrap()` only reaches
  /// `initializeDatasetOnce` when this device is NOT locally 'ready' — a
  /// fresh install, or a device the user has explicitly reset out of
  /// `needsReset`. In both, "there is no dataset, make one" is what the user
  /// asked for. A locally-'ready' device short-circuits on the marker read
  /// long before this and can never get here.
  Future<String> _ensureRootFolderForDatasetCreation() async {
    final found = await _findRootFolder();
    if (found != null) return found;
    return _createRootFolder();
  }

  /// Creates the root folder, then reconciles against a concurrent creator.
  ///
  /// **Why the extra listing, which costs one request once per dataset.**
  /// Recording an id is what makes M2.11 work, and it is also what removes
  /// the only convergence story the pre-M2.11 code had. Before, two devices
  /// that both created a folder named X would both re-list on every run and
  /// both take the oldest, so a create/create race healed itself. Now each
  /// would record the folder it personally created and neither would ever
  /// list again: two datasets, forever, silently — the exact split-brain
  /// this milestone exists to remove, reintroduced from the other end.
  /// § 8.4's existence-check-before-create race is a real, disclosed
  /// property of `files.create`, so this is not hypothetical.
  ///
  /// The reconciliation is deterministic oldest-wins over the union of what
  /// the listing returned and the folder just created — the union, because
  /// Drive's listing index is eventually consistent (§ 8.2 item 6) and may
  /// not yet contain this device's own brand-new folder.
  ///
  /// **The comparison is `(createdTime, id)`, and the second component is
  /// load-bearing rather than tidiness (review round 2, finding F3).** It
  /// shipped as a strict `isBefore`, which is a *partial* order: Drive's
  /// `createdTime` is millisecond-resolution, and two folders created in the
  /// same millisecond by two racing devices tie, so neither beat the other
  /// and each device kept its own — the reconciliation producing exactly the
  /// split-brain it exists to prevent. Drive ids are unique, so ordering the
  /// pair makes the winner total and identical on every device that sees the
  /// same set.
  ///
  /// **More than one PRE-EXISTING candidate is refused, not reconciled
  /// (review round 2, finding F4).** [_findRootFolder] throws
  /// [SyncAmbiguousRootFolderException] when its listing returns several
  /// same-named roots; before this, a listing that lagged and returned *zero*
  /// routed the identical Drive state here instead, where oldest-wins
  /// silently adopted a folder this device had neither created nor
  /// discovered. One call earlier it stopped and asked; one call later it
  /// guessed. The same rule now applies at both, counted over candidates
  /// other than this call's own creation, so the answer no longer depends on
  /// which side of a listing-index refresh the call landed on.
  ///
  /// **A retry CAN still multiply folders, and review round 3 disproved the
  /// claim that stood here.** That claim was: "this device's own leftover is
  /// visible to the next run's [_findRootFolder] listing, which throws before
  /// reaching here." True only when the leftover has reached Drive's listing
  /// index. Executed counterexample: the transport drops the connection on
  /// the first request *after* a successful folder create, the user retries,
  /// and the listing has not yet surfaced the leftover — so discovery sees
  /// zero, this method creates a second folder, and the account ends up with
  /// two same-named roots both carrying `datasetRoot`. The lag involved is
  /// the same § 8.2 item 6 eventual consistency this comment invokes three
  /// paragraphs down as the reason the reconciliation exists at all, so it is
  /// not an exotic staging.
  ///
  /// What changed with the F4 rule is the *consequence*, and it got worse
  /// rather than better: pre-M2.11 such a leftover was benign, because
  /// oldest-wins resolved it on every launch. Now every future device that
  /// must discover by name hard-fails with [SyncAmbiguousRootFolderException]
  /// until a human deletes the extra folder in Drive. So a transient network
  /// blip during one device's first setup can permanently poison name
  /// discovery for the whole account — with no signal to the user who caused
  /// it, since their own device resolves fine by recorded id. Refusing is
  /// still the right call (the alternative is the silent wrong pick this rule
  /// exists to remove), but the cost is real and is not mitigated anywhere;
  /// the repair is manual, and the re-openable folder dialog is what makes it
  /// reachable.
  ///
  /// ---------------------------------------------------------------------
  /// **What it does NOT fix, stated accurately after review round 2 found
  /// the earlier statement wrong in both halves.**
  /// ---------------------------------------------------------------------
  /// It said the split-brain needed the listing to lag on *both* devices,
  /// and that this was "the same exposure the pre-M2.11 code had". Neither
  /// is true:
  ///
  ///  * A lag on the **single** side that created the *newer* folder is
  ///    enough. B records the globally-oldest folder; A's listings — the
  ///    discovery one and the reconciliation one — both miss it; A creates
  ///    and records its own. B never lists again either, because it already
  ///    has an id. Two datasets, no error.
  ///  * Pre-M2.11 this **healed on the next run**, because resolution was
  ///    re-done from the name every launch and both devices re-took the
  ///    oldest. Recording an id is what converts a transient divergence into
  ///    a permanent one. That is a real cost of this milestone, not a
  ///    pre-existing condition it inherited.
  ///
  /// **A bounded self-heal was considered and deliberately rejected** — the
  /// candidate being "keep re-running the name reconciliation until this
  /// device has observed a peer's log in its folder, and stop once it has",
  /// which is exactly the window in which a split is undetectable. Three
  /// reasons against, the first decisive:
  ///
  ///   1. **This method's own leftover poisons it.** The losing folder is
  ///      left in place (below) carrying the same name *and* the
  ///      `datasetRoot` tag, so a device that kept re-listing would see two
  ///      candidates and, under the F4 rule above, refuse to sync — turning
  ///      a healthy, converged single-device install into a hard error. The
  ///      heal would fire most often on the installs that need it least.
  ///   2. **It orphans commits.** Adopting a different folder after this
  ///      device has already published leaves those commits in the old
  ///      folder, and strands any third device that joined it. The failure
  ///      it trades for is quieter, not smaller.
  ///   3. A single-device user is *permanently* "alone", so the extra
  ///      listing is not a bounded cost for them; it is every round forever.
  ///
  /// The permanence is therefore disclosed rather than mechanised, and the
  /// remedy is the one M2.11 already builds: the settings screen says which
  /// device CREATED a dataset rather than joining one, and the folder id and
  /// the re-openable folder dialog on that same screen let the user point
  /// this device at the other one's folder. `drive_folder_identity_test.dart`
  /// pins the permanence explicitly, so adding a heal later means
  /// consciously rewriting that test rather than silently changing behaviour.
  ///
  /// **The loser's now-empty folder is left in place**, and the reason
  /// recorded here used to be wrong: it said "deleting a folder this code
  /// cannot prove is unused". Unusedness is in fact the one thing it *can*
  /// prove — the folder was created by this very call milliseconds earlier
  /// and nothing has been written to it. The real reason is narrower: a
  /// Drive-side delete is the one action here with no undo, this code has
  /// only ever *inferred* which folder it created (from a create response it
  /// may have retried), and a wrong delete destroys a user's data where a
  /// wrong keep destroys nothing. The cost of keeping is worse than the
  /// earlier text implied and is stated here rather than left to be found:
  /// the leftover carries the chosen name **and** the `datasetRoot` tag, so
  /// it makes name discovery permanently ambiguous for every future device —
  /// which now means every such device stops with
  /// [SyncAmbiguousRootFolderException] until the user removes it in Drive.
  Future<String> _createRootFolder() async {
    final stored = await _folderStore.read();
    final name = stored.folderName ?? _fallbackRootFolderName;
    final created = await _createMetadataOnly({
      'name': name,
      'mimeType': 'application/vnd.google-apps.folder',
      'appProperties': {_rootTagKey: _rootTagValue},
    });

    final candidates = await _listAll(_rootFolderQuery(name));
    final others = [for (final c in candidates) if (c.id != created.id) c];
    if (others.length > 1) {
      others.sort(_oldestRootFolderFirst);
      throw SyncAmbiguousRootFolderException(
        folderName: name,
        candidateCount: others.length,
        candidateIds: [for (final f in others) f.id],
      );
    }

    var winner = created;
    for (final candidate in others) {
      if (_oldestRootFolderFirst(candidate, winner) < 0) winner = candidate;
    }

    await _rememberRootFolder(winner.id, name);
    return winner.id;
  }

  /// Total, stable order over root-folder candidates: oldest first, ties
  /// broken by Drive's (unique) file id. See [_createRootFolder] for why the
  /// tie-break is not cosmetic.
  static int _oldestRootFolderFirst(_DriveFile a, _DriveFile b) {
    final byTime = a.createdTime.compareTo(b.createdTime);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  }

  String _rootFolderQuery(String name) =>
      "mimeType = 'application/vnd.google-apps.folder' and trashed = false "
      "and name = '${_escapeQueryValue(name)}' and "
      "appProperties has { key='$_rootTagKey' and value='$_rootTagValue' }";

  // ===========================================================================
  // Dataset lifecycle
  // ===========================================================================

  static const _markerObjectType = 'datasetInitMarker';

  @override
  Future<void> initializeDatasetOnce(DatasetInitMarker marker) async {
    // The one caller allowed to build a root folder for a dataset whose
    // recorded folder has vanished — see
    // [_ensureRootFolderForDatasetCreation] for why bootstrap, and only
    // bootstrap, is entitled to that.
    final rootId = await _ensureRootFolderForDatasetCreation();
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
    bool sealed = false,
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
    // Sealed bytes are ciphertext and cannot hash to the plaintext address
    // (M3.4) — `blob_sync.dart` verifies after decrypting instead. The md5
    // cross-check below still runs, since it compares what Drive says it
    // stored against what we actually sent, which is key-independent.
    final actualHash = sealed ? contentHash : sha256.convert(bytes).toString();
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
  Future<Stream<List<int>>> downloadBlob(
    String contentHash, {
    bool sealed = false,
  }) async {
    final rootId = await _ensureRootFolder();
    final blob = await _findBlob(rootId, contentHash);
    if (blob == null) {
      throw ArgumentError(
        'downloadBlob: no blob stored for contentHash $contentHash',
      );
    }
    final bytes = await _downloadContent(blob.id);
    // Sealed: ciphertext, so the plaintext address cannot match. The
    // caller decrypts and re-hashes (M3.4).
    final actualHash = sealed ? contentHash : sha256.convert(bytes).toString();
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
