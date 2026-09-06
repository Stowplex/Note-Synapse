/// Rewrites relative `src` / `href` / `poster` / `srcset` values in an HTML
/// fragment so they become absolute URLs resolved against [baseUrl].
///
/// The web clipper captures `document.body.innerHTML` verbatim when the
/// Readability toggle is off, which leaves relative references (`/media/a.png`,
/// `../img/b.jpg`, `//cdn/x.png`) intact. Those references are useless once the
/// page is converted to markdown and stored in a note: images cannot be
/// downloaded and links are dead.
///
/// Only relative references are rewritten. A value that already carries a URI
/// scheme is left exactly as it was — never re-parsed, never re-encoded. That
/// matters because Dart's [Uri] normalizer is not the WHATWG URL parser: it
/// would percent-encode IDN host bytes (`https://例え.jp` → `https://%E4%BE%8B…`),
/// re-encode `%`, `[`, `]` and `|` in paths and queries, and flip the case of
/// existing percent-escapes — breaking DNS resolution for the first and
/// HMAC-signed CDN query strings for the rest.
///
/// The pass is therefore idempotent and safe to run unconditionally, including
/// on Readability-processed HTML (whose URLs are already absolute, so it is
/// left untouched).
///
/// Fragment-only values (`#section`) are deliberately **left untouched**: the
/// note renderer intercepts them and scrolls to the matching heading inside the
/// note. Absolutizing them would turn an in-note jump into a link that kicks
/// the reader out to a browser.
library;

import 'package:html/parser.dart' show parseFragment;

/// Attributes holding exactly one URL.
const List<String> _singleUrlAttributes = ['src', 'href', 'poster'];

/// Attributes holding a comma-separated candidate list (`url [descriptor]`).
const List<String> _srcsetAttributes = ['srcset', 'data-srcset'];

/// Schemes that cannot serve as a base for resolution.
const Set<String> _skippedSchemes = {
  'data',
  'blob',
  'javascript',
  'mailto',
  'tel',
  'about',
};

final RegExp _schemeToken = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*$');
final RegExp _trailingCommas = RegExp(r',+$');

/// Returns [html] with relative URLs resolved against [baseUrl].
///
/// Returns [html] unchanged when [baseUrl] is null/blank, unparseable, has no
/// scheme, or uses a non-hierarchical scheme such as `about:` or `data:`.
String absolutizeUrls(String html, String? baseUrl) {
  if (html.isEmpty) {
    return html;
  }

  final base = _parseBase(baseUrl);
  if (base == null) {
    return html;
  }

  // Parsed in body context because that is what both callers capture
  // (`document.body.innerHTML`). Note the walk cannot reach inside
  // `<noscript>`: the parser treats it as raw text with scripting enabled, so
  // it has no element children. html2md discards `<noscript>` for the same
  // reason, so nothing reachable in the output is missed.
  final fragment = parseFragment(html, container: 'body');
  var changed = false;

  for (final element in fragment.querySelectorAll('*')) {
    for (final name in _singleUrlAttributes) {
      final value = element.attributes[name];
      if (value == null) continue;
      final resolved = _resolveSingle(base, value);
      if (resolved != null) {
        element.attributes[name] = resolved;
        changed = true;
      }
    }

    for (final name in _srcsetAttributes) {
      final value = element.attributes[name];
      if (value == null) continue;
      final resolved = _resolveSrcset(base, value);
      if (resolved != value) {
        element.attributes[name] = resolved;
        changed = true;
      }
    }
  }

  // Avoid a serialization round-trip (which can subtly reformat markup) when
  // there was nothing to rewrite.
  if (!changed) {
    return html;
  }

  return fragment.outerHtml;
}

/// Parses [baseUrl] into a usable base, or returns null when it cannot serve
/// as one.
Uri? _parseBase(String? baseUrl) {
  if (baseUrl == null) return null;
  final trimmed = baseUrl.trim();
  if (trimmed.isEmpty) return null;

  final base = Uri.tryParse(trimmed);
  if (base == null || !base.hasScheme) return null;
  if (_skippedSchemes.contains(base.scheme.toLowerCase())) return null;
  return base;
}

/// Resolves a single URL attribute value.
///
/// Returns null when the value must be left exactly as it is (either because
/// it is one of the skipped forms, or because resolving produced no change).
String? _resolveSingle(Uri base, String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;

  // Fragment-only links stay in-document; see the library doc comment.
  if (trimmed.startsWith('#')) return null;

  // Anything that already carries a scheme is an absolute URI and needs no
  // resolution. Passing it through `Uri.resolve` anyway would only re-encode
  // it; see the library doc comment. This subsumes `data:`, `mailto:`, `tel:`,
  // `javascript:` and `blob:`. Protocol-relative `//host/x` has no scheme and
  // is still resolved.
  if (_hasScheme(trimmed)) return null;

  try {
    final resolved = base.resolve(trimmed).toString();
    return resolved == value ? null : resolved;
  } on FormatException {
    // A single malformed URL must never abort the whole clip.
    return null;
  }
}

/// Whether [value] begins with a URI scheme, e.g. `https:` or `data:`.
///
/// A bare colon is not enough: a relative path such as `foo/bar:baz.png` must
/// still be resolved, so the part before the colon has to be a valid scheme
/// token.
bool _hasScheme(String value) {
  final colon = value.indexOf(':');
  if (colon <= 0) return false;
  return _schemeToken.hasMatch(value.substring(0, colon));
}

/// Resolves every candidate URL in a `srcset`-style value while preserving the
/// original whitespace, commas and descriptors (`2x`, `640w`).
///
/// Candidates are split on whitespace first (not on commas), so comma-bearing
/// URLs such as `data:` URIs survive intact.
String _resolveSrcset(Uri base, String value) {
  final out = StringBuffer();
  var i = 0;
  final length = value.length;

  while (i < length) {
    // Separators between candidates: whitespace and commas, copied verbatim.
    final separatorStart = i;
    while (i < length && (_isWhitespace(value[i]) || value[i] == ',')) {
      i++;
    }
    out.write(value.substring(separatorStart, i));
    if (i >= length) break;

    // The URL runs until the next whitespace character.
    final urlStart = i;
    while (i < length && !_isWhitespace(value[i])) {
      i++;
    }
    var url = value.substring(urlStart, i);

    // A URL ending in commas terminates the candidate; the commas belong to
    // the separator, not to the URL.
    var trailing = '';
    final match = _trailingCommas.firstMatch(url);
    if (match != null) {
      trailing = match.group(0)!;
      url = url.substring(0, url.length - trailing.length);
    }

    out.write(_resolveSingle(base, url) ?? url);
    out.write(trailing);
    if (trailing.isNotEmpty) continue;

    // The descriptor runs until the next comma.
    final descriptorStart = i;
    while (i < length && value[i] != ',') {
      i++;
    }
    out.write(value.substring(descriptorStart, i));
  }

  return out.toString();
}

bool _isWhitespace(String c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}
