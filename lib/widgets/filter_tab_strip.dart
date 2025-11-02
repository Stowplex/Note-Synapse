import 'package:flutter/material.dart';
import '../models/filter.dart';
import '../l10n/app_localizations.dart';
import 'custom_filter_dialog.dart';

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

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _showCreateFilterDialog() {
    showDialog(
      context: context,
      builder: (context) => CustomFilterDialog(
        availableTags: widget.availableTags,
      ),
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return SizedBox(
      height: 48,
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildTab('default', l10n.defaultNotes, Icons.note),
            const SizedBox(width: 8),
            _buildTab('pinned', l10n.pinnedNotes, Icons.push_pin),
            const SizedBox(width: 8),
            _buildTab('archived', l10n.archivedNotes, Icons.archive),
            const SizedBox(width: 8),
            _buildTab('all', l10n.allNotes, Icons.list),
            ...widget.customFilters.map((filter) => [
              const SizedBox(width: 8),
              _buildCustomFilterTab(filter),
            ]).expand((x) => x),
            const SizedBox(width: 8),
            _buildAddButton(),
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
    final l10n = AppLocalizations.of(context)!;
    return GestureDetector(
      onTap: _showCreateFilterDialog,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline,
            style: BorderStyle.solid,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add,
              size: 16,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            const SizedBox(width: 4),
            Text(
              l10n.addFilter,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
