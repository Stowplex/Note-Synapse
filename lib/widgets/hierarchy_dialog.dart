import 'package:flutter/material.dart';
import '../models/filter.dart';

class HierarchyDialog extends StatelessWidget {
  final Filter? rootFilter;
  final List<Filter> allFilters;
  final Function(Filter) onSelect;
  final Function(Filter) onEdit;
  final Function(Filter) onDelete;
  final bool Function(Filter)? filterPredicate;

  const HierarchyDialog({
    super.key,
    this.rootFilter,
    required this.allFilters,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
    this.filterPredicate,
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

    // Apply predicate if provided
    if (filterPredicate != null) {
      initialFilters = initialFilters.where(filterPredicate!).toList();
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
    var children = _getDirectChildren(filter, allFilters);

    // Apply predicate to children as well
    if (filterPredicate != null) {
      children = children.where(filterPredicate!).toList();
    }

    // Sort children alphabetically
    children.sort((a, b) => a.name.compareTo(b.name));

    final hasTags = filter.includeTags.isNotEmpty;
    final hasText =
        filter.includeText != null && filter.includeText!.isNotEmpty;

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
              // Icons based on filter content
              if (hasTags) ...[
                const Icon(Icons.label, size: 14, color: Colors.blueGrey),
                const SizedBox(width: 4),
              ],
              if (hasText) ...[
                const Icon(Icons.text_fields, size: 14, color: Colors.blueGrey),
                const SizedBox(width: 4),
              ],
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
