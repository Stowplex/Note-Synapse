import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/note.dart';
import '../services/database_service.dart';
import '../services/service_locator.dart';

/// A modal note picker returning the user's selection as a list of notes.
///
/// Used by `Synapse.pickNotes` so a plugin (or an AI-tool call mid-conversation)
/// can ask the user which notes to act on **by reference** — the caller only
/// receives note ids/titles, never content, so selecting notes for a plugin
/// never routes their content through the AI conversation.
class NotePickerSheet extends StatefulWidget {
  const NotePickerSheet({
    super.key,
    this.title,
    this.multiSelect = true,
    this.initialTag,
    this.initialQuery,
    this.preselectedIds = const [],
  });

  final String? title;
  final bool multiSelect;
  final String? initialTag;
  final String? initialQuery;
  final List<String> preselectedIds;

  /// Shows the picker as a modal bottom sheet. Resolves to the selected notes,
  /// or `null` if the user cancels.
  static Future<List<Note>?> show(
    BuildContext context, {
    String? title,
    bool multiSelect = true,
    String? initialTag,
    String? initialQuery,
    List<String> preselectedIds = const [],
  }) {
    return showModalBottomSheet<List<Note>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => NotePickerSheet(
        title: title,
        multiSelect: multiSelect,
        initialTag: initialTag,
        initialQuery: initialQuery,
        preselectedIds: preselectedIds,
      ),
    );
  }

  @override
  State<NotePickerSheet> createState() => _NotePickerSheetState();
}

class _NotePickerSheetState extends State<NotePickerSheet> {
  final DatabaseService _db = getIt<DatabaseService>();
  final TextEditingController _searchController = TextEditingController();

  List<Note> _allNotes = [];
  List<Note> _visibleNotes = [];
  final Set<String> _selected = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.preselectedIds);
    if (widget.initialQuery != null) {
      _searchController.text = widget.initialQuery!;
    }
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final notes = widget.initialTag != null && widget.initialTag!.isNotEmpty
        ? await _db.getNotesByTag(widget.initialTag!)
        : await _db.getAllNotes();
    if (!mounted) return;
    setState(() {
      _allNotes = notes.where((n) => !n.isArchived).toList();
      _loading = false;
    });
    _applyFilter();
  }

  void _applyFilter() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      _visibleNotes = query.isEmpty
          ? _allNotes
          : _allNotes
              .where((n) =>
                  n.title.toLowerCase().contains(query) ||
                  n.content.toLowerCase().contains(query))
              .toList();
    });
  }

  void _toggle(String id) {
    setState(() {
      if (widget.multiSelect) {
        if (!_selected.remove(id)) {
          _selected.add(id);
        }
      } else {
        _selected
          ..clear()
          ..add(id);
      }
    });
  }

  void _confirm() {
    final chosen =
        _allNotes.where((n) => _selected.contains(n.id)).toList();
    Navigator.of(context).pop(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: media.size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title ?? l10n.selectNotes,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.cancel),
                  ),
                  FilledButton(
                    onPressed: _selected.isEmpty ? null : _confirm,
                    child: Text(
                      widget.multiSelect
                          ? l10n.addWithCount(_selected.length)
                          : l10n.selectAction,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _searchController,
                onChanged: (_) => _applyFilter(),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: l10n.searchNotes,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _visibleNotes.isEmpty
                      ? Center(child: Text(l10n.noNotesFound))
                      : ListView.builder(
                          itemCount: _visibleNotes.length,
                          itemBuilder: (context, index) {
                            final note = _visibleNotes[index];
                            final selected = _selected.contains(note.id);
                            return CheckboxListTile(
                              value: selected,
                              onChanged: (_) => _toggle(note.id),
                              title: Text(
                                note.title.isEmpty ? l10n.untitled : note.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: note.tags.isEmpty
                                  ? null
                                  : Text(
                                      note.tags.map((t) => '#$t').join(' '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              controlAffinity:
                                  ListTileControlAffinity.leading,
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
