import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_revision.dart';
import '../models/note.dart';
import '../models/user_app.dart';
import '../providers/app_provider.dart';
import '../services/approval_service.dart';
import '../services/database_service.dart';
import '../services/global_library_service.dart';
import '../services/logger_service.dart';
import '../services/service_locator.dart';
import '../services/sql_query_service.dart';
import '../services/user_app_runtime_bridge.dart';
import '../services/web_session_service.dart';
import '../screens/settings/web_login_browser_screen.dart';
import '../screens/note_selection_dialog.dart';
import 'approval_dialog.dart';
import 'tag_selection_dialog.dart';

typedef UserAppOpenNote = Future<void> Function(Note note, bool replaceWindow);
typedef UserAppOpenConversations =
    Future<void> Function(List<Note> notes, bool immersiveMode);
typedef UserAppOpenAIActions = Future<void> Function(List<Note> notes);

/// Opens the note merge screen on [notes] and resolves to the merged note, or
/// `null` if the user backed out without merging.
///
/// `null` means precisely that - a host that cannot open the screen must throw
/// instead, so the plugin is not told the user declined.
typedef UserAppOpenMerge = Future<Note?> Function(List<Note> notes);

/// Shared WebView that hosts a User App.
///
/// Encapsulates the [UserAppRuntimeBridge] construction, [InAppWebView]
/// configuration, custom scheme routing (`synapse://`, `synapseuser://`,
/// `synapsetemp://`), bootstrap script injection, handler registration, and
/// the Android clipboard shim. Used by both the interactive playground
/// ([UserAppViewScreen]) and markdown-embedded apps ([EmbeddedUserAppView]).
///
/// Callers control size by wrapping this widget in a [SizedBox] or
/// [Expanded]; this widget does not constrain itself.
class UserAppWebView extends StatefulWidget {
  const UserAppWebView({
    super.key,
    required this.app,
    required this.revision,
    required this.selectedNotes,
    required this.sourceLabel,
    this.params = const {},
    this.onOpenNote,
    this.onOpenConversations,
    this.onOpenAIActions,
    this.onOpenMerge,
    this.onConsoleMessage,
    this.onLoadStart,
    this.onLoadStop,
    this.onReceivedError,
    this.onBridgeReady,
  });

  /// The user app being rendered.
  final UserApp app;

  /// The revision whose HTML will be loaded.
  final AppRevision revision;

  /// Notes exposed to the app via `window.Synapse.Notes`.
  final List<Note> selectedNotes;

  /// Arbitrary parameter map exposed to the app via `window.Synapse.Params`.
  final Map<String, dynamic> params;

  /// Shown to the user in approval dialogs; identifies the source of write
  /// requests (e.g. `"App: <name>"` for the playground or
  /// `"Embedded app: <name>"` for in-markdown embeds).
  final String sourceLabel;

  final UserAppOpenNote? onOpenNote;
  final UserAppOpenConversations? onOpenConversations;
  final UserAppOpenAIActions? onOpenAIActions;
  final UserAppOpenMerge? onOpenMerge;
  final void Function(InAppWebViewController, ConsoleMessage)? onConsoleMessage;
  final void Function(InAppWebViewController, WebUri?)? onLoadStart;
  final void Function(InAppWebViewController, WebUri?)? onLoadStop;
  final void Function(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceError error,
  )?
  onReceivedError;

  /// Invoked once the bridge is created so the caller can keep a reference
  /// (useful for approving writes for the session, etc.).
  final void Function(UserAppRuntimeBridge bridge)? onBridgeReady;

  @override
  State<UserAppWebView> createState() => _UserAppWebViewState();
}

class _UserAppWebViewState extends State<UserAppWebView> {
  late UserAppRuntimeBridge _bridge;

  /// False until the bridge behind the WebView about to be created has loaded
  /// the selected notes' sources, so its bootstrap script can carry them (see
  /// [UserAppRuntimeBridge.loadSelectedNoteSources]); reset when a new app or
  /// revision replaces the WebView.
  bool _bridgeReady = false;

  /// The provider this view is subscribed to for Space changes, kept so the
  /// listener can be removed in [dispose] without a `BuildContext`.
  AppProvider? _contextSource;
  int _bridgeGeneration = 0;

  @override
  void initState() {
    super.initState();
    _initBridge();
    // Activation lives in AppProvider, which notifies on every change; the
    // page only hears about it if something bridges the two. A background user
    // app keeps a live WebView, so the boot-time value alone would go stale.
    final provider = context.read<AppProvider>();
    _contextSource = provider..addListener(_publishContextIfChanged);
  }

  @override
  void dispose() {
    _contextSource?.removeListener(_publishContextIfChanged);
    _bridge.detach();
    super.dispose();
  }

  void _publishContextIfChanged() {
    unawaited(_bridge.republishContextIfChanged());
  }

  @override
  void didUpdateWidget(covariant UserAppWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final webViewReplaced =
        oldWidget.app.id != widget.app.id ||
        oldWidget.revision.revisionNumber != widget.revision.revisionNumber;
    if (webViewReplaced ||
        !identical(oldWidget.selectedNotes, widget.selectedNotes) ||
        !identical(oldWidget.params, widget.params)) {
      // Every bridge owns exactly one platform WebView/document lifetime.
      // Notes/Params are bootstrap-only too, so replacing them must replace
      // the WebView even when app id and revision number stay the same.
      _bridge.detach();
      _bridgeGeneration++;
      _bridgeReady = false;
      _initBridge();
    }
  }

  /// Builds the bridge, hands it to [UserAppWebView.onBridgeReady] right away
  /// and marks it ready once the selected notes' sources are loaded — at once
  /// when there are no notes, so the common case costs no extra frame. Once
  /// ready, a later bridge for the same WebView never hides it again; only
  /// [didUpdateWidget] resets the flag, when the WebView is replaced anyway.
  /// The load never throws, but `whenComplete` makes sure a failure could not
  /// leave the plugin blank either.
  void _initBridge() {
    final bridge = _buildBridge();
    _bridge = bridge;
    widget.onBridgeReady?.call(bridge);
    if (widget.selectedNotes.isEmpty) {
      _bridgeReady = true;
      return;
    }
    bridge.loadSelectedNoteSources().whenComplete(() {
      if (!mounted || !identical(_bridge, bridge)) return;
      if (!_bridgeReady) setState(() => _bridgeReady = true);
    });
  }

  UserAppRuntimeBridge _buildBridge() {
    return UserAppRuntimeBridge(
      app: widget.app,
      appProvider: context.read<AppProvider>(),
      revisionNumber: widget.revision.revisionNumber,
      isInteractive: true,
      selectedNotes: widget.selectedNotes,
      params: widget.params,
      onOpenNote: (note, replaceWindow) async {
        if (!mounted) return;
        await widget.onOpenNote?.call(note, replaceWindow);
      },
      onOpenConversations: (notes, immersiveMode) async {
        if (!mounted) return;
        await widget.onOpenConversations?.call(notes, immersiveMode);
      },
      onOpenAIActions: (notes) async {
        if (!mounted) return;
        await widget.onOpenAIActions?.call(notes);
      },
      // Left null when the host gave us no handler, so the bridge reports
      // 'not supported in this context' rather than a null that a plugin would
      // read as the user cancelling the merge. For the same reason an unmounted
      // view throws instead of returning null: the bridge turns that into a
      // success:false error, so a plugin can tell 'the host could not open the
      // screen' from 'the user backed out'.
      onOpenMerge: widget.onOpenMerge == null
          ? null
          : (notes) async {
              if (!mounted) {
                throw StateError('user app view is no longer mounted');
              }
              return widget.onOpenMerge!(notes);
            },
      onModificationRequest: (source, noteId, modification) async {
        if (!mounted) return false;

        String? title;
        String? snippet;
        try {
          final note = await DatabaseService().getNote(noteId);
          if (note != null) {
            title = note.title;
            final content = note.content;
            snippet = content.length > 200
                ? '${content.substring(0, 200)}...'
                : content;
          }
        } catch (e) {
          LoggerService.warning('Failed to fetch note details: $e');
        }

        if (!mounted) return false;

        final request = ApprovalRequest.noteModification(
          noteId: noteId,
          modification: modification,
          source: widget.sourceLabel,
          noteTitle: title,
          noteSnippet: snippet,
        );
        final result = await ApprovalDialog.showWithContext(context, request);

        if (result.approved) {
          if (result.approvedForSession) {
            source.approveSession();
          }
          return true;
        }
        return false;
      },
      onSqlWriteApprovalRequest: (source, sql, queryType) async {
        if (!mounted) return false;

        final request = ApprovalRequest.sqlWrite(
          sql: sql,
          queryType: queryType,
          queryTypeDescription: _describeSqlQueryType(queryType),
          source: widget.sourceLabel,
        );
        final result = await ApprovalDialog.showWithContext(context, request);

        if (result.approved) {
          if (result.approvedForSession) {
            source.approveSqlWritesForSession();
          }
          return true;
        }
        return false;
      },
      onDeletionApprovalRequest: (source, noteIds) async {
        if (!mounted) return false;

        final noteDetails = <Map<String, String>>[];
        try {
          final notes = await DatabaseService().getNotesByIds(noteIds);
          for (final note in notes) {
            final content = note.content;
            final snippet = content.length > 100
                ? '${content.substring(0, 100)}...'
                : content;
            noteDetails.add({
              'id': note.id,
              'title': note.title,
              'snippet': snippet,
            });
          }
        } catch (e) {
          LoggerService.warning('Failed to fetch note details: $e');
        }

        if (!mounted) return false;

        final request = ApprovalRequest.noteDeletion(
          noteIds: noteIds,
          source: widget.sourceLabel,
          noteDetails: noteDetails,
        );
        final result = await ApprovalDialog.showWithContext(context, request);

        if (result.approved) {
          if (result.approvedForSession) {
            source.approveDeletionsForSession();
          }
          return true;
        }
        return false;
      },
      onWebLoginRequest: (source, url) async {
        if (!mounted) return false;
        // A plugin asking for a login almost always means the one it had has
        // gone stale, so when a session already exists open the browser in
        // refresh mode: it clears the dead cookies first (otherwise the site
        // replays them and never shows its login form) and keeps the app's
        // existing grant.
        final domain = WebSessionService.domainKeyFor(url);
        final existing = domain.isEmpty
            ? null
            : await getIt<WebSessionService>().getSession(domain);
        if (!mounted) return false;
        // Open the in-app login browser; it captures + persists the session
        // and pops `true` once the user saves their login.
        final result = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => WebLoginBrowserScreen(
              initialUrl: url,
              refreshDomain: existing != null ? domain : null,
            ),
          ),
        );
        return result == true;
      },
      onSessionAccessApprovalRequest: (source, domain) async {
        if (!mounted) return false;
        final request = ApprovalRequest.sessionAccess(
          domain: domain,
          source: widget.sourceLabel,
        );
        final result = await ApprovalDialog.showWithContext(context, request);
        return result.approved;
      },
      onPickNotes: (source, options) async {
        if (!mounted) return null;
        final preselected =
            (options['preselectedIds'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
        final initialTag = options['initialTag'] as String?;
        // Reuse the app's rich note picker (tag filters, search, card previews,
        // multi/single select) instead of a bespoke sheet.
        final selected = await showDialog<List<Note>>(
          context: context,
          builder: (dialogContext) => NoteSelectionDialog(
            title: options['title'] as String?,
            singleSelection: options['multiSelect'] == false,
            initialSelectedNoteIds: preselected,
            initialTags: (initialTag != null && initialTag.isNotEmpty)
                ? [initialTag]
                : null,
            onNotesSelected: (notes) => Navigator.of(dialogContext).pop(notes),
          ),
        );
        if (selected == null) {
          return null; // cancelled
        }
        return [
          for (final note in selected) {'id': note.id, 'title': note.title},
        ];
      },
      onPickTags: (source, options) async {
        if (!mounted) return null;
        final preselected =
            (options['preselectedTags'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
        // Reuse the app's tag selection dialog (search, "Add from Filter",
        // multi-select) — returns the chosen tag names.
        final tags = await showDialog<List<String>>(
          context: context,
          builder: (_) => TagSelectionDialog(
            title: options['title'] as String?,
            initialSelectedTags: preselected,
            allowEmptySelection: false,
            // Picking existing tags to act on — don't let the user invent a new
            // tag that matches zero notes.
            allowCreateNew: false,
          ),
        );
        return tags; // null when cancelled
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_bridgeReady) return const SizedBox.shrink();
    final bridge = _bridge;
    final htmlData = widget.revision.appCode;

    return InAppWebView(
      key: ValueKey(
        '${widget.app.id}:${widget.revision.revisionNumber}:$_bridgeGeneration',
      ),
      initialData: InAppWebViewInitialData(
        data: htmlData,
        mimeType: 'text/html',
        encoding: 'utf8',
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        clearCache: true,
        cacheEnabled: true,
        supportZoom: true,
        builtInZoomControls: true,
        displayZoomControls: false,
        resourceCustomSchemes: const ['synapse', 'synapseuser', 'synapsetemp'],
      ),
      onLoadResourceWithCustomScheme: (controller, request) async {
        LoggerService.debug(
          'onLoadResourceWithCustomScheme: ${request.url} - ${request.url.path}',
        );
        final scheme = request.url.scheme.toLowerCase();
        if (scheme == 'synapse') {
          return await _handleSynapseScheme(request.url);
        } else if (scheme == 'synapseuser') {
          return await bridge.handleSynapseUserScheme(request.url);
        } else if (scheme == 'synapsetemp') {
          return await bridge.handleSynapseTempScheme(request.url);
        }
        return null;
      },
      shouldOverrideUrlLoading: (controller, request) async {
        final url = request.request.url;
        if (url == null) return NavigationActionPolicy.CANCEL;

        final scheme = url.scheme.toLowerCase();
        if (scheme == 'about' || scheme == 'data') {
          return NavigationActionPolicy.ALLOW;
        }

        if (scheme == 'http' || scheme == 'https') {
          launchUrl(url.uriValue);
        }
        return NavigationActionPolicy.CANCEL;
      },
      initialUserScripts: UnmodifiableListView<UserScript>([
        bridge.buildBootstrapScript(),
      ]),
      onWebViewCreated: (controller) {
        bridge.registerJavaScriptHandlers(controller);
      },
      onLoadStart: (controller, url) {
        bridge.pageDidStartLoading();
        widget.onLoadStart?.call(controller, url);
      },
      onLoadStop: (controller, url) {
        unawaited(bridge.pageDidFinishLoading());
        controller.evaluateJavascript(source: _clipboardShimScript);
        widget.onLoadStop?.call(controller, url);
      },
      onConsoleMessage: (controller, consoleMessage) {
        widget.onConsoleMessage?.call(controller, consoleMessage);
      },
      onReceivedError: (controller, request, error) {
        widget.onReceivedError?.call(controller, request, error);
      },
    );
  }

  Future<CustomSchemeResponse?> _handleSynapseScheme(WebUri url) async {
    final relativePath = resolveSynapseAssetRelativePath(
      url.uriValue,
      rawUrl: url.rawValue,
    );
    if (relativePath == null) {
      LoggerService.warning('Rejected invalid synapse asset URL: $url');
      return CustomSchemeResponse(
        contentType: 'text/plain',
        data: Uint8List.fromList(
          utf8.encode('/* Invalid synapse asset URL */'),
        ),
      );
    }

    final service = GlobalLibraryService();
    final customPath = await service.resolveLibraryPath(relativePath);

    if (customPath != null) {
      final file = File(customPath);
      if (await file.exists()) {
        final data = await file.readAsBytes();
        return CustomSchemeResponse(
          contentType: synapseAssetContentType(relativePath),
          data: data,
        );
      }
    }

    try {
      final data = await rootBundle.load('assets/scripts/$relativePath');
      return CustomSchemeResponse(
        contentType: synapseAssetContentType(relativePath),
        data: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } catch (_) {
      LoggerService.warning(
        'Failed to load asset: assets/scripts/$relativePath',
      );
      return CustomSchemeResponse(
        contentType: 'text/plain',
        data: Uint8List.fromList(
          utf8.encode('/* Asset not found: $relativePath */'),
        ),
      );
    }
  }
}

/// Resolves a `synapse://` URL to a path below `assets/scripts/`.
///
/// Legacy URLs store the filename in the host (`synapse://mermaid.min.js`).
/// Formula Studio also needs nested paths for local fonts, such as
/// `synapse://mathlive/fonts/KaTeX_Main-Regular.woff2`.
///
/// Pass [rawUrl] when it is available so encoded traversal segments can be
/// rejected before Dart's URI parser normalizes them.
String? resolveSynapseAssetRelativePath(Uri url, {String? rawUrl}) {
  if (url.scheme.toLowerCase() != 'synapse' ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty ||
      url.hasPort ||
      (rawUrl != null && _hasUnsafeRawSynapsePath(rawUrl))) {
    return null;
  }

  final segments = <String>[url.host, ...url.pathSegments];
  if (segments.any(
    (segment) =>
        segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.contains('/') ||
        segment.contains('\\') ||
        segment.contains('\u0000'),
  )) {
    return null;
  }
  return segments.join('/');
}

bool _hasUnsafeRawSynapsePath(String rawUrl) {
  final authorityStart = rawUrl.indexOf('://');
  if (authorityStart < 0) return true;

  var pathStart = -1;
  for (var index = authorityStart + 3; index < rawUrl.length; index++) {
    final character = rawUrl[index];
    if (character == '/' || character == '?' || character == '#') {
      if (character == '/') pathStart = index;
      break;
    }
  }
  if (pathStart == -1) return false;

  var pathEnd = rawUrl.length;
  for (final delimiter in ['?', '#']) {
    final index = rawUrl.indexOf(delimiter, pathStart);
    if (index >= 0 && index < pathEnd) pathEnd = index;
  }

  for (final rawSegment
      in rawUrl.substring(pathStart + 1, pathEnd).split('/')) {
    late final String segment;
    try {
      segment = Uri.decodeComponent(rawSegment);
    } on FormatException {
      return true;
    }
    if (segment == '.' ||
        segment == '..' ||
        segment.contains('/') ||
        segment.contains('\\') ||
        segment.contains('\u0000')) {
      return true;
    }
  }
  return false;
}

/// MIME type returned for a local User App dependency.
String synapseAssetContentType(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.js') || lower.endsWith('.mjs')) {
    return 'application/javascript';
  }
  if (lower.endsWith('.css')) return 'text/css';
  if (lower.endsWith('.woff2')) return 'font/woff2';
  if (lower.endsWith('.wasm')) return 'application/wasm';
  if (lower.endsWith('.json')) return 'application/json';
  return 'application/octet-stream';
}

String _describeSqlQueryType(SqlQueryType queryType) {
  switch (queryType) {
    case SqlQueryType.select:
    case SqlQueryType.pragma:
    case SqlQueryType.other:
      return 'SQL';
    default:
      return SqlQueryService.describeQueryType(queryType);
  }
}

const String _clipboardShimScript = '''
  if (!navigator.clipboard) {
    navigator.clipboard = {
      writeText: (msg) => {
        return window.flutter_inappwebview?.callHandler("copy-to-clipboard", msg);
      }
    };
  } else {
    navigator.clipboard.writeText = (msg) => {
      return window.flutter_inappwebview?.callHandler("copy-to-clipboard", msg);
    };
  }

  window.copyToClipboard = (text) => {
    return window.flutter_inappwebview?.callHandler("copy-to-clipboard", text);
  };

  if (typeof document !== 'undefined') {
    const originalExecCommand = document.execCommand;
    document.execCommand = function(command, showUI, value) {
      if (command === 'copy' && value) {
        return window.flutter_inappwebview?.callHandler("copy-to-clipboard", value);
      }
      return originalExecCommand.call(this, command, showUI, value);
    };
  }
''';
