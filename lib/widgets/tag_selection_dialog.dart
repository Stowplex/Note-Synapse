import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../screens/tag_management_screen.dart';
import '../services/service_locator.dart';
import '../services/tag_image_service.dart';
import 'hierarchy_dialog.dart';
import 'tag_focus_action.dart';

class TagSelectionDialog extends StatefulWidget {
  final List<String> initialSelectedTags;
  final List<String> excludedTags;
  final bool allowCreateNew;
  final bool allowEmptySelection;
  final String? title;
  final String? description;
  final String Function(int count)? confirmLabelBuilder;
  final bool showManageTagsButton;
  final bool returnAsSet;

  /// Whether long-pressing a tag chip offers *Focus on this tag*, which turns
  /// the tag into a Space and activates it.
  ///
  /// Opt-in, because this dialog is also the "which tags does this note carry"
  /// editor and the plugin `pickTags` sheet — surfaces where changing the whole
  /// app's scope is not a plausible intent. It is switched on where the user is
  /// already narrowing what they are looking at (the notes and calendar tag
  /// filters, via [MultiSelectTagFilter]).
  final bool enableSpaceFocus;

  const TagSelectionDialog({
    super.key,
    this.initialSelectedTags = const [],
    this.excludedTags = const [],
    this.allowCreateNew = true,
    this.allowEmptySelection = false,
    this.title,
    this.description,
    this.confirmLabelBuilder,
    this.showManageTagsButton = false,
    this.returnAsSet = false,
    this.enableSpaceFocus = false,
  });

  @override
  State<TagSelectionDialog> createState() => _TagSelectionDialogState();
}

class _TagSelectionDialogState extends State<TagSelectionDialog> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedTags = {};
  final Set<String> _filterDerivedTags = {}; // Tags added via "Add from Filter"
  String _tagSearchQuery = '';
  String? _appDocsPath;

  @override
  void initState() {
    super.initState();
    _selectedTags.addAll(widget.initialSelectedTags);
    _searchController.addListener(() {
      setState(() {
        _tagSearchQuery = _searchController.text;
      });
    });
    _initAppDocsPath();
  }

  Future<void> _initAppDocsPath() async {
    final dir = await getApplicationDocumentsDirectory();
    if (mounted) {
      setState(() {
        _appDocsPath = dir.path;
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _canSubmit {
    return widget.allowEmptySelection || _selectedTags.isNotEmpty;
  }

  void _handleTagSelection(String tag) {
    setState(() {
      if (_selectedTags.contains(tag)) {
        _selectedTags.remove(tag);
        _filterDerivedTags.remove(tag); // Also remove from derived set
      } else {
        _selectedTags.add(tag);
      }
    });
  }

  void _navigateToTagManagement(BuildContext context) {
    Navigator.pop(context); // Close the tag selection dialog first
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const TagManagementScreen()),
    );
  }

  void _openFilterSelection(BuildContext context, AppProvider appProvider) {
    showDialog(
      context: context,
      builder: (context) => HierarchyDialog(
        allFilters: appProvider.filters,
        filterPredicate: (f) => f.includeTags.isNotEmpty,
        onConfirmSelection: (selectedIds) {
          setState(() {
            for (final filterId in selectedIds) {
              try {
                final filter = appProvider.filters.firstWhere(
                  (f) => f.id == filterId,
                );
                for (final tag in filter.includeTags) {
                  if (!_selectedTags.contains(tag) &&
                      !widget.excludedTags.contains(tag)) {
                    _selectedTags.add(tag);
                    _filterDerivedTags.add(tag);
                  } else if (_selectedTags.contains(tag)) {
                    _filterDerivedTags.add(tag);
                  }
                }
              } catch (e) {
                // Filter might not exist
              }
            }
          });
        },
        onEdit: (filter) {
          // No-op
        },
        onPin: (filter) {
          // No-op
        },
        onDelete: (filter) {
          // No-op
        },
      ),
    );
  }

  String _buildConfirmLabel(AppLocalizations l10n) {
    final builder = widget.confirmLabelBuilder;
    if (builder != null) {
      return builder(_selectedTags.length);
    }

    // For filter scenarios (allowEmptySelection), always use "Apply Filters"
    if (widget.allowEmptySelection) {
      return l10n.applyFilters;
    }

    if (_selectedTags.isEmpty) {
      return l10n.addTagsCapitalized;
    }

    final count = _selectedTags.length;
    return l10n.addTagsWithCount(count);
  }

  Widget? _buildTagAvatar(String tagName) {
    final tagImageService = getIt<TagImageService>();
    final imagePath = tagImageService.getImagePathForTag(tagName);
    if (imagePath == null) return null;

    ImageProvider imageProvider;
    if (TagImageService.isBuiltin(imagePath)) {
      imageProvider = AssetImage(
        TagImageService.builtinAssetPath(
          TagImageService.builtinName(imagePath),
        ),
      );
    } else if (_appDocsPath != null) {
      imageProvider = FileImage(File('$_appDocsPath/$imagePath'));
    } else {
      return null;
    }

    return CircleAvatar(radius: 8, backgroundImage: imageProvider);
  }

  /// Adds the *Focus on this tag* long-press to [chip] when the host opted in.
  ///
  /// A wrapping detector rather than a chip parameter: neither [FilterChip],
  /// [ActionChip] nor [Chip] exposes `onLongPress`, and their internal `InkWell`
  /// only claims the tap, so the long press is uncontested.
  Widget _withFocusAction(String tag, Widget chip) {
    if (!widget.enableSpaceFocus) return chip;
    return GestureDetector(
      onLongPress: () => showTagFocusSheet(context, tag),
      child: chip,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isFilterDialog = widget.allowEmptySelection && !widget.allowCreateNew;
    final searchLabel = widget.allowCreateNew
        ? l10n.addNewTagOrSearch
        : isFilterDialog
        ? l10n.searchTagsToFilter
        : l10n.searchTags;
    final dialogTitle = widget.title ?? l10n.selectTags;

    return Consumer<AppProvider>(
      builder: (context, appProvider, child) {
        final tagImageService = getIt<TagImageService>();
        final allTags = appProvider.tags.map((tag) => tag.name).toList()
          ..sort((a, b) {
            final aHasImage = tagImageService.getImagePathForTag(a) != null;
            final bHasImage = tagImageService.getImagePathForTag(b) != null;
            if (aHasImage != bHasImage) return aHasImage ? -1 : 1;
            return a.toLowerCase().compareTo(b.toLowerCase());
          });

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
                                final isDerived = _filterDerivedTags.contains(
                                  tag,
                                );
                                return _withFocusAction(
                                  tag,
                                  Chip(
                                    avatar: _buildTagAvatar(tag),
                                    label: Text(tag),
                                    backgroundColor: isDerived
                                        ? Colors.purple.withOpacity(0.1)
                                        : null,
                                    deleteIcon: const Icon(
                                      Icons.close,
                                      size: 18,
                                    ),
                                    onDeleted: () {
                                      setState(() {
                                        _selectedTags.remove(tag);
                                        _filterDerivedTags.remove(tag);
                                      });
                                    },
                                  ),
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
                                final isSelected = _selectedTags.contains(tag);
                                // Use FilterChip for filter scenarios (allowEmptySelection) to show selected state
                                // Use ActionChip for regular tag selection (add-only mode)
                                if (widget.allowEmptySelection) {
                                  return _withFocusAction(
                                    tag,
                                    FilterChip(
                                      avatar: _buildTagAvatar(tag),
                                      label: Text(tag),
                                      selected: isSelected,
                                      onSelected: (selected) {
                                        _handleTagSelection(tag);
                                      },
                                    ),
                                  );
                                } else {
                                  return _withFocusAction(
                                    tag,
                                    ActionChip(
                                      avatar: _buildTagAvatar(tag),
                                      label: Text(tag),
                                      onPressed: () {
                                        setState(() {
                                          _selectedTags.add(tag);
                                        });
                                      },
                                    ),
                                  );
                                }
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
              onPressed: () => _openFilterSelection(context, appProvider),
              child: Text(l10n.addFromFilter),
            ),
            if (widget.showManageTagsButton) ...[
              TextButton(
                onPressed: () => _navigateToTagManagement(context),
                child: Text(l10n.manageTags),
              ),
              const SizedBox(width: 8),
            ],
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.cancel),
            ),
            ElevatedButton(
              onPressed: _canSubmit
                  ? () {
                      if (widget.returnAsSet) {
                        // Return Set<String> for filter scenarios
                        Navigator.of(context).pop(_selectedTags);
                      } else {
                        Navigator.of(context).pop(_selectedTags.toList());
                      }
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
