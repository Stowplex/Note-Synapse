import 'package:flutter/material.dart';
import '../models/filter.dart';
import '../models/note.dart';
import '../l10n/app_localizations.dart';

class ActiveFiltersDialog extends StatelessWidget {
  final List<Filter> selectedFilters;
  final Set<String> additionalTags;

  /// The active Space's name, when one is active. Shown as a top row with a
  /// *Leave* action: this dialog is where the user goes to ask "why am I not
  /// seeing everything", so the Space belongs at the top of the answer.
  final String? spaceName;

  /// Leaves the active Space. Null when no Space is active.
  final VoidCallback? onLeaveSpace;

  final Function(Filter) onRemoveFilter;
  final VoidCallback onClearTags;

  const ActiveFiltersDialog({
    super.key,
    required this.selectedFilters,
    required this.additionalTags,
    this.spaceName,
    this.onLeaveSpace,
    required this.onRemoveFilter,
    required this.onClearTags,
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
              'Active Filters',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Divider(),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (spaceName != null) ...[
                      _buildSpaceRow(context, spaceName!),
                      if (selectedFilters.isNotEmpty ||
                          additionalTags.isNotEmpty)
                        _buildSeparator(context, 'AND'),
                    ],

                    if (selectedFilters.isEmpty &&
                        additionalTags.isEmpty &&
                        spaceName == null)
                      const Text('No active filters.'),

                    ...selectedFilters.asMap().entries.map((entry) {
                      final index = entry.key;
                      final filter = entry.value;
                      final isLast = index == selectedFilters.length - 1;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildFilterSection(context, filter),
                          if (!isLast) _buildSeparator(context, 'OR'),
                        ],
                      );
                    }),

                    if (selectedFilters.isNotEmpty && additionalTags.isNotEmpty)
                      _buildSeparator(context, 'AND'),

                    if (additionalTags.isNotEmpty)
                      _buildAdditionalTagsSection(context),
                  ],
                ),
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

  Widget _buildSpaceRow(BuildContext context, String name) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.workspaces_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.spaceRowLabel(name),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          if (onLeaveSpace != null)
            TextButton(
              onPressed: onLeaveSpace,
              child: Text(l10n.leaveSpace),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterSection(BuildContext context, Filter filter) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  filter.name,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: () => onRemoveFilter(filter),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Remove filter',
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (filter.includeTags.isNotEmpty) ...[
            Text(
              l10n.includeTags,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: filter.includeTags.map((tag) {
                return Chip(
                  label: Text(tag),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  labelStyle: const TextStyle(fontSize: 12),
                );
              }).toList(),
            ),
            const SizedBox(height: 4),
          ],
          if (filter.excludeTags.isNotEmpty) ...[
            Text(
              l10n.excludeTags,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: filter.excludeTags.map((tag) {
                return Chip(
                  label: Text(tag),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  labelStyle: const TextStyle(fontSize: 12),
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.errorContainer.withOpacity(0.5),
                );
              }).toList(),
            ),
            const SizedBox(height: 4),
          ],
          if (filter.noteTypes.isNotEmpty &&
              filter.noteTypes.length < NoteType.values.length) ...[
            Text(l10n.noteType, style: Theme.of(context).textTheme.bodySmall),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: filter.noteTypes.map((type) {
                return Chip(
                  label: Text(type == NoteType.note ? l10n.note : l10n.task),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  labelStyle: const TextStyle(fontSize: 12),
                );
              }).toList(),
            ),
            const SizedBox(height: 4),
          ],
          if (filter.includeText != null && filter.includeText!.isNotEmpty) ...[
            Text(
              l10n.includeText,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Chip(
              label: Text(filter.includeText!),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              labelStyle: const TextStyle(fontSize: 12),
            ),
          ],
          if (filter.includeTags.isEmpty &&
              filter.excludeTags.isEmpty &&
              filter.noteTypes.length == NoteType.values.length &&
              (filter.includeText == null || filter.includeText!.isEmpty))
            Text(
              'No specific criteria (matches all notes)',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
        ],
      ),
    );
  }

  Widget _buildAdditionalTagsSection(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.secondaryContainer.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.secondary.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Additional Tags',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: onClearTags,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Clear tags',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: additionalTags.map((tag) {
              return Chip(
                label: Text(tag),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                labelStyle: const TextStyle(fontSize: 12),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildSeparator(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}
