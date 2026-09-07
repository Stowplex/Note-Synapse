import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'logger_service.dart';

class WebContentExtractionResult {
  const WebContentExtractionResult({
    required this.title,
    required this.htmlContent,
    required this.textContent,
    required this.excerpt,
  });

  final String title;
  final String htmlContent;
  final String textContent;
  final String excerpt;
}

class ReadabilityExtractionException implements Exception {
  ReadabilityExtractionException(this.message);

  final String message;

  @override
  String toString() => 'ReadabilityExtractionException: $message';
}

class WebContentExtractionService {
  WebContentExtractionService._();

  static String? _cachedReadabilityScript;
  static const Set<String> _allowedSchemes = {
    'http',
    'https',
    'data',
    'about',
    'file',
    'javascript',
  };

  static Future<String> _loadReadabilityScript() async {
    return _cachedReadabilityScript ??= await rootBundle.loadString(
      'assets/scripts/Readability.min.js',
    );
  }

  /// Exposes the Readability script so other widgets (like manual extraction
  /// flows) can inject it into a WebView without triggering a full extraction.
  static Future<String> getReadabilityScript() async {
    return _loadReadabilityScript();
  }

  // ── Page source info ────────────────────────────────────────────────────

  /// Reads where the loaded page says it lives, for the `sources` entry a
  /// clip records (`NoteSource.fromPageInfo` consumes the result). Returns
  /// JSON text of `{href, canonical, ogUrl, siteName, title, byline,
  /// published}` with `''` for anything the page does not declare, and
  /// never throws: every read is guarded, so a hostile or half-loaded page
  /// degrades to empty fields instead of failing the extraction. `title`,
  /// `siteName` and `byline` are capped at 1000 characters (they are
  /// display strings that end up in `notes.metadata`); the URLs and the
  /// date are returned whole. The `<head>` survives [applyReadabilityView]
  /// (only `body.innerHTML` is replaced), so this works after the
  /// Readability toggle too.
  ///
  /// Decode the `evaluateJavascript` result with [parsePageSourceInfo].
  static const String pageSourceInfoScript = r'''
    (function() {
      function attr(selector, name) {
        try {
          var el = document.querySelector(selector);
          var value = el ? el.getAttribute(name) : null;
          return typeof value === 'string' ? value : '';
        } catch (e) {
          return '';
        }
      }
      var info = {
        href: '',
        canonical: '',
        ogUrl: '',
        siteName: '',
        title: '',
        byline: '',
        published: ''
      };
      try {
        info.href = String(window.location.href || '');
      } catch (e) {}
      try {
        info.title = String(document.title || '');
      } catch (e) {}
      // Token match, so rel="canonical alternate" is found as well.
      info.canonical = attr('link[rel~="canonical"]', 'href');
      info.ogUrl = attr(
        'meta[property="og:url"], meta[name="og:url"]', 'content');
      info.siteName = attr(
        'meta[property="og:site_name"], meta[name="og:site_name"]', 'content');
      // Open Graph's article:author is a profile URL; it only stands in for
      // a missing author name when it is not one.
      var articleAuthor = attr('meta[property="article:author"]', 'content');
      if (/^https?:/i.test(articleAuthor)) {
        articleAuthor = '';
      }
      info.byline = attr('meta[name="author"]', 'content') || articleAuthor;
      info.published =
        attr('meta[property="article:published_time"]', 'content') ||
        attr('meta[name="date"]', 'content');
      // Display strings only: a runaway <title> must not land whole in
      // notes.metadata. The URLs and the date are returned untouched.
      try {
        info.title = info.title.slice(0, 1000);
        info.siteName = info.siteName.slice(0, 1000);
        info.byline = info.byline.slice(0, 1000);
      } catch (e) {}
      try {
        return JSON.stringify(info);
      } catch (e) {
        return '';
      }
    })();
  ''';

  /// Decodes an `evaluateJavascript` result of [pageSourceInfoScript] into
  /// the `{href, canonical, ogUrl, siteName, title, byline, published}` map
  /// `NoteSource.fromPageInfo` reads.
  ///
  /// The script returns JSON text: Android's controller hands it back as a
  /// [String] (it JSON-decodes the native result once, which unwraps the
  /// string literal) and iOS returns it as is. A [Map] is accepted too, for
  /// an implementation that decodes JS objects itself, and a payload wrapped
  /// in a second JSON string layer is unwrapped. Anything else — `null`, a
  /// number, a list, unparseable text — yields an empty map. Never throws.
  /// Keys are stringified; values pass through untouched (the consumer
  /// ignores non-string ones). The result is a fresh, mutable map.
  static Map<String, dynamic> parsePageSourceInfo(dynamic result) {
    Object? value = result;
    // JSON text, possibly wrapped in one more JSON string layer.
    for (var i = 0; i < 2; i++) {
      final text = value;
      if (text is! String) break;
      try {
        value = jsonDecode(text);
      } catch (_) {
        return {};
      }
    }
    if (value is! Map) return {};
    return value.map((key, v) => MapEntry(key.toString(), v));
  }

  static Future<WebContentExtractionResult> extractFromController(
    InAppWebViewController controller,
  ) async {
    final script = await _loadReadabilityScript();
    await controller.evaluateJavascript(source: script);

    final result = await controller.evaluateJavascript(
      source: _readabilityInvokeScript,
    );

    if (result is Map) {
      if (result['error'] != null) {
        throw ReadabilityExtractionException(result['error'].toString());
      }

      final content = result['content']?.toString() ?? '';
      if (content.isEmpty) {
        throw ReadabilityExtractionException('No readable content found');
      }

      return WebContentExtractionResult(
        title: result['title']?.toString() ?? '',
        htmlContent: content,
        textContent: result['textContent']?.toString() ?? '',
        excerpt: result['excerpt']?.toString() ?? '',
      );
    }

    throw ReadabilityExtractionException(
      'Unexpected response from Readability',
    );
  }

  /// Applies the Readability DOM transformation to the currently loaded page.
  /// Throws [ReadabilityExtractionException] if the transformation fails.
  static Future<void> applyReadabilityView(
    InAppWebViewController controller,
  ) async {
    final script = await _loadReadabilityScript();
    await controller.evaluateJavascript(source: script);

    final result = await controller.evaluateJavascript(
      source: _readabilityDomApplyScript,
    );

    if (result is Map) {
      if (result['success'] == true) {
        return;
      }

      final error =
          result['error']?.toString() ?? 'Readability returned empty result';
      throw ReadabilityExtractionException(error);
    }

    throw ReadabilityExtractionException(
      'Unexpected response while applying Readability',
    );
  }

  static Future<WebContentExtractionResult> extractFromUrl(
    String url, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !_allowedSchemes.contains(uri.scheme.toLowerCase())) {
      throw ReadabilityExtractionException('Unsupported URL scheme');
    }

    final completer = Completer<WebContentExtractionResult>();
    final startTime = DateTime.now();

    final headlessWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        allowFileAccess: false,
        allowContentAccess: false,
        allowFileAccessFromFileURLs: false,
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
      ),
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final targetUrl = navigationAction.request.url;
        if (targetUrl == null) {
          return NavigationActionPolicy.CANCEL;
        }

        final scheme = targetUrl.scheme.toLowerCase();
        if (_allowedSchemes.contains(scheme)) {
          return NavigationActionPolicy.ALLOW;
        }

        LoggerService.warning(
          '[WebContentExtraction] Blocked navigation to unsupported scheme: $scheme',
        );
        return NavigationActionPolicy.CANCEL;
      },
      onLoadStop: (controller, _) async {
        if (completer.isCompleted) {
          return;
        }

        try {
          final article = await extractFromController(controller);
          LoggerService.debug(
            '[WebContentExtraction] Extracted content in ${DateTime.now().difference(startTime).inMilliseconds}ms',
          );
          completer.complete(article);
        } catch (e, stackTrace) {
          LoggerService.error(
            '[WebContentExtraction] Extraction failed: $e',
            error: e,
            stackTrace: stackTrace,
          );
          if (!completer.isCompleted) {
            completer.completeError(e);
          }
        }
      },
      onLoadError: (controller, url, code, message) {
        if (completer.isCompleted) {
          return;
        }

        final error = ReadabilityExtractionException(
          'Failed to load page ($code): $message',
        );
        LoggerService.error(
          '[WebContentExtraction] Load error for $url: $message ($code)',
        );
        completer.completeError(error);
      },
      onLoadHttpError: (controller, url, statusCode, description) {
        if (completer.isCompleted) {
          return;
        }

        final error = ReadabilityExtractionException(
          'HTTP $statusCode: $description',
        );
        LoggerService.error(
          '[WebContentExtraction] HTTP error $statusCode for $url: $description',
        );
        completer.completeError(error);
      },
    );

    await headlessWebView.run();

    try {
      final result = await completer.future.timeout(
        timeout,
        onTimeout: () {
          throw ReadabilityExtractionException('Timed out loading $url');
        },
      );
      return result;
    } finally {
      try {
        if (headlessWebView.isRunning()) {
          await headlessWebView.dispose();
        }
      } catch (e) {
        LoggerService.warning(
          '[WebContentExtraction] Error disposing headless webview: $e',
        );
      }
    }
  }

  static const String _readabilityInvokeScript = '''
    (function() {
      try {
        const article = new Readability(document).parse();
        if (article) {
          return {
            title: article.title || document.title || '',
            content: article.content || '',
            textContent: article.textContent || '',
            excerpt: article.excerpt || ''
          };
        }
        return { error: 'Readability returned empty result' };
      } catch (e) {
        return { error: e.toString() };
      }
    })();
  ''';

  static const String _readabilityDomApplyScript = '''
    (function() {
      try {
        const article = new Readability(document).parse();
        if (!article || !article.content) {
          return { success: false, error: 'Readability returned empty result' };
        }

        const styleId = '__ns_readability_style';
        let style = document.getElementById(styleId);
        if (!style) {
          style = document.createElement('style');
          style.id = styleId;
          style.innerHTML = 'body { margin: 0 auto; max-width: 720px; padding: 24px; font-size: 18px; line-height: 1.6; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #ffffff; color: #111111; } img { max-width: 100%; height: auto; }';
          document.head.appendChild(style);
        }

        document.body.innerHTML = article.content;
        document.title = article.title || document.title;
        window.scrollTo(0, 0);

        return { success: true, title: article.title || '' };
      } catch (e) {
        return { success: false, error: e.toString() };
      }
    })();
  ''';
}
