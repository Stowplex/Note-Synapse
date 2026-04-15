import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import '../l10n/app_localizations.dart';
import 'synapse_note_editor.dart';

/// Result of the block editor dialog
enum BlockEditorResult {
  /// User cancelled the dialog
  cancelled,

  /// User requested to delete the block
  deleted,

  /// User saved changes to the block
  saved,
}

/// Data returned from the block editor dialog
class BlockEditorData {
  final BlockEditorResult result;
  final String? editedContent;

  const BlockEditorData({required this.result, this.editedContent});

  const BlockEditorData.cancelled()
    : result = BlockEditorResult.cancelled,
      editedContent = null;

  const BlockEditorData.deleted()
    : result = BlockEditorResult.deleted,
      editedContent = null;

  const BlockEditorData.saved(String content)
    : result = BlockEditorResult.saved,
      editedContent = content;
}

/// Callback type for pickers that return a markdown string to insert
typedef MarkdownPickerCallback = Future<String?> Function();

/// Backwards-compatible alias for the image picker callback
typedef ImagePickerCallback = MarkdownPickerCallback;

/// A dialog for editing a specific markdown block
class BlockEditorDialog extends StatefulWidget {
  final String initialContent;
  final MarkdownPickerCallback? onPickImage;
  final MarkdownPickerCallback? onPickNoteLink;
  final MarkdownPickerCallback? onPickAttachmentLink;

  const BlockEditorDialog({
    super.key,
    required this.initialContent,
    this.onPickImage,
    this.onPickNoteLink,
    this.onPickAttachmentLink,
  });

  /// Shows the block editor dialog and returns the result
  static Future<BlockEditorData?> show(
    BuildContext context,
    String initialContent, {
    MarkdownPickerCallback? onPickImage,
    MarkdownPickerCallback? onPickNoteLink,
    MarkdownPickerCallback? onPickAttachmentLink,
  }) async {
    return showDialog<BlockEditorData>(
      context: context,
      barrierDismissible: false,
      builder: (context) => BlockEditorDialog(
        initialContent: initialContent,
        onPickImage: onPickImage,
        onPickNoteLink: onPickNoteLink,
        onPickAttachmentLink: onPickAttachmentLink,
      ),
    );
  }

  @override
  State<BlockEditorDialog> createState() => _BlockEditorDialogState();
}

class _BlockEditorDialogState extends State<BlockEditorDialog> {
  late final CodeLineEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = CodeLineEditingController.fromText(widget.initialContent);
    _focusNode = FocusNode();

    // Request focus after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleSave() {
    final content = _controller.text;
    Navigator.of(context).pop(BlockEditorData.saved(content));
  }

  void _handleDelete() async {
    final l10n = AppLocalizations.of(context)!;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteBlock),
        content: Text(l10n.deleteBlockConfirmation),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      Navigator.of(context).pop(const BlockEditorData.deleted());
    }
  }

  void _handleCancel() {
    Navigator.of(context).pop(const BlockEditorData.cancelled());
  }

  /// Handle image picking by calling the callback and inserting result into our controller
  Future<void> _handlePickImage() async {
    await _handleMarkdownPicker(widget.onPickImage);
  }

  /// Handle note link picking by calling the callback and inserting result into our controller
  Future<void> _handlePickNoteLink() async {
    await _handleMarkdownPicker(widget.onPickNoteLink);
  }

  /// Handle attachment link picking by calling the callback and inserting result into our controller
  Future<void> _handlePickAttachmentLink() async {
    await _handleMarkdownPicker(widget.onPickAttachmentLink);
  }

  /// Shared helper that invokes a markdown picker callback and inserts the
  /// returned markdown at the current cursor position in the local controller.
  Future<void> _handleMarkdownPicker(MarkdownPickerCallback? callback) async {
    if (callback == null) return;

    final markdown = await callback();
    if (markdown != null && markdown.isNotEmpty && mounted) {
      // Insert markdown at current cursor position in our controller
      final sel = _controller.selection;
      final text = _controller.text;
      final lines = _controller.value.codeLines;

      // Calculate offset
      int offset = 0;
      for (int i = 0; i < sel.start.index && i < lines.length; i++) {
        offset += lines[i].text.length + 1;
      }
      offset += sel.start.offset;

      // Insert markdown
      final newText =
          text.substring(0, offset) + markdown + text.substring(offset);
      _controller.text = newText;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final size = MediaQuery.of(context).size;

    // Dialog dimensions: ~80% width, ~60% height
    final dialogWidth = size.width * 0.8;
    final dialogHeight = size.height * 0.6;

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: dialogWidth,
        height: dialogHeight,
        constraints: BoxConstraints(
          maxWidth: 800,
          maxHeight: 600,
          minWidth: 300,
          minHeight: 200,
        ),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(28),
                  topRight: Radius.circular(28),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.edit_note,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    l10n.editBlock,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _handleCancel,
                    tooltip: l10n.cancel,
                  ),
                ],
              ),
            ),

            // Editor
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SynapseNoteEditor(
                  controller: _controller,
                  focusNode: _focusNode,
                  language: 'markdown',
                  onPickImage: widget.onPickImage != null
                      ? _handlePickImage
                      : null,
                  onPickNoteLink: widget.onPickNoteLink != null
                      ? _handlePickNoteLink
                      : null,
                  onPickAttachmentLink: widget.onPickAttachmentLink != null
                      ? _handlePickAttachmentLink
                      : null,
                ),
              ),
            ),

            // Actions
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).dividerColor,
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Delete button
                  TextButton.icon(
                    onPressed: _handleDelete,
                    icon: const Icon(Icons.delete_outline),
                    label: Text(l10n.deleteBlock),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                  ),

                  // Cancel and Save buttons
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: _handleCancel,
                        child: Text(l10n.cancel),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _handleSave,
                        icon: const Icon(Icons.save),
                        label: Text(l10n.save),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
