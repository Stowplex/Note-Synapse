import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/attachment.dart';
import '../l10n/app_localizations.dart';

/// Dialog for configuring PDF AI context range
class PdfAiContextDialog extends StatefulWidget {
  const PdfAiContextDialog({
    super.key,
    required this.attachment,
    required this.currentConfig,
    required this.outline,
    required this.totalPages,
    required this.onSave,
  });

  final Attachment attachment;
  final PdfAiContextConfig? currentConfig;
  final List<PdfOutlineNode>? outline;
  final int totalPages;
  final void Function(PdfAiContextConfig?) onSave;

  @override
  State<PdfAiContextDialog> createState() => _PdfAiContextDialogState();
}

class _PdfAiContextDialogState extends State<PdfAiContextDialog> {
  late String _mode;
  late int _windowSize;
  late Set<String> _selectedChapters;

  @override
  void initState() {
    super.initState();
    _mode = widget.currentConfig?.mode ?? 'all';
    _windowSize = widget.currentConfig?.windowSize ?? 10;
    _selectedChapters = Set<String>.from(
      widget.currentConfig?.selectedChapters ?? [],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final hasOutline = widget.outline != null && widget.outline!.isNotEmpty;

    return AlertDialog(
      title: const Text('Configure AI Context'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Select which pages to include when AI processes this PDF:',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            // All Document option
            RadioListTile<String>(
              title: const Text('All Document'),
              subtitle: Text('${widget.totalPages} pages'),
              value: 'all',
              groupValue: _mode,
              onChanged: (value) => setState(() => _mode = value!),
              contentPadding: EdgeInsets.zero,
            ),

            // Window option
            RadioListTile<String>(
              title: const Text('Window Around Current Page'),
              subtitle: Text(
                '$_windowSize pages centered on where you are reading',
              ),
              value: 'window',
              groupValue: _mode,
              onChanged: (value) => setState(() => _mode = value!),
              contentPadding: EdgeInsets.zero,
            ),

            // Window size slider
            if (_mode == 'window') ...[
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Row(
                  children: [
                    const Text('Pages:'),
                    Expanded(
                      child: Slider(
                        value: _windowSize.toDouble(),
                        min: 2,
                        max: 20,
                        divisions: 9,
                        label: '$_windowSize',
                        onChanged: (value) =>
                            setState(() => _windowSize = value.round()),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(
                        '$_windowSize',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Chapters option (only if outline exists)
            if (hasOutline) ...[
              RadioListTile<String>(
                title: const Text('Selected Chapters'),
                subtitle: Text(
                  _selectedChapters.isEmpty
                      ? 'Choose specific sections'
                      : '${_selectedChapters.length} chapter(s) selected',
                ),
                value: 'chapters',
                groupValue: _mode,
                onChanged: (value) => setState(() => _mode = value!),
                contentPadding: EdgeInsets.zero,
              ),

              if (_mode == 'chapters') ...[
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: _buildChapterCheckboxes(widget.outline!, 0),
                  ),
                ),
              ],
            ],

            if (!hasOutline && _mode == 'chapters') ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This PDF has no outline/table of contents',
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        if (widget.currentConfig != null)
          TextButton(
            onPressed: () {
              widget.onSave(null); // Reset to default
              Navigator.pop(context);
            },
            child: const Text('Reset to Default'),
          ),
        FilledButton(
          onPressed: () {
            final config = _mode == 'all'
                ? null // null means all document (default)
                : PdfAiContextConfig(
                    mode: _mode,
                    windowSize: _mode == 'window' ? _windowSize : null,
                    selectedChapters: _mode == 'chapters'
                        ? _selectedChapters.toList()
                        : null,
                  );
            widget.onSave(config);
            Navigator.pop(context);
          },
          child: Text(l10n.save),
        ),
      ],
    );
  }

  List<Widget> _buildChapterCheckboxes(List<PdfOutlineNode> nodes, int depth) {
    final widgets = <Widget>[];

    for (final node in nodes) {
      widgets.add(
        CheckboxListTile(
          title: Text(
            node.title,
            style: TextStyle(fontSize: depth > 0 ? 14 : 16),
          ),
          value: _selectedChapters.contains(node.title),
          onChanged: (value) {
            setState(() {
              if (value == true) {
                _selectedChapters.add(node.title);
              } else {
                _selectedChapters.remove(node.title);
              }
            });
          },
          contentPadding: EdgeInsets.only(left: 8 + (depth * 16), right: 8),
          dense: true,
        ),
      );

      if (node.children.isNotEmpty) {
        widgets.addAll(_buildChapterCheckboxes(node.children, depth + 1));
      }
    }

    return widgets;
  }
}
