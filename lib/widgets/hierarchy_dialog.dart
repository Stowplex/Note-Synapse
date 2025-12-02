import 'package:flutter/material.dart';
import '../models/filter.dart';

class HierarchyDialog extends StatefulWidget {
  final Filter? rootFilter;
  final List<Filter> allFilters;
  final Set<String>? initialSelectedIds;
  final Function(Set<String>) onConfirmSelection;
  final Function(Filter) onEdit;
  final Function(Filter) onPin;
  final Function(Filter) onDelete;
  final bool Function(Filter)? filterPredicate;
  final bool multiSelectMode;

  const HierarchyDialog({
    super.key,
    this.rootFilter,
    required this.allFilters,
    this.initialSelectedIds,
    required this.onConfirmSelection,
    required this.onEdit,
    required this.onPin,
    required this.onDelete,
    this.filterPredicate,
    this.multiSelectMode = true,
  });

  @override
  State<HierarchyDialog> createState() => _HierarchyDialogState();
}

class _HierarchyDialogState extends State<HierarchyDialog> {
  late Set<String> _selectedIds;
  final Set<String> _expandedIds = {};
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _selectedIds = Set.from(widget.initialSelectedIds ?? {});
    // User requirement: "They should start collapsed."
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    if (query != _searchQuery) {
      setState(() {
        _searchQuery = query;
        if (_searchQuery.isNotEmpty) {
          _expandMatchingFilters();
        }
      });
    }
  }

  void _expandMatchingFilters() {
    _expandedIds.clear();
    final matches = widget.allFilters.where((f) {
      return f.name.toLowerCase().contains(_searchQuery);
    });

    for (final match in matches) {
      // Find all ancestors
      var current = match;
      // We need to find parents. Since we don't have parent links, we search in allFilters.
      // This is O(N^2) roughly, but N is small.
      bool changed = true;
      while (changed) {
        changed = false;
        try {
          // Find a parent for 'current'
          final parent = widget.allFilters.firstWhere(
            (p) => current.isChildOf(p) && current != p,
          );
          _expandedIds.add(parent.id);
          current = parent;
          changed = true;
        } catch (e) {
          // No parent found
        }
      }
    }
  }

  void _toggleSelection(String id) {
    setState(() {
      if (widget.multiSelectMode) {
        if (_selectedIds.contains(id)) {
          _selectedIds.remove(id);
        } else {
          _selectedIds.add(id);
        }
      } else {
        _selectedIds = {id};
      }
    });
  }

  void _toggleExpanded(String id) {
    setState(() {
      if (_expandedIds.contains(id)) {
        _expandedIds.remove(id);
      } else {
        _expandedIds.add(id);
      }
    });
  }

  void _expandAll() {
    setState(() {
      _expandedIds.addAll(widget.allFilters.map((f) => f.id));
    });
  }

  void _collapseAll() {
    setState(() {
      _expandedIds.clear();
    });
  }

  List<Filter> _getDirectChildren(Filter? parent, List<Filter> scope) {
    if (parent == null) {
      // Roots
      return scope.where((f) {
        return !scope.any((other) => f != other && f.isChildOf(other));
      }).toList();
    }
    final descendants = scope.where((f) => f.isChildOf(parent)).toList();
    return descendants.where((child) {
      return !descendants.any(
        (other) => child != other && child.isChildOf(other),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Toolbar
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search filters...',
                      prefixIcon: const Icon(Icons.search),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.unfold_more),
                  tooltip: 'Expand All',
                  onPressed: _expandAll,
                ),
                IconButton(
                  icon: const Icon(Icons.unfold_less),
                  tooltip: 'Collapse All',
                  onPressed: _collapseAll,
                ),
              ],
            ),
            const Divider(),
            Flexible(
              child: SingleChildScrollView(child: _buildContent(context)),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    widget.onConfirmSelection(_selectedIds);
                    Navigator.of(context).pop();
                  },
                  child: const Text('Confirm'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    var filters = widget.allFilters;
    if (widget.filterPredicate != null) {
      filters = filters.where(widget.filterPredicate!).toList();
    }

    if (filters.isEmpty) {
      return const Text('No filters found.');
    }

    final roots = _getDirectChildren(widget.rootFilter, filters);
    roots.sort((a, b) => a.name.compareTo(b.name));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: roots.map((filter) => _buildNode(context, filter, 0)).toList(),
    );
  }

  Widget _buildNode(BuildContext context, Filter filter, int depth) {
    var children = _getDirectChildren(filter, widget.allFilters);
    if (widget.filterPredicate != null) {
      children = children.where(widget.filterPredicate!).toList();
    }
    children.sort((a, b) => a.name.compareTo(b.name));

    final isExpanded = _expandedIds.contains(filter.id);
    final isSelected = _selectedIds.contains(filter.id);
    final hasChildren = children.isNotEmpty;

    final hasTags = filter.includeTags.isNotEmpty;
    final hasText =
        filter.includeText != null && filter.includeText!.isNotEmpty;
    final isMatched =
        _searchQuery.isNotEmpty &&
        filter.name.toLowerCase().contains(_searchQuery);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => _toggleSelection(filter.id),
          onLongPress: () => _toggleSelection(filter.id),
          child: Container(
            color: isMatched
                ? Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withOpacity(0.3)
                : null,
            padding: EdgeInsets.only(left: depth * 16.0, top: 2.0, bottom: 2.0),
            child: Row(
              children: [
                // Expand/Collapse Indicator
                if (hasChildren)
                  InkWell(
                    onTap: () => _toggleExpanded(filter.id),
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Icon(
                        isExpanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 20,
                        color: Colors.grey,
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 28), // Placeholder for alignment
                // Selection Indicator (Checkbox-like)
                Container(
                  margin: const EdgeInsets.only(right: 8.0),
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    border: Border.all(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: isSelected
                      ? Icon(
                          Icons.check,
                          size: 14,
                          color: Theme.of(context).colorScheme.onPrimary,
                        )
                      : null,
                ),

                // Icons based on filter content
                if (hasTags) ...[
                  const Icon(Icons.label, size: 14, color: Colors.blueGrey),
                  const SizedBox(width: 4),
                ],
                if (hasText) ...[
                  const Icon(
                    Icons.text_fields,
                    size: 14,
                    color: Colors.blueGrey,
                  ),
                  const SizedBox(width: 4),
                ],

                // Filter Name
                Expanded(
                  child: Text(
                    filter.name,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ),

                // Edit/Delete Buttons
                Visibility(
                  visible: isSelected,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildActionButton(
                        icon: Icons.edit,
                        onTap: () => widget.onEdit(filter),
                      ),
                      _buildActionButton(
                        icon: filter.isPinned
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        onTap: () => widget.onPin(filter),
                      ),
                      _buildActionButton(
                        icon: Icons.close,
                        onTap: () => widget.onDelete(filter),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (isExpanded && hasChildren)
          Column(
            children: children
                .map((child) => _buildNode(context, child, depth + 1))
                .toList(),
          ),
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 16, color: Theme.of(context).iconTheme.color),
        ),
      ),
    );
  }
}
