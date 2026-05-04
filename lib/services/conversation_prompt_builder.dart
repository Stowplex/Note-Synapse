import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../models/conversation.dart';
import '../models/note.dart';
import '../utils/file_utils.dart';
import 'conversation_ai_engine.dart';
import 'database_service.dart';
import 'logger_service.dart';
import 'prompts/note_prompt_builder.dart';
import 'prompts/prompt_models.dart';

/// Shared prompt context plumbing for conversation-like chat surfaces.
///
/// The UI screens still own their system prompts and tool execution policy,
/// but note context attachments and stored message attachments should pass
/// through this single route.
class ConversationPromptBuilder {
  ConversationPromptBuilder(this._databaseService);

  final DatabaseService _databaseService;

  Future<PromptMessage?> buildNoteContextMessage(
    List<Note> notes, {
    int? currentPdfPage,
  }) async {
    final noteBuilder = NotePromptBuilder(_databaseService);
    final contextMessage = await noteBuilder.buildContextMessage(
      notes,
      currentPdfPage: currentPdfPage,
    );
    if (contextMessage.content.trim().isEmpty &&
        contextMessage.attachments.isEmpty) {
      return null;
    }
    return contextMessage;
  }

  Future<List<PromptMessage>> buildConversationMessages({
    required List<ConversationMessage> messages,
    required String? currentModelId,
    List<PlatformFile> latestUserAttachments = const [],
  }) {
    return ConversationAiEngine.buildConversationMessages(
      messages: messages,
      currentModelId: currentModelId,
      loadAttachments: (message) => loadMessageAttachments(
        message: message,
        messageHistory: messages,
        latestUserAttachments: latestUserAttachments,
      ),
    );
  }

  Future<List<PlatformFile>> loadMessageAttachments({
    required ConversationMessage message,
    required List<ConversationMessage> messageHistory,
    List<PlatformFile> latestUserAttachments = const [],
  }) async {
    if (message.type != MessageType.user) {
      return const [];
    }

    if (latestUserAttachments.isNotEmpty &&
        message.id == _latestUserMessageId(messageHistory)) {
      return Future.wait(latestUserAttachments.map(normalizePlatformFile));
    }

    if (message.attachmentPaths.isEmpty) {
      return const [];
    }

    final files = <PlatformFile>[];
    for (final path in message.attachmentPaths) {
      try {
        if (_isUri(path)) {
          files.add(
            PlatformFile(
              name: path.split('/').last,
              path: path,
              size: 0,
              bytes: null,
            ),
          );
          continue;
        }

        final resolvedPath = await FileUtils.resolvePortableAttachmentPath(
          path,
        );
        final file = File(resolvedPath);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        files.add(
          PlatformFile(
            name: path.split('/').last,
            path: resolvedPath,
            size: bytes.length,
            bytes: bytes,
          ),
        );
      } catch (e) {
        LoggerService.warning(
          'Failed to load conversation attachment $path: $e',
        );
      }
    }

    return files;
  }

  Future<PlatformFile> normalizePlatformFile(PlatformFile file) async {
    if (file.bytes != null || file.path == null || _isUri(file.path!)) {
      return file;
    }

    try {
      final resolvedPath = await FileUtils.resolvePortableAttachmentPath(
        file.path!,
      );
      final bytes = await File(resolvedPath).readAsBytes();
      return PlatformFile(
        name: file.name,
        path: resolvedPath,
        size: bytes.length,
        bytes: bytes,
      );
    } catch (e) {
      LoggerService.warning('Failed to normalize attachment ${file.name}: $e');
      return file;
    }
  }

  String? _latestUserMessageId(List<ConversationMessage> messages) {
    for (final message in messages.reversed) {
      if (message.type == MessageType.user) {
        return message.id;
      }
    }
    return null;
  }

  bool _isUri(String path) {
    return path.startsWith('http://') ||
        path.startsWith('https://') ||
        path.startsWith('gs://');
  }
}
