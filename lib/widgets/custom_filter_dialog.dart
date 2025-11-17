import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/filter.dart';
import '../l10n/app_localizations.dart';
import '../widgets/tag_selection_dialog.dart';

class CustomFilterDialog extends StatefulWidget {
  final List<String> availableTags;
  final Filter? existingFilter;

  const CustomFilterDialog({
    super.key,
    required this.availableTags,
    this.existingFilter,
  });

  @override
  State<CustomFilterDialog> createState() => _CustomFilterDialogState();
}

class _CustomFilterDialogState extends State<CustomFilterDialog> {
  late TextEditingController _nameController;
  late TextEditingController _includeTextController;
  late TextEditingController _includeTagsController;
  bool _includeArchived = false;
  Set<String> _selectedTags = {};

  final Uuid _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existingFilter?.name ?? '');
    _includeTextController = TextEditingController(text: widget.existingFilter?.includeText ?? '');
    _includeTagsController = TextEditingController();
    _includeArchived = widget.existingFilter?.includeArchived ?? false;
    _selectedTags = Set.from(widget.existingFilter?.includeTags ?? []);
    _updateTagsDisplay();
    
    // Add listeners to update validation state
    _nameController.addListener(_onTextChanged);
    _includeTextController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _nameController.removeListener(_onTextChanged);
    _includeTextController.removeListener(_onTextChanged);
    _nameController.dispose();
    _includeTextController.dispose();
    _includeTagsController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    setState(() {
      // This will trigger a rebuild and update the button state
    });
  }

  void _updateTagsDisplay() {
    _includeTagsController.text = _selectedTags.join(', ');
  }

  void _showTagSelector() async {
    final l10n = AppLocalizations.of(context)!;
    
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => TagSelectionDialog(
        title: l10n.selectTags,
        initialSelectedTags: _selectedTags.toList(),
        allowCreateNew: false,
        allowEmptySelection: true,
        showManageTagsButton: false, // No manage tags in filter creator
        returnAsSet: false,
      ),
    );

    if (result != null) {
      setState(() {
        _selectedTags = result.toSet();
        _updateTagsDisplay();
      });
    }
  }

  void _removeTag(String tag) {
    setState(() {
      _selectedTags.remove(tag);
      _updateTagsDisplay();
    });
  }

  bool _isValid() {
    return _nameController.text.trim().isNotEmpty &&
           (_includeTextController.text.trim().isNotEmpty || _selectedTags.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(widget.existingFilter != null ? l10n.editFilter : l10n.createFilter),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.filterName,
                border: const OutlineInputBorder(),
                hintText: l10n.filterNameHint,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _includeTextController,
              decoration: InputDecoration(
                labelText: l10n.includeText,
                border: const OutlineInputBorder(),
                hintText: l10n.includeTextHint,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _includeTagsController,
              decoration: InputDecoration(
                labelText: l10n.includeTags,
                border: const OutlineInputBorder(),
                hintText: l10n.includeTagsHint,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _showTagSelector,
                ),
              ),
              readOnly: true,
              onTap: _showTagSelector,
            ),
            if (_selectedTags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: _selectedTags.map((tag) => Chip(
                  label: Text(tag),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: () => _removeTag(tag),
                )).toList(),
              ),
            ],
            const SizedBox(height: 16),
            CheckboxListTile(
              title: Text(l10n.includeArchivedNotes),
              value: _includeArchived,
              onChanged: (value) {
                setState(() {
                  _includeArchived = value ?? false;
                });
              },
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isValid() ? _saveFilter : null,
          child: Text(widget.existingFilter != null ? l10n.update : l10n.create),
        ),
      ],
    );
  }

  void _saveFilter() {
    final filter = Filter(
      id: widget.existingFilter?.id ?? _uuid.v4(),
      name: _nameController.text.trim(),
      includeText: _includeTextController.text.trim().isEmpty ? null : _includeTextController.text.trim(),
      includeTags: _selectedTags.toList(),
      includeArchived: _includeArchived,
      createdAt: widget.existingFilter?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );

    Navigator.of(context).pop(filter);
  }
}
