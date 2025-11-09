import 'dart:async';

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
        if (await headlessWebView.isRunning()) {
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
}
