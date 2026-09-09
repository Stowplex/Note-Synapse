import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Locale;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../models/note.dart';
import '../models/note_source.dart';
import '../models/user_app.dart';
import '../providers/app_provider.dart';
import '../services/ai_service.dart';
import '../services/database_service.dart';
import 'web_session_service.dart';
import 'app_domain_grant_service.dart';
import 'crypto_service.dart';
import 'plugin_task_service.dart';
import 'share_service.dart';
import '../services/logger_service.dart';
import '../services/user_app_service.dart';
import '../utils/file_type_utils.dart';
import '../utils/file_utils.dart';
import '../utils/synapse_temp_utils.dart';
import 'approval_service.dart';
import 'block_note_scope_service.dart';
import 'note_modification_service.dart';
import 'space_scope_service.dart';
import 'sql_query_service.dart';
import 'service_locator.dart';
import 'tts_service.dart';

typedef OpenNoteCallback = Future<void> Function(Note note, bool replaceWindow);
typedef OpenConversationsCallback =
    Future<void> Function(List<Note> notes, bool immersiveMode);
typedef OpenAIActionsCallback = Future<void> Function(List<Note> notes);

/// Asks the host to open the note merge screen on [notes]; resolves to the
/// merged note, or `null` if the user backed out without merging.
///
/// A host that cannot open the screen at all must throw rather than return
/// `null`, which the bridge would report to the plugin as a cancellation.
typedef OpenMergeCallback = Future<Note?> Function(List<Note> notes);
typedef ModificationRequestCallback =
    Future<bool> Function(
      UserAppRuntimeBridge source,
      String noteId,
      Map<String, dynamic> modification,
    );
typedef SqlWriteApprovalCallback =
    Future<bool> Function(
      UserAppRuntimeBridge source,
      String sql,
      SqlQueryType queryType,
    );
typedef DeletionApprovalCallback =
    Future<bool> Function(UserAppRuntimeBridge source, List<String> noteIds);

/// Asks the host to open the in-app web login browser at [url] so the user can
/// sign into a site; resolves `true` once a session was captured.
typedef WebLoginRequestCallback =
    Future<bool> Function(UserAppRuntimeBridge source, String url);

/// Asks the host to confirm the app may use the saved web-login session for
/// [domain]; resolves `true` if the user approves. Approval is persisted as a
/// grant so it is only prompted once per app+domain.
typedef SessionAccessApprovalCallback =
    Future<bool> Function(UserAppRuntimeBridge source, String domain);

/// Asks the host to present a native note picker with [options]; resolves to the
/// selected notes as `{id, title}` maps, or `null` if the user cancelled.
typedef PickNotesCallback =
    Future<List<Map<String, String>>?> Function(
      UserAppRuntimeBridge source,
      Map<String, dynamic> options,
    );

/// Asks the host to present a native tag picker with [options]; resolves to the
/// selected tag names, or `null` if the user cancelled.
typedef PickTagsCallback =
    Future<List<String>?> Function(
      UserAppRuntimeBridge source,
      Map<String, dynamic> options,
    );

/// An error whose message was written BY THE HOST for a plugin to display.
///
/// Only these are echoed verbatim into the `errors` array returned to plugin
/// JS. Arbitrary exceptions are redacted, because they can embed absolute
/// container paths or (from sqflite) a statement plus its bound arguments, i.e.
/// note content.
class PluginFacingException implements Exception {
  PluginFacingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Shared runtime bridge that wires the Synapse JavaScript API into a WebView.
///
/// This bridge is used by both the interactive user app playground and the
/// headless AI tool runtime to guarantee identical JavaScript capabilities.
class UserAppRuntimeBridge {
  UserAppRuntimeBridge({
    required this.app,
    required this.appProvider,
    required this.revisionNumber,
    required this.isInteractive,
    List<Note>? selectedNotes,
    Map<String, List<NoteSource>>? selectedNoteSources,
    Map<String, dynamic>? params,
    this.onOpenNote,
    this.onOpenConversations,
    this.onOpenAIActions,
    this.onOpenMerge,
    this.onModificationRequest,
    this.onSqlWriteApprovalRequest,
    this.onDeletionApprovalRequest,
    this.onWebLoginRequest,
    this.onSessionAccessApprovalRequest,
    this.onPickNotes,
    this.onPickTags,
  }) : _selectedNotes = selectedNotes ?? const [],
       _selectedNoteSources = {...?selectedNoteSources},
       _params = params ?? const {};

  final UserApp app;
  final AppProvider appProvider;
  final int revisionNumber;
  final bool isInteractive;
  final List<Note> _selectedNotes;

  /// Where each selected note was clipped from, keyed by note id (the
  /// transient id for a block note), for the `sources` field of
  /// `Synapse.Notes`. Filled by [loadSelectedNoteSources] (or handed in by a
  /// caller that already has the lists); a note without an entry gets `[]`.
  final Map<String, List<NoteSource>> _selectedNoteSources;
  final Map<String, dynamic> _params;
  final OpenNoteCallback? onOpenNote;
  final OpenConversationsCallback? onOpenConversations;
  final OpenAIActionsCallback? onOpenAIActions;
  final OpenMergeCallback? onOpenMerge;
  final ModificationRequestCallback? onModificationRequest;
  final SqlWriteApprovalCallback? onSqlWriteApprovalRequest;
  final DeletionApprovalCallback? onDeletionApprovalRequest;
  final WebLoginRequestCallback? onWebLoginRequest;
  final SessionAccessApprovalCallback? onSessionAccessApprovalRequest;
  final PickNotesCallback? onPickNotes;
  final PickTagsCallback? onPickTags;

  bool _sessionApprovedModifications = false;
  bool _sessionApprovedSqlWrites = false;
  bool _sessionApprovedDeletions = false;

  /// The controller of the WebView this bridge is attached to, captured in
  /// [registerJavaScriptHandlers]. Null for a bridge that was built but never
  /// attached (a bootstrap-script-only unit test), which is why
  /// [notifySpaceChanged] is a no-op rather than an error in that state.
  InAppWebViewController? _controller;

  void approveSession() {
    _sessionApprovedModifications = true;
  }

  void approveSqlWritesForSession() {
    _sessionApprovedSqlWrites = true;
    LoggerService.debug(
      '[UserAppRuntimeBridge] SQL write operations approved for session',
    );
  }

  void approveDeletionsForSession() {
    _sessionApprovedDeletions = true;
    LoggerService.debug(
      '[UserAppRuntimeBridge] Note deletions approved for session',
    );
  }

  DatabaseService get _databaseService => getIt<DatabaseService>();

  /// Block scopes are optional: headless hosts (AI tools) and tests may never
  /// register the service, in which case there are simply no block scopes and
  /// every note id is an ordinary one.
  BlockNoteScopeService? get _blockScopes =>
      getIt.isRegistered<BlockNoteScopeService>()
      ? getIt<BlockNoteScopeService>()
      : null;

  BlockNoteScope? _blockScopeFor(String noteId) => _blockScopes?.lookup(noteId);
  SqlQueryService get _sqlQueryService => getIt<SqlQueryService>();
  TtsService get _ttsService => getIt<TtsService>();
  WebSessionService get _webSessionService => getIt<WebSessionService>();
  AppDomainGrantService get _appDomainGrantService =>
      getIt<AppDomainGrantService>();
  static final HttpClient _proxyHttpClient = HttpClient()
    ..autoUncompress = true;

  /// Loads the sources of every selected note into the map
  /// [buildBootstrapScript] reads, so `Synapse.Notes[i].sources` is populated.
  /// Await it before the bootstrap script is built. A transient block note has
  /// no row of its own and inherits its parent's sources, as it does title,
  /// tags and attachments; the entry is keyed by the transient id its
  /// `Synapse.Notes` entry uses. Never throws (see
  /// [AppProvider.getNoteSources]).
  Future<void> loadSelectedNoteSources() async {
    // One round trip for the whole selection: the plugin view waits on this.
    final loaded = await Future.wait(
      _selectedNotes.map(
        (note) => appProvider.getNoteSources(_realNoteId(note.id)),
      ),
    );
    for (var i = 0; i < _selectedNotes.length; i++) {
      _selectedNoteSources[_selectedNotes[i].id] = loaded[i];
    }
  }

  /// Creates the bootstrap user script that initialises the Synapse namespace.
  UserScript buildBootstrapScript() {
    final notesJson = _buildSelectedNotesJson();
    final paramsJson = _buildParamsJson();
    final spaceJson = buildSpaceJson();
    final toolEnvFlag = isInteractive ? 'true' : 'false';

    final script =
        '''
        const originalConsoleLog = console.log;
        const originalConsoleError = console.error;
        const originalConsoleWarn = console.warn;

        console.log = function(...args) {
          const msg = args.map((arg) => {
            if (typeof arg === 'string') return arg;
            try {
              return JSON.stringify(arg, null, 2);
            } catch (_) {
              return String(arg);
            }
          }).join('\\n');
          originalConsoleLog(msg);
          window.flutter_inappwebview.callHandler('log', msg, 'LOG');
        };

        console.error = function(...args) {
          const msg = args.map((arg) => {
            if (typeof arg === 'string') return arg;
            try {
              return JSON.stringify(arg, null, 2);
            } catch (_) {
              return String(arg);
            }
          }).join('\\n');
          originalConsoleError(msg);
          window.flutter_inappwebview.callHandler('log', msg, 'ERROR');
        };

        console.warn = function(...args) {
          const msg = args.map((arg) => {
            if (typeof arg === 'string') return arg;
            try {
              return JSON.stringify(arg, null, 2);
            } catch (_) {
              return String(arg);
            }
          }).join('\\n');
          originalConsoleWarn(msg);
          window.flutter_inappwebview.callHandler('log', msg, 'WARN');
        };

        window.Synapse = {
          runQuery: async (sql) => {
            const result = await window.flutter_inappwebview.callHandler('runQuery', sql);
            return result;
          },
          storeAppState: async (state) => {
            const result = await window.flutter_inappwebview.callHandler('storeAppState', state ?? {});
            return result;
          },
          loadAppState: async () => {
            const result = await window.flutter_inappwebview.callHandler('loadAppState');
            return result;
          },
          chatAI: async (prompt, options = {}) => {
            const result = await window.flutter_inappwebview.callHandler('chatAI', prompt, options);
            return result;
          },
          proxyFetch: async (url, options = {}) => {
            const o =
              (options && typeof options === 'object' && !Array.isArray(options))
                ? options : {};
            const explicitKeys = ['method', 'body', 'json', 'headers',
              'bodyBinary', 'multipart', 'session', 'followRedirects', 'responseMode'];
            const hasExplicitOptions = explicitKeys.some(
              (k) => Object.prototype.hasOwnProperty.call(o, k));

            let headers = {};
            if (hasExplicitOptions) {
              if (o.headers && typeof o.headers === 'object') {
                headers = o.headers;
              }
            } else {
              // Legacy: a bare options object with none of the known keys is
              // treated as the headers map.
              headers = o;
            }

            const payload = {
              url,
              method: hasExplicitOptions && o.method ? o.method : 'GET',
              headers,
              body: hasExplicitOptions ? o.body ?? null : null,
              json: hasExplicitOptions ? o.json ?? null : null,
              bodyBinary: hasExplicitOptions ? o.bodyBinary ?? null : null,
              multipart: hasExplicitOptions ? o.multipart ?? null : null,
              session: hasExplicitOptions ? o.session === true : false,
              // When attaching the user's session cookies, do NOT auto-follow
              // redirects by default: a cross-host 3xx would otherwise carry the
              // cookies onward, and surfacing the 3xx also lets the plugin detect
              // an expired session redirecting to a login page. Callers can still
              // opt back in with followRedirects: true.
              followRedirects: hasExplicitOptions
                ? (Object.prototype.hasOwnProperty.call(o, 'followRedirects')
                    ? o.followRedirects !== false
                    : o.session !== true)
                : true,
              responseMode: hasExplicitOptions && typeof o.responseMode === 'string'
                ? o.responseMode : 'auto',
            };

            const result = await window.flutter_inappwebview.callHandler('proxyFetch', payload);
            return result;
          },
          fetchWebPage: async (url) => {
            const result = await window.flutter_inappwebview.callHandler('fetchWebPage', url);
            return result;
          },
          originFetch: async (url, options = {}) => {
            const opts = (options && typeof options === 'object' && !Array.isArray(options)) ? options : {};
            const payload = {
              url,
              origin: typeof opts.origin === 'string' ? opts.origin : null,
              method: typeof opts.method === 'string' ? opts.method : 'GET',
              headers: (opts.headers && typeof opts.headers === 'object') ? opts.headers : {},
              responseMode: typeof opts.responseMode === 'string' ? opts.responseMode : 'tempFile',
            };
            const result = await window.flutter_inappwebview.callHandler('originFetch', payload);
            return result;
          },
          downloadFile: async (url, options = {}) => {
            const opts = (options && typeof options === 'object' && !Array.isArray(options)) ? options : {};
            const payload = {
              url,
              headers: (opts.headers && typeof opts.headers === 'object') ? opts.headers : {},
            };
            return await window.flutter_inappwebview.callHandler('downloadFile', payload);
          },
          readAttachment: async (attachmentPath) => {
            const result = await window.flutter_inappwebview.callHandler('readAttachment', attachmentPath);
            return result;
          },
          saveTemp: async (data, mimeType) => {
            const result = await window.flutter_inappwebview.callHandler('saveTemp', data ?? {}, mimeType ?? '');
            return result;
          },
          saveNotes: async (notes) => {
            const result = await window.flutter_inappwebview.callHandler('saveNotes', notes ?? []);
            return result;
          },
          deleteNotes: async (noteIds) => {
            const result = await window.flutter_inappwebview.callHandler('deleteNotes', noteIds ?? []);
            return result;
          },
          openNote: async (noteId, replaceWindow = false) => {
            const result = await window.flutter_inappwebview.callHandler('openNote', noteId, replaceWindow === true);
            return result;
          },
          updateNotes: async (notes) => {
             const result = await window.flutter_inappwebview.callHandler('updateNotes', notes ?? []);
             return result;
          },
          openConversations: async (notes = [], immersiveMode = false) => {
            const result = await window.flutter_inappwebview.callHandler('openConversations', notes ?? [], immersiveMode === true);
            return result;
          },
          openAIActions: async (notes = []) => {
            const result = await window.flutter_inappwebview.callHandler('openAIActions', notes ?? []);
            return result;
          },
          openMerge: async (notes = []) => {
            const result = await window.flutter_inappwebview.callHandler('openMerge', notes ?? []);
            return result;
          },
          tts: {
            speak: async (text, options = {}) => {
              const result = await window.flutter_inappwebview.callHandler('ttsSpeak', text ?? '', options ?? {});
              return result;
            },
            stop: async () => {
              const result = await window.flutter_inappwebview.callHandler('ttsStop');
              return result;
            },
            getLanguages: async () => {
              const result = await window.flutter_inappwebview.callHandler('ttsGetLanguages');
              return result;
            },
          },
          session: {
            requestLogin: async (options = {}) => {
              const url = (options && typeof options === 'object' && !Array.isArray(options))
                ? (options.url || '') : (typeof options === 'string' ? options : '');
              return await window.flutter_inappwebview.callHandler('sessionRequestLogin', url);
            },
            status: async (domain) => {
              return await window.flutter_inappwebview.callHandler('sessionStatus', domain ?? '');
            },
            getCookies: async (domain) => {
              return await window.flutter_inappwebview.callHandler('sessionGetCookies', domain ?? '');
            },
          },
          crypto: {
            digest: async (algorithm, data) => {
              return await window.flutter_inappwebview.callHandler('cryptoDigest', algorithm ?? '', data ?? {});
            },
          },
          exportNotes: async (noteIds, options = {}) => {
            return await window.flutter_inappwebview.callHandler('exportNotes', noteIds ?? [], options ?? {});
          },
          pickNotes: async (options = {}) => {
            return await window.flutter_inappwebview.callHandler('pickNotes', options ?? {});
          },
          pickTags: async (options = {}) => {
            return await window.flutter_inappwebview.callHandler('pickTags', options ?? {});
          },
          tasks: {
            schedule: async (options = {}) => {
              return await window.flutter_inappwebview.callHandler('tasksSchedule', options ?? {});
            },
            cancel: async (taskId) => {
              return await window.flutter_inappwebview.callHandler('tasksCancel', taskId ?? '');
            },
            list: async () => {
              return await window.flutter_inappwebview.callHandler('tasksList');
            },
          },
          Notes: $notesJson,
          Params: $paramsJson,
          space: $spaceJson,
        };

        if (!window.Synapse.tool) {
          window.Synapse.tool = {};
        }
        if (!window.Synapse.tool.registered) {
          window.Synapse.tool.registered = {};
        }
        window.Synapse.tool.env = { isInteractive: $toolEnvFlag };
        window.Synapse.tool.invoke = async (toolName, params = {}) => {
          const fn = window.Synapse.tool.registered?.[toolName];
          if (typeof fn !== 'function') {
            throw new Error('Tool not found: ' + toolName);
          }
          const result = fn(params) ?? null;
          if (result && typeof result.then === 'function') {
            return await result;
          }
          return result;
        };
      ''';
    return UserScript(
      source: script,
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    );
  }

  /// Name of the DOM event fired at `window` when the active Space changes.
  static const String spaceChangedEvent = 'synapse:spacechanged';

  /// `window.Synapse.space` as a JavaScript literal: `{id, name, tags}` for the
  /// active Space, or `null` when none is active.
  ///
  /// Read from [SpaceScopeService], not from `appProvider`: the headless AI
  /// tool runtime builds a bridge with no widget tree behind it, and M5 put
  /// `activeSpaceName` on the service beside `activeSpaceId` and `stampTags`
  /// exactly so a `BuildContext`-free caller can name the Space.
  ///
  /// **Always [jsonEncode]d, never interpolated field by field.** A Space name
  /// is arbitrary user text: a name containing `"`, `\` or a newline pasted
  /// straight into the bootstrap source would end the JavaScript string early
  /// and take the *whole* `window.Synapse` object down with it — every API, not
  /// just this one. Encoding is the only thing standing between a Space called
  /// `He said "no"` and a dead plugin runtime.
  String buildSpaceJson() {
    final scope = SpaceScopeService.shared();
    // `isActive` also rejects an id resolved from prefs whose tags have not
    // been pushed in yet, which would otherwise publish a Space with an empty
    // `tags` array that a plugin would read as "scoped to nothing".
    if (!scope.isActive) return 'null';
    return jsonEncode({
      'id': scope.activeSpaceId,
      'name': scope.activeSpaceName,
      'tags': scope.stampTags,
    });
  }

  /// The script that republishes the Space onto an already-loaded page.
  ///
  /// Both halves matter: `window.Synapse.space` is updated so an app reading it
  /// later sees the new value, *and* [spaceChangedEvent] fires so an app that
  /// is already running can react. The detail is the same object, `null` on
  /// leave.
  String buildSpaceChangedScript() {
    final spaceJson = buildSpaceJson();
    return '''
      (function () {
        var space = $spaceJson;
        if (window.Synapse) { window.Synapse.space = space; }
        window.dispatchEvent(
          new CustomEvent('$spaceChangedEvent', { detail: space })
        );
      })();
    ''';
  }

  /// Tells the live page that the active Space changed.
  ///
  /// The boot-time value in [buildBootstrapScript] is not enough on its own:
  /// a background user app keeps a **live WebView** (its route is covered, not
  /// popped), so an app running while the user switches Spaces would otherwise
  /// go on scoping its queries to a Space the user has left.
  Future<void> notifySpaceChanged() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(source: buildSpaceChangedScript());
    } catch (e) {
      // A WebView disposed between the space change and this call throws; the
      // page is gone, so there is nothing to tell and nothing to recover.
      LoggerService.warning(
        '[UserAppRuntimeBridge] Could not dispatch $spaceChangedEvent: $e',
      );
    }
  }

  /// Registers all JavaScript handlers required by the Synapse runtime.
  void registerJavaScriptHandlers(InAppWebViewController controller) {
    _controller = controller;
    controller.addJavaScriptHandler(
      handlerName: 'runQuery',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final requestedSql = args.first as String;
          LoggerService.debug(
            '[Synapse.runQuery] Called with SQL: $requestedSql',
          );

          // Detect query type using SqlQueryService
          final queryType = _sqlQueryService.getQueryType(requestedSql);
          final isReadOnly = _sqlQueryService.isReadOnlyQuery(requestedSql);

          // A transient block-note id has no database row, so a plugin that
          // re-reads its note with SQL before writing (good practice, and what
          // Table Studio does) would otherwise get zero rows and abort. Serve
          // those reads from the parent row with the block's own values patched
          // in, so a block scope behaves like a note here too.
          final scopedIds = _blockScopeIdsIn(requestedSql);
          if (scopedIds.isNotEmpty && !isReadOnly) {
            return {
              'success': false,
              'error':
                  'This note id refers to a selected block, which has no '
                  'database row, so it cannot be written with SQL. Use '
                  'Synapse.updateNotes with this id instead - the host applies '
                  'the change to the right part of the parent note.',
            };
          }
          final sql = _rewriteBlockScopeIds(requestedSql, scopedIds);

          LoggerService.debug(
            '[Synapse.runQuery] Query type: ${_sqlQueryService.getQueryTypeDescription(queryType)}, read-only: $isReadOnly',
          );

          // If it's a write operation, check for approval
          if (!isReadOnly) {
            if (!_sessionApprovedSqlWrites) {
              if (onSqlWriteApprovalRequest != null) {
                final approved = await onSqlWriteApprovalRequest!(
                  this,
                  sql,
                  queryType,
                );
                if (!approved) {
                  return {
                    'success': false,
                    'error': 'User denied the SQL write operation.',
                  };
                }
                LoggerService.debug(
                  '[Synapse.runQuery] Write operation approved by user',
                );
              } else {
                return {
                  'success': false,
                  'error':
                      'Write operations require user approval. This context does not support write operations.',
                };
              }
            }
          }

          // Execute the query
          final result = await _sqlQueryService.executeQuery(
            sql,
            requireApprovalForWrites: false, // Already checked above
            allowWriteOperations: true,
          );

          final duration = DateTime.now().difference(startTime);

          if (result.success) {
            LoggerService.debug(
              '[Synapse.runQuery] Success - Returned ${result.data?.length ?? 0} rows in ${duration.inMilliseconds}ms',
            );
            return {
              'success': true,
              'data': _patchBlockScopeRows(result.data ?? [], scopedIds),
              if (result.truncated) 'truncated': true,
              if (result.truncated && result.totalRows != null)
                'totalRows': result.totalRows,
            };
          } else {
            LoggerService.error('[Synapse.runQuery] Error: ${result.error}');
            return {'success': false, 'error': result.error};
          }
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.runQuery] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'storeAppState',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final state =
              (args.isNotEmpty ? args.first : <String, dynamic>{})
                  as Map<String, dynamic>;
          LoggerService.debug(
            '[Synapse.storeAppState] Called with state keys: ${state.keys.toList()}',
          );
          await appProvider.saveAppState(app.id, state);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.storeAppState] Success - State saved in ${duration.inMilliseconds}ms',
          );
          return {'success': true};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.storeAppState] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'loadAppState',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          LoggerService.debug(
            '[Synapse.loadAppState] Called for app: ${app.id}',
          );
          final state = await getIt<UserAppService>().getAppState(app.id);
          final duration = DateTime.now().difference(startTime);
          if (state != null) {
            LoggerService.debug(
              '[Synapse.loadAppState] Success - State loaded with keys: ${state.keys.toList()} in ${duration.inMilliseconds}ms',
            );
          } else {
            LoggerService.debug(
              '[Synapse.loadAppState] Success - No state found in ${duration.inMilliseconds}ms',
            );
          }
          return {'success': true, 'data': state};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.loadAppState] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    // SECURITY / TRUST BOUNDARY:
    // proxyFetch intentionally allows user apps to make arbitrary network
    // requests (including to localhost / private IPs). This is safe under the
    // current "VS Code extension" trust model: user apps are authored by the
    // user or generated from the user's own prompts, and there is no
    // third-party app marketplace or untrusted distribution channel.
    //
    // Revisit this assumption (e.g. add an allowlist / private-IP block and
    // per-app capability grants) BEFORE either:
    //   1. shipping a third-party / community app marketplace, or
    //   2. allowing apps to be generated from untrusted ingested content
    //      (clipped web pages, shared notes) where prompt injection could
    //      author an exfiltrating app.
    // At that point proxyFetch + chatAI become a data-exfiltration path.
    controller.addJavaScriptHandler(
      handlerName: 'proxyFetch',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          if (args.isEmpty || args.first == null || args.first is! Map) {
            throw ArgumentError('Request options are required');
          }

          final rawOptions = Map<String, dynamic>.from(args.first as Map);
          final urlRaw = (rawOptions['url'] as String?)?.trim() ?? '';
          if (urlRaw.isEmpty) {
            throw ArgumentError('URL is required');
          }

          final uri = Uri.parse(urlRaw);
          final method =
              (rawOptions['method'] as String?)?.toUpperCase() ?? 'GET';

          final headers = <String, String>{};
          final rawHeaders = rawOptions['headers'];
          if (rawHeaders is Map) {
            rawHeaders.forEach((key, value) {
              if (key == null || value == null) {
                return;
              }
              final keyStr = key.toString().trim();
              if (keyStr.isEmpty) {
                return;
              }
              headers[keyStr] = value.toString();
            });
          }

          // Attach the user's saved login cookies when requested. This is
          // gated on a per-app grant for the URL's domain; cookie *values*
          // never cross into JS.
          if (rawOptions['session'] == true) {
            final permission = await _applySessionCookies(urlRaw, headers);
            if (permission != null) {
              return permission; // permission_required / permission_denied
            }
          }

          // Body precedence: multipart > bodyBinary > json > body. multipart
          // and bodyBinary produce raw bytes; json/body produce a string.
          List<int>? bodyBytes;
          final multipart = rawOptions['multipart'];
          final bodyBinary = rawOptions['bodyBinary'];
          final jsonBody = rawOptions['json'];
          if (multipart is List) {
            final built = await _buildMultipartBody(multipart);
            bodyBytes = built.bytes;
            headers[HttpHeaders.contentTypeHeader] = built.contentType;
          } else if (bodyBinary != null) {
            bodyBytes = base64Decode(bodyBinary.toString());
            if (!headers.keys.any(
              (k) => k.toLowerCase() == HttpHeaders.contentTypeHeader,
            )) {
              headers[HttpHeaders.contentTypeHeader] =
                  'application/octet-stream';
            }
          } else if (jsonBody != null) {
            try {
              bodyBytes = utf8.encode(jsonEncode(jsonBody));
              if (!headers.keys.any(
                (k) => k.toLowerCase() == HttpHeaders.contentTypeHeader,
              )) {
                headers[HttpHeaders.contentTypeHeader] =
                    'application/json; charset=utf-8';
              }
            } catch (e) {
              throw ArgumentError('Failed to encode JSON body: $e');
            }
          } else if (rawOptions['body'] != null) {
            bodyBytes = utf8.encode(rawOptions['body'].toString());
            if (!headers.keys.any(
              (k) => k.toLowerCase() == HttpHeaders.contentTypeHeader,
            )) {
              headers[HttpHeaders.contentTypeHeader] =
                  'text/plain; charset=utf-8';
            }
          }

          LoggerService.debug(
            '[Synapse.proxyFetch] $method $urlRaw with headers: ${headers.keys.toList()}',
          );

          final request = await _proxyHttpClient.openUrl(method, uri);
          // followRedirects defaults to true; when false a 3xx is returned as-is
          // so the caller can inspect the Location (auth-expiry detection).
          request.followRedirects = rawOptions['followRedirects'] != false;
          headers.forEach((key, value) {
            try {
              request.headers.set(key, value);
            } catch (e) {
              LoggerService.warning(
                '[Synapse.proxyFetch] Failed to set header "$key": $e',
              );
            }
          });

          if (bodyBytes != null && method != 'GET' && method != 'HEAD') {
            request.add(bodyBytes);
          }

          final response = await request.close();

          // Roll the saved login forward with whatever cookies the site just
          // rotated. Without this the stored session is a frozen snapshot that
          // only decays, even though every authenticated request is handing us
          // a fresh one. Confined to the request's own registrable domain so a
          // cross-domain redirect can never write into another site's login.
          if (rawOptions['session'] == true) {
            final setCookies =
                response.headers[HttpHeaders.setCookieHeader] ?? const [];
            if (setCookies.isNotEmpty) {
              final effectiveUrl = response.redirects.isEmpty
                  ? urlRaw
                  : uri.resolveUri(response.redirects.last.location).toString();
              if (WebSessionService.domainKeyFor(effectiveUrl) ==
                  WebSessionService.domainKeyFor(urlRaw)) {
                await _webSessionService.mergeSetCookieHeaders(
                  effectiveUrl,
                  setCookies,
                );
              }
            }
          }

          final bytesBuilder = BytesBuilder(copy: false);
          await for (final chunk in response) {
            bytesBuilder.add(chunk);
          }
          final bytes = bytesBuilder.takeBytes();

          final mime =
              response.headers.value(HttpHeaders.contentTypeHeader) ??
              'application/octet-stream';
          final normalizedMime = mime.split(';').first.trim().isNotEmpty
              ? mime.split(';').first.trim()
              : 'application/octet-stream';

          // Expose response headers generically, but never leak credential
          // headers into JS — Set-Cookie carries rotated session tokens and
          // must stay Dart-side to preserve the cookie-isolation model.
          const sensitiveResponseHeaders = {'set-cookie', 'set-cookie2'};
          final responseHeaders = <String, String>{};
          response.headers.forEach((name, values) {
            if (sensitiveResponseHeaders.contains(name.toLowerCase())) {
              return;
            }
            responseHeaders[name] = values.join(', ');
          });
          String? redirectedTo;
          if (response.redirects.isNotEmpty) {
            redirectedTo = response.redirects.last.location.toString();
          } else if (response.isRedirect) {
            redirectedTo = response.headers.value(HttpHeaders.locationHeader);
          }

          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.proxyFetch] Success (${response.statusCode}) in ${duration.inMilliseconds}ms',
          );

          final result = <String, dynamic>{
            'status': 'success',
            'statusCode': response.statusCode,
            'headers': responseHeaders,
            if (redirectedTo != null) 'redirectedTo': redirectedTo,
          };

          final responseMode =
              (rawOptions['responseMode'] as String?) ?? 'auto';
          if (responseMode == 'tempFile') {
            final saved = await SynapseTempUtils.saveTempData(
              mimeType: normalizedMime,
              base64Data: base64Encode(bytes),
            );
            result['uri'] = saved.uri;
            result['mime'] = normalizedMime;
          } else {
            final asText =
                responseMode == 'text' ||
                (responseMode == 'auto' && _isTextMime(normalizedMime));
            final asBinary = responseMode == 'binary';
            final data = (asText && !asBinary)
                ? utf8.decode(bytes, allowMalformed: true)
                : base64Encode(bytes);
            result['content'] = {'mime': normalizedMime, 'data': data};
          }
          return result;
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.proxyFetch] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'status': 'error', 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'chatAI',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final prompt = args.first as String;
          final options = args.length > 1
              ? args[1] as Map<String, dynamic>?
              : null;
          LoggerService.debug(
            '[Synapse.chatAI] Called with prompt: ${prompt.length > 100 ? '${prompt.substring(0, 100)}...' : prompt}',
          );
          LoggerService.debug(
            '[Synapse.chatAI] Raw options received: $options',
          );

          final validated = _validateChatOptions(options ?? const {});
          final attachments = await _processMixedAttachments(
            validated.attachments,
          );

          // Extract new options for model hint and response type
          final modelHintRaw = options?['model_hint'];
          final List<String>? modelHint = modelHintRaw is List
              ? modelHintRaw.map((e) => e.toString()).toList()
              : null;
          final responseType = options?['response_type'] as String? ?? 'string';
          final isMultiPart = responseType == 'multi_part';
          final voiceRaw = options?['voice'];
          final String? voice = voiceRaw is String ? voiceRaw : null;

          if (isMultiPart) {
            LoggerService.debug(
              '[Synapse.chatAI] Using multi-part response mode',
            );
            final response = await getIt<AIService>().chatAIMultiPart(
              prompt,
              temperature: validated.temperature,
              topK: validated.topK,
              topP: validated.topP,
              attachedFiles: attachments,
              modelHint: modelHint,
              voice: voice,
            );

            final duration = DateTime.now().difference(startTime);
            LoggerService.debug(
              '[Synapse.chatAI] Multi-part success - ${response.length} parts in ${duration.inMilliseconds}ms',
            );
            return {'success': true, 'response': response};
          } else {
            final response = await getIt<AIService>().chatAI(
              prompt,
              temperature: validated.temperature,
              topK: validated.topK,
              topP: validated.topP,
              attachedFiles: attachments,
              modelHint: modelHint,
              voice: voice,
            );

            final duration = DateTime.now().difference(startTime);
            LoggerService.debug(
              '[Synapse.chatAI] Success - Response length: ${response.length} in ${duration.inMilliseconds}ms',
            );
            return {'success': true, 'response': response};
          }
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.chatAI] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'ttsSpeak',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final text = args.isNotEmpty ? args.first as String : '';
          if (text.trim().isEmpty) {
            return {'success': false, 'error': 'No text provided to speak.'};
          }
          final options = args.length > 1
              ? args[1] as Map<String, dynamic>?
              : null;
          final language = options?['language'] as String?;
          final rate = (options?['rate'] as num?)?.toDouble();
          final pitch = (options?['pitch'] as num?)?.toDouble();
          final volume = (options?['volume'] as num?)?.toDouble();
          LoggerService.debug(
            '[Synapse.tts.speak] Called with ${text.length} chars, language: $language',
          );
          await _ttsService.speak(
            text,
            language: language,
            rate: rate,
            pitch: pitch,
            volume: volume,
          );
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.tts.speak] Completed in ${duration.inMilliseconds}ms',
          );
          return {'success': true};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.tts.speak] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'ttsStop',
      callback: (args) async {
        try {
          await _ttsService.stop();
          return {'success': true};
        } catch (e) {
          LoggerService.error('[Synapse.tts.stop] Error: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'ttsGetLanguages',
      callback: (args) async {
        try {
          final languages = await _ttsService.getLanguages();
          return {'success': true, 'data': languages};
        } catch (e) {
          LoggerService.error('[Synapse.tts.getLanguages] Error: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'log',
      callback: (args) async {
        try {
          final message = args.isNotEmpty ? args.first?.toString() ?? '' : '';
          final level = args.length > 1
              ? args[1]?.toString().toUpperCase() ?? 'LOG'
              : 'LOG';
          LoggerService.info('[UserApp.$level] $message');
        } catch (e) {
          LoggerService.error(
            '[UserApp.LOG] Error in log handler: $e',
            error: e,
          );
        }
        return null;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'copy-to-clipboard',
      callback: (args) async {
        try {
          final text = args.isNotEmpty ? args.first?.toString() ?? '' : '';
          await Clipboard.setData(ClipboardData(text: text));
          LoggerService.debug(
            '[UserApp.CLIPBOARD] Text copied to clipboard: ${text.length > 50 ? '${text.substring(0, 50)}...' : text}',
          );
          return {'success': true};
        } catch (e) {
          LoggerService.error(
            '[UserApp.CLIPBOARD] Error copying to clipboard: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'fetchWebPage',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final rawUrl = args.isNotEmpty ? args.first : null;
          final url = rawUrl == null ? '' : rawUrl.toString().trim();
          LoggerService.debug('[Synapse.fetchWebPage] Called with URL: $url');

          final result = await UserAppService.fetchWebPage(url);
          final duration = DateTime.now().difference(startTime);
          final markdownLength = (result['markdown'] as String?)?.length ?? 0;
          LoggerService.debug(
            '[Synapse.fetchWebPage] Success - Markdown length $markdownLength in ${duration.inMilliseconds}ms',
          );
          return {'success': true, 'data': result};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.fetchWebPage] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'originFetch',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          if (args.isEmpty || args.first is! Map) {
            throw ArgumentError('Request options are required');
          }
          final options = Map<String, dynamic>.from(args.first as Map);
          final url = (options['url'] as String?)?.trim() ?? '';
          if (url.isEmpty) {
            throw ArgumentError('URL is required');
          }

          final headers = <String, String>{};
          final rawHeaders = options['headers'];
          if (rawHeaders is Map) {
            rawHeaders.forEach((key, value) {
              if (key != null && value != null) {
                headers[key.toString()] = value.toString();
              }
            });
          }

          LoggerService.debug('[Synapse.originFetch] Called with URL: $url');
          final result = await UserAppService.originFetch(
            url,
            originRaw: options['origin'] as String?,
            method: (options['method'] as String?) ?? 'GET',
            headers: headers,
            responseMode: (options['responseMode'] as String?) ?? 'tempFile',
          );
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.originFetch] Completed in ${duration.inMilliseconds}ms',
          );
          return result;
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.originFetch] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'status': 'error', 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'sessionRequestLogin',
      callback: (args) async {
        try {
          final url = args.isNotEmpty
              ? (args.first?.toString().trim() ?? '')
              : '';
          if (url.isEmpty) {
            throw ArgumentError('A url is required to request login');
          }
          final domain = WebSessionService.domainKeyFor(url);
          final callback = onWebLoginRequest;
          if (callback == null) {
            // Headless / no UI available to present the login browser.
            return {'success': false, 'error': 'no_ui', 'domain': domain};
          }
          final loggedIn = await callback(this, url);
          return {'success': loggedIn, 'loggedIn': loggedIn, 'domain': domain};
        } catch (e) {
          LoggerService.error(
            '[Synapse.session.requestLogin] Error: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'sessionStatus',
      callback: (args) async {
        try {
          final input = args.isNotEmpty
              ? (args.first?.toString().trim() ?? '')
              : '';
          if (input.isEmpty) {
            throw ArgumentError('A domain or url is required');
          }
          final domain = WebSessionService.domainKeyFor(input);
          final session = await _webSessionService.getSession(domain);
          final loggedIn = session != null && session.liveCookies.isNotEmpty;
          final expiresAt = session?.lastExpiry;
          return {
            'success': true,
            'loggedIn': loggedIn,
            'domain': domain,
            'savedAt': session?.savedAt.toIso8601String(),
            if (session?.refreshedAt != null)
              'refreshedAt': session!.refreshedAt!.toIso8601String(),
            if (expiresAt != null) 'expiresAt': expiresAt.toIso8601String(),
            // Lets an app offer a re-login before a request actually fails.
            'expiringSoon':
                loggedIn &&
                expiresAt != null &&
                expiresAt.difference(DateTime.now()).inDays < 3,
          };
        } catch (e) {
          LoggerService.error('[Synapse.session.status] Error: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'sessionGetCookies',
      callback: (args) async {
        try {
          final input = args.isNotEmpty
              ? (args.first?.toString().trim() ?? '')
              : '';
          if (input.isEmpty) {
            throw ArgumentError('A domain or url is required');
          }
          final domain = WebSessionService.domainKeyFor(input);

          // Resolve the session BEFORE the grant: approving access to a login
          // that does not exist would record a grant with no row in Web Logins
          // to revoke it from, which would then silently re-arm if the user
          // later saved a login for this domain.
          if (await _webSessionService.getSession(domain) == null) {
            return {'success': false, 'error': 'no_session', 'domain': domain};
          }

          // Reading raw cookie values is sensitive: gate on a per-app+domain
          // grant, prompting the user for approval the first time. Shared with
          // proxyFetch/downloadFile so a grant is only ever written in one
          // place.
          final granted = await _ensureDomainGrant(domain);
          if (granted == null) {
            return {'success': false, 'error': 'permission_required'};
          }
          if (!granted) {
            return {'success': false, 'error': 'permission_denied'};
          }

          // Re-read after approval rather than reuse the pre-prompt snapshot,
          // so a login deleted or re-saved while the dialog was open cannot
          // hand back stale cookie values.
          final session = await _webSessionService.getSession(domain);
          if (session == null || session.liveCookies.isEmpty) {
            return {'success': false, 'error': 'no_session', 'domain': domain};
          }
          final cookies = session.liveCookies
              .map(
                (c) => {
                  'name': c.name,
                  'value': c.value,
                  if (c.domain != null) 'domain': c.domain,
                  if (c.path != null) 'path': c.path,
                },
              )
              .toList();
          return {'success': true, 'domain': domain, 'cookies': cookies};
        } catch (e) {
          LoggerService.error(
            '[Synapse.session.getCookies] Error: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'downloadFile',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          if (args.isEmpty || args.first is! Map) {
            throw ArgumentError('Request options are required');
          }
          final options = Map<String, dynamic>.from(args.first as Map);
          final urlRaw = (options['url'] as String?)?.trim() ?? '';
          if (urlRaw.isEmpty) {
            throw ArgumentError('url is required');
          }
          final uri = Uri.parse(urlRaw);
          if (uri.scheme != 'http' && uri.scheme != 'https') {
            throw ArgumentError('Only HTTP(S) URLs are supported');
          }

          // Same grant as session use — downloading with the user's live login
          // acts as them on that site.
          //
          // With no saved login there is nothing to grant access to, so no
          // grant is recorded (one the user could never see or revoke). This
          // download then runs UNAUTHENTICATED: unlike proxyFetch, the hop loop
          // below reads the *live* cookie jar, which can hold cookies for a
          // site the user signed into without saving a login. Attaching those
          // without an approved grant would be an ungated authenticated fetch,
          // so `authorized` gates the cookie attachment, not just the prompt.
          final downloadDomain = WebSessionService.domainKeyFor(urlRaw);
          final authorized =
              await _webSessionService.getSession(downloadDomain) != null;
          if (authorized) {
            final granted = await _ensureDomainGrant(downloadDomain);
            if (granted == null) {
              return {'status': 'error', 'error': 'permission_required'};
            }
            if (!granted) {
              return {'status': 'error', 'error': 'permission_denied'};
            }
          }

          final extraHeaders = <String, String>{};
          final rawHeaders = options['headers'];
          if (rawHeaders is Map) {
            rawHeaders.forEach((k, v) {
              if (k != null && v != null) {
                extraHeaders[k.toString()] = v.toString();
              }
            });
          }

          // Follow redirects MANUALLY so cookies are re-scoped per hop: each
          // request carries only the live cookies for that hop's own domain. A
          // cross-domain redirect therefore never carries the granted domain's
          // cookies onward (the leak dart:io's auto-follow would cause).
          var currentUri = uri;
          HttpClientResponse? response;
          for (var hop = 0; hop <= 10; hop++) {
            final request = await _proxyHttpClient.openUrl('GET', currentUri);
            request.followRedirects = false;
            final hopHeaders = <String, String>{
              'user-agent':
                  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
              'referer': '${currentUri.scheme}://${currentUri.host}/',
              'sec-fetch-site': 'cross-site',
              'sec-fetch-dest': 'document',
              'sec-fetch-mode': 'navigate',
              'sec-fetch-user': '?1',
              ...extraHeaders,
            };
            // Only when a grant was approved above: without one this must stay
            // an unauthenticated fetch, and the live jar would otherwise supply
            // cookies for sites the user never saved a login for.
            if (authorized) {
              final hopCookies = await _webSessionService.liveCookieHeaderFor(
                currentUri.toString(),
              );
              if (hopCookies.isNotEmpty) {
                hopHeaders['cookie'] = hopCookies;
              }
            }
            hopHeaders.forEach((k, v) {
              try {
                request.headers.set(k, v);
              } catch (_) {}
            });
            final resp = await request.close();
            // Same roll-forward as proxyFetch, per hop, and only for hops that
            // stayed on the domain whose login was actually granted.
            if (authorized &&
                WebSessionService.domainKeyFor(currentUri.toString()) ==
                    downloadDomain) {
              final setCookies =
                  resp.headers[HttpHeaders.setCookieHeader] ?? const [];
              if (setCookies.isNotEmpty) {
                await _webSessionService.mergeSetCookieHeaders(
                  currentUri.toString(),
                  setCookies,
                );
              }
            }
            if (resp.isRedirect) {
              final loc = resp.headers.value(HttpHeaders.locationHeader);
              await resp.drain<void>();
              if (loc == null || hop == 10) {
                return {'status': 'error', 'error': 'too_many_redirects'};
              }
              currentUri = currentUri.resolve(loc);
              continue;
            }
            response = resp;
            break;
          }
          if (response == null) {
            return {'status': 'error', 'error': 'no_response'};
          }

          // A non-2xx response is not the file (auth/error page). Surface it
          // rather than saving an error body as the "download".
          if (response.statusCode < 200 || response.statusCode >= 300) {
            await response.drain<void>();
            return {
              'status': 'error',
              'error': 'auth_required',
              'statusCode': response.statusCode,
            };
          }

          final bytesBuilder = BytesBuilder(copy: false);
          await for (final chunk in response) {
            bytesBuilder.add(chunk);
          }
          final bytes = bytesBuilder.takeBytes();
          final mime =
              (response.headers.value(HttpHeaders.contentTypeHeader) ??
                      'application/octet-stream')
                  .split(';')
                  .first
                  .trim();

          // Downloadable media/binary is never text/* — a text body means a
          // login/error page slipped through.
          if (mime.startsWith('text/')) {
            return {
              'status': 'error',
              'error': 'auth_required',
              'statusCode': response.statusCode,
            };
          }

          final saved = await SynapseTempUtils.saveTempData(
            mimeType: mime.isEmpty ? 'application/octet-stream' : mime,
            bytes: bytes,
          );
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.downloadFile] ${response.statusCode} $mime '
            '(${bytes.length}B) in ${duration.inMilliseconds}ms',
          );
          return {
            'status': 'success',
            'statusCode': response.statusCode,
            'mime': mime,
            'uri': saved.uri,
            'bytes': bytes.length,
          };
        } catch (e) {
          LoggerService.error('[Synapse.downloadFile] Error: $e', error: e);
          return {'status': 'error', 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'pickNotes',
      callback: (args) async {
        try {
          final options = (args.isNotEmpty && args.first is Map)
              ? Map<String, dynamic>.from(args.first as Map)
              : <String, dynamic>{};
          final callback = onPickNotes;
          if (callback == null) {
            return {'success': false, 'error': 'no_ui'};
          }
          final selected = await callback(this, options);
          if (selected == null) {
            return {'success': true, 'cancelled': true, 'notes': []};
          }
          return {'success': true, 'notes': selected};
        } catch (e) {
          LoggerService.error('[Synapse.pickNotes] Error: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'pickTags',
      callback: (args) async {
        try {
          final options = (args.isNotEmpty && args.first is Map)
              ? Map<String, dynamic>.from(args.first as Map)
              : <String, dynamic>{};
          final callback = onPickTags;
          if (callback == null) {
            return {'success': false, 'error': 'no_ui'};
          }
          final selected = await callback(this, options);
          if (selected == null) {
            return {'success': true, 'cancelled': true, 'tags': []};
          }
          return {'success': true, 'tags': selected};
        } catch (e) {
          LoggerService.error('[Synapse.pickTags] Error: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'cryptoDigest',
      callback: (args) async {
        try {
          final algorithm = args.isNotEmpty ? (args[0]?.toString() ?? '') : '';
          final data = (args.length > 1 && args[1] is Map)
              ? Map<String, dynamic>.from(args[1] as Map)
              : <String, dynamic>{};
          final text = data['text'] as String?;
          final base64Data = (data['base64'] ?? data['base64Data']) as String?;
          final hex = getIt<CryptoService>().digestHex(
            algorithm,
            text: text,
            base64Data: base64Data,
          );
          return {'success': true, 'hex': hex};
        } catch (e) {
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'exportNotes',
      callback: (args) async {
        try {
          final rawIds = args.isNotEmpty ? args.first : null;
          final noteIds = <String>[];
          if (rawIds is List) {
            for (final id in rawIds) {
              if (id != null && id.toString().trim().isNotEmpty) {
                noteIds.add(id.toString());
              }
            }
          }
          if (noteIds.isEmpty) {
            throw ArgumentError('noteIds must be a non-empty array');
          }
          final options = (args.length > 1 && args[1] is Map)
              ? Map<String, dynamic>.from(args[1] as Map)
              : <String, dynamic>{};
          final includeLinked =
              options['includeSubNotesAndLinkedNotes'] != false;
          final includeAttachments = options['includeAttachmentList'] != false;

          // Load a default (English) localization instance; exportNotes has no
          // BuildContext, and the l10n only affects section labels in the
          // exported markdown.
          final l10n = await AppLocalizations.delegate.load(const Locale('en'));

          final exported = <Map<String, dynamic>>[];
          for (final noteId in noteIds) {
            final note = await _resolveNoteForRead(noteId);
            if (note == null) {
              continue;
            }
            // A transient block note has no sources row of its own; its
            // **Source:** lines are the parent's, like its attachments below.
            final markdown = await ShareService.generateMarkdownText(
              notes: [note],
              includeSubNotesAndLinkedNotes: includeLinked,
              appProvider: appProvider,
              l10n: l10n,
              sourceNoteIdFor: _realNoteId,
            );
            final entry = <String, dynamic>{
              'id': note.id,
              'title': note.title,
              'markdown': markdown,
            };
            if (includeAttachments) {
              // A transient block note has no attachment rows of its own; it
              // inherits the parent's, which is what its attachmentPaths
              // already advertise.
              final attachments = await _databaseService.getAttachmentsForNote(
                _realNoteId(noteId),
              );
              entry['attachments'] = [
                for (final att in attachments)
                  {
                    'id': att.id,
                    'path': await FileUtils.resolvePortableAttachmentPath(
                      att.filePath,
                    ),
                    'fileName': att.fileName,
                    'mimeType': att.fileType,
                  },
              ];
            }
            exported.add(entry);
          }

          return {'success': true, 'notes': exported};
        } catch (e) {
          LoggerService.error('[Synapse.exportNotes] Error: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'tasksSchedule',
      callback: (args) async {
        try {
          final options = (args.isNotEmpty && args.first is Map)
              ? Map<String, dynamic>.from(args.first as Map)
              : <String, dynamic>{};
          final tool = (options['tool'] as String?)?.trim() ?? '';
          if (tool.isEmpty) {
            throw ArgumentError('tool is required');
          }
          final params = (options['params'] is Map)
              ? Map<String, dynamic>.from(options['params'] as Map)
              : <String, dynamic>{};
          final delaySeconds = (options['delaySeconds'] as num?)?.toInt() ?? 60;
          final maxRuns = (options['maxRuns'] as num?)?.toInt() ?? 1;
          final taskId = await getIt<PluginTaskService>().schedule(
            appUuid: app.uuid,
            tool: tool,
            params: params,
            delaySeconds: delaySeconds,
            maxRuns: maxRuns,
          );
          return {'success': true, 'taskId': taskId};
        } catch (e) {
          LoggerService.error('[Synapse.tasks.schedule] Error: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'tasksCancel',
      callback: (args) async {
        try {
          final taskId = args.isNotEmpty ? (args.first?.toString() ?? '') : '';
          if (taskId.isEmpty) {
            throw ArgumentError('taskId is required');
          }
          await getIt<PluginTaskService>().cancel(taskId);
          return {'success': true};
        } catch (e) {
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'tasksList',
      callback: (args) async {
        try {
          final tasks = await getIt<PluginTaskService>().list(app.uuid);
          return {'success': true, 'tasks': tasks};
        } catch (e) {
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'readAttachment',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final attachmentPath = args.first as String;
          LoggerService.debug(
            '[Synapse.readAttachment] Called with path: $attachmentPath',
          );
          final result = await _readAttachmentFromPath(attachmentPath);
          final duration = DateTime.now().difference(startTime);
          if (result != null) {
            LoggerService.debug(
              '[Synapse.readAttachment] Success - Read ${result['data']?.length ?? 0} characters in ${duration.inMilliseconds}ms',
            );
            return {
              'success': true,
              'data': result['data'],
              'mimeType': result['mimeType'],
            };
          }
          LoggerService.warning(
            '[Synapse.readAttachment] Attachment not found in database: $attachmentPath',
          );
          return {
            'success': false,
            'error': 'Attachment not found in database',
          };
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.readAttachment] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'saveTemp',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          if (args.length < 2) {
            throw Exception('saveTemp requires data and mimeType arguments');
          }

          final dataArg = args[0];
          final mimeArg = args[1];

          if (mimeArg is! String || mimeArg.trim().isEmpty) {
            throw Exception('saveTemp requires a mimeType string');
          }

          if (dataArg is! Map) {
            throw Exception(
              'saveTemp data must be an object with text and/or binary fields',
            );
          }

          final dataMap = Map<String, dynamic>.from(dataArg);
          final textValue = dataMap['text']?.toString();
          final binaryValue = dataMap['binary']?.toString();

          if ((textValue == null || textValue.isEmpty) &&
              (binaryValue == null || binaryValue.isEmpty)) {
            throw Exception(
              'saveTemp requires either data.text or data.binary',
            );
          }

          final result = await SynapseTempUtils.saveTempData(
            mimeType: mimeArg,
            text: textValue?.isEmpty == true ? null : textValue,
            base64Data: binaryValue?.isEmpty == true ? null : binaryValue,
          );

          final fileName = result.file.uri.pathSegments.isNotEmpty
              ? result.file.uri.pathSegments.last
              : result.file.path;
          final sizeBytes = await result.file.length();
          final duration = DateTime.now().difference(startTime);

          LoggerService.debug(
            '[Synapse.saveTemp] Created $fileName (${result.mimeType}, $sizeBytes bytes) in ${duration.inMilliseconds}ms',
          );
          return {'success': true, 'uri': result.uri};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.saveTemp] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'saveNotes',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final notesData =
              (args.isNotEmpty ? args.first : []) as List<dynamic>;
          LoggerService.debug(
            '[Synapse.saveNotes] Called with ${notesData.length} notes',
          );
          final savedNoteIds = await _saveNotesFromJavaScript(notesData);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.saveNotes] Success - Saved ${savedNoteIds.length} notes in ${duration.inMilliseconds}ms',
          );
          return {
            'success': true,
            'savedCount': savedNoteIds.length,
            'savedNoteIds': savedNoteIds,
          };
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.saveNotes] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'deleteNotes',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final noteIdsData =
              (args.isNotEmpty ? args.first : []) as List<dynamic>;
          LoggerService.debug(
            '[Synapse.deleteNotes] Called with ${noteIdsData.length} note IDs',
          );
          final deletedCount = await _deleteNotesFromJavaScript(noteIdsData);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.deleteNotes] Success - Deleted $deletedCount notes in ${duration.inMilliseconds}ms',
          );
          return {'success': true, 'deletedCount': deletedCount};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.deleteNotes] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'openNote',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          if (onOpenNote == null) {
            return {
              'success': false,
              'error': 'openNote not supported in this context',
            };
          }

          final noteId = args.first as String;
          final replaceWindow = args.length > 1
              ? (args[1] as bool? ?? false)
              : false;
          LoggerService.debug(
            '[Synapse.openNote] Called with noteId: $noteId, replaceWindow: $replaceWindow',
          );

          final note = await _resolveNoteForNavigation(noteId);
          if (note == null) {
            final duration = DateTime.now().difference(startTime);
            LoggerService.warning(
              '[Synapse.openNote] Note not found: $noteId after ${duration.inMilliseconds}ms',
            );
            return {'success': false, 'error': 'Note not found: $noteId'};
          }

          await onOpenNote!(note, replaceWindow);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.openNote] Success - Opening note: ${note.title} in ${duration.inMilliseconds}ms',
          );
          return {'success': true};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.openNote] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'updateNotes',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final notesData =
              (args.isNotEmpty ? args.first : []) as List<dynamic>;
          LoggerService.debug(
            '[Synapse.updateNotes] Called with ${notesData.length} note updates',
          );

          // Check approval before any modifications
          if (!_sessionApprovedModifications) {
            if (onModificationRequest != null) {
              // Build specific modification data if single note, otherwise summary
              String targetNoteId = 'batch-update';
              Map<String, dynamic> modificationData;

              if (notesData.length == 1 &&
                  notesData.first is Map<String, dynamic>) {
                final noteData = notesData.first as Map<String, dynamic>;
                final rawId = noteData['id']?.toString() ?? 'unknown';
                // Show the parent note for a transient block write, so the
                // dialog names something the user recognizes.
                targetNoteId = _realNoteId(rawId);

                // If granular modification, pass that. Otherwise pass the note data.
                if (noteData.containsKey('modification') &&
                    noteData['modification'] is Map) {
                  modificationData = _sanitizedForApproval(
                    noteData['modification'] as Map,
                  );
                } else {
                  modificationData = _sanitizedForApproval(noteData)
                    ..remove('id');
                }
                // Tell the user WHICH of the two this is. Without it a plugin
                // launched on one block can get a whole-note rewrite approved
                // by making the dialog look exactly like the block edit the
                // user asked for. Copied above, so the applied write (which is
                // re-read from noteData) never sees these keys.
                final scopeKey = _writeScopeKeyFor(rawId);
                if (scopeKey != null) modificationData[scopeKey] = true;
              } else {
                // Batch update: Itemize first 20 notes
                final updates = <Map<String, dynamic>>[];
                final NOTE_LIMIT = 20;

                for (var i = 0; i < notesData.length && i < NOTE_LIMIT; i++) {
                  final item = notesData[i];
                  if (item is Map<String, dynamic>) {
                    final id = _realNoteId(item['id']?.toString() ?? 'unknown');
                    // Extract modification similar to single case
                    Map<String, dynamic> changes;
                    if (item.containsKey('modification') &&
                        item['modification'] is Map) {
                      changes = _sanitizedForApproval(
                        item['modification'] as Map,
                      );
                    } else {
                      changes = _sanitizedForApproval(item)..remove('id');
                    }

                    updates.add({'id': id, 'changes': changes});
                  }
                }

                final rawIds = notesData
                    .whereType<Map<String, dynamic>>()
                    .map((n) => n['id']?.toString() ?? 'unknown')
                    .toList();

                modificationData = <String, dynamic>{
                  'isBatch': true,
                  'count': notesData.length,
                  'updates': updates,
                  // Keep noteIds for legacy/other checks if needed?
                  'noteIds': rawIds.map(_realNoteId).toList(),
                };

                // A batch must carry the scope notice too, otherwise adding a
                // second entry is enough to hide a whole-note rewrite behind
                // what looks like a block edit. Whole-note wins: if ANY entry
                // targets a real note during a block-scoped session, say so.
                if (rawIds.any(
                  (id) =>
                      _writeScopeKeyFor(id) ==
                      ApprovalRequest.scopeWholeNoteKey,
                )) {
                  modificationData[ApprovalRequest.scopeWholeNoteKey] = true;
                } else if (rawIds.isNotEmpty &&
                    rawIds.every((id) => _blockScopeFor(id) != null)) {
                  modificationData[ApprovalRequest.scopeBlockKey] = true;
                }
              }

              final approved = await onModificationRequest!(
                this,
                targetNoteId,
                modificationData,
              );
              if (!approved) {
                return {'success': false, 'error': 'User denied modification.'};
              }
            } else {
              return {
                'success': false,
                'error': 'Modification not supported in this context.',
              };
            }
          }

          final outcome = await _updateNotesFromJavaScript(notesData);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.updateNotes] Success - Updated ${outcome.updatedCount} notes in ${duration.inMilliseconds}ms',
          );
          return {
            'success': true,
            'updatedCount': outcome.updatedCount,
            // Additive: existing apps ignore these, but a refused write is no
            // longer indistinguishable from a successful no-op. `error` is the
            // singular form existing plugins already read (Table Studio's
            // interpretUpdateResult, for one), so they surface the reason
            // without any change.
            if (outcome.errors.isNotEmpty) 'errors': outcome.errors,
            if (outcome.errors.isNotEmpty) 'error': outcome.errors.first,
          };
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.updateNotes] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'openConversations',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          if (onOpenConversations == null) {
            return {
              'success': false,
              'error': 'openConversations not supported in this context',
            };
          }

          final notesData =
              (args.isNotEmpty ? args.first : []) as List<dynamic>;
          final immersiveMode = args.length > 1
              ? (args[1] as bool? ?? false)
              : false;

          LoggerService.debug(
            '[Synapse.openConversations] Called with ${notesData.length} notes, immersiveMode: $immersiveMode',
          );

          if (immersiveMode && notesData.isEmpty) {
            final duration = DateTime.now().difference(startTime);
            LoggerService.warning(
              '[Synapse.openConversations] Error: immersiveMode requires at least one note after ${duration.inMilliseconds}ms',
            );
            return {
              'success': false,
              'error': 'immersiveMode requires at least one note',
            };
          }

          final notes = await _resolveNotesArg(
            notesData,
            'Synapse.openConversations',
          );

          await onOpenConversations!(notes, immersiveMode);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.openConversations] Success - Opened conversations with ${notes.length} notes in ${duration.inMilliseconds}ms',
          );
          return {'success': true};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.openConversations] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'openAIActions',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          if (onOpenAIActions == null) {
            return {
              'success': false,
              'error': 'openAIActions not supported in this context',
            };
          }

          final notesData =
              (args.isNotEmpty ? args.first : []) as List<dynamic>;
          LoggerService.debug(
            '[Synapse.openAIActions] Called with ${notesData.length} notes',
          );

          final notes = await _resolveNotesArg(
            notesData,
            'Synapse.openAIActions',
          );

          await onOpenAIActions!(notes);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.openAIActions] Success - Opened AI actions with ${notes.length} notes in ${duration.inMilliseconds}ms',
          );
          return {'success': true};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.openAIActions] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'openMerge',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          if (onOpenMerge == null) {
            return {
              'success': false,
              'error': 'openMerge not supported in this context',
            };
          }

          final rawArg = args.isNotEmpty ? args.first : const <dynamic>[];
          if (rawArg is! List) {
            LoggerService.warning(
              '[Synapse.openMerge] Expected an array of notes, got '
              '${rawArg.runtimeType}',
            );
            return {
              'success': false,
              'error': 'openMerge expects an array of notes or note IDs',
            };
          }
          final notesData = rawArg;
          LoggerService.debug(
            '[Synapse.openMerge] Called with ${notesData.length} notes',
          );

          // Count distinct notes, not resolved entries: a repeated id, and any
          // set of block-scope ids from one note, all resolve to the same note.
          // MergeDocument.addSource drops the repeats, so the merge screen
          // would open on one source and pop a picker the app never asked for.
          final notes = _distinctById(
            await _resolveNotesArg(notesData, 'Synapse.openMerge'),
          );

          if (notes.length < 2) {
            LoggerService.warning(
              '[Synapse.openMerge] Only ${notes.length} distinct note(s) from '
              '${notesData.length} entries',
            );
            return {
              'success': false,
              'error':
                  'openMerge needs at least two notes; '
                  '${notesData.length} entries resolved to '
                  '${notes.length} distinct note(s)',
            };
          }

          final merged = await onOpenMerge!(notes);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.openMerge] Success - Merged ${notes.length} notes into '
            '${merged?.id ?? 'nothing (cancelled)'} in ${duration.inMilliseconds}ms',
          );
          if (merged == null) {
            return {'success': true, 'cancelled': true};
          }
          return {'success': true, 'mergedNoteId': merged.id};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error(
            '[Synapse.openMerge] Error after ${duration.inMilliseconds}ms: $e',
            error: e,
          );
          return {'success': false, 'error': e.toString()};
        }
      },
    );
  }

  /// Handles the synapse_user:// custom scheme for serving stored dependencies.
  Future<CustomSchemeResponse?> handleSynapseUserScheme(Uri url) async {
    try {
      final path = url.path;
      LoggerService.debug('[SynapseUser] Handling request for path: $path');

      final dependency = await _databaseService.getDependencyByAppAndPath(
        app.uuid,
        revisionNumber,
        path,
      );

      if (dependency == null) {
        LoggerService.warning(
          '[SynapseUser] Dependency not found for path: $path',
        );
        return CustomSchemeResponse(
          contentType: 'text/plain',
          data: Uint8List.fromList(
            utf8.encode('// Dependency not found: $path'),
          ),
        );
      }

      final bytes = dependency['bytes'] as List<int>;
      LoggerService.debug(
        '[SynapseUser] Found dependency: ${bytes.length} bytes',
      );
      final contentType = _getMimeTypeFromExtension(
        FileTypeUtils.getFileExtension(path),
      );

      return CustomSchemeResponse(
        contentType: contentType,
        data: Uint8List.fromList(bytes),
      );
    } catch (e) {
      LoggerService.error(
        '[SynapseUser] Error handling synapse_user scheme: $e',
        error: e,
      );
      return CustomSchemeResponse(
        contentType: 'text/plain',
        data: Uint8List.fromList(
          utf8.encode('// Error loading dependency: $e'),
        ),
      );
    }
  }

  /// Handles the synapsetemp:/// custom scheme used for temporary files
  /// generated by Synapse.saveTemp.
  Future<CustomSchemeResponse?> handleSynapseTempScheme(Uri url) async {
    try {
      final tempFile = await SynapseTempUtils.loadFile(url.toString());
      LoggerService.debug(
        '[SynapseTemp] Serving ${tempFile.fileName} (${tempFile.bytes.length} bytes)',
      );
      return CustomSchemeResponse(
        contentType: tempFile.mimeType,
        data: tempFile.bytes,
      );
    } catch (e) {
      LoggerService.error(
        '[SynapseTemp] Error handling synapsetemp scheme: $e',
        error: e,
      );
      return CustomSchemeResponse(
        contentType: 'text/plain',
        data: Uint8List.fromList(
          utf8.encode('// Temporary resource unavailable'),
        ),
      );
    }
  }

  String _buildParamsJson() {
    if (_params.isEmpty) {
      return '{}';
    }
    try {
      return jsonEncode(_params);
    } catch (e) {
      LoggerService.warning(
        '[UserAppRuntimeBridge] Params are not JSON-serializable, '
        'falling back to {}: $e',
      );
      return '{}';
    }
  }

  String _buildSelectedNotesJson() {
    if (_selectedNotes.isEmpty) {
      return '[]';
    }

    final notesData = _selectedNotes.map((note) {
      final data = <String, dynamic>{
        'id': note.id,
        'title': note.title,
        'content': note.content,
        'tags': note.tags,
        'createdAt': note.createdAt.toIso8601String(),
        'updatedAt': note.updatedAt.toIso8601String(),
        'isTask': note.isTask,
        'status': note.isTask ? note.status.toString() : null,
        'pinned': note.pinned,
        'isArchived': note.isArchived,
        'attachmentPaths': note.attachmentPaths,
        'sources': sourcesToPluginJson(
          _selectedNoteSources[note.id] ?? const [],
        ),
      };

      // Additive only: a transient block note also advertises the note it was
      // sliced from. Apps that don't know about block scopes simply ignore
      // these keys and keep working unchanged.
      final scope = _blockScopeFor(note.id);
      if (scope != null) {
        data['isBlockScope'] = true;
        data['parentNoteId'] = scope.parentNoteId;
      }
      return data;
    }).toList();
    return jsonEncode(notesData);
  }

  /// The `sources` array of a `Synapse.Notes` entry: one
  /// `{id, url, title?, siteName?, clippedAt?, kind, method}` object per
  /// source, null fields omitted and `clippedAt` as a UTC ISO-8601 string —
  /// the shape `api_documentation.md` promises plugins.
  static List<Map<String, dynamic>> sourcesToPluginJson(
    List<NoteSource> sources,
  ) => [
    for (final s in sources)
      {
        'id': s.id,
        'url': s.url,
        if (s.title != null) 'title': s.title,
        if (s.siteName != null) 'siteName': s.siteName,
        if (s.clippedAt != null)
          'clippedAt': s.clippedAt!.toUtc().toIso8601String(),
        'kind': s.kind,
        'method': s.method,
      },
  ];

  /// Resolves a note id for reading/exporting.
  ///
  /// A transient block-note id resolves to a synthesized note whose content is
  /// the block text; ordinary ids hit the database.
  Future<Note?> _resolveNoteForRead(String noteId) async {
    final scope = _blockScopeFor(noteId);
    if (scope != null) return _blockScopes!.asNote(scope);
    return _databaseService.getNote(noteId);
  }

  /// Resolves a note id for navigation (open note / conversations / AI actions).
  ///
  /// A transient block note cannot be navigated to — it has no database row —
  /// so it resolves to the real note the block lives in.
  Future<Note?> _resolveNoteForNavigation(String noteId) async {
    final scope = _blockScopeFor(noteId);
    if (scope != null) return _databaseService.getNote(scope.parentNoteId);
    return _databaseService.getNote(noteId);
  }

  /// Resolves a `notes` argument - entries are either note id strings or
  /// objects carrying an `id` - into the notes they name, in argument order.
  ///
  /// An entry that is malformed (not a string, or an object whose `id` is not a
  /// string) is skipped with a warning, exactly like one naming a note that no
  /// longer exists: a single bad entry must not abort the whole call with a raw
  /// Dart cast message. [tag] names the calling handler in those warnings.
  ///
  /// Block-scope ids resolve to their parent note, so the result can contain
  /// the same note more than once; callers that care must de-duplicate.
  Future<List<Note>> _resolveNotesArg(
    List<dynamic> notesData,
    String tag,
  ) async {
    final notes = <Note>[];
    for (final noteData in notesData) {
      String? noteId;
      if (noteData is String) {
        noteId = noteData;
      } else if (noteData is Map<String, dynamic> && noteData['id'] is String) {
        noteId = noteData['id'] as String;
      }
      if (noteId == null) {
        LoggerService.warning(
          '[$tag] Skipping malformed note entry: $noteData',
        );
        continue;
      }
      final note = await _resolveNoteForNavigation(noteId);
      if (note != null) {
        notes.add(note);
      } else {
        LoggerService.warning('[$tag] Note not found: $noteId');
      }
    }
    return notes;
  }

  /// Drops repeats of the same note, keeping the first occurrence of each id.
  List<Note> _distinctById(List<Note> notes) {
    final seen = <String>{};
    return [
      for (final note in notes)
        if (seen.add(note.id)) note,
    ];
  }

  /// Open block-scope ids that appear literally in [sql].
  ///
  /// Ids are v4 UUIDs, so a coincidental match is not a practical concern, and
  /// the scan is skipped entirely when no scope is open.
  List<String> _blockScopeIdsIn(String sql) {
    final scopes = _blockScopes;
    if (scopes == null || !scopes.hasOpenScopes) return const [];
    return scopes.openIds.where(sql.contains).toList();
  }

  /// Replaces each transient id in [sql] with its parent note id, so the query
  /// runs against a row that actually exists.
  String _rewriteBlockScopeIds(String sql, List<String> scopedIds) {
    var rewritten = sql;
    for (final id in scopedIds) {
      final parentId = _realNoteId(id);
      if (parentId != id) rewritten = rewritten.replaceAll(id, parentId);
    }
    return rewritten;
  }

  /// Patches rows that came back from a rewritten query so the plugin sees the
  /// BLOCK, not the whole parent note: `content` becomes the block text and
  /// `id` goes back to the transient id it asked about.
  ///
  /// A careful app commonly selects only `content`, so the returned row may not
  /// contain an `id` at all. When exactly one scope produced exactly one such
  /// row, it is still safe to patch it. Without that case the app receives the
  /// entire parent note and may write that content back into the selected
  /// block, duplicating the note.
  ///
  /// Rows with an `id` are patched only when it is the parent of a scope named
  /// in the original query, so unrelated rows in a multi-note query remain
  /// untouched.
  List<Map<String, dynamic>> _patchBlockScopeRows(
    List<Map<String, dynamic>> rows,
    List<String> scopedIds,
  ) {
    if (scopedIds.isEmpty || rows.isEmpty) return rows;
    final scopes = _blockScopes;
    if (scopes == null) return rows;

    final byParent = <String, BlockNoteScope>{};
    for (final id in scopedIds) {
      final scope = scopes.lookup(id);
      if (scope != null) byParent[scope.parentNoteId] = scope;
    }
    if (byParent.isEmpty) return rows;

    final soleScope = scopedIds.length == 1 && rows.length == 1
        ? scopes.lookup(scopedIds.single)
        : null;

    return rows.map((row) {
      final rowId = row['id']?.toString();
      final scope = rowId == null ? soleScope : byParent[rowId];
      if (scope == null) return row;
      final patched = Map<String, dynamic>.from(row);
      if (patched.containsKey('id')) patched['id'] = scope.tempNoteId;
      if (patched.containsKey('content')) patched['content'] = scope.text;
      return patched;
    }).toList();
  }

  /// Maps a transient block-note id to the real note it belongs to, leaving
  /// ordinary ids untouched. Used wherever a virtual id would otherwise reach
  /// something that only understands real notes — approval dialogs (a uuid that
  /// resolves to no note is meaningless to the user) and attachment lookups.
  String _realNoteId(String noteId) =>
      _blockScopeFor(noteId)?.parentNoteId ?? noteId;

  /// True when this runtime was launched on a block rather than whole notes.
  bool get _isBlockScopedSession =>
      _selectedNotes.isNotEmpty &&
      _selectedNotes.any((n) => _blockScopeFor(n.id) != null);

  /// Copies a plugin-supplied map for display in the approval dialog, dropping
  /// any `__`-prefixed key.
  ///
  /// Those keys are the HOST's channel for telling the dialog what the write is
  /// scoped to. If a plugin's own `__scopeBlock` survived into the payload it
  /// would label a whole-note rewrite "block only" — an attacker-controlled
  /// reassurance, i.e. worse than showing no notice at all.
  Map<String, dynamic> _sanitizedForApproval(Map<dynamic, dynamic> source) {
    final copy = <String, dynamic>{};
    source.forEach((key, value) {
      final name = key.toString();
      if (name.startsWith('__')) return;
      copy[name] = value;
    });
    return copy;
  }

  /// Scope hint for the approval dialog, or null when there is nothing to
  /// disambiguate (an ordinary whole-note session).
  ///
  /// Withholding `parentNoteId` would not help here: `Synapse.runQuery` allows
  /// unapproved SELECTs, so a plugin can always discover real note ids. The
  /// defence is making the two cases visibly different at the consent surface.
  String? _writeScopeKeyFor(String noteId) {
    if (_blockScopeFor(noteId) != null) return ApprovalRequest.scopeBlockKey;
    if (_isBlockScopedSession) return ApprovalRequest.scopeWholeNoteKey;
    return null;
  }

  _ValidatedChatOptions _validateChatOptions(Map<String, dynamic> options) {
    double? temperature;
    int? topK;
    double? topP;
    List<dynamic> attachments = const [];

    if (options.containsKey('temperature')) {
      final tempValue = options['temperature'];
      if (tempValue is num) {
        temperature = tempValue.toDouble();
      } else {
        throw Exception(
          'Parameter validation failed: temperature must be a number, got ${tempValue.runtimeType}',
        );
      }
    }

    if (options.containsKey('topK')) {
      final topKValue = options['topK'];
      if (topKValue is int) {
        topK = topKValue;
      } else if (topKValue is double &&
          topKValue == topKValue.roundToDouble()) {
        topK = topKValue.round();
      } else {
        throw Exception(
          'Parameter validation failed: topK must be an integer, got ${topKValue.runtimeType}',
        );
      }
    }

    if (options.containsKey('topP')) {
      final topPValue = options['topP'];
      if (topPValue is num) {
        final value = topPValue.toDouble();
        if (value < 0 || value > 1) {
          throw Exception(
            'Parameter validation failed: topP must be between 0.0 and 1.0, got $value',
          );
        }
        topP = value;
      } else {
        throw Exception(
          'Parameter validation failed: topP must be a number, got ${topPValue.runtimeType}',
        );
      }
    }

    if (options.containsKey('attachments')) {
      final attachmentValue = options['attachments'];
      if (attachmentValue is List) {
        attachments = attachmentValue;
      } else {
        throw Exception(
          'Parameter validation failed: attachments must be an array, got ${attachmentValue.runtimeType}',
        );
      }
    }

    LoggerService.debug(
      '[Synapse.chatAI] Validated parameters: temperature=$temperature, topK=$topK, topP=$topP, attachments=${attachments.length}',
    );
    return _ValidatedChatOptions(
      temperature: temperature,
      topK: topK,
      topP: topP,
      attachments: attachments,
    );
  }

  Future<List<PlatformFile>> _processMixedAttachments(
    List<dynamic> attachments,
  ) async {
    if (attachments.isEmpty) {
      return const [];
    }

    final validAttachments = <PlatformFile>[];

    for (var i = 0; i < attachments.length; i++) {
      final attachment = attachments[i];
      try {
        if (attachment is String) {
          final attachmentPath = attachment;
          if (SynapseTempUtils.isSynapseTempUri(attachmentPath)) {
            try {
              final tempFile = await SynapseTempUtils.loadFile(attachmentPath);
              validAttachments.add(
                PlatformFile(
                  name: tempFile.fileName,
                  path: tempFile.file.path,
                  size: tempFile.bytes.length,
                  bytes: tempFile.bytes,
                ),
              );
              LoggerService.debug(
                '[Synapse.chatAI] Added temporary attachment: ${tempFile.fileName} (${tempFile.bytes.length} bytes)',
              );
            } catch (e) {
              LoggerService.warning(
                '[Synapse.chatAI] Warning: Temporary attachment unavailable: $attachmentPath ($e)',
              );
            }
            continue;
          }

          final isValid = await _databaseService.verifyAttachmentPath(
            attachmentPath,
          );
          if (!isValid) {
            LoggerService.warning(
              '[Synapse.chatAI] Warning: Attachment path not found in database: $attachmentPath',
            );
            continue;
          }

          final file = File(attachmentPath);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            final fileName = attachmentPath.split('/').last;
            validAttachments.add(
              PlatformFile(
                name: fileName,
                path: attachmentPath,
                size: bytes.length,
                bytes: bytes,
              ),
            );
            LoggerService.debug(
              '[Synapse.chatAI] Added file attachment: $fileName (${bytes.length} bytes)',
            );
          } else {
            LoggerService.warning(
              '[Synapse.chatAI] Warning: Attachment file not found: $attachmentPath',
            );
          }
        } else if (attachment is Map<String, dynamic>) {
          final type = attachment['type'] as String?;
          final mimeType = attachment['mimeType'] as String?;
          final data = attachment['data'] as String?;
          if (type == 'base64' && mimeType != null && data != null) {
            var base64String = data;
            if (base64String.contains(',')) {
              base64String = base64String.split(',').last;
            }
            final bytes = base64Decode(base64String);
            final extension = _getExtensionFromMimeType(mimeType);
            final fileName =
                'attachment_${DateTime.now().millisecondsSinceEpoch}.$extension';
            validAttachments.add(
              PlatformFile(
                name: fileName,
                path: '',
                size: bytes.length,
                bytes: bytes,
              ),
            );
            LoggerService.debug(
              '[Synapse.chatAI] Added base64 attachment: $fileName (${bytes.length} bytes, $mimeType)',
            );
          } else {
            LoggerService.warning(
              '[Synapse.chatAI] Warning: Invalid base64 attachment object at index $i: missing type, mimeType, or data',
            );
          }
        } else {
          LoggerService.warning(
            '[Synapse.chatAI] Warning: Invalid attachment type at index $i: expected string or object, got ${attachment.runtimeType}',
          );
        }
      } catch (e) {
        LoggerService.error(
          '[Synapse.chatAI] Error processing attachment at index $i: $e',
          error: e,
        );
      }
    }

    return validAttachments;
  }

  /// Whether [mime] should be surfaced as a decoded text string rather than
  /// base64 in `responseMode: 'auto'`.
  static bool _isTextMime(String mime) {
    final m = mime.toLowerCase();
    return m.startsWith('text/') ||
        m == 'application/json' ||
        m == 'application/javascript' ||
        m == 'application/xml';
  }

  /// Resolves the per-app grant for [url]'s domain and, if allowed, merges the
  /// user's saved-session cookies into [headers]. Returns `null` on success, or
  /// an error result map (`permission_required` / `permission_denied`) that the
  /// caller should return as-is.
  /// Ensures this app has a grant to use the saved login for [domain],
  /// prompting for approval the first time. Returns `true` (granted),
  /// `false` (user declined), or `null` (no approval UI available).
  Future<bool?> _ensureDomainGrant(String domain) async {
    if (await _appDomainGrantService.isGranted(app.uuid, domain)) {
      return true;
    }
    // Never record a grant against a login that does not exist. The Web Logins
    // screen lists grants under their saved login, so such a grant would have
    // no row to be revoked from, and would silently re-arm the app if the user
    // later saved a login for this domain. This is the single place a grant is
    // written, so guarding here holds for every caller.
    if (await _webSessionService.getSession(domain) == null) {
      return null;
    }
    final callback = onSessionAccessApprovalRequest;
    if (callback == null) {
      return null;
    }
    final granted = await callback(this, domain);
    if (!granted) {
      return false;
    }
    // Approval is an unbounded await. If the login was deleted while the
    // prompt was open its grants have already been revoked, so writing one now
    // would recreate the very grant this guards against.
    if (await _webSessionService.getSession(domain) == null) {
      return null;
    }
    await _appDomainGrantService.grant(app.uuid, domain);
    return true;
  }

  Future<Map<String, dynamic>?> _applySessionCookies(
    String url,
    Map<String, String> headers,
  ) async {
    final domain = WebSessionService.domainKeyFor(url);
    // No saved login for this domain: send the request unauthenticated, as it
    // would have gone out anyway, rather than prompt for and record a grant
    // against a credential that does not exist. Returning before the cookie
    // merge also means no cookie can be attached without a grant even if a
    // login is saved concurrently.
    if (await _webSessionService.getSession(domain) == null) {
      return null;
    }
    final granted = await _ensureDomainGrant(domain);
    if (granted == null) {
      return {'status': 'error', 'error': 'permission_required'};
    }
    if (!granted) {
      return {'status': 'error', 'error': 'permission_denied'};
    }

    final cookieHeader = await _webSessionService.cookieHeaderFor(url);
    if (cookieHeader.isNotEmpty) {
      final existingKey = headers.keys.firstWhere(
        (k) => k.toLowerCase() == 'cookie',
        orElse: () => '',
      );
      if (existingKey.isEmpty) {
        headers['Cookie'] = cookieHeader;
      } else {
        // Preserve any cookies the plugin set explicitly, then append ours.
        headers[existingKey] = '${headers[existingKey]}; $cookieHeader';
      }
    }
    return null;
  }

  /// Builds a `multipart/form-data` request body from a list of part specs.
  ///
  /// Each part is a map with `name` and one of `text`, `dataBase64`, or
  /// `attachmentPath` (streamed from disk without a base64 round-trip through
  /// the plugin), plus optional `filename` and `mimeType`.
  Future<({List<int> bytes, String contentType})> _buildMultipartBody(
    List<dynamic> parts,
  ) async {
    final boundary =
        '----SynapseBoundary${DateTime.now().microsecondsSinceEpoch}';
    final builder = BytesBuilder();
    // UTF-8 (not ASCII) so non-ASCII names/filenames don't throw; browsers send
    // form-data field values as UTF-8 too.
    void writeHeader(String s) => builder.add(utf8.encode(s));
    // Prevent header injection / malformed parts: drop CR/LF and escape quotes
    // and backslashes in quoted-string header values.
    String quote(String v) => v
        .replaceAll(RegExp(r'[\r\n]'), '')
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"');

    for (final raw in parts) {
      if (raw is! Map) {
        continue;
      }
      final part = Map<String, dynamic>.from(raw);
      final name = (part['name'] as String?)?.trim() ?? '';
      if (name.isEmpty) {
        continue;
      }
      final filename = part['filename'] as String?;
      var mimeType = part['mimeType'] as String?;

      List<int> contentBytes;
      if (part['attachmentPath'] != null) {
        final attachment = await _readAttachmentFromPath(
          part['attachmentPath'].toString(),
        );
        if (attachment == null) {
          throw ArgumentError(
            'Attachment not found: ${part['attachmentPath']}',
          );
        }
        contentBytes = base64Decode(attachment['data'] as String);
        mimeType ??= attachment['mimeType'] as String?;
      } else if (part['dataBase64'] != null) {
        contentBytes = base64Decode(part['dataBase64'].toString());
      } else if (part['text'] != null) {
        contentBytes = utf8.encode(part['text'].toString());
      } else {
        contentBytes = const [];
      }

      final disposition = StringBuffer(
        'Content-Disposition: form-data; name="${quote(name)}"',
      );
      if (filename != null) {
        disposition.write('; filename="${quote(filename)}"');
      }
      writeHeader('--$boundary\r\n');
      writeHeader('$disposition\r\n');
      if (mimeType != null && mimeType.isNotEmpty) {
        writeHeader('Content-Type: ${quote(mimeType)}\r\n');
      }
      writeHeader('\r\n');
      builder.add(contentBytes);
      writeHeader('\r\n');
    }
    writeHeader('--$boundary--\r\n');

    return (
      bytes: builder.takeBytes(),
      contentType: 'multipart/form-data; boundary=$boundary',
    );
  }

  Future<Map<String, dynamic>?> _readAttachmentFromPath(
    String attachmentPath,
  ) async {
    final isValid = await _databaseService.verifyAttachmentPath(attachmentPath);
    if (!isValid) {
      LoggerService.warning(
        '[Synapse.readAttachment] Attachment path not found in database: $attachmentPath',
      );
      return null;
    }

    final file = File(attachmentPath);
    if (!await file.exists()) {
      LoggerService.warning(
        '[Synapse.readAttachment] Attachment file not found: $attachmentPath',
      );
      return null;
    }

    final bytes = await file.readAsBytes();
    final fileName = attachmentPath.split('/').last;
    final mimeType = _getMimeTypeFromExtension(
      FileTypeUtils.getFileExtension(fileName),
    );
    final base64Data = base64Encode(bytes);
    return {'data': base64Data, 'mimeType': mimeType};
  }

  /// Creates a note per entry in [notesData], returning the ids of the notes
  /// that were created, in the order of the inputs that succeeded.
  Future<List<String>> _saveNotesFromJavaScript(List<dynamic> notesData) async {
    final modificationService = getIt<NoteModificationService>();
    final savedNoteIds = <String>[];
    for (final noteData in notesData) {
      if (noteData is! Map<String, dynamic>) continue;
      try {
        final note = await modificationService.buildNote(noteData);
        await appProvider.addNote(note);
        savedNoteIds.add(note.id);
        LoggerService.debug(
          '[Synapse.saveNotes] Saved note: ${note.id} - ${note.title}',
        );
      } catch (e) {
        LoggerService.error(
          '[Synapse.saveNotes] Error saving note: $e',
          error: e,
        );
      }
    }
    return savedNoteIds;
  }

  Future<int> _deleteNotesFromJavaScript(List<dynamic> noteIdsData) async {
    // Validate and collect note IDs first
    final noteIds = <String>[];
    for (final noteIdData in noteIdsData) {
      if (noteIdData is! String || noteIdData.trim().isEmpty) {
        LoggerService.warning(
          '[Synapse.deleteNotes] Invalid note ID: $noteIdData',
        );
        continue;
      }
      noteIds.add(noteIdData.trim());
    }

    if (noteIds.isEmpty) {
      return 0;
    }

    // Deleting a transient block EMPTIES one block; it never removes a note.
    // Routing it through the note-deletion gate would show "Allow Note
    // Deletion? ... This action cannot be undone" naming the whole parent note,
    // which misstates the effect. Those ids go through the modification gate
    // instead, where the block scope notice is shown.
    final blockIds = noteIds.where((id) => _blockScopeFor(id) != null).toList();
    final realNoteIds = noteIds
        .where((id) => _blockScopeFor(id) == null)
        .toList();

    if (realNoteIds.isNotEmpty && !_sessionApprovedDeletions) {
      if (onDeletionApprovalRequest != null) {
        final approved = await onDeletionApprovalRequest!(this, realNoteIds);
        if (!approved) {
          LoggerService.debug(
            '[Synapse.deleteNotes] User denied deletion of '
            '${realNoteIds.length} notes',
          );
          throw Exception('User denied the note deletion.');
        }
      } else {
        // No approval callback - block delete operations
        LoggerService.warning(
          '[Synapse.deleteNotes] No approval callback, blocking deletion',
        );
        throw Exception('Note deletion requires user approval.');
      }
    }

    for (final blockId in blockIds) {
      if (_sessionApprovedModifications) continue;
      if (onModificationRequest == null) {
        throw Exception('Modification not supported in this context.');
      }
      final approved = await onModificationRequest!(
        this,
        _realNoteId(blockId),
        <String, dynamic>{
          'content': {'action': 'replace', 'text': ''},
          ApprovalRequest.scopeBlockKey: true,
        },
      );
      if (!approved) {
        throw Exception('User denied modification.');
      }
    }

    var deletedCount = 0;
    for (final noteId in noteIds) {
      try {
        // Deleting a transient block note means removing that block from its
        // parent, never deleting the parent note itself.
        if (_blockScopeFor(noteId) != null) {
          final result = await _blockScopes!.writeBack(noteId, '');
          if (result.ok) {
            deletedCount++;
            LoggerService.debug(
              '[Synapse.deleteNotes] Deleted block scope: $noteId',
            );
          } else {
            LoggerService.warning(
              '[Synapse.deleteNotes] Failed to delete block $noteId: '
              '${result.error}',
            );
          }
          continue;
        }

        await appProvider.deleteNote(noteId);
        deletedCount++;
        LoggerService.debug('[Synapse.deleteNotes] Deleted note: $noteId');
      } catch (e) {
        LoggerService.error(
          '[Synapse.deleteNotes] Error deleting note $noteId: $e',
          error: e,
        );
      }
    }
    return deletedCount;
  }

  String _getExtensionFromMimeType(String mimeType) {
    switch (mimeType.toLowerCase()) {
      case 'image/jpeg':
      case 'image/jpg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/gif':
        return 'gif';
      case 'image/svg+xml':
        return 'svg';
      case 'image/webp':
        return 'webp';
      case 'text/plain':
        return 'txt';
      case 'text/html':
        return 'html';
      case 'text/css':
        return 'css';
      case 'application/javascript':
        return 'js';
      case 'application/json':
        return 'json';
      case 'application/pdf':
        return 'pdf';
      case 'application/zip':
        return 'zip';
      default:
        return 'bin';
    }
  }

  String _getMimeTypeFromExtension(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'svg':
        return 'image/svg+xml';
      case 'webp':
        return 'image/webp';
      case 'txt':
        return 'text/plain';
      case 'html':
        return 'text/html';
      case 'css':
        return 'text/css';
      case 'js':
        return 'application/javascript';
      case 'json':
        return 'application/json';
      case 'pdf':
        return 'application/pdf';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }

  /// Applies `updateNotes` entries, returning how many were written plus a
  /// message for each one that was refused.
  ///
  /// Per-entry failures are collected rather than thrown: one bad entry must not
  /// abort the rest. They are reported back to the plugin so a refusal (a block
  /// that moved, a dead temp file, an immutable note) is actionable instead of
  /// looking like a silent success.
  Future<({int updatedCount, List<String> errors})> _updateNotesFromJavaScript(
    List<dynamic> notesData,
  ) async {
    var updatedCount = 0;
    final errors = <String>[];
    final modificationService = getIt<NoteModificationService>();

    for (final noteData in notesData) {
      if (noteData is! Map<String, dynamic>) continue;

      final id = noteData['id']?.toString();
      if (id == null || id.isEmpty) {
        LoggerService.warning(
          '[Synapse.updateNotes] Skipping update for note without ID',
        );
        errors.add('An update was skipped because it had no note id.');
        continue;
      }

      try {
        // A transient block note has no database row: route the write through
        // the block scope so it lands on the parent note's block range.
        if (_blockScopeFor(id) != null) {
          if (await _updateBlockScopedNote(id, noteData)) {
            updatedCount++;
          }
          continue;
        }

        final existingNote = await _databaseService.getNote(id);
        if (existingNote == null) {
          LoggerService.warning('[Synapse.updateNotes] Note not found: $id');
          errors.add('Note not found: $id');
          continue;
        }

        // Check for granular modification mode
        if (noteData.containsKey('modification') &&
            noteData['modification'] is Map<String, dynamic>) {
          // Use NoteModificationService for granular updates
          final modification = noteData['modification'] as Map<String, dynamic>;

          // Process attachments in modification if present
          if (modification.containsKey('attachments')) {
            final attMod = modification['attachments'] as Map<String, dynamic>?;
            if (attMod != null && attMod.containsKey('added')) {
              final addedPaths = <String>[];
              for (final att in (attMod['added'] as List? ?? [])) {
                addedPaths.add(
                  await modificationService.processAttachment(att),
                );
              }
              modification['attachments'] = {...attMod, 'added': addedPaths};
            }
          }

          if (NoteModificationService.isNoOpModification(modification)) {
            // Preserve the pre-existing plugin contract: an empty or
            // unrecognized-fields-only modification is a silent no-op
            // success, not an error.
            updatedCount++;
            LoggerService.debug(
              '[Synapse.updateNotes] No-op modification for note: $id',
            );
          } else {
            await modificationService.applyModifications(id, modification);
            updatedCount++;
            LoggerService.debug(
              '[Synapse.updateNotes] Applied granular modification to note: $id',
            );
          }
        } else {
          // Full replacement mode (existing behavior)
          final updatedNote = await _mergeNoteData(existingNote, noteData);
          await appProvider.updateNote(updatedNote);
          updatedCount++;
          LoggerService.debug(
            '[Synapse.updateNotes] Updated note: ${updatedNote.id} - ${updatedNote.title}',
          );
        }
      } catch (e) {
        LoggerService.error(
          '[Synapse.updateNotes] Error updating note $id: $e',
          error: e,
        );
        // Only messages the HOST authored are safe to hand to plugin JS; see
        // PluginFacingException. A '/'-based heuristic was wrong here — it
        // swallowed our own "Use action append/prepend/replace" message.
        errors.add(
          e is PluginFacingException
              ? e.message
              : 'Updating note $id failed. See the app log for details.',
        );
      }
    }
    return (updatedCount: updatedCount, errors: errors);
  }

  /// Applies an `updateNotes` entry that targets a transient block note.
  ///
  /// A block scope is deliberately **content-only**: the write is spliced back
  /// over the block's range in the parent note, and note-level fields (title,
  /// tags, links, subnotes, explicit attachments, task fields, pinned…) are
  /// ignored with a warning. Reasons:
  ///  * consent — the user approved "change this block", not "retag the note";
  ///  * shape — in full-replacement mode `tags`/`attachments` are Lists, but
  ///    [NoteModificationService.applyModifications] requires the granular
  ///    object form, so forwarding them threw and took the content write down
  ///    with it;
  ///  * atomicity — a forwarded parent write that committed before a failed
  ///    splice left the note half-updated.
  /// A plugin that genuinely wants note-level changes targets `parentNoteId`
  /// (exposed on the note object), which prompts for the real note.
  ///
  /// Returns true when something was written.
  Future<bool> _updateBlockScopedNote(
    String tempNoteId,
    Map<String, dynamic> noteData,
  ) async {
    final blockScopes = _blockScopes;
    final scope = blockScopes?.lookup(tempNoteId);
    if (blockScopes == null || scope == null) return false;

    String? newText;
    String? pendingAction;
    String? pendingActionText;
    Iterable<String> ignored = const [];

    if (noteData['modification'] is Map<String, dynamic>) {
      final modification = noteData['modification'] as Map<String, dynamic>;

      if (modification['content'] is Map<String, dynamic>) {
        final contentMod = modification['content'] as Map<String, dynamic>;
        final section = contentMod['section'] as String?;
        if (section != null && section.isNotEmpty) {
          throw PluginFacingException(
            'Section-scoped content modifications are not supported when '
            'operating on a block (note $tempNoteId is a block of '
            '${scope.parentNoteId}). Use action append/prepend/replace.',
          );
        }
        final action = contentMod['action'] as String? ?? 'no-op';
        final text = contentMod['text'] as String? ?? '';
        // Reject an unknown action rather than letting
        // applyWholeContentAction's default branch write the text back
        // unchanged: that reports a successful update for a note nothing
        // happened to, which is worse than an error.
        const supported = {'append', 'prepend', 'replace', 'no-op'};
        if (!supported.contains(action)) {
          throw PluginFacingException(
            'Unsupported content action "$action" for a block. Use '
            'append, prepend or replace.',
          );
        }
        if (action == 'no-op') {
          throw PluginFacingException(
            'Nothing to do: content action was "no-op" for block $tempNoteId.',
          );
        }
        // Empty text is a genuine no-op for append/prepend, but for 'replace'
        // it clears the block — which the full-replacement path also allows, so
        // rejecting it here would make the two modes disagree.
        if (text.isEmpty && action != 'replace') {
          throw PluginFacingException(
            'Nothing to do: "$action" with empty text leaves block '
            '$tempNoteId unchanged. To remove the block, call '
            'Synapse.deleteNotes with this id.',
          );
        }
        // Deliberately NOT computed here: the action must be applied to the
        // block's text as read inside writeBack's lock, or two overlapping
        // appends both start from the same snapshot and one is silently lost.
        pendingAction = action;
        pendingActionText = text;
      } else {
        throw PluginFacingException(
          'A block update must include a content modification. Note-level '
          'fields are ignored for a block; target parentNoteId '
          '(${scope.parentNoteId}) to change the note itself.',
        );
      }
      ignored = modification.keys.where((k) => k != 'content');
    } else {
      if (noteData.containsKey('content')) {
        newText = noteData['content']?.toString() ?? '';
      } else {
        throw PluginFacingException(
          'A block update must include "content". Note-level fields are '
          'ignored for a block; target parentNoteId (${scope.parentNoteId}) '
          'to change the note itself.',
        );
      }
      ignored = noteData.keys.where((k) => k != 'content' && k != 'id');
    }

    if (ignored.isNotEmpty) {
      LoggerService.warning(
        '[Synapse.updateNotes] Ignoring note-level fields '
        '${ignored.toList()} for block-scoped note $tempNoteId - a block scope '
        'only changes content. Target parentNoteId '
        '(${scope.parentNoteId}) to change the note itself.',
      );
    }

    final result = pendingAction != null
        ? await blockScopes.applyContentAction(
            tempNoteId,
            pendingAction,
            pendingActionText ?? '',
          )
        : await blockScopes.writeBack(tempNoteId, newText!);
    if (!result.ok) {
      // writeBack's messages are host-authored and actionable.
      throw PluginFacingException(result.error ?? 'Failed to update block.');
    }
    return true;
  }

  Future<Note> _mergeNoteData(
    Note existing,
    Map<String, dynamic> changes,
  ) async {
    String? title = existing.title;
    if (changes.containsKey('title')) {
      title = changes['title']?.toString().trim() ?? '';
      if (title.isEmpty) title = existing.title;
    }

    String? content = existing.content;
    if (changes.containsKey('content')) {
      content = changes['content']?.toString().trim() ?? existing.content;
    }

    NoteType type = existing.type;
    if (changes.containsKey('type')) {
      final typeStr = changes['type'].toString().toLowerCase();
      type = typeStr == 'task' ? NoteType.task : NoteType.note;
    }

    // Subnotes: replace entire list if present
    List<SubNote> subNotes = existing.subNotes;
    final subNotesData = changes['subNotes'] ?? changes['subnotes'];
    if (subNotesData is List) {
      subNotes = [];
      for (final subNoteData in subNotesData) {
        if (subNoteData is Map<String, dynamic>) {
          final name =
              (subNoteData['name'] ?? subNoteData['title'])
                  ?.toString()
                  .trim() ??
              'Untitled Task';
          subNotes.add(
            SubNote(
              id: const Uuid().v4(),
              name: name,
              content: subNoteData['content']?.toString().trim() ?? '',
              createdAt: DateTime.now(),
              isCompleted:
                  subNoteData['isCompleted'] == true ||
                  subNoteData['is_completed'] == true,
            ),
          );
        }
      }
    }

    // Tags: replace entire list if present
    List<String> tags = existing.tags;
    if (changes.containsKey('tags') && changes['tags'] is List) {
      tags = (changes['tags'] as List).map((e) => e.toString()).toList();
    }

    // Attachments: replace entire list if present
    final modificationService = getIt<NoteModificationService>();
    List<String> attachmentPaths = existing.attachmentPaths;
    if (changes.containsKey('attachments') && changes['attachments'] is List) {
      attachmentPaths = [];
      for (final attachment in (changes['attachments'] as List)) {
        attachmentPaths.add(
          await modificationService.processAttachment(attachment),
        );
      }
    }

    // Task fields
    String? scheduledAt = existing.scheduledAt;
    if (changes.containsKey('scheduledAt'))
      scheduledAt = changes['scheduledAt']?.toString();

    String? completeBy = existing.completeBy;
    if (changes.containsKey('completeBy'))
      completeBy = changes['completeBy']?.toString();

    TaskStatus? status = existing.status;
    if (changes.containsKey('status')) {
      final statusStr = changes['status'].toString().toLowerCase();
      switch (statusStr) {
        case 'todo':
          status = TaskStatus.todo;
          break;
        case 'in_progress':
          status = TaskStatus.inProgress;
          break;
        case 'complete':
          status = TaskStatus.complete;
          break;
        case 'abandoned':
          status = TaskStatus.abandoned;
          break;
        default:
          status = TaskStatus.todo;
      }
    }

    double? completionPercentage = existing.completionPercentage;
    if (changes.containsKey('completionPercentage')) {
      completionPercentage =
          (changes['completionPercentage'] as num?)?.toDouble() ?? 0.0;
    }

    bool pinned = existing.pinned;
    if (changes.containsKey('pinned')) {
      pinned = changes['pinned'] == true;
    }

    bool isArchived = existing.isArchived;
    if (changes.containsKey('isArchived')) {
      isArchived = changes['isArchived'] == true;
    }

    return existing.copyWith(
      title: title,
      content: content,
      type: type,
      subNotes: subNotes,
      tags: tags,
      attachmentPaths: attachmentPaths,
      scheduledAt: scheduledAt,
      completeBy: completeBy,
      status: status,
      completionPercentage: completionPercentage,
      pinned: pinned,
      isArchived: isArchived,
      updatedAt: DateTime.now(),
    );
  }
}

class _ValidatedChatOptions {
  const _ValidatedChatOptions({
    required this.temperature,
    required this.topK,
    required this.topP,
    required this.attachments,
  });

  final double? temperature;
  final int? topK;
  final double? topP;
  final List<dynamic> attachments;
}
