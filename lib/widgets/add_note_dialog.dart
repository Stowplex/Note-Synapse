import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/add_note_result.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
import '../l10n/app_localizations.dart';
import '../screens/note_selection_dialog.dart';
import '../services/conversation_attachment_service.dart';
import 'ai_note_creator_dialog.dart';

/// Dialog for choosing how to add or append a note from conversation messages
class AddNoteDialog extends StatefulWidget {
  final String content;
  final List<Note> contextNotes;
  final List<String> attachmentPaths;

  const AddNoteDialog({
    super.key,
    required this.content,
    this.contextNotes = const [],
    this.attachmentPaths = const [],
  });

  /// Show the dialog and return the resulting action if any
  static Future<AddNoteResult?> show({
    required BuildContext context,
    required String content,
    List<Note> contextNotes = const [],
    List<String> attachmentPaths = const [],
  }) async {
    return await showDialog<AddNoteResult?>(
      context: context,
      builder: (dialogContext) => AddNoteDialog(
        content: content,
        contextNotes: contextNotes,
        attachmentPaths: attachmentPaths,
      ),
    );
  }

  @override
  State<AddNoteDialog> createState() => _AddNoteDialogState();
}

class _AddNoteDialogState extends State<AddNoteDialog> {
  Note? _appendTarget;

  /// The tags a newly created note will carry: the active Space's stamp,
  /// prefilled, and removable before the first (and only) save.
  ///
  /// Invariant 5 — the stamp is a default, not a lock — requires an
  /// interactive creator to *show* the tags and let the user take them off.
  /// This dialog previously applied the stamp with no chips at all and no
  /// second screen to show them on: *Add as is* asks for a title and writes
  /// immediately, so the tags were never visible and never refusable.
  ///
  /// Filled in [didChangeDependencies] rather than [initState] because it
  /// reads the provider.
  List<String>? _pendingTags;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pendingTags ??= List<String>.of(context.read<AppProvider>().spaceTags);
  }

  void _removeTag(String tag) {
    setState(() => _pendingTags!.remove(tag));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      scrollable: true,
      title: Text(l10n.addNoteDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.addNoteDialogMessage),
          const SizedBox(height: 16),
          _buildAppendSelection(l10n),
          const SizedBox(height: 16),
          _buildTagChips(l10n),
          _buildOptionCard(
            context: context,
            icon: Icons.note_add,
            title: l10n.addAsIs,
            description: l10n.addAsIsDescription,
            onTap: _addAsIs,
          ),
          const SizedBox(height: 12),
          _buildOptionCard(
            context: context,
            icon: Icons.psychology,
            title: l10n.letAICreateNote,
            description: l10n.letAICreateNoteDescription,
            onTap: _letAICreate,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }

  /// The removable tag row. Renders nothing when there is nothing to remove,
  /// so the dialog is unchanged outside a Space.
  ///
  /// Only shown for the *create* paths: appending puts the content into a note
  /// that already exists, and `updateNote` never stamps (A6).
  Widget _buildTagChips(AppLocalizations l10n) {
    final tags = _pendingTags ?? const <String>[];
    if (tags.isEmpty || _appendTarget != null) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.tags,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final tag in tags)
                Chip(
                  label: Text(tag),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: () => _removeTag(tag),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAppendSelection(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final hasSelection = _appendTarget != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.appendToNote,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: _selectAppendNote,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hasSelection
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline.withOpacity(0.3),
              ),
              color: hasSelection
                  ? theme.colorScheme.primaryContainer.withOpacity(0.4)
                  : theme.colorScheme.surface,
            ),
            child: Row(
              children: [
                Icon(
                  hasSelection ? Icons.note_alt : Icons.add,
                  color: hasSelection
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface.withOpacity(0.6),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    hasSelection
                        ? _appendTarget!.title
                        : l10n.pleaseSelectNoteToAppend,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: hasSelection
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hasSelection) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: l10n.clearFilters,
                    splashRadius: 18,
                    onPressed: _clearAppendTarget,
                  ),
                ] else
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOptionCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(icon, color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addAsIs() async {
    if (_appendTarget != null) {
      await _appendContentToExistingNote(_appendTarget!);
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final titleController = TextEditingController();

    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(l10n.noteTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.enterNoteTitlePrompt),
            const SizedBox(height: 16),
            TextField(
              controller: titleController,
              decoration: InputDecoration(
                hintText: l10n.noteTitleHint,
                border: const OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              final text = titleController.text.trim();
              if (text.isNotEmpty) {
                Navigator.of(dialogContext).pop(text);
              }
            },
            child: Text(l10n.createNote),
          ),
        ],
      ),
    );

    if (!mounted) return;

    if (title == null || title.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    try {
      final appProvider = context.read<AppProvider>();
      final noteId = const Uuid().v4();

      // Process temporary attachments from content
      final processedContent =
          await ConversationAttachmentService.processContentForAttachments(
            content: widget.content,
            noteId: noteId,
          );

      // Process explicit attachments
      final processedFiles =
          await ConversationAttachmentService.processFilesForAttachments(
            filePaths: widget.attachmentPaths,
            noteId: noteId,
          );

      final allAttachments = [
        ...processedContent.attachmentPaths,
        ...processedFiles,
      ];

      final newNote = Note(
        id: noteId,
        title: title,
        content: processedContent.content,
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        subNotes: const [],
        // The chips shown above: the active Space's tags, so a note captured
        // from a conversation lands in the Space the user is working in, minus
        // any the user took off. Never `all-spaces` (A2).
        tags: List<String>.of(_pendingTags ?? const []),
        attachmentPaths: allAttachments,
        scheduledAt: null,
        completeBy: null,
        status: null,
        pinned: false,
        isArchived: false,
      );

      // No stamp: the chips above are the tags, and the user may have removed
      // some. Stamping here would put back exactly the tag they just took off
      // and turn the opt-out into a no-op (invariant 5).
      await appProvider.addNote(newNote, applySpaceTags: false);

      if (!mounted) return;

      // Deliberately no "Saved outside <Space>" snackbar here, unlike the note
      // editor and the share screen. This dialog returns an `AddNoteResult`
      // and every caller shows its own success snackbar the moment it pops
      // (`note_action_mixin.dart` `handleAddContentToNote`), which replaces
      // whatever this route queued. A warning the user never sees is worse
      // than none: it reads as covered.
      Navigator.of(context).pop(
        AddNoteResult.created([
          newNote,
        ], successMessage: l10n.noteCreatedSuccessfully(title)),
      );
    } catch (e) {
      if (!mounted) return;

      Navigator.of(
        context,
      ).pop(AddNoteResult.error(l10n.errorCreatingNote(e.toString())));
    }
  }

  Future<void> _appendContentToExistingNote(Note target) async {
    final l10n = AppLocalizations.of(context)!;

    try {
      final appProvider = context.read<AppProvider>();

      final existingNote = appProvider.notes.firstWhere(
        (note) => note.id == target.id,
        orElse: () => target,
      );

      // Process temporary attachments from content
      final processedContent =
          await ConversationAttachmentService.processContentForAttachments(
            content: widget.content,
            noteId: existingNote.id,
          );

      // Process explicit attachments
      final processedFiles =
          await ConversationAttachmentService.processFilesForAttachments(
            filePaths: widget.attachmentPaths,
            noteId: existingNote.id,
          );

      final combinedContent = _combineContent(
        existingNote.content,
        processedContent.content,
      );

      // Combine existing attachments with new ones
      final updatedAttachments = List<String>.from(existingNote.attachmentPaths)
        ..addAll(processedContent.attachmentPaths)
        ..addAll(processedFiles);

      final updatedNote = existingNote.copyWith(
        content: combinedContent,
        attachmentPaths: updatedAttachments,
        updatedAt: DateTime.now(),
      );

      await appProvider.updateNote(updatedNote);

      if (!mounted) return;

      final refreshedNote = appProvider.notes.firstWhere(
        (note) => note.id == updatedNote.id,
        orElse: () => updatedNote,
      );

      Navigator.of(context).pop(
        AddNoteResult.appended(
          refreshedNote,
          successMessage:
              '${l10n.contentAppendedSuccessfully} "${refreshedNote.title}"',
        ),
      );
    } catch (e) {
      if (!mounted) return;

      Navigator.of(
        context,
      ).pop(AddNoteResult.error(l10n.errorUpdatingNote(e.toString())));
    }
  }

  Future<void> _letAICreate() async {
    final result = await AINoteCreatorDialog.show(
      context: context,
      conversationContent: widget.content,
      contextNotes: widget.contextNotes,
      appendTarget: _appendTarget,
    );

    if (!mounted) return;

    Navigator.of(context).pop(result);
  }

  Future<void> _selectAppendNote() async {
    final l10n = AppLocalizations.of(context)!;

    final selectedNotes = await showDialog<List<Note>>(
      context: context,
      builder: (dialogContext) => NoteSelectionDialog(
        onNotesSelected: (notes) => Navigator.of(dialogContext).pop(notes),
        title: l10n.selectNoteToAppend,
        singleSelection: true,
      ),
    );

    if (!mounted) return;

    if (selectedNotes == null || selectedNotes.isEmpty) {
      return;
    }

    setState(() {
      _appendTarget = selectedNotes.first;
    });
  }

  void _clearAppendTarget() {
    setState(() {
      _appendTarget = null;
    });
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
}
