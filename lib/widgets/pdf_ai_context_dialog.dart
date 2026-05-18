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
  late Set<PdfBookmark> _selectedBookmarks;
  late int _bookmarkWindowSize;

  @override
  void initState() {
    super.initState();
    _mode = widget.currentConfig?.mode ?? 'all';
    _windowSize = widget.currentConfig?.windowSize ?? 10;
    _selectedChapters = Set<String>.from(
      widget.currentConfig?.selectedChapters ?? [],
    );
    _selectedBookmarks = Set<PdfBookmark>.from(
      widget.currentConfig?.selectedBookmarks ?? [],
    );
    _bookmarkWindowSize = widget.currentConfig?.bookmarkWindowSize ?? 1;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final hasOutline = widget.outline != null && widget.outline!.isNotEmpty;
    final bookmarks = widget.attachment.getBookmarks();
    final hasBookmarks = bookmarks.isNotEmpty;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.configureAiContext,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              Text(
                l10n.configureAiContextDescription,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // All Document option
                      RadioListTile<String>(
                        title: Text(l10n.aiContextAllDocument),
                        subtitle: Text(
                          l10n.aiContextPagesCount(widget.totalPages),
                        ),
                        value: 'all',
                        groupValue: _mode,
                        onChanged: (value) => setState(() => _mode = value!),
                        contentPadding: EdgeInsets.zero,
                      ),

                      // Window option
                      RadioListTile<String>(
                        title: Text(l10n.aiContextWindowAroundCurrentPage),
                        subtitle: Text(
                          l10n.aiContextPagesCenteredOnReading(_windowSize),
                        ),
                        value: 'window',
                        groupValue: _mode,
                        onChanged: (value) => setState(() => _mode = value!),
                        contentPadding: EdgeInsets.zero,
                      ),

                      if (_mode == 'window')
                        _buildSlider(
                          value: _windowSize,
                          label: l10n.pages,
                          min: 2,
                          max: 20,
                          onChanged: (val) => setState(() => _windowSize = val),
                        ),

                      // Bookmarks option
                      RadioListTile<String>(
                        title: Text(l10n.bookmarks),
                        subtitle: Text(
                          hasBookmarks
                              ? l10n.aiContextBookmarksAvailable(
                                  bookmarks.length,
                                )
                              : l10n.noBookmarksYet,
                        ),
                        value: 'bookmarks',
                        groupValue: _mode,
                        onChanged: hasBookmarks
                            ? (value) => setState(() => _mode = value!)
                            : null, // Disable if no bookmarks
                        contentPadding: EdgeInsets.zero,
                      ),

                      if (_mode == 'bookmarks') ...[
                        Padding(
                          padding: const EdgeInsets.only(left: 16, bottom: 8),
                          child: Text(
                            l10n.pagesBeforeAfter, // Localized "Pages before/after"
                            style: theme.textTheme.labelMedium,
                          ),
                        ),
                        _buildSlider(
                          value: _bookmarkWindowSize,
                          label: l10n.pages,
                          min: 0,
                          max: 5,
                          divisions: 5,
                          onChanged: (val) =>
                              setState(() => _bookmarkWindowSize = val),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: theme.dividerColor),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            children: [
                              // "Select All" check (optional but good UX)
                              CheckboxListTile(
                                title: Text(l10n.selectAll),
                                value:
                                    _selectedBookmarks.length ==
                                    bookmarks.length,
                                onChanged: (value) {
                                  setState(() {
                                    if (value == true) {
                                      _selectedBookmarks.addAll(bookmarks);
                                    } else {
                                      _selectedBookmarks.clear();
                                    }
                                  });
                                },
                                dense: true,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                              ),
                              const Divider(height: 1),
                              ...bookmarks.map((bookmark) {
                                return CheckboxListTile(
                                  title: Text(
                                    l10n.aiContextPageNumber(
                                      bookmark.pageNumber + 1,
                                    ),
                                  ),
                                  subtitle:
                                      bookmark.annotation != null &&
                                          bookmark.annotation!.isNotEmpty
                                      ? Text(
                                          bookmark.annotation!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        )
                                      : null,
                                  value: _selectedBookmarks.contains(bookmark),
                                  onChanged: (value) {
                                    setState(() {
                                      if (value == true) {
                                        _selectedBookmarks.add(bookmark);
                                      } else {
                                        _selectedBookmarks.remove(bookmark);
                                      }
                                    });
                                  },
                                  dense: true,
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                );
                              }).toList(),
                            ],
                          ),
                        ),
                      ],

                      // Chapters option
                      if (hasOutline) ...[
                        RadioListTile<String>(
                          title: Text(l10n.aiContextSelectedChapters),
                          subtitle: Text(
                            _selectedChapters.isEmpty
                                ? l10n.aiContextChooseSpecificSections
                                : l10n.aiContextChaptersSelected(
                                    _selectedChapters.length,
                                  ),
                          ),
                          value: 'chapters',
                          groupValue: _mode,
                          onChanged: (value) => setState(() => _mode = value!),
                          contentPadding: EdgeInsets.zero,
                        ),

                        if (_mode == 'chapters') ...[
                          const SizedBox(height: 8),
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: theme.dividerColor),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: _buildChapterCheckboxes(
                                widget.outline!,
                                0,
                              ),
                            ),
                          ),
                        ],
                      ],
                      if (!hasOutline && _mode == 'chapters')
                        _buildWarning(theme, l10n.aiContextPdfNoOutline),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (widget.currentConfig != null)
                    TextButton(
                      onPressed: () {
                        widget.onSave(null);
                        Navigator.pop(context);
                      },
                      child: Text(l10n.reset),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l10n.cancel),
                  ),
                  FilledButton(
                    onPressed: () {
                      final config = _mode == 'all'
                          ? null
                          : PdfAiContextConfig(
                              mode: _mode,
                              windowSize: _mode == 'window'
                                  ? _windowSize
                                  : null,
                              selectedChapters: _mode == 'chapters'
                                  ? _selectedChapters.toList()
                                  : null,
                              selectedBookmarks: _mode == 'bookmarks'
                                  ? _selectedBookmarks.toList()
                                  : null,
                              bookmarkWindowSize: _mode == 'bookmarks'
                                  ? _bookmarkWindowSize
                                  : null,
                            );
                      widget.onSave(config);
                      Navigator.pop(context);
                    },
                    child: Text(l10n.save),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSlider({
    required int value,
    required String label,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
    int? divisions,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Row(
        children: [
          Text('$label:'),
          Expanded(
            child: Slider(
              value: value.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: divisions ?? (max - min),
              label: '$value',
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWarning(ThemeData theme, String message) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.warning, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
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
          controlAffinity: ListTileControlAffinity.leading,
        ),
      );

      if (node.children.isNotEmpty) {
        widgets.addAll(_buildChapterCheckboxes(node.children, depth + 1));
      }
    }

    return widgets;
  }
}
