import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../widgets/tag_selection_dialog.dart';

class MultiSelectTagFilter extends StatefulWidget {
  final List<String> availableTags;
  final Set<String> selectedTags;
  final Function(Set<String>) onSelectionChanged;
  final String allNotesLabel;
  final String filterLabel;

  const MultiSelectTagFilter({
    super.key,
    required this.availableTags,
    required this.selectedTags,
    required this.onSelectionChanged,
    this.allNotesLabel = 'All Notes',
    this.filterLabel = 'Filter',
  });

  @override
  State<MultiSelectTagFilter> createState() => _MultiSelectTagFilterState();
}

class _MultiSelectTagFilterState extends State<MultiSelectTagFilter> {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showFilterMenu(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.filter_list),
          const SizedBox(width: 4),
          Text(
            _getFilterDisplayText(),
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  void _showFilterMenu(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => TagSelectionDialog(
        title: l10n.filter,
        initialSelectedTags: widget.selectedTags.toList(),
        allowCreateNew: false,
        allowEmptySelection: true,
        showManageTagsButton: true,
        returnAsSet: true,
      ),
    );

    if (result != null) {
      widget.onSelectionChanged(result);
    }
  }

  String _getFilterDisplayText() {
    if (widget.selectedTags.isEmpty) {
      return widget.allNotesLabel;
    } else if (widget.selectedTags.length == 1) {
      return widget.selectedTags.first;
    } else {
      return '${widget.selectedTags.length} tags';
    }
  }
}