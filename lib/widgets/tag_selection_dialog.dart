import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';

class TagSelectionDialog extends StatefulWidget {
  final List<String> initialSelectedTags;
  final List<String> excludedTags;
  final bool allowCreateNew;
  final bool allowEmptySelection;
  final String? title;
  final String? description;
  final String Function(int count)? confirmLabelBuilder;

  const TagSelectionDialog({
    super.key,
    this.initialSelectedTags = const [],
    this.excludedTags = const [],
    this.allowCreateNew = true,
    this.allowEmptySelection = false,
    this.title,
    this.description,
    this.confirmLabelBuilder,
  });

  @override
  State<TagSelectionDialog> createState() => _TagSelectionDialogState();
}

class _TagSelectionDialogState extends State<TagSelectionDialog> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedTags = {};
  String _tagSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _selectedTags.addAll(widget.initialSelectedTags);
    _searchController.addListener(() {
      setState(() {
        _tagSearchQuery = _searchController.text;
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _canSubmit => widget.allowEmptySelection || _selectedTags.isNotEmpty;

  String _buildConfirmLabel(AppLocalizations l10n) {
    final builder = widget.confirmLabelBuilder;
    if (builder != null) {
      return builder(_selectedTags.length);
    }

    if (_selectedTags.isEmpty) {
      return widget.allowEmptySelection ? l10n.apply : l10n.addTagsCapitalized;
    }

    final count = _selectedTags.length;
    return l10n.addTagsWithCount(count);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final searchLabel = widget.allowCreateNew
        ? l10n.addNewTagOrSearch
        : l10n.searchTags;
    final dialogTitle = widget.title ?? l10n.selectTags;

    return Consumer<AppProvider>(
      builder: (context, appProvider, child) {
        final allTags = appProvider.tags.map((tag) => tag.name).toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

        final availableTags = allTags.where((tag) {
          if (widget.excludedTags.contains(tag)) return false;
          if (_selectedTags.contains(tag)) return false;
          if (_tagSearchQuery.isEmpty) return true;
          return tag.toLowerCase().contains(_tagSearchQuery.toLowerCase());
        }).toList();

        return AlertDialog(
          title: Text(dialogTitle),
          content: SizedBox(
            width: 400,
            height: 400,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.description != null) ...[
                    Text(
                      widget.description!,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                  ],
                  Container(
                    height: 300,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[300]!),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_selectedTags.isNotEmpty) ...[
                            Text(
                              l10n.selectedTags,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withOpacity(0.7),
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: _selectedTags.map((tag) {
                                return Chip(
                                  label: Text(tag),
                                  deleteIcon: const Icon(Icons.close, size: 18),
                                  onDeleted: () {
                                    setState(() {
                                      _selectedTags.remove(tag);
                                    });
                                  },
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 16),
                          ],
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _searchController,
                                  decoration: InputDecoration(
                                    labelText: searchLabel,
                                    border: const OutlineInputBorder(),
                                    prefixIcon: Icon(
                                      widget.allowCreateNew
                                          ? Icons.add
                                          : Icons.search,
                                    ),
                                    isDense: true,
                                  ),
                                  onSubmitted: widget.allowCreateNew
                                      ? (value) {
                                          final trimmed = value.trim();
                                          if (trimmed.isNotEmpty &&
                                              !_selectedTags.contains(
                                                trimmed,
                                              ) &&
                                              !widget.excludedTags.contains(
                                                trimmed,
                                              )) {
                                            setState(() {
                                              _selectedTags.add(trimmed);
                                              _searchController.clear();
                                            });
                                          }
                                        }
                                      : null,
                                ),
                              ),
                              if (widget.allowCreateNew) ...[
                                const SizedBox(width: 8),
                                IconButton(
                                  onPressed: () {
                                    final value = _searchController.text.trim();
                                    if (value.isNotEmpty &&
                                        !_selectedTags.contains(value) &&
                                        !widget.excludedTags.contains(value)) {
                                      setState(() {
                                        _selectedTags.add(value);
                                        _searchController.clear();
                                      });
                                    }
                                  },
                                  icon: const Icon(Icons.add),
                                  style: IconButton.styleFrom(
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    foregroundColor: Theme.of(
                                      context,
                                    ).colorScheme.onPrimary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (availableTags.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              l10n.availableTags,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withOpacity(0.7),
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: availableTags.map((tag) {
                                return ActionChip(
                                  label: Text(tag),
                                  onPressed: () {
                                    setState(() {
                                      _selectedTags.add(tag);
                                    });
                                  },
                                );
                              }).toList(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.cancel),
            ),
            ElevatedButton(
              onPressed: _canSubmit
                  ? () {
                      Navigator.of(context).pop(_selectedTags.toList());
                    }
                  : null,
              child: Text(_buildConfirmLabel(l10n)),
            ),
          ],
        );
      },
    );
  }
}
