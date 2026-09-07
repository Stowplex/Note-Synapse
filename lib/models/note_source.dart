import 'package:uuid/uuid.dart';

/// Well-known values for [NoteSource.kind].
///
/// Plain strings rather than an enum so that a value written by a newer app
/// version survives a JSON round-trip through an older one.
class NoteSourceKind {
  NoteSourceKind._();

  /// A web page. The default.
  static const String web = 'web';

  /// A file (PDF, image, ...) downloaded from [NoteSource.url].
  static const String file = 'file';
}

/// Well-known values for [NoteSource.method]: how the source was recorded.
/// Plain strings for the same reason as [NoteSourceKind].
class NoteSourceMethod {
  NoteSourceMethod._();

  /// Webview / Readability extraction in the share flow.
  static const String extract = 'extract';

  /// AI extraction in the share flow.
  static const String ai = 'ai';

  /// A blob / file download in the share flow.
  static const String download = 'download';

  /// Entered or edited by hand.
  static const String manual = 'manual';

  /// Parsed from a `**Source:**` line while importing markdown.
  static const String import = 'import';
}

/// Where a note's content was clipped from.
///
/// Stored as one entry of the `sources` list in `notes.metadata` (see
/// `NoteMetadata` in `lib/utils/note_metadata.dart`). Absent optional fields
/// are omitted from the JSON. Every getter tolerates a garbage [url] because
/// the value can come from untrusted page data.
class NoteSource {
  /// Stable identifier so edit / remove can target one entry.
  final String id;

  /// The canonical URL when the page declares one, else the URL actually
  /// loaded (after redirects); for a [NoteSourceKind.file] source, the
  /// download URL. Open and Copy must use this value; [compactUrl] is for
  /// display only.
  final String url;

  /// The URL the user shared, recorded only when it differs from [url].
  final String? sharedUrl;

  /// The page's `<link rel="canonical">`, when it declared one.
  final String? canonicalUrl;

  final String? title;

  /// `og:site_name`, when the page declared one.
  final String? siteName;

  /// Author line (`meta[name=author]` and friends).
  final String? byline;

  /// `article:published_time`, when it was parseable.
  final DateTime? publishedAt;

  /// When the clip was made; null when the stored entry did not record it.
  final DateTime? clippedAt;

  /// One of [NoteSourceKind], or an unknown value from a newer version.
  final String kind;

  /// One of [NoteSourceMethod], or an unknown value from a newer version.
  final String method;

  /// [id] defaults to a fresh UUID. [url] is stored trimmed, so what is
  /// persisted is exactly the identity [NoteMetadata.sourceKey] de-duplicates
  /// on. The optional strings ([sharedUrl], [canonicalUrl], [title],
  /// [siteName], [byline]) are trimmed and stored as null when blank, so
  /// [toJson] omits them. [clippedAt] is stored as given;
  /// [NoteSource.fromPageInfo] is what defaults it to now.
  NoteSource({
    String? id,
    required String url,
    String? sharedUrl,
    String? canonicalUrl,
    String? title,
    String? siteName,
    String? byline,
    this.publishedAt,
    this.clippedAt,
    this.kind = NoteSourceKind.web,
    required this.method,
  }) : id = id ?? const Uuid().v4(),
       url = url.trim(),
       sharedUrl = _cleanString(sharedUrl),
       canonicalUrl = _cleanString(canonicalUrl),
       title = _cleanString(title),
       siteName = _cleanString(siteName),
       byline = _cleanString(byline);

  /// Builds a source from the `{href, canonical, ogUrl, siteName, title,
  /// byline, published}` map the share flow reads off the loaded page.
  ///
  /// [url] is picked by precedence `canonical` → `ogUrl` → `href` →
  /// [sharedUrl]; a relative candidate is resolved against `href` (or
  /// [sharedUrl]). [sharedUrl] is only recorded when it differs from the
  /// chosen [url]. Missing, empty or non-string keys are ignored and nothing
  /// here throws on page data; if no candidate is usable, [url] is the
  /// trimmed [sharedUrl] even when that is empty. [clippedAt] defaults to
  /// now.
  factory NoteSource.fromPageInfo(
    Map<String, dynamic> info, {
    required String sharedUrl,
    required String method,
    DateTime? clippedAt,
    String kind = NoteSourceKind.web,
  }) {
    final shared = sharedUrl.trim();
    final href = _absoluteHttpUrl(_cleanString(info['href']), base: shared);
    final base = href ?? shared;
    final canonical = _absoluteHttpUrl(
      _cleanString(info['canonical']),
      base: base,
    );
    final ogUrl = _absoluteHttpUrl(_cleanString(info['ogUrl']), base: base);
    final url = canonical ?? ogUrl ?? href ?? shared;
    return NoteSource(
      url: url,
      sharedUrl: shared.isNotEmpty && shared != url ? shared : null,
      canonicalUrl: canonical,
      title: _cleanText(info['title']),
      siteName: _cleanText(info['siteName']),
      byline: _cleanText(info['byline']),
      publishedAt: _parseDate(info['published']),
      clippedAt: clippedAt ?? DateTime.now(),
      kind: kind,
      method: method,
    );
  }

  /// Throws [FormatException] when [json] has no usable `url`. Every other
  /// field degrades gracefully: a missing or blank `id` becomes a UUID
  /// derived from the `url` (v5, URL namespace) so repeated reads of the
  /// same entry agree, a missing or unparseable `clippedAt` / `publishedAt`
  /// becomes null, a missing `kind` / `method` becomes [NoteSourceKind.web]
  /// / [NoteSourceMethod.manual]. Dates accept ISO-8601 strings or
  /// milliseconds since the epoch.
  factory NoteSource.fromJson(Map<String, dynamic> json) {
    final url = _cleanString(json['url']);
    if (url == null) {
      throw const FormatException('NoteSource requires a non-empty url');
    }
    return NoteSource(
      id: _cleanString(json['id']) ?? const Uuid().v5(Namespace.url.value, url),
      url: url,
      sharedUrl: _cleanString(json['sharedUrl']),
      canonicalUrl: _cleanString(json['canonicalUrl']),
      title: _cleanString(json['title']),
      siteName: _cleanString(json['siteName']),
      byline: _cleanString(json['byline']),
      publishedAt: _parseDate(json['publishedAt']),
      clippedAt: _parseDate(json['clippedAt']),
      kind: _cleanString(json['kind']) ?? NoteSourceKind.web,
      method: _cleanString(json['method']) ?? NoteSourceMethod.manual,
    );
  }

  /// Dates are written as UTC ISO-8601 strings; null fields are omitted.
  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    if (sharedUrl != null) 'sharedUrl': sharedUrl,
    if (canonicalUrl != null) 'canonicalUrl': canonicalUrl,
    if (title != null) 'title': title,
    if (siteName != null) 'siteName': siteName,
    if (byline != null) 'byline': byline,
    if (publishedAt != null)
      'publishedAt': publishedAt!.toUtc().toIso8601String(),
    if (clippedAt != null) 'clippedAt': clippedAt!.toUtc().toIso8601String(),
    'kind': kind,
    'method': method,
  };

  /// A copy with the given fields replaced. Passing `''` for an optional
  /// string ([sharedUrl], [canonicalUrl], [title], [siteName], [byline])
  /// clears it, because the constructor stores blank strings as null; a
  /// null argument keeps the current value.
  NoteSource copyWith({
    String? id,
    String? url,
    String? sharedUrl,
    String? canonicalUrl,
    String? title,
    String? siteName,
    String? byline,
    DateTime? publishedAt,
    DateTime? clippedAt,
    String? kind,
    String? method,
  }) => NoteSource(
    id: id ?? this.id,
    url: url ?? this.url,
    sharedUrl: sharedUrl ?? this.sharedUrl,
    canonicalUrl: canonicalUrl ?? this.canonicalUrl,
    title: title ?? this.title,
    siteName: siteName ?? this.siteName,
    byline: byline ?? this.byline,
    publishedAt: publishedAt ?? this.publishedAt,
    clippedAt: clippedAt ?? this.clippedAt,
    kind: kind ?? this.kind,
    method: method ?? this.method,
  );

  // ── Display helpers ──────────────────────────────────────────────────────

  /// Lower-cased host of [url] without a leading `www.`; empty when [url]
  /// has no host. A Unicode host (`例え.jp`), which [Uri] keeps
  /// percent-encoded, is decoded for display; a punycode `xn--` host is
  /// left as is.
  String get host =>
      _stripWww(_decodeLeniently(_uri?.host ?? '').toLowerCase());

  /// [title], else [host], else the raw [url].
  String get displayTitle {
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    final h = host;
    return h.isNotEmpty ? h : url;
  }

  /// Path budget (characters after the host) for [compactUrl].
  static const int _compactPathBudget = 48;

  /// A short, single-line rendering of [url] for display: no scheme, no
  /// `www.`, no fragment; the query is dropped once the path has two or more
  /// segments (`youtube.com/watch?v=abc` keeps it); the path is
  /// middle-ellipsized to about [_compactPathBudget] characters, e.g.
  /// `example.com/blog/2026/…/very-long-slug`. Widgets still apply
  /// `maxLines: 1` + ellipsis as the last resort.
  String get compactUrl {
    final uri = _uri;
    if (uri == null || uri.host.isEmpty) return _compactFallback(url);
    // Not uri.pathSegments: it throws on percent-escapes that are not valid
    // UTF-8 (`caf%E9`); such a segment is shown as written instead.
    final segments = uri.path
        .split('/')
        .where((s) => s.isNotEmpty)
        .map((s) => _singleLine(_decodeLeniently(s)))
        .toList();
    final authority = uri.hasPort ? '$host:${uri.port}' : host;
    final keepQuery = segments.length < 2 && uri.query.isNotEmpty;
    final path = segments.join('/');
    var tail = keepQuery ? '$path?${_singleLine(uri.query)}' : path;
    if (tail.length > _compactPathBudget) {
      tail = segments.length >= 2
          ? _ellipsizeSegments(segments, _compactPathBudget)
          : _ellipsizeMiddle(tail, _compactPathBudget);
    }
    return tail.isEmpty ? authority : '$authority/$tail';
  }

  // ── Internals ────────────────────────────────────────────────────────────

  static const String _ellipsis = '…';
  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _schemePrefix = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

  /// [url] parsed leniently: a scheme-less `example.com/x` is retried as
  /// https; garbage yields null.
  Uri? get _uri {
    final raw = url.trim();
    if (raw.isEmpty) return null;
    final parsed = Uri.tryParse(raw);
    if (parsed != null && (parsed.hasScheme || parsed.host.isNotEmpty)) {
      return parsed;
    }
    return Uri.tryParse('https://$raw');
  }

  static String _stripWww(String host) =>
      host.toLowerCase().startsWith('www.') ? host.substring(4) : host;

  static String _singleLine(String s) => s.replaceAll(_whitespace, ' ');

  /// [Uri.decodeComponent], falling back to [s] itself when its
  /// percent-escapes are not valid UTF-8 (`caf%E9`, a truncated `%E4%B8`) or
  /// not escapes at all (`100%`, `%zz`), so no getter depends on how [Uri]
  /// happens to normalise a malformed escape.
  static String _decodeLeniently(String s) {
    try {
      return Uri.decodeComponent(s);
    } on FormatException {
      return s;
    } on ArgumentError {
      return s;
    }
  }

  /// Rendering for a [url] that has no host: strip scheme / `www.` /
  /// fragment textually and shorten the rest.
  static String _compactFallback(String raw) {
    var s = _stripWww(raw.trim().replaceFirst(_schemePrefix, ''));
    final hash = s.indexOf('#');
    if (hash >= 0) s = s.substring(0, hash);
    return _ellipsizeMiddle(_singleLine(s), _compactPathBudget + 16);
  }

  /// Keeps the last segment and as many leading segments as fit:
  /// `blog/2026/…/very-long-slug`. A last segment that is itself too long
  /// is middle-ellipsized.
  static String _ellipsizeSegments(List<String> segments, int budget) {
    final last = segments.last;
    // '…/' + last must fit, otherwise shorten the last segment itself.
    if (last.length + 2 > budget) {
      return '$_ellipsis/${_ellipsizeMiddle(last, budget - 2)}';
    }
    final head = <String>[];
    var used = last.length + 2;
    for (final segment in segments.take(segments.length - 1)) {
      if (used + segment.length + 1 > budget) break;
      head.add(segment);
      used += segment.length + 1;
    }
    return [...head, _ellipsis, last].join('/');
  }

  static String _ellipsizeMiddle(String s, int budget) {
    if (s.length <= budget) return s;
    if (budget < 3) return _ellipsis;
    final keep = budget - 1;
    final head = (keep + 1) ~/ 2;
    final tail = keep - head;
    return '${s.substring(0, head)}$_ellipsis${s.substring(s.length - tail)}';
  }

  static bool _isHttp(Uri uri) =>
      (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;

  /// [candidate] as an absolute http(s) URL, resolving a relative reference
  /// against [base]; null when that is not possible. Other schemes
  /// (`javascript:`, `mailto:`, ...) are rejected.
  static String? _absoluteHttpUrl(String? candidate, {required String base}) {
    if (candidate == null) return null;
    final uri = Uri.tryParse(candidate);
    if (uri == null) return null;
    if (_isHttp(uri)) return candidate;
    if (uri.hasScheme || base.isEmpty) return null;
    final baseUri = Uri.tryParse(base);
    if (baseUri == null || !_isHttp(baseUri)) return null;
    try {
      final resolved = baseUri.resolveUri(uri);
      return _isHttp(resolved) ? resolved.toString() : null;
    } catch (_) {
      return null;
    }
  }

  /// Trimmed [value] when it is a non-empty string, else null.
  static String? _cleanString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// [_cleanString] with whitespace runs (including newlines) collapsed.
  static String? _cleanText(Object? value) {
    final s = _cleanString(value);
    return s == null ? null : _singleLine(s);
  }

  /// Largest magnitude [DateTime.fromMillisecondsSinceEpoch] accepts.
  static const double _maxEpochMillis = 8.64e15;

  /// ISO-8601 string or milliseconds since the epoch; null otherwise,
  /// including a number outside the range a [DateTime] can hold.
  static DateTime? _parseDate(Object? value) {
    if (value is String) return DateTime.tryParse(value.trim());
    if (value is num && value.isFinite && value.abs() <= _maxEpochMillis) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
    }
    return null;
  }
}
