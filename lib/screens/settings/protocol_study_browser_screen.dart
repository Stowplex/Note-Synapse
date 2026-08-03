import 'dart:collection';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../../models/protocol_exchange.dart';
import '../../models/protocol_study.dart';
import '../../services/protocol_study/protocol_capture_controller.dart';
import '../../services/protocol_study/protocol_capture_user_script.dart';
import '../../services/protocol_study/protocol_study_workspace.dart';
import '../../services/web_session_service.dart';
import 'protocol_network_screen.dart';

class ProtocolStudyBrowserScreen extends StatefulWidget {
  const ProtocolStudyBrowserScreen({
    super.key,
    required this.workspace,
    required this.webSessions,
    this.initialUrl,
    this.savedLoginDomain,
  });

  final ProtocolStudyWorkspace workspace;
  final WebSessionService webSessions;
  final String? initialUrl;
  final String? savedLoginDomain;

  @override
  State<ProtocolStudyBrowserScreen> createState() =>
      _ProtocolStudyBrowserScreenState();
}

class _ProtocolStudyBrowserScreenState
    extends State<ProtocolStudyBrowserScreen> {
  final _urlController = TextEditingController();
  final _handlerName =
      'protocolBridge_${const Uuid().v4().replaceAll('-', '')}';
  late ProtocolCaptureLimits _limits;
  late ProtocolCaptureController _capture;
  InAppWebViewController? _webView;
  WebUri? _currentUrl;
  bool _started = false;
  bool _loading = false;
  bool _saving = false;
  bool _savedOrDiscarded = false;
  bool _confirmingDiscard = false;

  @override
  void initState() {
    super.initState();
    _limits = const ProtocolCaptureLimits();
    _capture = ProtocolCaptureController(limits: _limits);
    if (widget.initialUrl case final initial?) {
      _urlController.text = initial;
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _capture.dispose();
    super.dispose();
  }

  String _normalizedUrl() {
    var value = _urlController.text.trim();
    if (value.isNotEmpty &&
        !RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://').hasMatch(value)) {
      value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) return '';
    return uri.toString();
  }

  Future<void> _start() async {
    final url = _normalizedUrl();
    if (url.isEmpty) return;
    if (widget.savedLoginDomain != null) {
      await widget.webSessions.restoreCookies(url);
    }
    if (!mounted) return;
    setState(() {
      _started = true;
      _currentUrl = WebUri(url);
      _urlController.text = url;
    });
  }

  Future<void> _navigate() async {
    final url = _normalizedUrl();
    if (url.isEmpty) return;
    if (!_started) return _start();
    await _webView?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  InAppWebViewSettings _settings() => InAppWebViewSettings(
    allowFileAccess: false,
    allowContentAccess: false,
    allowFileAccessFromFileURLs: false,
    allowUniversalAccessFromFileURLs: false,
    useShouldInterceptFetchRequest: false,
    useShouldInterceptAjaxRequest: false,
    useShouldInterceptRequest: false,
    useShouldOverrideUrlLoading: true,
  );

  UnmodifiableListView<UserScript> _scripts() => UnmodifiableListView([
    UserScript(
      groupName: 'note_synapse_protocol_study',
      source: ProtocolCaptureUserScript.build(
        handlerName: _handlerName,
        limits: _limits,
      ),
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      forMainFrameOnly: false,
      contentWorld: ContentWorld.PAGE,
    ),
  ]);

  Future<void> _chooseLimits() async {
    var responseBytes = _limits.maxResponseBodyBytes;
    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          AppLocalizations.of(context)!.protocolStudyResponseBodyLimit,
        ),
        content: StatefulBuilder(
          builder: (context, setDialogState) => DropdownButtonFormField<int>(
            initialValue: responseBytes,
            items: const [
              DropdownMenuItem(value: 256 * 1024, child: Text('256 KB')),
              DropdownMenuItem(value: 1024 * 1024, child: Text('1 MB')),
              DropdownMenuItem(value: 5 * 1024 * 1024, child: Text('5 MB')),
            ],
            onChanged: (value) =>
                setDialogState(() => responseBytes = value ?? responseBytes),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, responseBytes),
            child: Text(AppLocalizations.of(context)!.save),
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    _capture.dispose();
    setState(() {
      _limits = ProtocolCaptureLimits(
        maxResponseBodyBytes: chosen,
        maxEventBytes: 128 * 1024,
        maxSessionBytes: chosen > 1024 * 1024
            ? 50 * 1024 * 1024
            : 20 * 1024 * 1024,
      );
      _capture = ProtocolCaptureController(limits: _limits);
    });
  }

  Future<void> _openNetwork() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProtocolNetworkScreen(
          controller: _capture,
          webSessions: widget.webSessions,
          savedLoginDomain: widget.savedLoginDomain,
        ),
      ),
    );
  }

  Future<void> _attachCookieObservation(
    String exchangeId, {
    required bool request,
  }) async {
    final exchange = _capture.exchanges
        .where((item) => item.id == exchangeId)
        .firstOrNull;
    if (exchange == null) return;
    final cookie = await widget.webSessions.liveCookieHeaderFor(exchange.url);
    if (!mounted || cookie.isEmpty) return;
    _capture.addTrustedHeader(
      exchangeId,
      request: request,
      name: request
          ? 'Cookie-Jar-Observed-Near-Request'
          : 'Cookie-Jar-Observed-After-Response',
      value: cookie,
    );
  }

  ProtocolFidelityReport _fidelity() {
    final sources = _capture.exchanges
        .map((exchange) => exchange.source)
        .toSet();
    return ProtocolFidelityReport(
      // Actual Android/iOS document-start behavior is asserted by the Phase 0
      // integration fixture; a live arbitrary page can only prove the probe
      // ran, not that it preceded every site script.
      documentStart: _capture.pageInstanceId == null
          ? ProtocolCaptureFidelity.untested
          : ProtocolCaptureFidelity.partial,
      fetch: sources.contains(ProtocolRequestSource.fetch)
          ? ProtocolCaptureFidelity.verified
          : ProtocolCaptureFidelity.partial,
      xhr: sources.contains(ProtocolRequestSource.xhr)
          ? ProtocolCaptureFidelity.verified
          : ProtocolCaptureFidelity.partial,
      forms: sources.contains(ProtocolRequestSource.form)
          ? ProtocolCaptureFidelity.verified
          : ProtocolCaptureFidelity.partial,
      redirects: _capture.exchanges.any((exchange) => exchange.redirected)
          ? ProtocolCaptureFidelity.verified
          : ProtocolCaptureFidelity.partial,
      binaryBodies: _limits.captureBinary
          ? ProtocolCaptureFidelity.partial
          : ProtocolCaptureFidelity.unavailable,
    );
  }

  Future<void> _save() async {
    final url = _currentUrl?.toString() ?? _normalizedUrl();
    if (url.isEmpty) return;
    setState(() => _saving = true);
    final now = DateTime.now();
    final host = Uri.tryParse(url)?.host ?? 'Website';
    final study = ProtocolStudy(
      id: const Uuid().v4().replaceAll('-', ''),
      title: 'Protocol study: $host',
      startUrl: url,
      createdAt: now,
      updatedAt: now,
      sessionProvenance: widget.savedLoginDomain == null
          ? ProtocolSessionProvenance.unknownSharedState
          : ProtocolSessionProvenance.savedLoginRestored,
      savedLoginDomain: widget.savedLoginDomain,
      limits: _limits,
      exchanges: List.unmodifiable(_capture.exchanges),
      interactions: List.unmodifiable(_capture.interactions),
      fidelity: _fidelity(),
    );
    try {
      await widget.workspace.save(study);
      if (!mounted) return;
      _savedOrDiscarded = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.protocolStudySaved),
        ),
      );
      Navigator.pop(context, study);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDiscard() async {
    if (_confirmingDiscard || _savedOrDiscarded) return;
    _confirmingDiscard = true;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.protocolStudyDiscardSession),
        content: Text(
          AppLocalizations.of(context)!.protocolStudyDiscardSessionConfirm,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              AppLocalizations.of(context)!.protocolStudyDiscardSession,
            ),
          ),
        ],
      ),
    );
    _confirmingDiscard = false;
    if (approved != true || !mounted) return;
    setState(() => _savedOrDiscarded = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopScope(
      canPop: !_started || _savedOrDiscarded,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmDiscard());
      },
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _navigate(),
            decoration: InputDecoration(
              hintText: l10n.protocolStudyUrlHint,
              border: InputBorder.none,
            ),
          ),
          actions: [
            if (!_started)
              IconButton(
                onPressed: _chooseLimits,
                icon: const Icon(Icons.tune),
                tooltip: l10n.filter,
              ),
            IconButton(
              onPressed: _navigate,
              icon: const Icon(Icons.arrow_forward),
              tooltip: l10n.protocolStudyStart,
            ),
            if (_started)
              IconButton(
                onPressed: () {
                  _capture.startNewExample();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        AppLocalizations.of(
                          context,
                        )!.protocolStudyExampleNumber(
                          _capture.currentExampleIndex,
                        ),
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.add_chart_outlined),
                tooltip: AppLocalizations.of(context)!.protocolStudyNewExample,
              ),
            if (_started)
              IconButton(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                tooltip: l10n.protocolStudySave,
              ),
          ],
        ),
        body: Column(
          children: [
            if (widget.savedLoginDomain == null)
              MaterialBanner(
                content: Text(l10n.protocolStudySharedState),
                actions: [
                  TextButton(
                    onPressed: ScaffoldMessenger.of(
                      context,
                    ).hideCurrentMaterialBanner,
                    child: Text(l10n.close),
                  ),
                ],
              ),
            Expanded(
              child: !_started
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.travel_explore, size: 64),
                            const SizedBox(height: 16),
                            Text(
                              l10n.protocolStudyFidelityWarning,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 20),
                            FilledButton.icon(
                              onPressed: _start,
                              icon: const Icon(Icons.play_arrow),
                              label: Text(l10n.protocolStudyStart),
                            ),
                          ],
                        ),
                      ),
                    )
                  : InAppWebView(
                      key: ValueKey(_handlerName),
                      initialUrlRequest: URLRequest(url: _currentUrl),
                      initialUserScripts: _scripts(),
                      initialSettings: _settings(),
                      onWebViewCreated: (controller) {
                        _webView = controller;
                        controller.addJavaScriptHandler(
                          handlerName: _handlerName,
                          callback: (arguments) {
                            if (arguments.length == 1) {
                              final raw = arguments.first;
                              final accepted = _capture.acceptEvent(raw);
                              if (accepted && raw is Map) {
                                final id = raw['exchangeId'];
                                final type = raw['type'];
                                if (id is String && type == 'request') {
                                  unawaited(
                                    _attachCookieObservation(id, request: true),
                                  );
                                } else if (id is String && type == 'response') {
                                  unawaited(
                                    _attachCookieObservation(
                                      id,
                                      request: false,
                                    ),
                                  );
                                }
                              }
                            }
                            return null;
                          },
                        );
                      },
                      shouldOverrideUrlLoading: (controller, action) async {
                        final scheme = action.request.url?.scheme.toLowerCase();
                        return const {
                              'http',
                              'https',
                              'about',
                              'data',
                            }.contains(scheme)
                            ? NavigationActionPolicy.ALLOW
                            : NavigationActionPolicy.CANCEL;
                      },
                      onLoadStart: (controller, url) {
                        if (!mounted) return;
                        setState(() {
                          _loading = true;
                          _currentUrl = url;
                          if (url != null) _urlController.text = url.toString();
                        });
                      },
                      onLoadStop: (controller, url) {
                        if (!mounted) return;
                        setState(() {
                          _loading = false;
                          _currentUrl = url;
                          if (url != null) _urlController.text = url.toString();
                        });
                      },
                    ),
            ),
            if (_started)
              AnimatedBuilder(
                animation: _capture,
                builder: (context, _) => SafeArea(
                  top: false,
                  child: ListTile(
                    leading: _loading
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check),
                    title: Text(l10n.protocolStudyNetwork),
                    subtitle: Text(
                      '${_capture.exchanges.length} ${l10n.protocolStudyRequests}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _openNetwork,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
