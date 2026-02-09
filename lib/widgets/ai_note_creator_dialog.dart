import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../models/add_note_result.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
import '../l10n/app_localizations.dart';
import '../screens/note_selection_dialog.dart';
import '../services/conversation_attachment_service.dart';

/// Dialog for creating notes using AI with customizable prompt
/// Similar to the "create note" AI Action, with attachments and note selection
class AINoteCreatorDialog extends StatefulWidget {
  final String conversationContent;
  final List<Note> contextNotes;
  final Note? appendTarget;

  const AINoteCreatorDialog({
    super.key,
    required this.conversationContent,
    this.contextNotes = const [],
    this.appendTarget,
  });

  /// Show the dialog and return the result if any
  static Future<AddNoteResult?> show({
    required BuildContext context,
    required String conversationContent,
    List<Note> contextNotes = const [],
    Note? appendTarget,
  }) async {
    return await showDialog<AddNoteResult?>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AINoteCreatorDialog(
        conversationContent: conversationContent,
        contextNotes: contextNotes,
        appendTarget: appendTarget,
      ),
    );
  }

  @override
  State<AINoteCreatorDialog> createState() => _AINoteCreatorDialogState();
}

class _AINoteCreatorDialogState extends State<AINoteCreatorDialog> {
  final TextEditingController _promptController = TextEditingController(
    text: 'Summarize',
  );
  final List<PlatformFile> _attachedFiles = [];
  List<Note> _selectedNotes = [];
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    // Start with context notes already selected
    _selectedNotes = List.from(widget.contextNotes);
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Dialog(
      child: Container(
        constraints: BoxConstraints(
          maxHeight:
              MediaQuery.of(context).size.height -
              MediaQuery.of(context).viewInsets.bottom -
              40,
          maxWidth: 600,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(28),
                  topRight: Radius.circular(28),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.psychology,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.aiNoteCreator,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  if (!_isProcessing)
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                ],
              ),
            ),

            // Content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Instruction text
                    Text(
                      l10n.aiNoteCreatorInstructions,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Prompt input
                    Text(
                      l10n.prompt,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _promptController,
                      decoration: InputDecoration(
                        hintText: l10n.promptHint,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.edit),
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.attach_file),
                              onPressed: _attachFiles,
                              tooltip: l10n.attachFiles,
                            ),
                            IconButton(
                              icon: const Icon(Icons.camera_alt),
                              onPressed: _captureImage,
                              tooltip: l10n.takePhotoAttachment,
                            ),
                          ],
                        ),
                      ),
                      maxLines: 4,
                      minLines: 2,
                      enabled: !_isProcessing,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.promptTip,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.6),
                        fontStyle: FontStyle.italic,
                      ),
                    ),

                    // Attached files section
                    if (_attachedFiles.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _buildAttachedFilesSection(),
                    ],

                    // Additional notes section
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          l10n.additionalContextNotes(_selectedNotes.length),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        TextButton.icon(
                          onPressed: _isProcessing
                              ? null
                              : _selectAdditionalNotes,
                          icon: const Icon(Icons.add),
                          label: Text(l10n.addNotes),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_selectedNotes.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).colorScheme.outline.withOpacity(0.3),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _selectedNotes
                              .map(
                                (note) => Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.note, size: 16),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          note.title,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodyMedium,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (!_isProcessing)
                                        IconButton(
                                          icon: const Icon(
                                            Icons.close,
                                            size: 16,
                                          ),
                                          onPressed: () {
                                            setState(() {
                                              _selectedNotes.remove(note);
                                            });
                                          },
                                          constraints: const BoxConstraints(
                                            minWidth: 32,
                                            minHeight: 32,
                                          ),
                                          padding: EdgeInsets.zero,
                                        ),
                                    ],
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      )
                    else
                      Text(
                        l10n.noAdditionalNotesSelected,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.6),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Actions
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withOpacity(0.2),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isProcessing
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: Text(l10n.cancel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isProcessing ? null : _proceed,
                      child: _isProcessing
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(l10n.proceed),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachedFilesSection() {
    final l10n = AppLocalizations.of(context)!;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.attach_file,
                size: 16,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              ),
              const SizedBox(width: 8),
              Text(
                l10n.attachedFiles(_attachedFiles.length),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withOpacity(0.8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...List.generate(_attachedFiles.length, (index) {
            final file = _attachedFiles[index];
            return Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _getFileIcon(file.extension),
                    size: 16,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withOpacity(0.7),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      file.name,
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    _formatFileSize(file.size),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withOpacity(0.7),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!_isProcessing)
                    GestureDetector(
                      onTap: () => _removeAttachedFile(index),
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: Colors.red[600],
                      ),
                    ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Future<void> _attachFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: true,
      );

      if (result != null) {
        setState(() {
          _attachedFiles.addAll(result.files);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking files: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _captureImage() async {
    try {
      final ImagePicker picker = ImagePicker();

      final XFile? image = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        final file = File(image.path);
        final bytes = await file.readAsBytes();

        final platformFile = PlatformFile(
          name: image.name,
          size: bytes.length,
          bytes: bytes,
          path: image.path,
        );

        setState(() {
          _attachedFiles.add(platformFile);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error capturing image: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _removeAttachedFile(int index) {
    setState(() {
      _attachedFiles.removeAt(index);
    });
  }

  Future<void> _selectAdditionalNotes() async {
    final selectedNotes = await showDialog<List<Note>>(
      context: context,
      builder: (context) => NoteSelectionDialog(
        onNotesSelected: (notes) => Navigator.of(context).pop(notes),
      ),
    );

    if (selectedNotes != null) {
      setState(() {
        _selectedNotes = selectedNotes;
      });
    }
  }

  Future<void> _proceed() async {
    final l10n = AppLocalizations.of(context)!;

    if (_promptController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.pleaseEnterPrompt)));
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      final fullPrompt =
          '''
${_promptController.text.trim()}

Conversation content to process:
${widget.conversationContent}
''';

      final appProvider = context.read<AppProvider>();
      final appendTarget = widget.appendTarget;

      // Always create with persist: false so we can process attachments first
      final createdNotes = await appProvider.createNewNotes(
        fullPrompt,
        _selectedNotes,
        attachedFiles: _attachedFiles.isNotEmpty ? _attachedFiles : null,
        persist: false,
      );

      if (!mounted) return;

      if (appendTarget != null) {
        // Process attachments using the append target's ID
        final sourceProcessed =
            await ConversationAttachmentService.processContentForAttachments(
              content: widget.conversationContent,
              noteId: appendTarget.id,
            );

        final appendContent = _formatGeneratedNotesForAppend(createdNotes);

        if (appendContent.trim().isEmpty) {
          throw Exception('No content generated to append.');
        }

        // Process generated content for attachments
        final contentProcessed =
            await ConversationAttachmentService.processContentForAttachments(
              content: appendContent,
              noteId: appendTarget.id,
            );

        final allNewAttachments = {
          ...sourceProcessed.attachmentPaths,
          ...contentProcessed.attachmentPaths,
        }.toList();

        final updatedNote = await _appendGeneratedContentToNote(
          appendTarget,
          contentProcessed.content,
          allNewAttachments,
        );

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${l10n.contentAppendedSuccessfully} "${updatedNote.title}"',
            ),
            backgroundColor: Colors.green,
          ),
        );

        Navigator.of(context).pop(AddNoteResult.appended(updatedNote));
        return;
      }

      // Case: Creating new notes
      final finalNotes = <Note>[];
      for (final note in createdNotes) {
        // Process source content using the new note's ID
        final sourceProcessed =
            await ConversationAttachmentService.processContentForAttachments(
              content: widget.conversationContent,
              noteId: note.id,
            );

        // Process generated content
        final contentProcessed =
            await ConversationAttachmentService.processContentForAttachments(
              content: note.content,
              noteId: note.id,
            );

        final allAttachments = {
          ...note.attachmentPaths,
          ...sourceProcessed.attachmentPaths,
          ...contentProcessed.attachmentPaths,
        }.toList();

        final finalNote = note.copyWith(
          content: contentProcessed.content,
          attachmentPaths: allAttachments,
        );

        await appProvider.addNote(finalNote);
        finalNotes.add(finalNote);
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            finalNotes.length == 1
                ? l10n.noteCreatedSuccessfully(finalNotes.first.title)
                : l10n.multipleNotesCreatedSuccessfully(finalNotes.length),
          ),
          backgroundColor: Colors.green,
        ),
      );

      Navigator.of(context).pop(AddNoteResult.created(finalNotes));
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isProcessing = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.errorCreatingNote(e.toString())),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<Note> _appendGeneratedContentToNote(
    Note target,
    String addition,
    List<String> newAttachments,
  ) async {
    final appProvider = context.read<AppProvider>();

    final existingNote = appProvider.notes.firstWhere(
      (note) => note.id == target.id,
      orElse: () => target,
    );

    final combinedContent = _combineContent(existingNote.content, addition);

    final updatedAttachments = List<String>.from(existingNote.attachmentPaths)
      ..addAll(newAttachments);

    final updatedNote = existingNote.copyWith(
      content: combinedContent,
      attachmentPaths: updatedAttachments,
      updatedAt: DateTime.now(),
    );

    await appProvider.updateNote(updatedNote);

    final refreshedNote = appProvider.notes.firstWhere(
      (note) => note.id == updatedNote.id,
      orElse: () => updatedNote,
    );

    return refreshedNote;
  }

  String _formatGeneratedNotesForAppend(List<Note> notes) {
    if (notes.isEmpty) {
      return '';
    }

    final segments = <String>[];

    for (final note in notes) {
      final title = note.title.trim();
      final content = note.content.trim();

      if (title.isEmpty && content.isEmpty) {
        continue;
      }

      if (title.isNotEmpty && content.isNotEmpty) {
        segments.add('**$title**\n\n$content');
      } else if (title.isNotEmpty) {
        segments.add('**$title**');
      } else {
        segments.add(content);
      }
    }

    return segments.join('\n\n');
  }

  String _combineContent(String existing, String addition) {
    final existingTrimmed = existing.trimRight();
    final additionTrimmed = addition.trim();

    if (existingTrimmed.isEmpty) {
      return additionTrimmed;
    }

    if (additionTrimmed.isEmpty) {
      return existingTrimmed;
    }

    return '$existingTrimmed\n\n$additionTrimmed';
  }

  IconData _getFileIcon(String? extension) {
    if (extension == null) return Icons.insert_drive_file;

    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'bmp':
      case 'webp':
        return Icons.image;
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'txt':
        return Icons.text_snippet;
      case 'mp4':
      case 'avi':
      case 'mov':
        return Icons.video_file;
      case 'mp3':
      case 'wav':
      case 'aac':
        return Icons.audio_file;
      default:
        return Icons.insert_drive_file;
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
