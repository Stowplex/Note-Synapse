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
import '../services/sql_query_service.dart';
import '../services/user_app_runtime_bridge.dart';
import '../screens/settings/web_login_browser_screen.dart';
import '../screens/note_selection_dialog.dart';
import 'approval_dialog.dart';
import 'tag_selection_dialog.dart';

typedef UserAppOpenNote =
    Future<void> Function(Note note, bool replaceWindow);
typedef UserAppOpenConversations =
    Future<void> Function(List<Note> notes, bool immersiveMode);
typedef UserAppOpenAIActions = Future<void> Function(List<Note> notes);

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

  @override
  void initState() {
    super.initState();
    _bridge = _buildBridge();
    widget.onBridgeReady?.call(_bridge);
  }

  @override
  void didUpdateWidget(covariant UserAppWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app.id != widget.app.id ||
        oldWidget.revision.revisionNumber != widget.revision.revisionNumber ||
        !identical(oldWidget.selectedNotes, widget.selectedNotes) ||
        !identical(oldWidget.params, widget.params)) {
      _bridge = _buildBridge();
      widget.onBridgeReady?.call(_bridge);
    }
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
        // Open the in-app login browser; it captures + persists the session
        // and pops `true` once the user saves their login.
        final result = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => WebLoginBrowserScreen(initialUrl: url),
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
        final preselected = (options['preselectedIds'] as List?)
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
            initialTags:
                (initialTag != null && initialTag.isNotEmpty) ? [initialTag] : null,
            onNotesSelected: (notes) =>
                Navigator.of(dialogContext).pop(notes),
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
        final preselected = (options['preselectedTags'] as List?)
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
    final bridge = _bridge;
    final htmlData = widget.revision.appCode;

    return InAppWebView(
      key: ValueKey(
        '${widget.app.id}:${widget.revision.revisionNumber}',
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
        widget.onLoadStart?.call(controller, url);
      },
      onLoadStop: (controller, url) {
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
    final fileName = url.host;
    final service = GlobalLibraryService();
    final customPath = await service.resolveLibraryPath(fileName);

    if (customPath != null) {
      final file = File(customPath);
      if (await file.exists()) {
        final data = await file.readAsBytes();
        final contentType = fileName.endsWith('.css')
            ? 'text/css'
            : 'application/javascript';
        return CustomSchemeResponse(contentType: contentType, data: data);
      }
    }

    try {
      final data = await rootBundle.loadString('assets/scripts/$fileName');
      return CustomSchemeResponse(
        contentType: 'text/plain',
        data: Uint8List.fromList(utf8.encode(data)),
      );
    } catch (_) {
      LoggerService.warning(
        'Failed to load asset: assets/scripts/$fileName',
      );
      return CustomSchemeResponse(
        contentType: 'text/plain',
        data: Uint8List.fromList(
          utf8.encode('/* Asset not found: $fileName */'),
        ),
      );
    }
  }
}

String _describeSqlQueryType(SqlQueryType queryType) {
  switch (queryType) {
    case SqlQueryType.insert:
      return 'INSERT (add data)';
    case SqlQueryType.replace:
      return 'REPLACE (add or overwrite data)';
    case SqlQueryType.update:
      return 'UPDATE (modify data)';
    case SqlQueryType.delete:
      return 'DELETE (remove data)';
    case SqlQueryType.createTable:
      return 'CREATE TABLE';
    case SqlQueryType.createIndex:
      return 'CREATE INDEX';
    case SqlQueryType.createTrigger:
      return 'CREATE TRIGGER';
    case SqlQueryType.createView:
      return 'CREATE VIEW';
    case SqlQueryType.dropTable:
      return 'DROP TABLE';
    case SqlQueryType.dropIndex:
      return 'DROP INDEX';
    case SqlQueryType.dropTrigger:
      return 'DROP TRIGGER';
    case SqlQueryType.dropView:
      return 'DROP VIEW';
    case SqlQueryType.alterTable:
      return 'ALTER TABLE';
    case SqlQueryType.select:
    case SqlQueryType.pragma:
    case SqlQueryType.other:
      return 'SQL';
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
