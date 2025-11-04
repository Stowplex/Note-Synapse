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
import '../utils/file_utils.dart';

typedef OpenNoteCallback = Future<void> Function(Note note, bool replaceWindow);

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
  }) : _selectedNotes = selectedNotes ?? const [];

  final UserApp app;
  final AppProvider appProvider;
  final int revisionNumber;
  final bool isInteractive;
  final List<Note> _selectedNotes;
  final OpenNoteCallback? onOpenNote;

  final DatabaseService _databaseService = DatabaseService();
  static final HttpClient _proxyHttpClient = HttpClient()
    ..autoUncompress = true;

  /// Creates the bootstrap user script that initialises the Synapse namespace.
  UserScript buildBootstrapScript() {
    final notesJson = _buildSelectedNotesJson();
    final toolEnvFlag = isInteractive ? 'true' : 'false';

    final script = '''
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
          proxyFetch: async (url, headers = {}) => {
            const result = await window.flutter_inappwebview.callHandler('proxyFetch', url, headers ?? {});
            return result;
          },
          readAttachment: async (attachmentPath) => {
            const result = await window.flutter_inappwebview.callHandler('readAttachment', attachmentPath);
            return result;
          },
          saveNotes: async (notes) => {
            const result = await window.flutter_inappwebview.callHandler('saveNotes', notes ?? []);
            return result;
          },
          openNote: async (noteId, replaceWindow = false) => {
            const result = await window.flutter_inappwebview.callHandler('openNote', noteId, replaceWindow === true);
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
          final result = await _databaseService.executeRawQuery(sql);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug('[Synapse.runQuery] Success - Returned ${result.length} rows in ${duration.inMilliseconds}ms');
          return {'success': true, 'data': result};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.runQuery] Error after ${duration.inMilliseconds}ms: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'storeAppState',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final state = (args.isNotEmpty ? args.first : <String, dynamic>{}) as Map<String, dynamic>;
          LoggerService.debug('[Synapse.storeAppState] Called with state keys: ${state.keys.toList()}');
          await appProvider.saveAppState(app.id, state);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug('[Synapse.storeAppState] Success - State saved in ${duration.inMilliseconds}ms');
          return {'success': true};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.storeAppState] Error after ${duration.inMilliseconds}ms: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'loadAppState',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          LoggerService.debug('[Synapse.loadAppState] Called for app: ${app.id}');
          final state = await UserAppService.getAppState(app.id);
          final duration = DateTime.now().difference(startTime);
          if (state != null) {
            LoggerService.debug('[Synapse.loadAppState] Success - State loaded with keys: ${state.keys.toList()} in ${duration.inMilliseconds}ms');
          } else {
            LoggerService.debug('[Synapse.loadAppState] Success - No state found in ${duration.inMilliseconds}ms');
          }
          return {'success': true, 'data': state};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.loadAppState] Error after ${duration.inMilliseconds}ms: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'proxyFetch',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          if (args.isEmpty || args.first == null || (args.first as String).trim().isEmpty) {
            throw ArgumentError('URL is required');
          }

          final urlRaw = (args.first as String).trim();
          final uri = Uri.parse(urlRaw);

          final rawHeaders = args.length > 1 ? args[1] : null;
          final headers = <String, String>{};
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

          LoggerService.debug('[Synapse.proxyFetch] Fetching $urlRaw with headers: ${headers.keys.toList()}');

          final request = await _proxyHttpClient.getUrl(uri);
          headers.forEach((key, value) {
            try {
              request.headers.set(key, value);
            } catch (e) {
              LoggerService.warning('[Synapse.proxyFetch] Failed to set header "$key": $e');
            }
          });

          final response = await request.close();
          final bytesBuilder = BytesBuilder(copy: false);
          await for (final chunk in response) {
            bytesBuilder.add(chunk);
          }
          final bytes = bytesBuilder.takeBytes();

          final mime = response.headers.value(HttpHeaders.contentTypeHeader) ?? 'application/octet-stream';
          final normalizedMime = mime.split(';').first.trim().isNotEmpty
              ? mime.split(';').first.trim()
              : 'application/octet-stream';
          final isText = normalizedMime.toLowerCase().startsWith('text/');
          final data = isText
              ? utf8.decode(bytes, allowMalformed: true)
              : base64Encode(bytes);

          final duration = DateTime.now().difference(startTime);
          LoggerService.debug('[Synapse.proxyFetch] Success (${response.statusCode}) in ${duration.inMilliseconds}ms');

          return {
            'status': 'success',
            'statusCode': response.statusCode,
            'content': {
              'mime': normalizedMime,
              'data': data,
            },
          };
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.proxyFetch] Error after ${duration.inMilliseconds}ms: $e', error: e);
          return {
            'status': 'error',
            'error': e.toString(),
          };
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'chatAI',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final prompt = args.first as String;
          final options = args.length > 1 ? args[1] as Map<String, dynamic>? : null;
          LoggerService.debug('[Synapse.chatAI] Called with prompt: ${prompt.length > 100 ? '${prompt.substring(0, 100)}...' : prompt}');
          LoggerService.debug('[Synapse.chatAI] Raw options received: $options');

          final validated = _validateChatOptions(options ?? const {});
          final attachments = await _processMixedAttachments(validated.attachments);

          final response = await AIService.chatAI(
            prompt,
            temperature: validated.temperature,
            topK: validated.topK,
            topP: validated.topP,
            attachedFiles: attachments,
          );

          final duration = DateTime.now().difference(startTime);
          LoggerService.debug('[Synapse.chatAI] Success - Response length: ${response.length} in ${duration.inMilliseconds}ms');
          return {'success': true, 'response': response};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.chatAI] Error after ${duration.inMilliseconds}ms: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'log',
      callback: (args) async {
        try {
          final message = args.isNotEmpty ? args.first?.toString() ?? '' : '';
          final level = args.length > 1 ? args[1]?.toString().toUpperCase() ?? 'LOG' : 'LOG';
          LoggerService.info('[UserApp.$level] $message');
        } catch (e) {
          LoggerService.error('[UserApp.LOG] Error in log handler: $e', error: e);
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
          LoggerService.debug('[UserApp.CLIPBOARD] Text copied to clipboard: ${text.length > 50 ? '${text.substring(0, 50)}...' : text}');
          return {'success': true};
        } catch (e) {
          LoggerService.error('[UserApp.CLIPBOARD] Error copying to clipboard: $e', error: e);
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
          LoggerService.debug('[Synapse.readAttachment] Called with path: $attachmentPath');
          final result = await _readAttachmentFromPath(attachmentPath);
          final duration = DateTime.now().difference(startTime);
          if (result != null) {
            LoggerService.debug('[Synapse.readAttachment] Success - Read ${result['data']?.length ?? 0} characters in ${duration.inMilliseconds}ms');
            return {'success': true, 'data': result['data'], 'mimeType': result['mimeType']};
          }
          LoggerService.warning('[Synapse.readAttachment] Attachment not found in database: $attachmentPath');
          return {'success': false, 'error': 'Attachment not found in database'};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.readAttachment] Error after ${duration.inMilliseconds}ms: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'saveNotes',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final notesData = (args.isNotEmpty ? args.first : []) as List<dynamic>;
          LoggerService.debug('[Synapse.saveNotes] Called with ${notesData.length} notes');
          final savedCount = await _saveNotesFromJavaScript(notesData);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug('[Synapse.saveNotes] Success - Saved $savedCount notes in ${duration.inMilliseconds}ms');
          return {'success': true, 'savedCount': savedCount};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.saveNotes] Error after ${duration.inMilliseconds}ms: $e', error: e);
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
            return {'success': false, 'error': 'openNote not supported in this context'};
          }

          final noteId = args.first as String;
          final replaceWindow = args.length > 1 ? (args[1] as bool? ?? false) : false;
          LoggerService.debug('[Synapse.openNote] Called with noteId: $noteId, replaceWindow: $replaceWindow');

          final note = await _databaseService.getNote(noteId);
          if (note == null) {
            final duration = DateTime.now().difference(startTime);
            LoggerService.warning('[Synapse.openNote] Note not found: $noteId after ${duration.inMilliseconds}ms');
            return {'success': false, 'error': 'Note not found: $noteId'};
          }

          await onOpenNote!(note, replaceWindow);
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug('[Synapse.openNote] Success - Opening note: ${note.title} in ${duration.inMilliseconds}ms');
          return {'success': true};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.openNote] Error after ${duration.inMilliseconds}ms: $e', error: e);
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
        LoggerService.warning('[SynapseUser] Dependency not found for path: $path');
        return CustomSchemeResponse(
          contentType: 'text/plain',
          data: Uint8List.fromList(utf8.encode('// Dependency not found: $path')),
        );
      }

      final bytes = dependency['bytes'] as List<int>;
      LoggerService.debug('[SynapseUser] Found dependency: ${bytes.length} bytes');
      final contentType = _getMimeTypeFromExtension(FileTypeUtils.getFileExtension(path));

      return CustomSchemeResponse(
        contentType: contentType,
        data: Uint8List.fromList(bytes),
      );
    } catch (e) {
      LoggerService.error('[SynapseUser] Error handling synapse_user scheme: $e', error: e);
      return CustomSchemeResponse(
        contentType: 'text/plain',
        data: Uint8List.fromList(utf8.encode('// Error loading dependency: $e')),
      );
    }
  }

  String _buildSelectedNotesJson() {
    if (_selectedNotes.isEmpty) {
      return '[]';
    }

    final notesData = _selectedNotes.map((note) => {
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
        }).toList();
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
        throw Exception('Parameter validation failed: temperature must be a number, got ${tempValue.runtimeType}');
      }
    }

    if (options.containsKey('topK')) {
      final topKValue = options['topK'];
      if (topKValue is int) {
        topK = topKValue;
      } else if (topKValue is double && topKValue == topKValue.roundToDouble()) {
        topK = topKValue.round();
      } else {
        throw Exception('Parameter validation failed: topK must be an integer, got ${topKValue.runtimeType}');
      }
    }

    if (options.containsKey('topP')) {
      final topPValue = options['topP'];
      if (topPValue is num) {
        final value = topPValue.toDouble();
        if (value < 0 || value > 1) {
          throw Exception('Parameter validation failed: topP must be between 0.0 and 1.0, got $value');
        }
        topP = value;
      } else {
        throw Exception('Parameter validation failed: topP must be a number, got ${topPValue.runtimeType}');
      }
    }

    if (options.containsKey('attachments')) {
      final attachmentValue = options['attachments'];
      if (attachmentValue is List) {
        attachments = attachmentValue;
      } else {
        throw Exception('Parameter validation failed: attachments must be an array, got ${attachmentValue.runtimeType}');
      }
    }

    LoggerService.debug('[Synapse.chatAI] Validated parameters: temperature=$temperature, topK=$topK, topP=$topP, attachments=${attachments.length}');
    return _ValidatedChatOptions(
      temperature: temperature,
      topK: topK,
      topP: topP,
      attachments: attachments,
    );
  }

  Future<List<PlatformFile>> _processMixedAttachments(List<dynamic> attachments) async {
    if (attachments.isEmpty) {
      return const [];
    }

    final validAttachments = <PlatformFile>[];

    for (var i = 0; i < attachments.length; i++) {
      final attachment = attachments[i];
      try {
        if (attachment is String) {
          final attachmentPath = attachment;
          final isValid = await _databaseService.verifyAttachmentPath(attachmentPath);
          if (!isValid) {
            LoggerService.warning('[Synapse.chatAI] Warning: Attachment path not found in database: $attachmentPath');
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
            LoggerService.debug('[Synapse.chatAI] Added file attachment: $fileName (${bytes.length} bytes)');
          } else {
            LoggerService.warning('[Synapse.chatAI] Warning: Attachment file not found: $attachmentPath');
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
            final fileName = 'attachment_${DateTime.now().millisecondsSinceEpoch}.$extension';
            validAttachments.add(
              PlatformFile(
                name: fileName,
                path: '',
                size: bytes.length,
                bytes: bytes,
              ),
            );
            LoggerService.debug('[Synapse.chatAI] Added base64 attachment: $fileName (${bytes.length} bytes, $mimeType)');
          } else {
            LoggerService.warning('[Synapse.chatAI] Warning: Invalid base64 attachment object at index $i: missing type, mimeType, or data');
          }
        } else {
          LoggerService.warning('[Synapse.chatAI] Warning: Invalid attachment type at index $i: expected string or object, got ${attachment.runtimeType}');
        }
      } catch (e) {
        LoggerService.error('[Synapse.chatAI] Error processing attachment at index $i: $e', error: e);
      }
    }

    return validAttachments;
  }

  Future<Map<String, dynamic>?> _readAttachmentFromPath(String attachmentPath) async {
    final isValid = await _databaseService.verifyAttachmentPath(attachmentPath);
    if (!isValid) {
      LoggerService.warning('[Synapse.readAttachment] Attachment path not found in database: $attachmentPath');
      return null;
    }

    final file = File(attachmentPath);
    if (!await file.exists()) {
      LoggerService.warning('[Synapse.readAttachment] Attachment file not found: $attachmentPath');
      return null;
    }

    final bytes = await file.readAsBytes();
    final fileName = attachmentPath.split('/').last;
    final mimeType = _getMimeTypeFromExtension(FileTypeUtils.getFileExtension(fileName));
    final base64Data = base64Encode(bytes);
    return {
      'data': base64Data,
      'mimeType': mimeType,
    };
  }

  Future<int> _saveNotesFromJavaScript(List<dynamic> notesData) async {
    var savedCount = 0;
    for (final noteData in notesData) {
      if (noteData is! Map<String, dynamic>) continue;
      try {
        final note = await _createNoteFromJavaScriptData(noteData);
        await appProvider.addNote(note);
        savedCount++;
        LoggerService.debug('[Synapse.saveNotes] Saved note: ${note.id} - ${note.title}');
      } catch (e) {
        LoggerService.error('[Synapse.saveNotes] Error saving note: $e', error: e);
      }
    }
    return savedCount;
  }

  Future<Note> _createNoteFromJavaScriptData(Map<String, dynamic> data) async {
    final title = data['title']?.toString().trim() ?? '';
    if (title.isEmpty) {
      throw Exception('Note title is required and cannot be empty');
    }
    if (!data.containsKey('content')) {
      throw Exception('Note content is required and cannot be empty');
    }
    if (!data.containsKey('type')) {
      throw Exception('Note type is required');
    }

    final now = DateTime.now();
    final noteType = _parseNoteType(data['type'].toString());

    final subNotes = <SubNote>[];
    if (data['subNotes'] is List) {
      for (final subNoteData in (data['subNotes'] as List)) {
        if (subNoteData is Map<String, dynamic>) {
          subNotes.add(_createSubNoteFromJavaScriptData(subNoteData));
        }
      }
    }

    final attachmentPaths = <String>[];
    if (data['attachments'] is List) {
      for (final attachment in (data['attachments'] as List)) {
        attachmentPaths.add(await _processAttachmentFromJavaScript(attachment));
      }
    }

    String? scheduledAt;
    String? completeBy;
    TaskStatus? status;
    double? completionPercentage;
    if (noteType == NoteType.task) {
      scheduledAt = data['scheduledAt']?.toString();
      completeBy = data['completeBy']?.toString();
      status = data['status'] != null ? _parseTaskStatus(data['status'].toString()) : TaskStatus.todo;
      completionPercentage = data['completionPercentage'] != null ? (data['completionPercentage'] as num).toDouble() : 0.0;
    }

    return Note(
      id: const Uuid().v4(),
      title: title,
      content: data['content'].toString().trim(),
      type: noteType,
      createdAt: now,
      updatedAt: now,
      subNotes: subNotes,
      tags: const [],
      attachmentPaths: attachmentPaths,
      scheduledAt: scheduledAt,
      completeBy: completeBy,
      status: status,
      completionPercentage: completionPercentage,
      pinned: data['pinned'] == true,
      isArchived: data['isArchived'] == true,
    );
  }

  SubNote _createSubNoteFromJavaScriptData(Map<String, dynamic> data) {
    final name = data['name']?.toString().trim() ?? '';
    if (name.isEmpty) {
      throw Exception('SubNote name is required and cannot be empty');
    }

    return SubNote(
      id: const Uuid().v4(),
      name: name,
      content: data['content']?.toString().trim() ?? '',
      createdAt: DateTime.now(),
      isCompleted: data['isCompleted'] == true,
    );
  }

  NoteType _parseNoteType(String typeString) {
    switch (typeString.toLowerCase()) {
      case 'note':
        return NoteType.note;
      case 'task':
        return NoteType.task;
      default:
        throw Exception('Invalid note type: $typeString');
    }
  }

  TaskStatus _parseTaskStatus(String statusString) {
    switch (statusString.toLowerCase()) {
      case 'todo':
        return TaskStatus.todo;
      case 'in_progress':
        return TaskStatus.inProgress;
      case 'complete':
        return TaskStatus.complete;
      case 'abandoned':
        return TaskStatus.abandoned;
      default:
        return TaskStatus.todo;
    }
  }

  Future<String> _processAttachmentFromJavaScript(dynamic attachment) async {
    if (attachment is String) {
      final isValid = await _databaseService.verifyAttachmentPath(attachment);
      if (isValid) {
        return attachment;
      }
      throw Exception('Invalid attachment path: $attachment - file not found in database');
    } else if (attachment is Map<String, dynamic>) {
      if (attachment['type'] == 'base64' && attachment['data'] != null && attachment['fileName'] != null) {
        return await _saveBase64Attachment(attachment['data'], attachment['fileName']);
      }
      throw Exception('Invalid base64 attachment format: missing type, data, or fileName');
    }

    throw Exception('Invalid attachment format: expected string (file URI) or object (base64), got ${attachment.runtimeType}');
  }

  Future<String> _saveBase64Attachment(String base64Data, String fileName) async {
    try {
      var base64String = base64Data;
      if (base64String.contains(',')) {
        base64String = base64String.split(',').last;
      }

      final bytes = base64Decode(base64String);
      final relativePath = await FileUtils.saveFileToPrivateStorage(bytes, fileName);
      LoggerService.debug('[Synapse.saveNotes] Saved base64 attachment: $fileName (${bytes.length} bytes) to $relativePath');
      return relativePath;
    } catch (e) {
      LoggerService.error('[Synapse.saveNotes] Error saving base64 attachment: $e', error: e);
      rethrow;
    }
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

