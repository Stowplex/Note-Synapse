import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../screens/tag_management_screen.dart';

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

  void _showFilterMenu(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => _FilterDialog(
        availableTags: widget.availableTags,
        selectedTags: widget.selectedTags,
        onSelectionChanged: widget.onSelectionChanged,
        allNotesLabel: widget.allNotesLabel,
      ),
    );
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

class _FilterDialog extends StatefulWidget {
  final List<String> availableTags;
  final Set<String> selectedTags;
  final Function(Set<String>) onSelectionChanged;
  final String allNotesLabel;

  const _FilterDialog({
    required this.availableTags,
    required this.selectedTags,
    required this.onSelectionChanged,
    required this.allNotesLabel,
  });

  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  late Set<String> _localSelectedTags;

  @override
  void initState() {
    super.initState();
    _localSelectedTags = Set.from(widget.selectedTags);
  }

  void _handleTagSelection(String tag) {
    setState(() {
      if (tag == 'all') {
        // If "All Notes" is selected, clear all selections (empty set means "all")
        _localSelectedTags.clear();
      } else {
        // Multi-select logic: toggle individual tags
        if (_localSelectedTags.contains(tag)) {
          _localSelectedTags.remove(tag);
        } else {
          _localSelectedTags.add(tag);
        }
      }
    });
    
    // Update parent immediately
    widget.onSelectionChanged(_localSelectedTags);
  }

  void _navigateToTagManagement(BuildContext context) {
    Navigator.pop(context); // Close the filter dialog first
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const TagManagementScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return AlertDialog(
      title: Text(l10n.filter),
      content: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        width: 300,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // "All Notes" option
              InkWell(
                onTap: () => _handleTagSelection('all'),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _localSelectedTags.isEmpty,
                        onChanged: (value) => _handleTagSelection('all'),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        widget.allNotesLabel,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(),
              // Individual tag options
              ...widget.availableTags
                  .where((tag) => tag != 'all')
                  .map((tag) => InkWell(
                        onTap: () => _handleTagSelection(tag),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Row(
                            children: [
                              Checkbox(
                                value: _localSelectedTags.contains(tag),
                                onChanged: (value) => _handleTagSelection(tag),
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: Text(tag)),
                            ],
                          ),
                        ),
                      )),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _navigateToTagManagement(context),
          child: Text(l10n.manageTags),
        ),
        const SizedBox(width: 16),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.close),
        ),
      ],
    );
  }
}