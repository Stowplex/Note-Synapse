import 'dart:io';
import 'package:flutter/material.dart';
import '../models/note_annotation.dart';

enum AnnotationPreviewResult { none, addToScratchpad, removed }

class InNoteAnnotationPreview extends StatelessWidget {
  final NoteAnnotation annotation;
  final bool isInScratchpad;

  const InNoteAnnotationPreview({
    super.key,
    required this.annotation,
    required this.isInScratchpad,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: theme.dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Header
              Text(
                'Annotation',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              // Captured image
              _buildImageSection(context),
              const SizedBox(height: 16),
              // Annotation text
              if (annotation.content.isNotEmpty) ...[
                Text(
                  'Note',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.pink[400],
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  annotation.content,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 20),
              ],
              // Buttons
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: isInScratchpad
                          ? null
                          : () => Navigator.of(
                              context,
                            ).pop(AnnotationPreviewResult.addToScratchpad),
                      icon: const Icon(Icons.playlist_add, size: 18),
                      label: Text(
                        isInScratchpad ? 'In Scratchpad' : 'Add to Scratchpad',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => _confirmRemove(context),
                    icon: const Icon(Icons.delete_outline),
                    color: Theme.of(context).colorScheme.error,
                    tooltip: 'Remove Annotation',
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildImageSection(BuildContext context) {
    const imgExts = {'png', 'jpg', 'jpeg'};
    final imagePaths = annotation.attachmentPaths
        .where((p) => imgExts.contains(p.split('.').last.toLowerCase()))
        .toList();

    if (imagePaths.isEmpty) {
      return Container(
        height: 100,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Icon(
            Icons.image_not_supported_outlined,
            size: 36,
            color: Theme.of(context).disabledColor,
          ),
        ),
      );
    }

    if (imagePaths.length == 1) {
      return _buildSingleImage(context, imagePaths.first);
    }

    return SizedBox(
      height: 140,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: imagePaths.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          return SizedBox(
            width: 140,
            child: _buildSingleImage(context, imagePaths[index]),
          );
        },
      ),
    );
  }

  Widget _buildSingleImage(BuildContext context, String imagePath) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        File(imagePath),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Container(
          height: 100,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Icon(
              Icons.broken_image_outlined,
              size: 36,
              color: Theme.of(context).disabledColor,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove Annotation?'),
        content: const Text(
          'This will remove the annotation marker and its content permanently.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      Navigator.of(context).pop(AnnotationPreviewResult.removed);
    }
  }
}

Future<AnnotationPreviewResult?> showAnnotationPreview(
  BuildContext context,
  NoteAnnotation annotation, {
  required bool isInScratchpad,
}) {
  return showModalBottomSheet<AnnotationPreviewResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => InNoteAnnotationPreview(
      annotation: annotation,
      isInScratchpad: isInScratchpad,
    ),
  );
}
