import 'package:flutter/material.dart';
import '../models/filter.dart';

class HierarchyDialog extends StatelessWidget {
  final Filter rootFilter;
  final List<Filter> allFilters;
  final Function(Filter) onSelect;

  const HierarchyDialog({
    super.key,
    required this.rootFilter,
    required this.allFilters,
    required this.onSelect,
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
              'Hierarchy: ${rootFilter.name}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: _buildTree(context, rootFilter, allFilters),
              ),
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

  Widget _buildTree(BuildContext context, Filter parent, List<Filter> scope) {
    // Find all descendants of parent within the current scope
    final descendants = scope.where((f) => f.isChildOf(parent)).toList();

    // Find direct children: descendants that are not children of any other descendant in this set
    final directChildren = descendants.where((child) {
      return !descendants.any(
        (other) => child != other && child.isChildOf(other),
      );
    }).toList();

    if (directChildren.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: directChildren.map((child) {
        return Padding(
          padding: const EdgeInsets.only(left: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: () {
                  onSelect(child);
                  Navigator.of(context).pop();
                },
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8.0,
                    horizontal: 4.0,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.subdirectory_arrow_right,
                        size: 16,
                        color: Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        child.name,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
              _buildTree(context, child, descendants),
            ],
          ),
        );
      }).toList(),
    );
  }
}
