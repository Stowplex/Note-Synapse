import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../models/note.dart';
import '../models/tag.dart';
import '../models/attachment.dart';
import '../utils/file_utils.dart';
import '../services/database_service.dart';
import '../services/ai_service.dart';
import '../services/logger_service.dart';
import '../providers/app_provider.dart';
import 'dart:convert';
import 'note_modification_service.dart';

class ContentIngestionService {
  final DatabaseService _databaseService = DatabaseService();

  /// Checks if a note needs AI processing based on its tags and triggers ingestion.
  Future<void> processNote(
    Note note,
    AppProvider appProvider, {
    Function(String)? onMessage,
    Function(String)? onError,
    Function()? onSuccess,
  }) async {
    // Basic validation first
    if (note.tags.isEmpty) return;

    // Check availability of AI prompts for tags
    String? extractionPrompt;
    try {
      final List<Tag> tags = await _databaseService.getAllTags();

      for (final tag in note.tags) {
        final tagModel = tags.cast<Tag?>().firstWhere(
          (t) => t?.name == tag,
          orElse: () => null,
        );

        if (tagModel != null) {
          final prompt = await _databaseService.getTagExtractionPrompt(
            tagModel.id,
          );
          if (prompt != null && prompt.isNotEmpty) {
            extractionPrompt = prompt;
            break; // Use the first found prompt for now
          }
        }
      }
    } catch (e) {
      LoggerService.error('Error fetching tags or prompts: $e');
      onError?.call('Failed to check AI configuration');
      return;
    }

    if (extractionPrompt == null) return;

    // Show feedback
    onMessage?.call('Processing attachments with AI... Keep app open.');

    try {
      // 1. Fetch proper attachment objects from DB to get metadata (relative vs absolute path)
      final noteAttachments = await _databaseService.getAttachmentsForNote(
        note.id,
      );

      if (noteAttachments.isEmpty) {
        onError?.call('No attachments found on this note.');
        return;
      }

      final attachedFiles = <PlatformFile>[];

      // 2. Load file bytes for each attachment
      for (final attachment in noteAttachments) {
        // Skip if not included in AI context
        if (!attachment.includeInAIContext) continue;

        try {
          final fullPath = await FileUtils.getFullFilePath(
            attachment.filePath,
            attachment.isRelativePath,
          );

          final file = File(fullPath);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            attachedFiles.add(
              PlatformFile(
                name: attachment.fileName,
                path: fullPath,
                size: bytes.length,
                bytes: bytes,
              ),
            );
          } else {
            LoggerService.warning('Attachment file not found at $fullPath');
          }
        } catch (e) {
          LoggerService.error(
            'Failed to load attachment ${attachment.fileName}: $e',
          );
        }
      }

      // 3. Validate we actually have files to send
      if (attachedFiles.isEmpty) {
        onError?.call(
          'Could not load any valid attachments for AI processing.',
        );
        return;
      }

      final prompt =
          '''
$extractionPrompt

INSTRUCTION:
You can modify this note to extract information.
You may return a JSON object to perform specific modifications (title, content, tags, links, subnotes).
Schema:
{
  "content": { "action": "append"|"prepend"|"replace", "text": "..." },
  "title": { "new_title": "..." },
  "tags": { "added": ["..."], "removed": ["..."] },
  "link": [{ "relation": "...", "target": "note_id" }],
  "subnote": { "added": [{"name": "...", "content": "..."}] }
}
If you verify the output is simple text, I will prepend it as a summary.
If you return JSON, I will execute the modifications.

Note Context:
Title: ${note.title}
Tags: ${note.tags.join(', ')}
Content: ${note.content}
''';

      // Generate Summary/Modification
      final response = await AIService.generateWithAttachments(
        prompt,
        attachedFiles,
      );

      try {
        String jsonString = response.trim();
        // Strip markdown code blocks if present
        if (jsonString.contains('```')) {
          final RegExp regex = RegExp(
            r'```(?:json)?\s*(.*?)\s*```',
            dotAll: true,
          );
          final match = regex.firstMatch(jsonString);
          if (match != null) {
            jsonString = match.group(1) ?? jsonString;
          }
        }

        final json = jsonDecode(jsonString);
        if (json is Map<String, dynamic>) {
          // Enforce restriction: Attachment modification not allowed in this context
          json.remove('attachments');

          final service = NoteModificationService();
          // applyModifications writes to DB
          final updatedNote = await service.applyModifications(note.id, json);
          // Update AppProvider to reflect changes in UI (redundant DB write but safe)
          await appProvider.updateNote(updatedNote);
        } else {
          throw const FormatException();
        }
      } catch (e) {
        // Fallback: Prepend Summary to Note Content
        final newContent =
            '> [!SUMMARY]\n> ${response.replaceAll('\n', '\n> ')}\n\n${note.content}';
        await appProvider.updateNoteContent(note.id, newContent);
      }

      onSuccess?.call();
    } catch (e) {
      LoggerService.error('Ingestion failed: $e');
      onError?.call('AI Processing Failed: $e');
    }
  }
}
