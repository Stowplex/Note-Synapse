import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/filter.dart';
import '../models/note.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../services/space_scope_service.dart';
import '../widgets/tag_selection_dialog.dart';

class CustomFilterDialog extends StatefulWidget {
  /// Currently unused: the tag pickers below build their own list through
  /// [TagSelectionDialog]. Kept because three call sites still pass it.
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
  bool _isSpace = false;
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
    _isSpace = widget.existingFilter?.isSpace ?? false;
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

  /// Whether any selected include tag carries the comma that `filters`
  /// joins its tag lists on. Such a tag comes back from storage split into
  /// names no note carries, so the Space would scope to nothing and stamp
  /// tags that do not exist — the same disqualification `AppProvider.spaces`
  /// applies, checked here so a broken Space is never written in the first
  /// place.
  bool get _hasCommaTag => _selectedTags.any((tag) => tag.contains(','));

  /// Whether any selected include tag is reserved by the app.
  ///
  /// `all-spaces` as a Space's include-tag would stamp the cross-Space escape
  /// onto every note created in the Space (A2), make leaving it a permanent
  /// no-op and hide it from the chip list (A9); `agent-skill` would turn every
  /// new note into a malformed skill. `AppProvider._isUsableSpace` refuses
  /// such a filter, so saving one here would write a Space that can never be
  /// activated — the same disqualification, checked before the write.
  bool get _hasReservedTag =>
      _selectedTags.any(SpaceScopeService.isReservedTag);

  bool _isValid() {
    return _nameController.text.trim().isNotEmpty &&
        (_includeTextController.text.trim().isNotEmpty ||
            _selectedTags.isNotEmpty) &&
        _selectedNoteTypes.isNotEmpty &&
        // A Space needs include tags specifically, and tags that survive
        // storage. The general gating above accepts a text-only filter, which
        // would scope by text but stamp nothing — and an exclude-tags-only
        // filter is rejected for the same reason (decision 4 / A8).
        (!_isSpace ||
            _selectedTags.isNotEmpty && !_hasCommaTag && !_hasReservedTag);
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
            SwitchListTile(
              title: Text(l10n.useAsSpace),
              subtitle: Text(l10n.useAsSpaceDescription),
              value: _isSpace,
              onChanged: (value) {
                setState(() {
                  _isSpace = value;
                });
              },
              contentPadding: EdgeInsets.zero,
            ),
            if (_isSpace) ...[
              if (_selectedTags.isEmpty)
                _buildSpaceNotice(
                  context,
                  l10n.useAsSpaceNeedsIncludeTags,
                  isError: true,
                )
              else if (_hasReservedTag)
                // Same rule and same sentence as the tag-focus affordance: a
                // tag the app reserves for itself can never be a Space's
                // include-tag.
                _buildSpaceNotice(
                  context,
                  l10n.focusOnTagReserved,
                  isError: true,
                )
              else if (_hasCommaTag)
                // Same rule and same sentence as the tag-focus affordance:
                // include tags are stored comma-joined, so a tag carrying a
                // comma comes back split into names no note carries.
                _buildSpaceNotice(context, l10n.focusOnTagUnusable, isError: true)
              else
                _buildSpaceNotice(
                  context,
                  l10n.spaceStampPreview(_selectedTags.join(', ')),
                ),
              // Soft warnings: the stamp only ever adds the include tags, so a
              // note created inside the Space can still fail its other criteria.
              if (_includeTextController.text.trim().isNotEmpty)
                _buildSpaceNotice(context, l10n.spaceTextCriteriaWarning),
              if (_selectedNoteTypes.length < NoteType.values.length)
                _buildSpaceNotice(context, l10n.spaceNoteTypeWarning),
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

  Widget _buildSpaceNotice(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
    final color = isError
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.info_outline,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveFilter() async {
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
      isSpace: _isSpace,
      createdAt: widget.existingFilter?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await _offerRetagExistingMembers(filter);

    if (!mounted) return;
    Navigator.of(context).pop(filter);
  }

  /// Adding an include tag to a Space drops its current members out of scope —
  /// they do not carry the new tag. Offer to bring them along.
  ///
  /// Membership is counted *before* this edit is saved, so the ids tagged are
  /// exactly the notes the Space held when the user opened the editor.
  ///
  /// **A11**: membership here is the Space's *criteria*, so a note that is in
  /// scope only because it carries `all-spaces` is neither counted nor tagged
  /// — which means the count can be smaller than the list the user was just
  /// looking at. That is intended: stamping such a note would permanently file
  /// a deliberately global note into one Space. The stamp never adds
  /// `all-spaces` (A2), and this is the same rule read the other way round.
  Future<void> _offerRetagExistingMembers(Filter updated) async {
    final existing = widget.existingFilter;
    if (existing == null || !updated.isSpace) return;
    final added = updated.includeTags
        .where((tag) => !existing.includeTags.contains(tag))
        .toList();
    if (added.isEmpty) return;

    final appProvider = context.read<AppProvider>();
    final l10n = AppLocalizations.of(context)!;
    // `includeArchived` is forced: inside a Space archived-ness is decided by
    // the tab, so an archived member is still a member.
    final members = appProvider.getFilteredNotes(
      existing.copyWith(includeArchived: true),
    );
    if (members.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.tagExistingNotesTitle),
        content: Text(
          l10n.tagExistingNotesBody(
            members.length,
            updated.name,
            added.join(', '),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.notNow),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.tagExistingNotesConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // A failed write is surfaced by the provider's own `error`, which the notes
    // screen renders, so there is nothing useful to add here.
    await appProvider.batchUpdateTags(
      members.map((note) => note.id).toList(),
      added,
      const [],
    );
  }
}
