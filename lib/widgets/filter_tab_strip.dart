import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/filter.dart';
import '../providers/app_provider.dart';
import '../l10n/app_localizations.dart';
import 'custom_filter_dialog.dart';
import 'hierarchy_dialog.dart';
import 'active_filters_dialog.dart';

class FilterTabStrip extends StatefulWidget {
  final Set<String> selectedFilterIds;
  final Set<String> additionalSelectedTags;
  final List<Filter> customFilters;
  final List<String> availableTags;
  final Function(Set<String>) onFilterSelected;
  final Function(Filter) onFilterCreated;
  final Function(Filter) onFilterUpdated;
  final Function(String) onFilterDeleted;
  final Function(Set<String>) onTagsUpdated;

  const FilterTabStrip({
    super.key,
    required this.selectedFilterIds,
    this.additionalSelectedTags = const {},
    required this.customFilters,
    required this.availableTags,
    required this.onFilterSelected,
    required this.onFilterCreated,
    required this.onFilterUpdated,
    required this.onFilterDeleted,
    required this.onTagsUpdated,
  });

  @override
  State<FilterTabStrip> createState() => _FilterTabStripState();
}

class _FilterTabStripState extends State<FilterTabStrip> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _showCreateFilterDialog() {
    showDialog(
      context: context,
      builder: (context) =>
          CustomFilterDialog(availableTags: widget.availableTags),
    ).then((result) {
      if (result is Filter) {
        widget.onFilterCreated(result);
      }
    });
  }

  void _showEditFilterDialog(Filter filter) {
    showDialog(
      context: context,
      builder: (context) => CustomFilterDialog(
        availableTags: widget.availableTags,
        existingFilter: filter,
      ),
    ).then((result) {
      if (result is Filter) {
        widget.onFilterUpdated(result);
      }
    });
  }

  void _showDeleteConfirmation(Filter filter) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteFilter),
        content: Text(l10n.deleteFilterConfirm(filter.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onFilterDeleted(filter.id);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }

  void _showHierarchyDialog(Filter? rootFilter) {
    showDialog(
      context: context,
      builder: (context) => HierarchyDialog(
        rootFilter: rootFilter,
        allFilters: widget.customFilters,
        onConfirmSelection: (selectedIds) {
          widget.onFilterSelected(selectedIds);
        },
        onEdit: (filter) {
          Navigator.of(context).pop();
          _showEditFilterDialog(filter);
        },
        onPin: (filter) {
          // No need to pop, just toggle pin and let dialog rebuild if needed
          // But since dialog is stateful and might not listen to provider changes directly for the list...
          // Actually HierarchyDialog takes `allFilters` as a list. If provider updates, parent rebuilds, but dialog is pushed.
          // We might need to close and reopen, or better, make HierarchyDialog listen to provider?
          // For now, let's toggle. The dialog might not update immediately if it doesn't watch provider.
          // Wait, HierarchyDialog is built with `widget.customFilters`.
          // If we toggle pin, `widget.customFilters` in parent updates.
          // But `HierarchyDialog` is already pushed. It won't receive new props unless we use a Stream or ValueNotifier or Consumer inside it.
          // Let's check HierarchyDialog implementation again. It uses `widget.allFilters` in `build`.
          // It does NOT use Consumer.
          // So we should probably close the dialog or use a state management solution.
          // Given the current architecture, let's close it like edit/delete, or just toggle and hope for the best (it won't update).
          // User didn't ask for it to stay open, but "pin" usually implies quick action.
          // Let's try to toggle and see. If it doesn't update, we might need to wrap HierarchyDialog in Consumer.
          // Actually, let's wrap HierarchyDialog content in Consumer<AppProvider> in the dialog itself?
          // No, let's just toggle. If it doesn't refresh, we can improve later.
          // Actually, looking at `_showHierarchyDialog`, it passes `widget.customFilters`.
          // If I toggle pin, `AppProvider` notifies listeners. `FilterTabStrip` rebuilds.
          // But the Dialog is a separate route. It won't rebuild unless it listens to something.
          // I should probably close the dialog to be safe and consistent with Edit/Delete, OR make it live.
          // Making it live is better UX.
          // But for now, let's just implement the callback.
          // Wait, `HierarchyDialog` is NOT using `Consumer`.
          // I will just call `appProvider.toggleFilterPin(filter.id)` and maybe `setState` in dialog?
          // But `HierarchyDialog` doesn't know about `AppProvider`.
          // I'll pass a callback that does the work.
          // To make the UI update, `HierarchyDialog` needs to know the data changed.
          // Since `allFilters` is passed as a list, it's static for the dialog's lifetime.
          // I should probably modify `HierarchyDialog` to take a `Stream` or use `Provider` inside it?
          // Or simpler: The callback returns void.
          // If I want the icon to update, I need to update the local state of `HierarchyDialog` or rebuild it.
          // Let's just close it for now, similar to Edit/Delete, to ensure state consistency.
          // User said "add a pin there".
          // If I close it, it's annoying if they want to pin multiple.
          // Let's try to keep it open.
          // I will update `HierarchyDialog` to use `Consumer` in a separate step if needed.
          // For now, let's just pass the callback.
          context.read<AppProvider>().toggleFilterPin(filter.id);
          Navigator.of(context).pop();
        },
        onDelete: (filter) {
          Navigator.of(context).pop();
          _showDeleteConfirmation(filter);
        },
      ),
    );
  }

  void _showActiveFiltersDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            // Collect active filters based on CURRENT widget state
            // Note: widget.selectedFilterIds is updated by parent, so if we call onFilterSelected,
            // the parent rebuilds, and this dialog (being a child of the context that showed it?)
            // actually, showDialog pushes a new route. The parent rebuild doesn't automatically rebuild the dialog content
            // unless we pass fresh data.
            // BUT, we want the dialog to reflect the changes immediately.
            // Since the dialog is modal, we can maintain a local copy of the state?
            // OR, we rely on the callbacks to update the parent, and we just close the dialog if everything is empty.
            // Wait, if we update parent, the dialog is still showing old data.
            // We need to update the dialog's view of the data.
            // Let's use local state for the dialog and sync it?
            // No, simpler: Just close the dialog if everything is cleared.
            // If removing one item, we want to see it disappear.
            // So we need local state in StatefulBuilder.

            final currentFilterIds = Set<String>.from(widget.selectedFilterIds);
            final currentTags = Set<String>.from(widget.additionalSelectedTags);

            // Helper to rebuild list
            List<Filter> getActiveFilters() {
              final activeFilters = <Filter>[];
              for (final id in currentFilterIds) {
                if (id == 'default' ||
                    id == 'pinned' ||
                    id == 'archived' ||
                    id == 'all') {
                  if (id == 'default') {
                    activeFilters.add(
                      Filter(
                        id: 'default',
                        name: 'Active Notes',
                        includeTags: [],
                        includeText: '',
                        includeArchived: false,
                        createdAt: DateTime.now(),
                        updatedAt: DateTime.now(),
                      ),
                    );
                  } else if (id == 'pinned') {
                    activeFilters.add(
                      Filter(
                        id: 'pinned',
                        name: 'Pinned Notes',
                        includeTags: [],
                        includeText: '',
                        includeArchived: false,
                        createdAt: DateTime.now(),
                        updatedAt: DateTime.now(),
                      ),
                    );
                  } else if (id == 'archived') {
                    activeFilters.add(
                      Filter(
                        id: 'archived',
                        name: 'Archived Notes',
                        includeTags: [],
                        includeText: '',
                        includeArchived: true,
                        createdAt: DateTime.now(),
                        updatedAt: DateTime.now(),
                      ),
                    );
                  } else if (id == 'all') {
                    activeFilters.add(
                      Filter(
                        id: 'all',
                        name: 'All Notes',
                        includeTags: [],
                        includeText: '',
                        includeArchived: false,
                        createdAt: DateTime.now(),
                        updatedAt: DateTime.now(),
                      ),
                    );
                  }
                } else {
                  try {
                    final filter = widget.customFilters.firstWhere(
                      (f) => f.id == id,
                    );
                    activeFilters.add(filter);
                  } catch (e) {
                    // Filter not found
                  }
                }
              }
              return activeFilters;
            }

            return ActiveFiltersDialog(
              selectedFilters: getActiveFilters(),
              additionalTags: currentTags,
              onRemoveFilter: (filter) {
                setState(() {
                  currentFilterIds.remove(filter.id);
                  // Also update parent immediately
                  final newIds = Set<String>.from(currentFilterIds);
                  if (newIds.isEmpty && currentTags.isEmpty) {
                    newIds.add('default');
                    Navigator.of(context).pop(); // Close if empty
                  }
                  widget.onFilterSelected(newIds);
                });
              },
              onClearTags: () {
                setState(() {
                  currentTags.clear();
                  // Update parent
                  widget.onTagsUpdated({});
                  if (currentFilterIds.isEmpty) {
                    widget.onFilterSelected({'default'});
                    Navigator.of(context).pop();
                  }
                });
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final appProvider = context.watch<AppProvider>();
    final isHierarchyEnabled = appProvider.isHierarchyEnabled;

    // Sort filters: Pinned first, then by hierarchy/creation
    List<Filter> visibleFilters = List.from(widget.customFilters);

    // Separate pinned and unpinned
    final pinnedFilters = visibleFilters.where((f) => f.isPinned).toList();
    final unpinnedFilters = visibleFilters.where((f) => !f.isPinned).toList();

    List<Filter> hierarchyFilteredUnpinned = unpinnedFilters;
    if (isHierarchyEnabled) {
      hierarchyFilteredUnpinned = unpinnedFilters.where((f) {
        // Show if it is NOT a child of any other filter in the unpinned list
        return !unpinnedFilters.any((other) {
          if (f == other) return false;
          if (!f.isChildOf(other)) return false;
          if (other.isChildOf(f)) {
            return f.id.compareTo(other.id) > 0;
          }
          return true;
        });
      }).toList();
    }

    // Combine: Pinned first, then hierarchy-filtered unpinned
    visibleFilters = [...pinnedFilters, ...hierarchyFilteredUnpinned];

    final hasActiveFilters =
        widget.selectedFilterIds.any((id) => id != 'default') ||
        widget.additionalSelectedTags.isNotEmpty;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _buildHierarchyToggle(appProvider),
          const SizedBox(width: 2),
          // Add Filter Button
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showCreateFilterDialog,
            tooltip: 'Add Filter',
          ),
          const SizedBox(width: 2),
          // Filter Icon
          if (hasActiveFilters) ...[
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _showActiveFiltersDialog,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: Icon(
                    Icons.filter_list,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 2),
          ],
          // Action Group
          _buildActionGroup(l10n),

          for (final filter in visibleFilters) ...[
            const SizedBox(width: 2),
            _buildCustomFilterTab(filter, isHierarchyEnabled, appProvider),
          ],
          const SizedBox(width: 16), // Extra space at the end
        ],
      ),
    );
  }

  Widget _buildCustomFilterTab(
    Filter filter,
    bool isHierarchyEnabled,
    AppProvider appProvider,
  ) {
    final isSelected = widget.selectedFilterIds.contains(filter.id);
    final hasChildren = widget.customFilters.any(
      (other) => other != filter && other.isChildOf(filter),
    );

    return GestureDetector(
      onTap: () => widget.onFilterSelected({filter.id}),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.secondary
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? Theme.of(context).colorScheme.secondary
                : Theme.of(context).colorScheme.outline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (filter.isPinned) ...[
              Icon(
                Icons.push_pin,
                size: 14,
                color: isSelected
                    ? Theme.of(context).colorScheme.onSecondary
                    : Theme.of(context).colorScheme.onSurface,
              ),
              const SizedBox(width: 4),
            ],
            Text(
              filter.name,
              style: TextStyle(
                color: isSelected
                    ? Theme.of(context).colorScheme.onSecondary
                    : Theme.of(context).colorScheme.onSurface,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            if (isHierarchyEnabled && hasChildren) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () => _showHierarchyDialog(filter),
                child: Icon(
                  Icons.arrow_drop_down,
                  size: 20,
                  color: isSelected
                      ? Theme.of(context).colorScheme.onSecondary
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
            if (isSelected) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _showEditFilterDialog(filter),
                child: Icon(
                  Icons.edit,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSecondary,
                ),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () => appProvider.toggleFilterPin(filter.id),
                child: Icon(
                  filter.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSecondary,
                ),
              ),
              const SizedBox(width: 4),
            ],
            GestureDetector(
              onTap: () => _showDeleteConfirmation(filter),
              child: Icon(
                Icons.close,
                size: 16,
                color: isSelected
                    ? Theme.of(context).colorScheme.onSecondary
                    : Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionGroup(AppLocalizations l10n) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildActionIcon('default', Icons.note, l10n.defaultNotes),
          _buildActionIcon('pinned', Icons.push_pin, l10n.pinnedNotes),
          _buildActionIcon('archived', Icons.archive, l10n.archivedNotes),
          _buildActionIcon('all', Icons.list, l10n.allNotes),
        ],
      ),
    );
  }

  Widget _buildActionIcon(String id, IconData icon, String tooltip) {
    final isSelected = widget.selectedFilterIds.contains(id);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => widget.onFilterSelected({id}),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          decoration: isSelected
              ? BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                )
              : null,
          child: Icon(
            icon,
            size: 20,
            color: isSelected
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _buildHierarchyToggle(AppProvider appProvider) {
    final isHierarchyEnabled = appProvider.isHierarchyEnabled;
    return GestureDetector(
      onTap: () {
        appProvider.toggleHierarchy();
      },
      onLongPress: () {
        _showHierarchyDialog(null); // Show all hierarchy
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isHierarchyEnabled
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isHierarchyEnabled
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
            style: BorderStyle.solid,
          ),
        ),
        child: Icon(
          Icons.account_tree,
          size: 16,
          color: isHierarchyEnabled
              ? Theme.of(context).colorScheme.onPrimaryContainer
              : Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}
