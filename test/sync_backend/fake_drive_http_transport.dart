// A hand-written model of Google Drive REST API v3's HTTP surface — NOT a
// fake of `SyncBackend` (that's `MockSyncBackend`, one layer up). This
// fakes Drive itself, one layer *down* from `GoogleDriveBackend`
// (`lib/services/sync/google_drive_backend.dart`), so that class's own
// translation logic (Drive API calls <-> `SyncBackend` semantics) is what's
// actually exercised by `google_drive_backend_test.dart`, including running
// the M2.1 conformance suite (`runSyncBackendConformanceSuite`) against it
// unmodified.
//
// **What this proves, and what it explicitly does not (read before trusting
// any "Drive backend is conformant" claim):** this transport implements
// `files.create`/`files.list`/`files.get`(media)/`files.delete`, Drive's
// actual `multipart/related` upload wire format, `appProperties`-based
// query filtering (a small hand-rolled parser for exactly the query shapes
// `GoogleDriveBackend` generates — not a general Drive query-language
// parser), index-based pagination tokens, and scriptable error responses
// (401/403-rate-limited/403-quota/429/5xx/507) plus a controllable
// "eventually consistent listing" delay. It is this milestone's
// best-effort model of Drive's documented behavior, built without access to
// a real Drive account to verify against. It is NOT the real API: it can't
// catch a wrong assumption about real Drive's actual behavior that this
// model itself shares (a documentation misread, an edge case Drive's real
// implementation handles differently). § 8.6's exit criteria requires a
// real-Google-endpoints manual smoke test before this backend is fully
// conformant — that has not been performed (see the doc comment atop
// `google_drive_backend.dart`).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// One scripted failure, consumed (removed from the queue) the first time
/// [matches] returns true for an incoming request. Lets tests reproduce
/// specific Drive error shapes (401, 429, 403-quota, 5xx, ...) at a
/// specific point in a call sequence without the fake needing built-in
/// knowledge of what any given test scenario is trying to prove.
class ScriptedDriveFailure {
  final bool Function(http.BaseRequest request) matches;
  final int statusCode;
  final Map<String, dynamic>? errorBody;
  final Map<String, String>? headers;

  ScriptedDriveFailure({
    required this.matches,
    required this.statusCode,
    this.errorBody,
    this.headers,
  });

  /// Matches literally the next request of any kind — convenient for "the
  /// very next call fails," the common case in the tests below. Pass
  /// [matches] to target a more specific request instead.
  factory ScriptedDriveFailure.rateLimited({
    int? retryAfterSeconds,
    bool Function(http.BaseRequest request)? matches,
  }) => ScriptedDriveFailure(
    matches: matches ?? (_) => true,
    statusCode: 429,
    headers: retryAfterSeconds == null ? null : {'retry-after': '$retryAfterSeconds'},
    errorBody: {
      'error': {
        'code': 429,
        'message': 'Rate limit exceeded',
        'errors': [
          {'reason': 'rateLimitExceeded', 'message': 'Rate limit exceeded'},
        ],
      },
    },
  );

  factory ScriptedDriveFailure.quotaExceeded({
    bool Function(http.BaseRequest request)? matches,
  }) => ScriptedDriveFailure(
    matches: matches ?? (_) => true,
    statusCode: 403,
    errorBody: {
      'error': {
        'code': 403,
        'message': 'The user has exceeded their Drive storage quota',
        'errors': [
          {'reason': 'storageQuotaExceeded', 'message': 'Storage quota exceeded'},
        ],
      },
    },
  );

  factory ScriptedDriveFailure.serverError({
    int statusCode = 503,
    bool Function(http.BaseRequest request)? matches,
  }) => ScriptedDriveFailure(
    matches: matches ?? (_) => true,
    statusCode: statusCode,
    errorBody: {
      'error': {'code': statusCode, 'message': 'Backend Error'},
    },
  );

  /// Rejects requests bearing [staleBearerToken] with a 401 — the standard
  /// way tests script "the caller's current access token is stale" without
  /// the fake needing to know or validate real token semantics.
  factory ScriptedDriveFailure.unauthorized({
    required String staleBearerToken,
  }) => ScriptedDriveFailure(
    matches: (r) => r.headers['Authorization'] == 'Bearer $staleBearerToken',
    statusCode: 401,
    errorBody: {
      'error': {
        'code': 401,
        'message': 'Invalid Credentials',
        'errors': [
          {'reason': 'authError', 'message': 'Invalid Credentials'},
        ],
      },
    },
  );
}

class _StoredFile {
  final String id;
  String name;
  String mimeType;
  List<String> parents;
  Map<String, String> appProperties;
  Uint8List? content;
  final DateTime createdTime;
  DateTime modifiedTime;

  /// M2.11: Drive's `trashed` flag. Real Drive keeps a trashed file fully
  /// addressable by id — `files.get` still returns 200 — and only hides it
  /// from `trashed = false` listings, which is exactly why a backend that
  /// addresses its root folder by id has to check the flag rather than rely
  /// on a 404. This fake now models that instead of hard-deleting
  /// everything, so `debugTrashFile` reproduces "the user moved the sync
  /// folder to the bin" as distinct from `debugDeleteFile`'s "the user
  /// emptied the bin".
  bool trashed = false;

  /// When true, [omitMd5ChecksumInJson] suppresses the `md5Checksum` field
  /// from this file's JSON representation — simulating a Drive response
  /// that omits the field, whether or not that's known to happen for a
  /// real binary upload. Exists specifically so `GoogleDriveBackend`'s
  /// fallback-verification path (re-download-and-rehash when the field is
  /// absent) has a way to be exercised at all.
  bool omitMd5ChecksumInJson = false;

  _StoredFile({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.parents,
    required this.appProperties,
    required this.content,
    required this.createdTime,
    required this.modifiedTime,
  });

  /// Reported `md5Checksum` is always recomputed from whatever [content]
  /// currently is — including after `corruptNextUploadMd5` has swapped in
  /// corrupted bytes at store time — matching how real Drive computes this
  /// field from the bytes it actually persisted, not from what a client
  /// claimed to send.
  String get md5Checksum => md5.convert(content ?? const []).toString();
}

class _QueryMatcher {
  final String? parentId;
  final bool? trashedEquals;
  final String? mimeTypeEquals;
  final String? nameEquals;
  final Map<String, String> appProperties;

  _QueryMatcher({
    this.parentId,
    this.trashedEquals,
    this.mimeTypeEquals,
    this.nameEquals,
    required this.appProperties,
  });

  static final _appPropRegex = RegExp(
    r"appProperties has \{ key='((?:[^'\\]|\\.)*)' and value='((?:[^'\\]|\\.)*)' \}",
  );
  static final _parentsRegex = RegExp(r"^'((?:[^'\\]|\\.)*)' in parents$");
  static final _trashedRegex = RegExp(r'^trashed = (true|false)$');
  static final _mimeRegex = RegExp(r"^mimeType = '((?:[^'\\]|\\.)*)'$");
  static final _nameRegex = RegExp(r"^name = '((?:[^'\\]|\\.)*)'$");

  static String _unescape(String s) =>
      s.replaceAll(r"\'", "'").replaceAll(r'\\', '\\');

  /// Parses exactly the query shapes `GoogleDriveBackend` generates — a
  /// conjunction of `'<id>' in parents`, `trashed = false`,
  /// `mimeType = '...'`, `name = '...'`, and any number of
  /// `appProperties has { key='...' and value='...' }` clauses joined by
  /// ` and `. Not a general Drive query-language parser (see the file-level
  /// doc comment).
  factory _QueryMatcher.parse(String q) {
    final appProps = <String, String>{};
    for (final m in _appPropRegex.allMatches(q)) {
      appProps[_unescape(m.group(1)!)] = _unescape(m.group(2)!);
    }
    final remainder = q.replaceAll(_appPropRegex, '');

    String? parentId;
    bool? trashedEquals;
    String? mimeTypeEquals;
    String? nameEquals;

    final clauses = remainder
        .split(' and ')
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty);
    for (final clause in clauses) {
      final parentsMatch = _parentsRegex.firstMatch(clause);
      if (parentsMatch != null) {
        parentId = _unescape(parentsMatch.group(1)!);
        continue;
      }
      final trashedMatch = _trashedRegex.firstMatch(clause);
      if (trashedMatch != null) {
        trashedEquals = trashedMatch.group(1) == 'true';
        continue;
      }
      final mimeMatch = _mimeRegex.firstMatch(clause);
      if (mimeMatch != null) {
        mimeTypeEquals = _unescape(mimeMatch.group(1)!);
        continue;
      }
      final nameMatch = _nameRegex.firstMatch(clause);
      if (nameMatch != null) {
        nameEquals = _unescape(nameMatch.group(1)!);
        continue;
      }
      throw FormatException(
        'FakeDriveHttpTransport: unrecognized query clause "$clause" (full query: "$q")',
      );
    }
    return _QueryMatcher(
      parentId: parentId,
      trashedEquals: trashedEquals,
      mimeTypeEquals: mimeTypeEquals,
      nameEquals: nameEquals,
      appProperties: appProps,
    );
  }

  bool matches(_StoredFile f) {
    if (parentId != null && !f.parents.contains(parentId)) return false;
    if (trashedEquals != null && f.trashed != trashedEquals) return false;
    if (mimeTypeEquals != null && f.mimeType != mimeTypeEquals) return false;
    if (nameEquals != null && f.name != nameEquals) return false;
    for (final entry in appProperties.entries) {
      if (f.appProperties[entry.key] != entry.value) return false;
    }
    return true;
  }
}

class _MultipartParseResult {
  final Map<String, dynamic> metadata;
  final Uint8List mediaBytes;
  final String mediaContentType;
  _MultipartParseResult(this.metadata, this.mediaBytes, this.mediaContentType);
}

int _indexOfBytes(Uint8List haystack, List<int> needle, [int start = 0]) {
  final limit = haystack.length - needle.length;
  outer:
  for (var i = start; i <= limit; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Splits one multipart part's raw bytes (everything between two boundary
/// markers) into its header block and content, per RFC 2046: a leading
/// CRLF, header line(s), a blank line, the content, then a trailing CRLF
/// immediately before the next boundary marker (already excluded from
/// [raw] by the caller).
(String headerBlock, Uint8List content) _splitPart(Uint8List raw) {
  final blankLine = utf8.encode('\r\n\r\n');
  final headerEnd = _indexOfBytes(raw, blankLine, 0);
  if (headerEnd < 0) {
    throw const FormatException('FakeDriveHttpTransport: malformed multipart part (no header/body separator)');
  }
  final headerBlock = utf8.decode(raw.sublist(0, headerEnd));
  var content = raw.sublist(headerEnd + blankLine.length);
  if (content.length >= 2 && content[content.length - 2] == 13 && content[content.length - 1] == 10) {
    content = content.sublist(0, content.length - 2);
  }
  return (headerBlock, content);
}

_MultipartParseResult _parseMultipartRelated(Uint8List body, String boundary) {
  final marker = utf8.encode('--$boundary');
  final firstMarkerAt = _indexOfBytes(body, marker, 0);
  if (firstMarkerAt < 0) {
    throw const FormatException('FakeDriveHttpTransport: multipart boundary not found');
  }
  final afterFirstMarker = firstMarkerAt + marker.length;
  final secondMarkerAt = _indexOfBytes(body, marker, afterFirstMarker);
  final afterSecondMarker = secondMarkerAt + marker.length;
  final thirdMarkerAt = _indexOfBytes(body, marker, afterSecondMarker);
  if (secondMarkerAt < 0 || thirdMarkerAt < 0) {
    throw const FormatException('FakeDriveHttpTransport: malformed multipart/related body');
  }

  final part1 = _splitPart(body.sublist(afterFirstMarker, secondMarkerAt));
  final part2 = _splitPart(body.sublist(afterSecondMarker, thirdMarkerAt));

  final metadata = jsonDecode(utf8.decode(part1.$2)) as Map<String, dynamic>;
  final contentTypeMatch = RegExp(
    r'Content-Type:\s*([^\r\n]+)',
    caseSensitive: false,
  ).firstMatch(part2.$1);
  final mediaContentType = contentTypeMatch?.group(1)?.trim() ?? 'application/octet-stream';

  return _MultipartParseResult(metadata, part2.$2, mediaContentType);
}

/// The fake transport itself. Implements `http.Client` (via `BaseClient`)
/// so it drops directly into `GoogleDriveBackend`'s `httpClient` parameter.
class FakeDriveHttpTransport extends http.BaseClient {
  final Map<String, _StoredFile> _files = {};
  int _idCounter = 0;
  int _timeCounter = 0;
  int _listCallCount = 0;

  /// Consumed FIFO — the first entry whose [ScriptedDriveFailure.matches]
  /// returns true for an incoming request short-circuits normal handling.
  final List<ScriptedDriveFailure> scriptedFailures = [];

  /// Consumed once: when true, the *next* content-bearing `files.create`
  /// (multipart upload) silently corrupts the bytes it actually stores
  /// before computing the `md5Checksum` it reports back — simulating a
  /// torn write / storage-layer corruption between "bytes the caller sent"
  /// and "bytes Drive says it has" (§ 8.2 item 2), independent of the
  /// caller's own pre-send hash check (which only ever sees the original,
  /// uncorrupted bytes — this corruption happens strictly on this fake's
  /// side of the wire, exactly like a real torn write would).
  bool corruptNextUploadMd5 = false;

  /// Consumed once: when true, the *next* content-bearing `files.create`
  /// (multipart upload)'s JSON response omits the `md5Checksum` field
  /// entirely — the case `GoogleDriveBackend.uploadBlob`'s primary
  /// verification path (cross-checking Drive's reported md5Checksum)
  /// cannot use at all, exercising its fallback (re-download-and-rehash)
  /// path instead. Independent of [corruptNextUploadMd5] — combine both to
  /// simulate an omitted checksum on a genuinely corrupted write.
  bool omitMd5ChecksumForNextUpload = false;

  /// Simulates Drive's eventually-consistent `files.list` index (§ 8.2 item
  /// 6): a file hidden this way is excluded from `files.list` results
  /// until [_listCallCount] (incremented once per `files.list` HTTP call,
  /// including each page of a multi-page listing) reaches the recorded
  /// threshold. Deliberately keyed off a call counter, not wall-clock time,
  /// so tests are fast and deterministic.
  final Map<String, int> _visibleAfterListCall = {};

  /// Total number of stored objects — commits, blobs, snapshots, the
  /// marker, the root folder itself — currently present. Test-only
  /// introspection, not part of any real Drive API.
  int get debugFileCount => _files.length;

  /// Every request this transport has served, as `"<METHOD> <path>"` — the
  /// unit a "round trip" is actually counted in.
  ///
  /// Added for M2.12: `GoogleDriveBackend.appendCommit` used to cost three
  /// Drive round trips per commit (two `files.list`, one `files.create`) and
  /// now costs one on the sequential-push fast path. That saving is
  /// invisible to every other assertion in this suite — the stored objects
  /// and the returned outcomes are identical either way — so without
  /// something counting requests, a change that quietly reinstated the two
  /// listings would pass every test. [debugRequestLog] is what
  /// `google_drive_backend_test.dart`'s round-trip budget test pins.
  final List<String> debugRequestLog = [];

  /// Requests served since the last [debugResetRequestLog].
  int get debugRequestCount => debugRequestLog.length;

  void debugResetRequestLog() => debugRequestLog.clear();

  /// How many distinct stored Drive objects currently have exactly this
  /// set of `appProperties` key/value pairs — the way tests observe the
  /// §8.4 duplicate-create race actually happening at the storage layer
  /// (mirrors `MockSyncBackend.debugStorageObjectCountAtSeq`).
  int debugCountMatching(Map<String, String> appProperties) {
    return _files.values.where((f) {
      for (final entry in appProperties.entries) {
        if (f.appProperties[entry.key] != entry.value) return false;
      }
      return true;
    }).length;
  }

  /// Hides the most-recently-created stored object whose `appProperties`
  /// match [appProperties] from `files.list` results for the next
  /// [forListCalls] `files.list` HTTP calls — the hook
  /// `google_drive_backend_test.dart` uses to reproduce Drive's
  /// eventually-consistent listing and assert `CommitPage.hasGap`.
  void debugHideNewestMatchingFromListings(
    Map<String, String> appProperties, {
    required int forListCalls,
  }) {
    _StoredFile? newest;
    for (final f in _files.values) {
      var matches = true;
      for (final entry in appProperties.entries) {
        if (f.appProperties[entry.key] != entry.value) {
          matches = false;
          break;
        }
      }
      if (!matches) continue;
      if (newest == null || f.createdTime.isAfter(newest.createdTime)) {
        newest = f;
      }
    }
    if (newest == null) return;
    _visibleAfterListCall[newest.id] = _listCallCount + forListCalls;
  }

  /// Hides ONE named stored object from `files.list` results for the next
  /// [forListCalls] listing calls.
  ///
  /// [debugHideNewestMatchingFromListings] can only ever hide a single
  /// object (the newest match), which is enough to model "this device's own
  /// brand-new commit has not indexed yet" but cannot model M2.11's root
  /// folder cases at all: those need *several* pre-existing folders hidden
  /// at once (review finding F4), or one specific peer's folder hidden from
  /// one specific device (finding F3). Keyed off the same call counter, so
  /// the two hooks compose.
  void debugHideFromListings(String fileId, {required int forListCalls}) {
    _visibleAfterListCall[fileId] = _listCallCount + forListCalls;
  }

  // ==========================================================================
  // M2.11 test hooks: the things a user does to a folder in Drive's own UI,
  // which the app has no API for and must nevertheless survive.
  // ==========================================================================

  /// Drive ids of every stored folder, oldest-created first.
  List<String> get debugFolderIds =>
      (_files.values
              .where((f) => f.mimeType == 'application/vnd.google-apps.folder')
              .toList()
            ..sort((a, b) => a.createdTime.compareTo(b.createdTime)))
          .map((f) => f.id)
          .toList();

  String debugNameOf(String fileId) => _files[fileId]!.name;

  /// Renames a stored object, as a user renaming the sync folder in Drive
  /// would. The whole of M2.11's "a rename must not orphan the dataset"
  /// claim is tested through this.
  void debugRenameFile(String fileId, String newName) {
    _files[fileId]!.name = newName;
  }

  /// Moves an object to the trash: still resolvable by id (200 from
  /// `files.get`), excluded from `trashed = false` listings.
  void debugTrashFile(String fileId) {
    _files[fileId]!.trashed = true;
  }

  /// Destroys an object outright — the state after emptying Drive's bin.
  /// `files.get` on it 404s.
  void debugDeleteFile(String fileId) {
    _files.remove(fileId);
  }

  /// Plants a folder the app did not create in this session — how a test
  /// stages "there are already two folders with this name", the ambiguity
  /// pre-M2.11 resolved by silently taking one.
  ///
  /// [appProperties] defaults to the dataset-root tag `GoogleDriveBackend`
  /// stamps on its own root folder, because a folder without it is invisible
  /// to that backend's discovery query and would stage nothing.
  String debugCreateFolder(
    String name, {
    Map<String, String> appProperties = const {
      'synapseObjectType': 'datasetRoot',
    },
  }) {
    final file = _storeNewFile(
      metadata: {
        'name': name,
        'mimeType': 'application/vnd.google-apps.folder',
        'appProperties': appProperties,
      },
      content: null,
    );
    return file.id;
  }

  /// Freezes every subsequently-created object's `createdTime` at one
  /// instant, so a test can stage the state this fake's monotonic
  /// microsecond counter otherwise makes unreachable: **two files Drive
  /// reports as created at the identical time.**
  ///
  /// Drive's `createdTime` is millisecond-resolution and two folders created
  /// in the same millisecond by two devices is an ordinary outcome of the
  /// § 8.4 create/create race, so a tie is not exotic. M2.11's reconciliation
  /// tie-break shipped as a strict `isBefore`, which is a *partial* order:
  /// under a tie each device keeps its own folder, which is precisely the
  /// split-brain the reconciliation exists to prevent (review finding F3).
  /// Pass null to resume the monotonic counter.
  void debugFreezeCreatedTimeAt(DateTime? instant) {
    _frozenCreatedTime = instant;
  }

  DateTime? _frozenCreatedTime;

  DateTime _nextTimestamp() =>
      _frozenCreatedTime ??
      DateTime.utc(2026, 1, 1).add(Duration(microseconds: _timeCounter++));

  bool _isVisible(_StoredFile f) {
    final visibleAfter = _visibleAfterListCall[f.id];
    if (visibleAfter == null) return true;
    return _listCallCount >= visibleAfter;
  }

  static Uint8List _corrupt(Uint8List bytes) {
    if (bytes.isEmpty) return Uint8List.fromList([0xFF]);
    final copy = Uint8List.fromList(bytes);
    copy[copy.length ~/ 2] ^= 0xFF;
    return copy;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // A real Drive call is never synchronous. Forcing a genuine event-loop
    // turn (not just a microtask) on every simulated call is what makes
    // `google_drive_backend_test.dart`'s §8.4 concurrent-race test reliably
    // reproduce the existence-check-before-create race rather than being
    // flaky depending on incidental microtask ordering — the same role
    // `MockSyncBackend._simulateNonAtomicCreate`'s explicit
    // `Future.delayed(Duration.zero)` yield plays there, just applied
    // uniformly here since every one of this backend's writes is already
    // non-atomic by construction (§ file-level doc comment on
    // `google_drive_backend.dart`).
    await Future<void>.delayed(Duration.zero);

    debugRequestLog.add('${request.method} ${request.url.path}');

    for (var i = 0; i < scriptedFailures.length; i++) {
      if (scriptedFailures[i].matches(request)) {
        final failure = scriptedFailures.removeAt(i);
        return _errorResponse(failure.statusCode, failure.errorBody, failure.headers);
      }
    }

    final uri = request.url;
    final method = request.method;

    if (method == 'GET' && uri.path == '/drive/v3/files') {
      return _handleList(uri);
    }
    if (method == 'POST' && uri.path == '/drive/v3/files') {
      final bytes = await request.finalize().toBytes();
      return _handleCreateMetadataOnly(bytes);
    }
    if (method == 'POST' && uri.path == '/upload/drive/v3/files') {
      final bytes = await request.finalize().toBytes();
      return _handleCreateWithContent(request, bytes);
    }
    if (method == 'GET' &&
        uri.path.startsWith('/drive/v3/files/') &&
        uri.queryParameters['alt'] == 'media') {
      final id = uri.path.substring('/drive/v3/files/'.length);
      return _handleDownload(id);
    }
    if (method == 'GET' && uri.path.startsWith('/drive/v3/files/')) {
      final id = uri.path.substring('/drive/v3/files/'.length);
      return _handleGetMetadata(id);
    }
    if (method == 'DELETE' && uri.path.startsWith('/drive/v3/files/')) {
      final id = uri.path.substring('/drive/v3/files/'.length);
      return _handleDelete(id);
    }

    return _errorResponse(404, {
      'error': {'code': 404, 'message': 'unrecognized fake Drive endpoint: $method ${uri.path}'},
    });
  }

  http.StreamedResponse _handleList(Uri uri) {
    _listCallCount++;
    final q = uri.queryParameters['q'] ?? '';
    final pageSize = int.tryParse(uri.queryParameters['pageSize'] ?? '100') ?? 100;
    final pageToken = uri.queryParameters['pageToken'];

    final matcher = _QueryMatcher.parse(q);
    final matching = _files.values.where(matcher.matches).where(_isVisible).toList()
      ..sort((a, b) => a.createdTime.compareTo(b.createdTime));

    final startIndex = pageToken == null ? 0 : int.parse(pageToken);
    final page = matching.skip(startIndex).take(pageSize).toList();
    final nextIndex = startIndex + page.length;
    final nextPageToken = nextIndex < matching.length ? '$nextIndex' : null;

    return _jsonResponse(200, {
      'files': page.map(_fileJson).toList(),
      if (nextPageToken != null) 'nextPageToken': nextPageToken,
    });
  }

  http.StreamedResponse _handleCreateMetadataOnly(Uint8List bodyBytes) {
    final metadata = jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
    final file = _storeNewFile(metadata: metadata, content: null);
    return _jsonResponse(200, _fileJson(file));
  }

  http.StreamedResponse _handleCreateWithContent(
    http.BaseRequest request,
    Uint8List bodyBytes,
  ) {
    final contentType = request.headers['Content-Type'] ?? request.headers['content-type'] ?? '';
    final boundaryMatch = RegExp(r'boundary=(\S+)').firstMatch(contentType);
    if (boundaryMatch == null) {
      return _errorResponse(400, {
        'error': {'code': 400, 'message': 'missing multipart boundary'},
      });
    }
    final parsed = _parseMultipartRelated(bodyBytes, boundaryMatch.group(1)!);
    var storedContent = parsed.mediaBytes;
    if (corruptNextUploadMd5) {
      corruptNextUploadMd5 = false;
      storedContent = _corrupt(storedContent);
    }
    final file = _storeNewFile(metadata: parsed.metadata, content: storedContent);
    if (omitMd5ChecksumForNextUpload) {
      omitMd5ChecksumForNextUpload = false;
      file.omitMd5ChecksumInJson = true;
    }
    return _jsonResponse(200, _fileJson(file));
  }

  http.StreamedResponse _handleDownload(String fileId) {
    final file = _files[fileId];
    if (file == null) {
      return _errorResponse(404, _notFoundBody());
    }
    final content = file.content ?? Uint8List(0);
    return http.StreamedResponse(
      Stream.value(content),
      200,
      headers: {'content-type': file.mimeType},
    );
  }

  http.StreamedResponse _handleGetMetadata(String fileId) {
    final file = _files[fileId];
    if (file == null) {
      return _errorResponse(404, _notFoundBody());
    }
    return _jsonResponse(200, _fileJson(file));
  }

  http.StreamedResponse _handleDelete(String fileId) {
    final file = _files[fileId];
    if (file == null) {
      return _errorResponse(404, _notFoundBody());
    }
    _files.remove(fileId);
    return http.StreamedResponse(const Stream.empty(), 204);
  }

  _StoredFile _storeNewFile({
    required Map<String, dynamic> metadata,
    required Uint8List? content,
  }) {
    final id = 'file-${_idCounter++}';
    final now = _nextTimestamp();
    final file = _StoredFile(
      id: id,
      name: metadata['name'] as String? ?? '',
      mimeType: metadata['mimeType'] as String? ?? 'application/octet-stream',
      parents: (metadata['parents'] as List<dynamic>?)?.cast<String>() ?? const [],
      appProperties: ((metadata['appProperties'] as Map<String, dynamic>?) ?? const {})
          .map((k, v) => MapEntry(k, v.toString())),
      content: content,
      createdTime: now,
      modifiedTime: now,
    );
    _files[id] = file;
    return file;
  }

  Map<String, dynamic> _fileJson(_StoredFile f) => {
    'id': f.id,
    'name': f.name,
    'mimeType': f.mimeType,
    'appProperties': f.appProperties,
    'createdTime': f.createdTime.toIso8601String(),
    'modifiedTime': f.modifiedTime.toIso8601String(),
    'trashed': f.trashed,
    if (f.content != null && !f.omitMd5ChecksumInJson) 'md5Checksum': f.md5Checksum,
    if (f.content != null) 'size': '${f.content!.length}',
  };

  Map<String, dynamic> _notFoundBody() => {
    'error': {
      'code': 404,
      'message': 'File not found',
      'errors': [
        {'reason': 'notFound', 'message': 'File not found'},
      ],
    },
  };

  http.StreamedResponse _jsonResponse(int status, Map<String, dynamic> body) {
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream.value(bytes),
      status,
      headers: {'content-type': 'application/json'},
    );
  }

  http.StreamedResponse _errorResponse(
    int status,
    Map<String, dynamic>? body, [
    Map<String, String>? headers,
  ]) {
    final bytes = utf8.encode(
      jsonEncode(body ?? {'error': {'code': status, 'message': 'error'}}),
    );
    return http.StreamedResponse(
      Stream.value(bytes),
      status,
      headers: {'content-type': 'application/json', ...?headers},
    );
  }
}
