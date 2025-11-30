import 'package:flutter/material.dart';
import '../models/filter.dart';

class HierarchyDialog extends StatefulWidget {
  final Filter? rootFilter;
  final List<Filter> allFilters;
  final Set<String>? initialSelectedIds;
  final Function(Set<String>) onConfirmSelection;
  final Function(Filter) onEdit;
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

  @override
  void initState() {
    super.initState();
    _selectedIds = Set.from(widget.initialSelectedIds ?? {});
    // Auto-expand root if present, or maybe expand all by default?
    // User requirement: "They should start collapsed."
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
                Text(
                  widget.rootFilter != null
                      ? 'Hierarchy: ${widget.rootFilter!.name}'
                      : 'Filters',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => _toggleSelection(filter.id),
          onLongPress: () => _toggleSelection(filter.id),
          child: Padding(
            padding: EdgeInsets.only(left: depth * 16.0, top: 4.0, bottom: 4.0),
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

                // Edit/Delete Buttons (only if selected)
                if (isSelected) ...[
                  IconButton(
                    icon: const Icon(Icons.edit, size: 16),
                    onPressed: () => widget.onEdit(filter),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    splashRadius: 20,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => widget.onDelete(filter),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    splashRadius: 20,
                  ),
                  const SizedBox(width: 8),
                ],
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
}
