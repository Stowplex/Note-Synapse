import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../models/note.dart';
import '../models/tag.dart';
import '../utils/file_utils.dart';
import '../services/database_service.dart';
import '../services/ai_service.dart';
import '../services/logger_service.dart';
import '../providers/app_provider.dart';
import 'agent_service.dart';
import 'note_modification_service.dart';
import 'service_locator.dart';
import 'tag_workflow_service.dart';

import 'package:json_repair_flutter/json_repair_flutter.dart';

import '../widgets/local_model_workflow_warning_dialog.dart';

class ContentIngestionService {
  final DatabaseService _databaseService;

  /// Registered by [WorkflowShell] to show the local model warning dialog.
  /// Mirrors the [ApprovalService.fallbackApprovalRequest] pattern.
  /// When unset, the gate is bypassed and workflows run without prompting.
  static Future<LocalModelWorkflowApproval> Function()? onLocalModelApprovalRequired;

  /// Session flag — set to true when user picks "don't warn this session".
  /// Resets when a new [ContentIngestionService] instance is created (app restart).
  bool _suppressLocalModelWarning = false;

  /// Creates a ContentIngestionService.
  ///
  /// [databaseService] - The database service for data operations.
  ContentIngestionService(this._databaseService);

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

    final tagWorkflow = getIt<TagWorkflowService>();
    final agentService = getIt<AgentService>();
    List<ResolvedBinding> workflowBindings = const [];

    try {
      workflowBindings = await tagWorkflow.resolveBindings(note.tags);
    } catch (e) {
      LoggerService.error('Error resolving tag workflow bindings: $e');
      onError?.call('Failed to resolve workflow bindings: $e');
      return;
    }

    if (workflowBindings.isNotEmpty) {
      final supportsOrchestration = appProvider.modelConfig
              ?.customCapabilitiesObject?.supportsToolOrchestration ??
          true;

      if (!supportsOrchestration &&
          !_suppressLocalModelWarning &&
          onLocalModelApprovalRequired != null) {
        final approval = await onLocalModelApprovalRequired!();
        if (approval == LocalModelWorkflowApproval.cancel) {
          workflowBindings = const [];
        } else if (approval == LocalModelWorkflowApproval.proceedAndSuppress) {
          _suppressLocalModelWarning = true;
        }
        // LocalModelWorkflowApproval.proceed falls through.
      }

      for (final binding in workflowBindings) {
        onMessage?.call('Starting workflow for tag "${binding.matchedTag}"...');
        await agentService.runWorkflowTask(binding: binding, note: note);
      }
    }

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

    if (extractionPrompt == null) {
      if (workflowBindings.isNotEmpty) {
        onSuccess?.call();
      }
      return;
    }

    // Show feedback
    onMessage?.call('Processing attachments with AI... Keep app open.');

    try {
      // 1. Fetch proper attachment objects from DB to get metadata (relative vs absolute path)
      final noteAttachments = await _databaseService.getAttachmentsForNote(
        note.id,
      );

      if (noteAttachments.isEmpty) {
        if (workflowBindings.isNotEmpty) {
          onSuccess?.call();
        } else {
          onError?.call('No attachments found on this note.');
        }
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
        if (workflowBindings.isNotEmpty) {
          onSuccess?.call();
        } else {
          onError?.call(
            'Could not load any valid attachments for AI processing.',
          );
        }
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
      final response = await getIt<AIService>().generateWithAttachments(
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

        final json = repairJson(jsonString);
        if (json is Map<String, dynamic>) {
          // Enforce restriction: Attachment modification not allowed in this context
          json.remove('attachments');

          final modService = getIt<NoteModificationService>();
          if (await tagWorkflow.hasImmutableBinding(note.tags)) {
            // Source note is immutable — redirect to new note
            final newNoteData = <String, dynamic>{
              'title': 'Extracted: ${note.title}',
              'content':
                  (json['content'] as Map<String, dynamic>?)?['text'] ?? '',
              'link': [
                {'relation': 'derived_from', 'target': note.id},
              ],
            };
            // createNote persists AND publishes the change event that
            // refreshes the UI cache. The previous appProvider.addNote here
            // re-inserted the same primary key, threw, and dumped every
            // immutable-note ingestion into the summary-prepend fallback.
            await modService.createNote(newNoteData);
          } else {
            // applyModifications writes to DB and publishes the UI refresh.
            await modService.applyModifications(note.id, json);
          }
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
