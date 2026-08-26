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
///
/// ## Refresh mode
/// When [refreshDomain] is set the screen re-authenticates a login that already
/// exists instead of adding a new one. It clears that domain's live cookies
/// first — a session the server has invalidated has usually *not* passed its
/// `Expires`, so the WebView would keep replaying it and the site would answer
/// with a broken half-signed-in page rather than a login form. The saved
/// session and its app grants are left alone, and are put back untouched if the
/// user leaves without completing a sign-in.
class WebLoginBrowserScreen extends StatefulWidget {
  const WebLoginBrowserScreen({
    super.key,
    this.initialUrl,
    this.refreshDomain,
  });

  /// Optional URL to pre-load (e.g. when re-authenticating an existing login).
  final String? initialUrl;

  /// Registrable domain of an existing login to re-authenticate in place.
  /// `null` means this is an ordinary "add a login" visit.
  final String? refreshDomain;

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

  /// The session as it was when refresh mode started. Kept so an abandoned
  /// refresh can be undone — a failed re-login must never cost a login that
  /// might still have been working.
  WebSession? _snapshot;

  /// Set once this visit has captured a session, so leaving the screen keeps
  /// the new login instead of rolling [_snapshot] back.
  bool _captured = false;

  /// True while the domain's cookies are being cleared, before the WebView is
  /// created. The WebView must not navigate until then or it would replay the
  /// stale cookies this mode exists to get rid of.
  bool _preparingRefresh = false;

  bool get _isRefreshMode => widget.refreshDomain != null;

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
      _captured = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isRefreshMode
                ? l10n.webLoginRefreshed(session.domain)
                : l10n.loginSaved(session.domain),
          ),
        ),
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
      // In refresh mode the WebView is held back until the stale cookies are
      // gone; _prepareRefresh flips _hasLoadedOnce once that is done.
      _hasLoadedOnce = !_isRefreshMode;
    }
    if (_isRefreshMode) {
      _preparingRefresh = true;
      _prepareRefresh();
    }
  }

  /// Snapshots the existing session and wipes the domain's live cookies so the
  /// site serves a real login page, then lets the WebView load.
  Future<void> _prepareRefresh() async {
    final domain = widget.refreshDomain!;
    final service = getIt<WebSessionService>();
    try {
      final session = await service.getSession(domain);
      _snapshot = session;
      await service.clearLiveCookies(domain, savedUrl: session?.savedUrl);
    } catch (e) {
      LoggerService.warning('WebLoginBrowser: refresh prepare failed: $e');
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _preparingRefresh = false;
      if (_pendingInitialUrl != null) {
        _hasLoadedOnce = true;
      }
    });
  }

  /// Re-captures the session once the live jar looks like a completed sign-in.
  ///
  /// This runs after every page load rather than waiting for a button, which is
  /// what makes a refresh a single tap. It is safe to run repeatedly: the check
  /// requires the whole previous cookie set to be back with at least one new
  /// value, so a half-finished sign-in cannot overwrite the snapshot, and a
  /// later capture simply supersedes an earlier one.
  Future<void> _maybeAutoCapture(String? url) async {
    final snapshot = _snapshot;
    if (!_isRefreshMode || snapshot == null || url == null || _isSaving) {
      return;
    }
    final service = getIt<WebSessionService>();
    try {
      if (!await service.looksReauthenticated(url, snapshot)) {
        return;
      }
      final session = await service.saveSessionFromUrl(url);
      if (session == null || !mounted) {
        return;
      }
      // Advance the baseline so the next capture only fires on a further
      // rotation rather than on every page load.
      setState(() {
        _snapshot = session;
        _captured = true;
      });
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.webLoginRefreshed(session.domain))),
      );
    } catch (e) {
      LoggerService.warning('WebLoginBrowser: auto-capture failed: $e');
    }
  }

  /// Puts the pre-refresh session back when the user leaves without signing in.
  Future<void> _discardRefresh() async {
    final snapshot = _snapshot;
    if (!_isRefreshMode || snapshot == null || _captured) {
      return;
    }
    try {
      await getIt<WebSessionService>().restoreSession(snapshot);
    } catch (e) {
      LoggerService.warning('WebLoginBrowser: could not restore session: $e');
    }
  }

  /// Clears the current site's cookies so a stale sign-in can be redone. Offered
  /// in the plain "add a login" flow too, where the same stale-cookie problem
  /// shows up as a site that refuses to show its login form.
  Future<void> _clearCookiesForCurrentSite() async {
    final l10n = AppLocalizations.of(context)!;
    final target = _currentUrl?.toString() ?? _normalizeUrl(_urlController.text);
    final domain = WebSessionService.domainKeyFor(target);
    if (domain.isEmpty) {
      return;
    }
    await getIt<WebSessionService>().clearLiveCookies(domain, savedUrl: target);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.webLoginCookiesCleared)));
    await _controller?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    // Only intercept back when there is a snapshot to put back; otherwise leave
    // the native back gesture alone.
    final mustRestore = _isRefreshMode && !_captured && _snapshot != null;
    return PopScope(
      canPop: !mustRestore,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          return;
        }
        // An abandoned refresh must leave nothing behind: put the snapshot back
        // (session and cookies) before the screen goes away.
        final restored = _isRefreshMode && !_captured && _snapshot != null;
        await _discardRefresh();
        if (!mounted) {
          return;
        }
        if (restored) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.webLoginRefreshDiscarded)),
          );
        }
        Navigator.of(context).pop(_captured);
      },
      child: _buildScaffold(context, l10n),
    );
  }

  Widget _buildScaffold(BuildContext context, AppLocalizations l10n) {
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
          if (_hasLoadedOnce)
            IconButton(
              icon: const Icon(Icons.cleaning_services_outlined),
              tooltip: l10n.clearSiteCookies,
              onPressed: _clearCookiesForCurrentSite,
            ),
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
            child: _preparingRefresh
                ? const Center(child: CircularProgressIndicator())
                : _hasLoadedOnce
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
                    onLoadStop: (controller, url) async {
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
                      await _maybeAutoCapture(url?.toString());
                    },
                    initialSettings: _buildSettings(),
                  )
                : _buildPrompt(l10n),
          ),
        ],
      ),
      floatingActionButton: _hasLoadedOnce
          ? FloatingActionButton.extended(
              // Once refresh mode has captured a sign-in the browser stays open
              // (a later rotation is picked up automatically), so the button
              // becomes the way out rather than a second save.
              onPressed: _isSaving
                  ? null
                  : (_isRefreshMode && _captured
                        ? () => Navigator.of(context).pop(true)
                        : _saveLogin),
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      _isRefreshMode && _captured ? Icons.check : Icons.save,
                    ),
              label: Text(
                _isRefreshMode && _captured ? l10n.done : l10n.saveLogin,
              ),
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
              _isRefreshMode
                  ? l10n.webLoginRefreshHint
                  : l10n.webLoginBrowserHint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
