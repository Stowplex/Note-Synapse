import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/filter.dart';
import '../models/note.dart';
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
  late TextEditingController _excludeTagsController;
  bool _includeArchived = false;
  Set<String> _selectedTags = {};
  Set<String> _selectedExcludeTags = {};
  Set<NoteType> _selectedNoteTypes = {NoteType.note, NoteType.task};

  final Uuid _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.existingFilter?.name ?? '',
    );
    _includeTextController = TextEditingController(
      text: widget.existingFilter?.includeText ?? '',
    );
    _includeTagsController = TextEditingController();
    _excludeTagsController = TextEditingController();
    _includeArchived = widget.existingFilter?.includeArchived ?? false;
    _selectedTags = Set.from(widget.existingFilter?.includeTags ?? []);
    _selectedExcludeTags = Set.from(widget.existingFilter?.excludeTags ?? []);

    if (widget.existingFilter != null) {
      _selectedNoteTypes = Set.from(widget.existingFilter!.noteTypes);
    }

    _updateTagsDisplay();
    _updateExcludeTagsDisplay();

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
    _excludeTagsController.dispose();
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

  void _updateExcludeTagsDisplay() {
    _excludeTagsController.text = _selectedExcludeTags.join(', ');
  }

  void _showTagSelector() async {
    final l10n = AppLocalizations.of(context)!;

    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => TagSelectionDialog(
        title: l10n.selectTags,
        initialSelectedTags: _selectedTags.toList(),
        allowCreateNew: true,
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

  void _showExcludeTagSelector() async {
    final l10n = AppLocalizations.of(context)!;

    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => TagSelectionDialog(
        title: l10n.selectTagsToExclude,
        initialSelectedTags: _selectedExcludeTags.toList(),
        allowCreateNew: false, // Don't create tags just to exclude them usually
        allowEmptySelection: true,
        showManageTagsButton: false,
        returnAsSet: false,
      ),
    );

    if (result != null) {
      setState(() {
        _selectedExcludeTags = result.toSet();
        _updateExcludeTagsDisplay();
      });
    }
  }

  void _removeTag(String tag) {
    setState(() {
      _selectedTags.remove(tag);
      _updateTagsDisplay();
    });
  }

  void _removeExcludeTag(String tag) {
    setState(() {
      _selectedExcludeTags.remove(tag);
      _updateExcludeTagsDisplay();
    });
  }

  bool _isValid() {
    return _nameController.text.trim().isNotEmpty &&
        (_includeTextController.text.trim().isNotEmpty ||
            _selectedTags.isNotEmpty) &&
        _selectedNoteTypes.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(
        widget.existingFilter != null ? l10n.editFilter : l10n.createFilter,
      ),
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
                children: _selectedTags
                    .map(
                      (tag) => Chip(
                        label: Text(tag),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () => _removeTag(tag),
                      ),
                    )
                    .toList(),
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
            const SizedBox(height: 16),
            Text(l10n.noteType, style: Theme.of(context).textTheme.titleSmall),
            CheckboxListTile(
              title: Text(l10n.note),
              value: _selectedNoteTypes.contains(NoteType.note),
              onChanged: (value) {
                setState(() {
                  if (value == true) {
                    _selectedNoteTypes.add(NoteType.note);
                  } else {
                    _selectedNoteTypes.remove(NoteType.note);
                  }
                });
              },
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            CheckboxListTile(
              title: Text(l10n.task),
              value: _selectedNoteTypes.contains(NoteType.task),
              onChanged: (value) {
                setState(() {
                  if (value == true) {
                    _selectedNoteTypes.add(NoteType.task);
                  } else {
                    _selectedNoteTypes.remove(NoteType.task);
                  }
                });
              },
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _excludeTagsController,
              decoration: InputDecoration(
                labelText: l10n.excludeTags,
                border: const OutlineInputBorder(),
                hintText: l10n.excludeTagsHint,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _showExcludeTagSelector,
                ),
              ),
              readOnly: true,
              onTap: _showExcludeTagSelector,
            ),
            if (_selectedExcludeTags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: _selectedExcludeTags
                    .map(
                      (tag) => Chip(
                        label: Text(tag),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () => _removeExcludeTag(tag),
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.errorContainer.withOpacity(0.5),
                      ),
                    )
                    .toList(),
              ),
            ],
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
          child: Text(
            widget.existingFilter != null ? l10n.update : l10n.create,
          ),
        ),
      ],
    );
  }

  void _saveFilter() {
    final filter = Filter(
      id: widget.existingFilter?.id ?? _uuid.v4(),
      name: _nameController.text.trim(),
      includeText: _includeTextController.text.trim().isEmpty
          ? null
          : _includeTextController.text.trim(),
      includeTags: _selectedTags.toList(),
      excludeTags: _selectedExcludeTags.toList(),
      noteTypes: _selectedNoteTypes.toList(),
      includeArchived: _includeArchived,
      createdAt: widget.existingFilter?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );

    Navigator.of(context).pop(filter);
  }
}
