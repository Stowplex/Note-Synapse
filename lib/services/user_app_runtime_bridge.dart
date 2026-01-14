import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:uuid/uuid.dart';

import '../models/note.dart';
import '../models/user_app.dart';
import '../providers/app_provider.dart';
import '../services/ai_service.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import '../services/user_app_service.dart';
import '../utils/file_type_utils.dart';
import '../utils/synapse_temp_utils.dart';
import 'note_modification_service.dart';
import 'sql_query_service.dart';

typedef OpenNoteCallback = Future<void> Function(Note note, bool replaceWindow);
typedef OpenConversationsCallback =
    Future<void> Function(List<Note> notes, bool immersiveMode);
typedef OpenAIActionsCallback = Future<void> Function(List<Note> notes);
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
    this.onOpenNote,
    this.onOpenConversations,
    this.onOpenAIActions,
    this.onModificationRequest,
    this.onSqlWriteApprovalRequest,
    this.onDeletionApprovalRequest,
  }) : _selectedNotes = selectedNotes ?? const [];

  final UserApp app;
  final AppProvider appProvider;
  final int revisionNumber;
  final bool isInteractive;
  final List<Note> _selectedNotes;
  final OpenNoteCallback? onOpenNote;
  final OpenConversationsCallback? onOpenConversations;
  final OpenAIActionsCallback? onOpenAIActions;
  final ModificationRequestCallback? onModificationRequest;
  final SqlWriteApprovalCallback? onSqlWriteApprovalRequest;
  final DeletionApprovalCallback? onDeletionApprovalRequest;

  bool _sessionApprovedModifications = false;
  bool _sessionApprovedSqlWrites = false;
  bool _sessionApprovedDeletions = false;

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

  final DatabaseService _databaseService = DatabaseService();
  late final SqlQueryService _sqlQueryService = SqlQueryService(
    databaseService: _databaseService,
  );
  static final HttpClient _proxyHttpClient = HttpClient()
    ..autoUncompress = true;

  /// Creates the bootstrap user script that initialises the Synapse namespace.
  UserScript buildBootstrapScript() {
    final notesJson = _buildSelectedNotesJson();
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
            const normalizedOptions = options ?? {};
            const hasExplicitOptions =
              normalizedOptions &&
              typeof normalizedOptions === 'object' &&
              !Array.isArray(normalizedOptions) &&
              (
                Object.prototype.hasOwnProperty.call(normalizedOptions, 'method') ||
                Object.prototype.hasOwnProperty.call(normalizedOptions, 'body') ||
                Object.prototype.hasOwnProperty.call(normalizedOptions, 'json') ||
                Object.prototype.hasOwnProperty.call(normalizedOptions, 'headers')
              );

            let headers = {};
            if (
              normalizedOptions &&
              typeof normalizedOptions === 'object' &&
              !Array.isArray(normalizedOptions)
            ) {
              if (hasExplicitOptions) {
                if (normalizedOptions.headers && typeof normalizedOptions.headers === 'object') {
                  headers = normalizedOptions.headers;
                }
              } else {
                headers = normalizedOptions;
              }
            }

            const payload = {
              url,
              method: hasExplicitOptions && normalizedOptions.method ? normalizedOptions.method : 'GET',
              headers,
              body: hasExplicitOptions ? normalizedOptions.body ?? null : null,
              json: hasExplicitOptions ? normalizedOptions.json ?? null : null,
            };

            const result = await window.flutter_inappwebview.callHandler('proxyFetch', payload);
            return result;
          },
          fetchWebPage: async (url) => {
            const result = await window.flutter_inappwebview.callHandler('fetchWebPage', url);
            return result;
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
          Notes: $notesJson,
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

  /// Registers all JavaScript handlers required by the Synapse runtime.
  void registerJavaScriptHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'runQuery',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final sql = args.first as String;
          LoggerService.debug('[Synapse.runQuery] Called with SQL: $sql');

          // Detect query type using SqlQueryService
          final queryType = _sqlQueryService.getQueryType(sql);
          final isReadOnly = _sqlQueryService.isReadOnlyQuery(sql);

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
            return {'success': true, 'data': result.data ?? []};
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
          final state = await UserAppService.getAppState(app.id);
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

          String? requestBody;
          final jsonBody = rawOptions['json'];
          if (jsonBody != null) {
            try {
              requestBody = jsonEncode(jsonBody);
              final contentTypeKey = headers.keys.firstWhere(
                (key) => key.toLowerCase() == HttpHeaders.contentTypeHeader,
                orElse: () => '',
              );
              if (contentTypeKey.isEmpty) {
                headers[HttpHeaders.contentTypeHeader] =
                    'application/json; charset=utf-8';
              }
            } catch (e) {
              throw ArgumentError('Failed to encode JSON body: $e');
            }
          } else if (rawOptions['body'] != null) {
            requestBody = rawOptions['body'].toString();
            final contentTypeKey = headers.keys.firstWhere(
              (key) => key.toLowerCase() == HttpHeaders.contentTypeHeader,
              orElse: () => '',
            );
            if (contentTypeKey.isEmpty) {
              headers[HttpHeaders.contentTypeHeader] =
                  'text/plain; charset=utf-8';
            }
          }

          LoggerService.debug(
            '[Synapse.proxyFetch] $method $urlRaw with headers: ${headers.keys.toList()}',
          );

          final request = await _proxyHttpClient.openUrl(method, uri);
          headers.forEach((key, value) {
            try {
              request.headers.set(key, value);
            } catch (e) {
              LoggerService.warning(
                '[Synapse.proxyFetch] Failed to set header "$key": $e',
              );
            }
          });

          if (requestBody != null && method != 'GET' && method != 'HEAD') {
            request.add(utf8.encode(requestBody));
          }

          final response = await request.close();
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
          var isText = normalizedMime.toLowerCase().startsWith('text/');
          switch (normalizedMime.toLowerCase()) {
            case 'application/json':
              isText = true;
              break;
            case 'application/javascript':
              isText = true;
              break;
            case 'application/xml':
              isText = true;
            default:
              break;
          }
          final data = isText
              ? utf8.decode(bytes, allowMalformed: true)
              : base64Encode(bytes);

          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.proxyFetch] Success (${response.statusCode}) in ${duration.inMilliseconds}ms',
          );

          return {
            'status': 'success',
            'statusCode': response.statusCode,
            'content': {'mime': normalizedMime, 'data': data},
          };
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

          if (isMultiPart) {
            LoggerService.debug(
              '[Synapse.chatAI] Using multi-part response mode',
            );
            final response = await AIService.chatAIMultiPart(
              prompt,
              temperature: validated.temperature,
              topK: validated.topK,
              topP: validated.topP,
              attachedFiles: attachments,
              modelHint: modelHint,
            );

            final duration = DateTime.now().difference(startTime);
            LoggerService.debug(
              '[Synapse.chatAI] Multi-part success - ${response.length} parts in ${duration.inMilliseconds}ms',
            );
            return {'success': true, 'response': response};
          } else {
            final response = await AIService.chatAI(
              prompt,
              temperature: validated.temperature,
              topK: validated.topK,
              topP: validated.topP,
              attachedFiles: attachments,
              modelHint: modelHint,
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
          final savedCount = await _saveNotesFromJavaScript(notesData);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.saveNotes] Success - Saved $savedCount notes in ${duration.inMilliseconds}ms',
          );
          return {'success': true, 'savedCount': savedCount};
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

          final note = await _databaseService.getNote(noteId);
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
                targetNoteId = noteData['id']?.toString() ?? 'unknown';

                // If granular modification, pass that. Otherwise pass the note data.
                if (noteData.containsKey('modification') &&
                    noteData['modification'] is Map) {
                  modificationData = noteData['modification'];
                } else {
                  modificationData = Map.from(noteData)..remove('id');
                }
              } else {
                // Batch update: Itemize first 20 notes
                final updates = <Map<String, dynamic>>[];
                final NOTE_LIMIT = 20;

                for (var i = 0; i < notesData.length && i < NOTE_LIMIT; i++) {
                  final item = notesData[i];
                  if (item is Map<String, dynamic>) {
                    final id = item['id']?.toString() ?? 'unknown';
                    // Extract modification similar to single case
                    Map<String, dynamic> changes;
                    if (item.containsKey('modification') &&
                        item['modification'] is Map) {
                      changes = item['modification'];
                    } else {
                      changes = Map.from(item)..remove('id');
                    }

                    updates.add({'id': id, 'changes': changes});
                  }
                }

                modificationData = <String, dynamic>{
                  'isBatch': true,
                  'count': notesData.length,
                  'updates': updates,
                  // Keep noteIds for legacy/other checks if needed?
                  'noteIds': notesData
                      .whereType<Map<String, dynamic>>()
                      .map((n) => n['id']?.toString() ?? 'unknown')
                      .toList(),
                };
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

          final updatedCount = await _updateNotesFromJavaScript(notesData);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.updateNotes] Success - Updated $updatedCount notes in ${duration.inMilliseconds}ms',
          );
          return {'success': true, 'updatedCount': updatedCount};
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

          final notes = <Note>[];
          for (final noteData in notesData) {
            if (noteData is Map<String, dynamic> && noteData['id'] != null) {
              final noteId = noteData['id'] as String;
              final note = await _databaseService.getNote(noteId);
              if (note != null) {
                notes.add(note);
              } else {
                LoggerService.warning(
                  '[Synapse.openConversations] Note not found: $noteId',
                );
              }
            } else if (noteData is String) {
              final note = await _databaseService.getNote(noteData);
              if (note != null) {
                notes.add(note);
              } else {
                LoggerService.warning(
                  '[Synapse.openConversations] Note not found: $noteData',
                );
              }
            }
          }

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

          final notes = <Note>[];
          for (final noteData in notesData) {
            if (noteData is Map<String, dynamic> && noteData['id'] != null) {
              final noteId = noteData['id'] as String;
              final note = await _databaseService.getNote(noteId);
              if (note != null) {
                notes.add(note);
              } else {
                LoggerService.warning(
                  '[Synapse.openAIActions] Note not found: $noteId',
                );
              }
            } else if (noteData is String) {
              final note = await _databaseService.getNote(noteData);
              if (note != null) {
                notes.add(note);
              } else {
                LoggerService.warning(
                  '[Synapse.openAIActions] Note not found: $noteData',
                );
              }
            }
          }

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

  String _buildSelectedNotesJson() {
    if (_selectedNotes.isEmpty) {
      return '[]';
    }

    final notesData = _selectedNotes
        .map(
          (note) => {
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
          },
        )
        .toList();
    return jsonEncode(notesData);
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

  Future<int> _saveNotesFromJavaScript(List<dynamic> notesData) async {
    final modificationService = NoteModificationService();
    var savedCount = 0;
    for (final noteData in notesData) {
      if (noteData is! Map<String, dynamic>) continue;
      try {
        final note = await modificationService.buildNote(noteData);
        await appProvider.addNote(note);
        savedCount++;
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
    return savedCount;
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

    // Check approval before deleting
    if (!_sessionApprovedDeletions) {
      if (onDeletionApprovalRequest != null) {
        final approved = await onDeletionApprovalRequest!(this, noteIds);
        if (!approved) {
          LoggerService.debug(
            '[Synapse.deleteNotes] User denied deletion of ${noteIds.length} notes',
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

    var deletedCount = 0;
    for (final noteId in noteIds) {
      try {
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

  Future<int> _updateNotesFromJavaScript(List<dynamic> notesData) async {
    var updatedCount = 0;
    final modificationService = NoteModificationService();

    for (final noteData in notesData) {
      if (noteData is! Map<String, dynamic>) continue;

      final id = noteData['id']?.toString();
      if (id == null || id.isEmpty) {
        LoggerService.warning(
          '[Synapse.updateNotes] Skipping update for note without ID',
        );
        continue;
      }

      try {
        final existingNote = await _databaseService.getNote(id);
        if (existingNote == null) {
          LoggerService.warning('[Synapse.updateNotes] Note not found: $id');
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

          await modificationService.applyModifications(id, modification);
          updatedCount++;
          LoggerService.debug(
            '[Synapse.updateNotes] Applied granular modification to note: $id',
          );
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
      }
    }
    return updatedCount;
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
    final modificationService = NoteModificationService();
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
