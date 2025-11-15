import 'dart:collection';

class RemoteImageReference {
  final String url;
  final String? altText;

  const RemoteImageReference({required this.url, this.altText});
}

class RemoteImageUtils {
  static final RegExp _markdownImagePattern = RegExp(
    r'!\[([^\]]*)\]\(([^)]+)\)',
    multiLine: true,
  );
  static final RegExp _htmlImagePattern = RegExp(
    r'''<img[^>]+src=["'](http[^"']+)["'][^>]*>''',
    caseSensitive: false,
  );

  static bool _isRemoteUrl(String url) {
    final lower = url.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  static List<RemoteImageReference> extractRemoteImages(String content) {
    if (content.trim().isEmpty) {
      return const [];
    }

    final ordered = LinkedHashMap<String, RemoteImageReference>();

    for (final match in _markdownImagePattern.allMatches(content)) {
      if (match.groupCount < 2) continue;
      final rawAlt = match.group(1)?.trim();
      final rawTarget = match.group(2)?.trim();
      if (rawTarget == null || rawTarget.isEmpty) continue;

      final url = _extractUrlTarget(rawTarget);
      if (url == null || !_isRemoteUrl(url) || ordered.containsKey(url)) {
        continue;
      }
      ordered[url] = RemoteImageReference(url: url, altText: rawAlt);
    }

    for (final match in _htmlImagePattern.allMatches(content)) {
      final url = match.group(1);
      if (url == null || !_isRemoteUrl(url) || ordered.containsKey(url)) {
        continue;
      }
      ordered[url] = RemoteImageReference(url: url);
    }

    return ordered.values.toList(growable: false);
  }

  static String? _extractUrlTarget(String rawTarget) {
    final sanitized = rawTarget.split(RegExp(r'\s')).first;
    if (sanitized.isEmpty) {
      return null;
    }
    final cleaned = sanitized.replaceAll(RegExp(r'[\(\)<>]'), '');
    return cleaned;
  }
}
