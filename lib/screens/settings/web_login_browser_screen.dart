import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../l10n/app_localizations.dart';
import '../../services/logger_service.dart';
import '../../services/service_locator.dart';
import '../../services/web_session_service.dart';

/// In-app browser where the user signs into a site. On "Save login" the current
/// session cookies are captured and persisted via [WebSessionService].
///
/// This is a real, interactive browser, so SSO, 2FA and captcha all work — no
/// passwords are ever handled or stored, only the resulting session cookies.
class WebLoginBrowserScreen extends StatefulWidget {
  const WebLoginBrowserScreen({super.key, this.initialUrl});

  /// Optional URL to pre-load (e.g. when re-authenticating an existing login).
  final String? initialUrl;

  @override
  State<WebLoginBrowserScreen> createState() => _WebLoginBrowserScreenState();
}

class _WebLoginBrowserScreenState extends State<WebLoginBrowserScreen> {
  static const Set<String> _allowedSchemes = {
    'http',
    'https',
    'data',
    'about',
    'file',
    'javascript',
  };

  /// Desktop Chrome UA used when "Request Desktop Site" is on. Some sites gate
  /// mobile user-agents into a native app and only expose a login form on the
  /// desktop page; overriding the UA (in addition to the content mode) is the
  /// reliable trigger for the desktop layout on Android.
  static const String _desktopUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0.0.0 Safari/537.36';

  final TextEditingController _urlController = TextEditingController();
  InAppWebViewController? _controller;
  WebUri? _currentUrl;

  /// The URL the WebView should first load. Set either from [widget.initialUrl]
  /// or from the first URL the user types, so the WebView is created with it as
  /// its `initialUrlRequest` (the controller does not exist before then).
  String? _pendingInitialUrl;
  bool _isLoading = false;
  bool _isSaving = false;
  bool _hasLoadedOnce = false;

  /// When true, request the desktop version of pages (per-session only).
  bool _desktopMode = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  /// Builds the WebView settings for the current [_desktopMode]. Used both at
  /// creation (`initialSettings`) and on runtime toggle (`setSettings`) so the
  /// two stay in sync.
  InAppWebViewSettings _buildSettings() {
    return InAppWebViewSettings(
      allowFileAccess: false,
      allowContentAccess: false,
      allowFileAccessFromFileURLs: false,
      preferredContentMode: _desktopMode
          ? UserPreferredContentMode.DESKTOP
          : UserPreferredContentMode.RECOMMENDED,
      // Android-only knobs that widen the layout for desktop pages.
      useWideViewPort: _desktopMode,
      loadWithOverviewMode: _desktopMode,
      userAgent: _desktopMode ? _desktopUserAgent : '',
    );
  }

  Future<void> _toggleDesktopMode() async {
    setState(() => _desktopMode = !_desktopMode);
    final controller = _controller;
    if (controller != null) {
      await controller.setSettings(settings: _buildSettings());
      await controller.reload();
    }
  }

  String _normalizeUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) {
      return url;
    }
    if (!RegExp(r'^[a-zA-Z]+://').hasMatch(url)) {
      url = 'https://$url';
    }
    return url;
  }

  Future<void> _navigateToTyped() async {
    final url = _normalizeUrl(_urlController.text);
    if (url.isEmpty) {
      return;
    }
    final uri = WebUri(url);
    if (_controller == null) {
      // WebView not created yet: build it with this URL as its initial request.
      setState(() {
        _pendingInitialUrl = url;
        _hasLoadedOnce = true;
      });
      return;
    }
    await _controller!.loadUrl(urlRequest: URLRequest(url: uri));
  }

  Future<void> _saveLogin() async {
    final l10n = AppLocalizations.of(context)!;
    final target = _currentUrl?.toString() ?? _normalizeUrl(_urlController.text);
    if (target.isEmpty) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final service = getIt<WebSessionService>();
      final session = await service.saveSessionFromUrl(target);
      if (!mounted) {
        return;
      }
      if (session == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.webLoginCaptureFailed)),
        );
        setState(() => _isSaving = false);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.loginSaved(session.domain))),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      LoggerService.warning('WebLoginBrowser: save failed: $e');
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.webLoginCaptureFailed)),
      );
      setState(() => _isSaving = false);
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      _urlController.text = widget.initialUrl!;
      _pendingInitialUrl = _normalizeUrl(widget.initialUrl!);
      _hasLoadedOnce = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final initialUrl = _pendingInitialUrl;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _urlController,
          keyboardType: TextInputType.url,
          autocorrect: false,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _navigateToTyped(),
          decoration: InputDecoration(
            hintText: l10n.webLoginBrowserHint,
            border: InputBorder.none,
            isDense: true,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _desktopMode ? Icons.desktop_windows : Icons.phone_android,
            ),
            tooltip: _desktopMode
                ? l10n.requestMobileSite
                : l10n.requestDesktopSite,
            onPressed: _toggleDesktopMode,
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.arrow_forward),
              tooltip: l10n.webLoginBrowserHint,
              onPressed: _navigateToTyped,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _hasLoadedOnce
                ? InAppWebView(
                    initialUrlRequest: initialUrl != null
                        ? URLRequest(url: WebUri(initialUrl))
                        : null,
                    onWebViewCreated: (controller) =>
                        _controller = controller,
                    shouldOverrideUrlLoading:
                        (controller, navigationAction) async {
                      final url = navigationAction.request.url;
                      if (url == null) {
                        return NavigationActionPolicy.CANCEL;
                      }
                      if (_allowedSchemes.contains(url.scheme.toLowerCase())) {
                        return NavigationActionPolicy.ALLOW;
                      }
                      return NavigationActionPolicy.CANCEL;
                    },
                    onLoadStart: (controller, url) {
                      if (!mounted) {
                        return;
                      }
                      setState(() {
                        _isLoading = true;
                        _currentUrl = url;
                        if (url != null) {
                          _urlController.text = url.toString();
                        }
                      });
                    },
                    onLoadStop: (controller, url) {
                      if (!mounted) {
                        return;
                      }
                      setState(() {
                        _isLoading = false;
                        _currentUrl = url;
                        if (url != null) {
                          _urlController.text = url.toString();
                        }
                      });
                    },
                    initialSettings: _buildSettings(),
                  )
                : _buildPrompt(l10n),
          ),
        ],
      ),
      floatingActionButton: _hasLoadedOnce
          ? FloatingActionButton.extended(
              onPressed: _isSaving ? null : _saveLogin,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save),
              label: Text(l10n.saveLogin),
            )
          : null,
    );
  }

  Widget _buildPrompt(AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.public, size: 56, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              l10n.webLoginBrowserHint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
