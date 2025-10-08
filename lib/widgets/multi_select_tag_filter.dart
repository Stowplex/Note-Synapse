import 'package:flutter/material.dart';

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
  late Set<String> _selectedTags;

  @override
  void initState() {
    super.initState();
    _selectedTags = Set.from(widget.selectedTags);
  }

  @override
  void didUpdateWidget(MultiSelectTagFilter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedTags != widget.selectedTags) {
      _selectedTags = Set.from(widget.selectedTags);
    }
  }

  void _handleTagSelection(String tag) {
    setState(() {
      if (tag == 'all') {
        // If "All Notes" is selected, clear all selections (empty set means "all")
        _selectedTags.clear();
      } else {
        // Toggle the selected tag
        if (_selectedTags.contains(tag)) {
          _selectedTags.remove(tag);
        } else {
          _selectedTags.add(tag);
        }
      }
    });
    
    widget.onSelectionChanged(_selectedTags);
  }

  String _getFilterDisplayText() {
    if (_selectedTags.isEmpty) {
      return widget.allNotesLabel;
    } else if (_selectedTags.length == 1) {
      return _selectedTags.first;
    } else {
      return '${_selectedTags.length} tags';
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: (value) {
        // This is just to close the popup, actual handling is done in the menu items
      },
      itemBuilder: (context) => [
        // "All Notes" option
        PopupMenuItem<String>(
          value: 'all',
          child: InkWell(
            onTap: () => _handleTagSelection('all'),
            child: Row(
              children: [
                Checkbox(
                  value: _selectedTags.isEmpty,
                  onChanged: (value) => _handleTagSelection('all'),
                ),
                const SizedBox(width: 8),
                Text(widget.allNotesLabel),
              ],
            ),
          ),
        ),
        const PopupMenuDivider(),
        // Individual tag options - make it scrollable
        PopupMenuItem<String>(
          value: 'tags',
          enabled: false,
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6, // 60% of viewport height
            ),
            width: 200,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: widget.availableTags
                    .where((tag) => tag != 'all')
                    .map((tag) => InkWell(
                          onTap: () => _handleTagSelection(tag),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), // Reduced from 8 to 4
                            child: Row(
                              children: [
                                Checkbox(
                                  value: _selectedTags.contains(tag),
                                  onChanged: (value) => _handleTagSelection(tag),
                                ),
                                const SizedBox(width: 8),
                                Expanded(child: Text(tag)),
                              ],
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ),
          ),
        ),
      ],
      icon: Row(
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
}