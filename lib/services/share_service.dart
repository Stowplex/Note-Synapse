import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/note.dart';

class ShareService {
  static const MethodChannel _channel = MethodChannel('note_synapse/share');

  /// Initialize the share service and set up method call handler
  static void initialize() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  /// Handle incoming method calls from Android
  static Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'handleSharedContent':
        return await _handleSharedContent(call.arguments);
      default:
        throw PlatformException(
          code: 'UNIMPLEMENTED',
          message: 'ShareService does not recognize method ${call.method}',
        );
    }
  }

  /// Process shared content from Android intent
  static Future<Map<String, dynamic>> _handleSharedContent(dynamic arguments) async {
    try {
      final Map<String, dynamic> data = Map<String, dynamic>.from(arguments);
      final String? action = data['action'];
      final String? type = data['type'];
      final String? text = data['text'];
      final String? filePath = data['filePath'];
      final String? fileName = data['fileName'];

      if (action == 'SEND' || action == 'SEND_MULTIPLE') {
        if (type == 'text/plain' && text != null) {
          return await _processTextContent(text);
        } else if (type?.startsWith('image/') == true && filePath != null) {
          return await _processImageContent(filePath, fileName);
        } else if (type == 'application/pdf' && filePath != null) {
          return await _processPdfContent(filePath, fileName);
        }
      }

      return {
        'success': false,
        'error': 'Unsupported content type: $type',
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Error processing shared content: $e',
      };
    }
  }

  /// Process shared text content
  static Future<Map<String, dynamic>> _processTextContent(String text) async {
    try {
      final note = Note(
        id: const Uuid().v4(),
        title: 'Shared Text - ${DateTime.now().toString().substring(0, 16)}',
        content: text,
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        tags: ['shared', 'text'],
      );

      return {
        'success': true,
        'note': note.toJson(),
        'contentType': 'text',
        'preview': text.length > 100 ? '${text.substring(0, 100)}...' : text,
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Error processing text content: $e',
      };
    }
  }

  /// Process shared image content
  static Future<Map<String, dynamic>> _processImageContent(String filePath, String? fileName) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return {
          'success': false,
          'error': 'Image file not found: $filePath',
        };
      }

      final note = Note(
        id: const Uuid().v4(),
        title: 'Shared Image - ${DateTime.now().toString().substring(0, 16)}',
        content: 'Image shared from ${fileName ?? 'unknown source'}',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        attachmentPaths: [filePath],
        tags: ['shared', 'image'],
      );

      return {
        'success': true,
        'note': note.toJson(),
        'contentType': 'image',
        'preview': 'Image: ${fileName ?? 'unknown'}',
        'filePath': filePath,
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Error processing image content: $e',
      };
    }
  }

  /// Process shared PDF content
  static Future<Map<String, dynamic>> _processPdfContent(String filePath, String? fileName) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return {
          'success': false,
          'error': 'PDF file not found: $filePath',
        };
      }

      final note = Note(
        id: const Uuid().v4(),
        title: 'Shared PDF - ${DateTime.now().toString().substring(0, 16)}',
        content: 'PDF shared from ${fileName ?? 'unknown source'}',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        attachmentPaths: [filePath],
        tags: ['shared', 'pdf'],
      );

      return {
        'success': true,
        'note': note.toJson(),
        'contentType': 'pdf',
        'preview': 'PDF: ${fileName ?? 'unknown'}',
        'filePath': filePath,
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Error processing PDF content: $e',
      };
    }
  }

}
