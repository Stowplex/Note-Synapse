import 'package:flutter/material.dart';
import '../models/filter.dart';

class HierarchyDialog extends StatelessWidget {
  final Filter? rootFilter;
  final List<Filter> allFilters;
  final Function(Filter) onSelect;
  final Function(Filter) onEdit;
  final Function(Filter) onDelete;

  const HierarchyDialog({
    super.key,
    this.rootFilter,
    required this.allFilters,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              rootFilter != null
                  ? 'Hierarchy: ${rootFilter!.name}'
                  : 'All Filters',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(child: _buildContent(context)),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    List<Filter> initialFilters;
    if (rootFilter != null) {
      // Show children of the root filter
      initialFilters = _getDirectChildren(rootFilter!, allFilters);
    } else {
      // Show all root filters (filters that are not children of any other filter)
      initialFilters = allFilters.where((f) {
        return !allFilters.any((other) => f != other && f.isChildOf(other));
      }).toList();
    }

    if (initialFilters.isEmpty) {
      return const Text('No filters found.');
    }

    // Sort alphabetically
    initialFilters.sort((a, b) => a.name.compareTo(b.name));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: initialFilters
          .map((filter) => _buildNode(context, filter))
          .toList(),
    );
  }

  List<Filter> _getDirectChildren(Filter parent, List<Filter> scope) {
    final descendants = scope.where((f) => f.isChildOf(parent)).toList();
    return descendants.where((child) {
      return !descendants.any(
        (other) => child != other && child.isChildOf(other),
      );
    }).toList();
  }

  Widget _buildNode(BuildContext context, Filter filter) {
    final children = _getDirectChildren(filter, allFilters);
    // Sort children alphabetically
    children.sort((a, b) => a.name.compareTo(b.name));

    return Padding(
      padding: const EdgeInsets.only(left: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (children.isNotEmpty)
                const Icon(
                  Icons.subdirectory_arrow_right,
                  size: 16,
                  color: Colors.grey,
                )
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: () {
                    onSelect(filter);
                    Navigator.of(context).pop();
                  },
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8.0,
                      horizontal: 4.0,
                    ),
                    child: Text(
                      filter.name,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit, size: 16),
                onPressed: () {
                  // Navigator.of(context).pop(); // Keep dialog open? User request implies behavior same as filter line.
                  // In filter line, edit dialog opens.
                  // If we want to keep hierarchy dialog open, we need to handle the result and refresh.
                  // But HierarchyDialog is stateless.
                  // If we open on top, we need to make sure HierarchyDialog rebuilds if name changes.
                  // Since it's stateless and passed `allFilters`, it won't auto-update unless parent rebuilds.
                  // So closing it might be safer, or we rely on parent to rebuild it.
                  // Let's just call the callback.
                  onEdit(filter);
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                splashRadius: 20,
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: () {
                  onDelete(filter);
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                splashRadius: 20,
              ),
            ],
          ),
          if (children.isNotEmpty)
            Column(
              children: children
                  .map((child) => _buildNode(context, child))
                  .toList(),
            ),
        ],
      ),
    );
  }
}
