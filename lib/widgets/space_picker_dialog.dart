import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/filter.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
import '../screens/note_selection_dialog.dart';
import '../services/space_scope_service.dart';

/// A flat checklist of Spaces for one or more notes.
///
/// Every Space is listed with its current membership pre-checked; confirming
/// applies the difference — newly checked Spaces are joined, newly unchecked
/// ones are left — so a "move" between Spaces is one join and one leave under a
/// single confirm.
///
/// Membership here is measured on the **tags** (does the note carry every one
/// of the Space's include-tags?), because the tags are what the checkbox
/// actually writes. Whether the Space then goes on to *show* the note is a
/// separate question its own criteria answer, and the post-join feedback
/// reports it — see [AppProvider.notesHiddenBySpace].
class SpacePickerDialog extends StatefulWidget {
  /// The notes whose membership is being edited. Never empty in practice; an
  /// empty list renders the dialog with everything unchecked and applies
  /// nothing.
  final List<String> noteIds;

  const SpacePickerDialog({super.key, required this.noteIds});

  /// Opens the picker. Resolves to true when at least one join or leave was
  /// applied, so a caller can refresh or report.
  static Future<bool> show(BuildContext context, List<String> noteIds) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => SpacePickerDialog(noteIds: noteIds),
    );
    return changed ?? false;
  }

  @override
  State<SpacePickerDialog> createState() => _SpacePickerDialogState();
}

class _SpacePickerDialogState extends State<SpacePickerDialog> {
  /// Membership as it stood when the dialog opened: true (all notes in), false
  /// (none), null (some). Read once so a mid-dialog notify cannot silently
  /// rewrite what "unchanged" means.
  final Map<String, bool?> _initial = {};

  /// What the user asked for. Only entries that differ from [_initial] are
  /// applied.
  final Map<String, bool?> _desired = {};

  bool _loaded = false;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final appProvider = context.read<AppProvider>();
    final notes = [
      for (final id in widget.noteIds)
        ...appProvider.notes.where((n) => n.id == id),
    ];
    for (final space in appProvider.spaces) {
      final state = spaceMembership(space, notes);
      _initial[space.id] = state;
      _desired[space.id] = state;
    }
  }

  /// true when every note in [notes] carries all of [space]'s include-tags,
  /// false when none does, null when only some do.
  static bool? spaceMembership(Filter space, List<Note> notes) {
    if (notes.isEmpty) return false;
    var inCount = 0;
    for (final note in notes) {
      if (space.includeTags.every(note.tags.contains)) inCount++;
    }
    if (inCount == 0) return false;
    if (inCount == notes.length) return true;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final appProvider = context.watch<AppProvider>();
    final spaces = [...appProvider.spaces]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return AlertDialog(
      title: Text(l10n.addToSpaceTitle),
      content: SizedBox(
        width: 400,
        child: spaces.isEmpty
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.noSpacesYet,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.noSpacesYetHint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.noteIds.length > 1
                        ? l10n.addToSpaceHintPlural(widget.noteIds.length)
                        : l10n.addToSpaceHint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final space in spaces)
                          CheckboxListTile(
                            key: ValueKey('space-check-${space.id}'),
                            // Tristate so a partial selection stays visibly
                            // partial until the user decides; tapping always
                            // lands on a definite join or leave.
                            tristate: true,
                            value: _desired[space.id],
                            title: Text(space.name),
                            subtitle: Text(
                              _desired[space.id] == null
                                  ? '${l10n.spaceMembershipPartial} · '
                                        '${space.includeTags.join(', ')}'
                                  : space.includeTags.join(', '),
                            ),
                            onChanged: _busy
                                ? null
                                : (_) => setState(() {
                                    _desired[space.id] =
                                        _desired[space.id] != true;
                                  }),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          onPressed: _busy || spaces.isEmpty ? null : _apply,
          child: Text(l10n.save),
        ),
      ],
    );
  }

  Future<void> _apply() async {
    final appProvider = context.read<AppProvider>();
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);

    var ok = true;
    var changed = false;
    final joined = <Filter, List<String>>{};

    for (final space in appProvider.spaces) {
      final before = _initial[space.id];
      final after = _desired[space.id];
      if (after == before || after == null) continue;

      changed = true;
      if (after) {
        // Recorded before the write, and only the notes that are actually
        // moving: "3 added" must not count a note that was already there.
        joined[space] = notesMissingSpaceTags(
          appProvider,
          widget.noteIds,
          space,
        );
        ok = await appProvider.joinSpace(widget.noteIds, space.id) && ok;
      } else {
        ok = await appProvider.leaveSpace(widget.noteIds, space.id) && ok;
      }
    }

    if (!mounted) return;
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.spaceMembershipFailed)),
      );
      setState(() => _busy = false);
      return;
    }

    final feedback = spaceJoinFeedback(appProvider, l10n, joined);
    navigator.pop(changed);
    if (feedback != null) {
      messenger.showSnackBar(SnackBar(content: Text(feedback)));
    }
  }
}

/// The subset of [noteIds] that a join into [space] would actually change —
/// the notes not already carrying every one of its include-tags.
///
/// This is what [spaceJoinFeedback] means by "joined", and it is not the same
/// as "the notes the Space does not show": membership is measured on the tags,
/// while the Space's `noteTypes`, `excludeTags` and `includeText` can go on
/// hiding a note that is fully stamped. Counting the offered notes instead
/// produces "1 added" for a join that wrote nothing.
///
/// Must be evaluated **before** the write, while the tags still say what they
/// said when the user chose.
List<String> notesMissingSpaceTags(
  AppProvider appProvider,
  List<String> noteIds,
  Filter space,
) {
  final byId = {for (final note in appProvider.notes) note.id: note};
  return [
    for (final id in noteIds)
      if (!_carries(byId[id], space)) id,
  ];
}

/// Whether [note] already carries every one of [space]'s include-tags.
///
/// A note the provider has never heard of counts as *not* carrying them: it
/// cannot be shown to be already in, and over-reporting a join is the milder
/// of the two errors.
bool _carries(Note? note, Filter space) =>
    note != null && space.includeTags.every(note.tags.contains);

/// "N added · M not shown because *Space* only shows tasks".
///
/// [joined] maps each Space that gained notes to the ids that actually moved
/// into it. Returns null when nothing moved. Must be called **after** the join,
/// since the hidden count is measured on the stamped notes.
String? spaceJoinFeedback(
  AppProvider appProvider,
  AppLocalizations l10n,
  Map<Filter, List<String>> joined,
) {
  final lines = <String>[];
  for (final entry in joined.entries) {
    final ids = entry.value;
    if (ids.isEmpty) continue;
    final parts = <String>[l10n.spaceJoinAdded(ids.length)];
    final hidden = appProvider.notesHiddenBySpace(ids, entry.key.id);
    if (hidden > 0) {
      parts.add(_hiddenReason(l10n, entry.key, hidden));
    }
    lines.add(parts.join(' · '));
  }
  return lines.isEmpty ? null : lines.join('\n');
}

/// Names the Space criterion most likely to be hiding a freshly added note.
///
/// A Space restricted to a single note type is by far the common case and is
/// worth saying out loud; anything else (excludeTags, includeText) collapses
/// into one generic phrase rather than a taxonomy the user has to decode.
String _hiddenReason(AppLocalizations l10n, Filter space, int hidden) {
  if (space.noteTypes.length == 1) {
    return space.noteTypes.first == NoteType.task
        ? l10n.spaceJoinHiddenTasks(hidden, space.name)
        : l10n.spaceJoinHiddenNotes(hidden, space.name);
  }
  return l10n.spaceJoinHiddenFilter(hidden, space.name);
}

/// Adds or removes `all-spaces` on [noteIds] — the *Show in every space*
/// toggle.
///
/// Returns false when the write failed, which the caller must surface: the tag
/// is the only thing that makes a note visible outside its own Space, so a
/// silent no-op leaves the user believing the opposite of what happened.
Future<bool> setShowInEverySpace(
  AppProvider appProvider,
  List<String> noteIds,
  bool value,
) {
  const tag = SpaceScopeService.allSpacesTag;
  return appProvider.batchUpdateTags(
    noteIds,
    value ? const [tag] : const [],
    value ? const [] : const [tag],
  );
}

/// *Add existing notes…* — picks from the **complement** of the active Space
/// and joins the result.
///
/// Only notes the Space does not already show are offered, and the ones that
/// belong to no Space at all are listed first: those are what a user is
/// normally filing, and burying them under another Space's notes is what makes
/// this dialog useless at scale.
Future<void> showAddExistingNotesDialog(BuildContext context) async {
  final appProvider = context.read<AppProvider>();
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);

  final space = appProvider.activeSpace;
  if (space == null) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.addExistingNotesNoSpace)),
    );
    return;
  }

  final inScope = appProvider.scopedNotes.map((n) => n.id).toSet();
  final complement = [
    for (final note in appProvider.notes)
      if (!inScope.contains(note.id)) note,
  ];
  if (complement.isEmpty) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.addExistingNotesNothingLeft(space.name))),
    );
    return;
  }

  final otherSpaces = appProvider.spaces.where((s) => s.id != space.id);
  final unfiled = <String>{
    for (final note in complement)
      if (!otherSpaces.any((s) => s.includeTags.every(note.tags.contains)))
        note.id,
  };

  final selected = await showDialog<List<Note>>(
    context: context,
    builder: (dialogContext) => NoteSelectionDialog(
      title: l10n.addExistingNotesTitle(space.name),
      candidateNotes: complement,
      priorityNoteIds: unfiled,
      onNotesSelected: (notes) => Navigator.of(dialogContext).pop(notes),
    ),
  );
  if (selected == null || selected.isEmpty) return;

  final ids = [for (final note in selected) note.id];
  // The complement is computed from the *authoritative* predicate, so a note
  // can be offered here while already carrying every include-tag — whenever
  // the Space narrows by `noteTypes`, `excludeTags` or `includeText`. Joining
  // it writes nothing, and "1 added" would be a lie. Recorded before the
  // write, exactly as `_apply` does.
  final moved = notesMissingSpaceTags(appProvider, ids, space);
  final ok = await appProvider.joinSpace(ids, space.id);
  if (!ok) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.spaceMembershipFailed)),
    );
    return;
  }
  final feedback = spaceJoinFeedback(appProvider, l10n, {space: moved});
  if (feedback != null) {
    messenger.showSnackBar(SnackBar(content: Text(feedback)));
  }
}

/// "Saved outside *Space*" with a *Show all notes* escape.
///
/// Fires whenever a Space is active and [savedTags] is missing **any** of its
/// include-tags: the user was shown the stamp, took part or all of it off, and
/// the note they just wrote is about to vanish from the list they are looking
/// at.
///
/// The quantifier is `every`, not `any`, because include tags are ANDed — the
/// authoritative predicate is `AppProvider._isInSpace`, which evaluates the
/// whole Space filter. Dropping one tag of `{thesis, 2026}` is already enough
/// to put the note out of scope, and a guard that waited for the *last* tag to
/// go would stay silent through exactly that case. (The two quantifiers
/// coincide only on a single-tag Space.)
void reportSavedOutsideSpace(
  BuildContext context,
  AppProvider appProvider,
  List<String> savedTags,
) {
  final space = appProvider.activeSpace;
  if (space == null) return;
  if (savedTags.contains(SpaceScopeService.allSpacesTag)) return;
  if (space.includeTags.every(savedTags.contains)) return;

  final l10n = AppLocalizations.of(context)!;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(l10n.savedOutsideSpace(space.name)),
      action: SnackBarAction(
        label: l10n.showAllNotes,
        onPressed: () => appProvider.setActiveSpace(null),
      ),
    ),
  );
}
