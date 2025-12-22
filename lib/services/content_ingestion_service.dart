import 'package:file_picker/file_picker.dart';
import '../models/note.dart';
import '../models/tag.dart';
import '../services/database_service.dart';
import '../services/ai_service.dart';
import '../services/logger_service.dart';
import '../providers/app_provider.dart';

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
    if (note.tags.isEmpty || note.attachmentPaths.isEmpty) return;

    // Check availability of AI prompts for tags
    String? extractionPrompt;
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

    if (extractionPrompt == null) return;

    // Show feedback
    onMessage?.call('Processing attachments with AI... Keep app open.');

    try {
      final attachedFiles = <PlatformFile>[];
      for (final path in note.attachmentPaths) {
        final name = path.split('/').last;
        attachedFiles.add(
          PlatformFile(name: name, path: path, size: 0, bytes: null),
        );
      }

      // Generate Summary
      final summary = await AIService.generateWithAttachments(
        extractionPrompt,
        attachedFiles,
      );

      // Prepend Summary to Note Content
      final newContent =
          '> [!SUMMARY]\n> ${summary.replaceAll('\n', '\n> ')}\n\n${note.content}';

      // Update Note
      await appProvider.updateNoteContent(note.id, newContent);

      onSuccess?.call();
    } catch (e) {
      LoggerService.error('Ingestion failed: $e');
      onError?.call('AI Processing Failed: $e');
    }
  }
}
