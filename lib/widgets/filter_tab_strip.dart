import 'package:flutter/material.dart';
import '../models/filter.dart';
import '../l10n/app_localizations.dart';
import 'custom_filter_dialog.dart';
import 'hierarchy_dialog.dart';

class FilterTabStrip extends StatefulWidget {
  final String selectedFilterId;
  final List<Filter> customFilters;
  final List<String> availableTags;
  final Function(String) onFilterSelected;
  final Function(Filter) onFilterCreated;
  final Function(Filter) onFilterUpdated;
  final Function(String) onFilterDeleted;

  const FilterTabStrip({
    super.key,
    required this.selectedFilterId,
    required this.customFilters,
    required this.availableTags,
    required this.onFilterSelected,
    required this.onFilterCreated,
    required this.onFilterUpdated,
    required this.onFilterDeleted,
  });

  @override
  State<FilterTabStrip> createState() => _FilterTabStripState();
}

class _FilterTabStripState extends State<FilterTabStrip> {
  final ScrollController _scrollController = ScrollController();
  bool _isHierarchyEnabled = false;

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
        onSelect: (filter) {
          widget.onFilterSelected(filter.id);
        },
        onEdit: (filter) {
          // Close hierarchy dialog first? Or keep it open?
          // If we close it, we can reopen it after edit if needed.
          // For now, let's close it to avoid state issues, as the edit dialog is modal.
          Navigator.of(context).pop();
          _showEditFilterDialog(filter);
        },
        onDelete: (filter) {
          Navigator.of(context).pop();
          _showDeleteConfirmation(filter);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    List<Filter> visibleFilters = widget.customFilters;
    if (_isHierarchyEnabled) {
      visibleFilters = widget.customFilters.where((f) {
        // Show if it is NOT a child of any other filter in the list
        // If two filters are mutually children (identical), use ID to break tie
        return !widget.customFilters.any((other) {
          if (f == other) return false;
          if (!f.isChildOf(other)) return false;
          // f is child of other.
          // If other is ALSO child of f (identical), only hide if f.id > other.id
          if (other.isChildOf(f)) {
            return f.id.compareTo(other.id) > 0;
          }
          return true;
        });
      }).toList();
    }

    return SizedBox(
      height: 48,
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildHierarchyToggle(),
            const SizedBox(width: 8),
            _buildAddButton(),
            const SizedBox(width: 8),
            _buildTab('default', l10n.defaultNotes, Icons.note),
            const SizedBox(width: 8),
            _buildTab('pinned', l10n.pinnedNotes, Icons.push_pin),
            const SizedBox(width: 8),
            _buildTab('archived', l10n.archivedNotes, Icons.archive),
            const SizedBox(width: 8),
            _buildTab('all', l10n.allNotes, Icons.list),
            ...visibleFilters
                .map(
                  (filter) => [
                    const SizedBox(width: 8),
                    _buildCustomFilterTab(filter),
                  ],
                )
                .expand((x) => x),
            const SizedBox(width: 16), // Extra space at the end
          ],
        ),
      ),
    );
  }

  Widget _buildTab(String id, String label, IconData icon) {
    final isSelected = widget.selectedFilterId == id;

    return GestureDetector(
      onTap: () => widget.onFilterSelected(id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected
                  ? Theme.of(context).colorScheme.onPrimary
                  : Theme.of(context).colorScheme.onSurface,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSurface,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomFilterTab(Filter filter) {
    final isSelected = widget.selectedFilterId == filter.id;
    final hasChildren = widget.customFilters.any(
      (other) => other != filter && other.isChildOf(filter),
    );

    return GestureDetector(
      onTap: () => widget.onFilterSelected(filter.id),
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
            Text(
              filter.name,
              style: TextStyle(
                color: isSelected
                    ? Theme.of(context).colorScheme.onSecondary
                    : Theme.of(context).colorScheme.onSurface,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            if (_isHierarchyEnabled && hasChildren) ...[
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

  Widget _buildAddButton() {
    return GestureDetector(
      onTap: _showCreateFilterDialog,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline,
            style: BorderStyle.solid,
          ),
        ),
        child: Icon(
          Icons.add,
          size: 16,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }

  Widget _buildHierarchyToggle() {
    return GestureDetector(
      onTap: () {
        setState(() {
          _isHierarchyEnabled = !_isHierarchyEnabled;
        });
      },
      onLongPress: () {
        _showHierarchyDialog(null); // Show all hierarchy
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _isHierarchyEnabled
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _isHierarchyEnabled
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
            style: BorderStyle.solid,
          ),
        ),
        child: Icon(
          Icons.account_tree,
          size: 16,
          color: _isHierarchyEnabled
              ? Theme.of(context).colorScheme.onPrimaryContainer
              : Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}
