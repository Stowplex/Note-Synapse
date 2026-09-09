import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/filter.dart';
import '../providers/app_provider.dart';
import '../services/space_scope_service.dart';

/// What [focusOnTag] did.
enum FocusTagOutcome {
  /// A new one-tag Space was created and activated.
  created,

  /// The Space that already scoped to this tag was activated again.
  reused,

  /// The tag can never be a Space tag — see [canFocusOnTag].
  unusableTag,

  /// The tag is reserved by the app — see [SpaceScopeService.isReservedTag].
  reservedTag,

  /// The write or the activation was rejected; nothing changed.
  failed,
}

/// The result of *Focus on this tag*: [space] is set only when the scope
/// actually changed.
@immutable
class FocusTagResult {
  final FocusTagOutcome outcome;
  final Filter? space;

  const FocusTagResult(this.outcome, [this.space]);

  bool get ok =>
      outcome == FocusTagOutcome.created || outcome == FocusTagOutcome.reused;
}

/// Whether [tag] can become a Space's include-tag.
///
/// `filters.includeTags` is stored **comma-joined**
/// (`database_service.insertFilter` / `getAllFilters`), so a tag containing a
/// comma comes back as two tag names no note carries — `AppProvider` refuses to
/// treat such a filter as a Space at all (`_isUsableSpace`). Rejecting it here
/// means the user is told, rather than getting a filter that silently never
/// activates.
///
/// A reserved tag is refused for the same reason and by the same authority:
/// `all-spaces` as a Space's include-tag would stamp the cross-Space escape
/// onto every note created in that Space (A2). The tag picker this sheet is
/// reached from lists every tag row, and migration v47 guarantees
/// `all-spaces` is one of them, so this affordance is a live way to reach it.
bool canFocusOnTag(String tag) =>
    tag.trim().isNotEmpty &&
    !tag.contains(',') &&
    !SpaceScopeService.isReservedTag(tag);

/// Why [tag] cannot become a Space's include-tag, or null when it can.
///
/// Two different refusals, because they have two different explanations: a
/// comma is something the user can fix by renaming the tag, while a reserved
/// tag can never be a Space no matter what the user does.
String? tagFocusRefusal(AppLocalizations l10n, String tag) {
  if (SpaceScopeService.isReservedTag(tag)) return l10n.focusOnTagReserved;
  if (!canFocusOnTag(tag)) return l10n.focusOnTagUnusable;
  return null;
}

/// The Space whose membership is exactly [tag], or null when there is none.
///
/// "Exactly" is the whole point: a Space including `thesis` *and* `2026` is a
/// different scope, and reusing it for the `thesis` chip would silently drop
/// the user into a narrower list than they asked for. `AppProvider.spaces`
/// already excludes filters that are flagged but unusable.
Filter? findTagSpace(AppProvider appProvider, String tag) {
  for (final space in appProvider.spaces) {
    if (space.includeTags.length == 1 && space.includeTags.first == tag) {
      return space;
    }
  }
  return null;
}

/// Creates (or reuses) the Space for [tag] and activates it, in one action.
///
/// The reuse lookup is what stops a second *Focus on this tag* from filling the
/// filter strip with duplicates — the first invocation creates a filter named
/// after the tag, and every later one must find it.
///
/// A plain filter that happens to carry the same single include tag is
/// deliberately **not** promoted: flipping someone's saved filter into a Space
/// behind a long-press is a bigger change than this affordance asks for, and
/// the filter tab's own *Activate as space* already exists for when they do
/// want that.
///
/// Returns rather than throws: `setActiveSpace` reports a rejected activation
/// the same way, and the only sane response in either case is to leave the
/// current scope alone and say so.
Future<FocusTagResult> focusOnTag(AppProvider appProvider, String tag) async {
  if (SpaceScopeService.isReservedTag(tag)) {
    return const FocusTagResult(FocusTagOutcome.reservedTag);
  }
  if (!canFocusOnTag(tag)) {
    return const FocusTagResult(FocusTagOutcome.unusableTag);
  }

  final existing = findTagSpace(appProvider, tag);
  if (existing != null) {
    final ok = await appProvider.setActiveSpace(existing.id);
    return ok
        ? FocusTagResult(FocusTagOutcome.reused, existing)
        : const FocusTagResult(FocusTagOutcome.failed);
  }

  final now = DateTime.now();
  final space = Filter(
    name: tag,
    includeTags: [tag],
    isSpace: true,
    createdAt: now,
    updatedAt: now,
  );
  try {
    // `addFilter` rethrows a write failure after recording it; a Space that was
    // never persisted must not be activated, or the next launch resolves a
    // dangling id.
    await appProvider.addFilter(space);
  } catch (_) {
    return const FocusTagResult(FocusTagOutcome.failed);
  }

  final ok = await appProvider.setActiveSpace(space.id);
  return ok
      ? FocusTagResult(FocusTagOutcome.created, space)
      : const FocusTagResult(FocusTagOutcome.failed);
}

/// The long-press action sheet on a tag chip.
///
/// Mirrors the filter tab's *Activate as space* sheet: a bare chip has no popup
/// menu to extend, and an unlabelled long-press that silently rewrites the
/// user's scope would be worse than no affordance at all — so the gesture opens
/// a named action instead of acting directly.
///
/// The picker the chip lives in is closed before activating, because the answer
/// to "focus on this tag" is the newly scoped list behind it, not a tag picker
/// sitting over a list that changed underneath.
Future<void> showTagFocusSheet(BuildContext context, String tag) async {
  final l10n = AppLocalizations.of(context)!;
  final appProvider = context.read<AppProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final refusal = tagFocusRefusal(l10n, tag);
  final usable = refusal == null;

  final chosen = await showModalBottomSheet<bool>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              tag,
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.workspaces_outlined),
            title: Text(l10n.focusOnThisTag),
            subtitle: refusal == null ? null : Text(refusal),
            enabled: usable,
            onTap: usable
                ? () => Navigator.of(sheetContext).pop(true)
                : null,
          ),
        ],
      ),
    ),
  );
  if (chosen != true) return;

  if (navigator.canPop()) navigator.pop();

  // The messenger was captured above the popped route, so it is still mounted.
  final result = await focusOnTag(appProvider, tag);
  if (result.ok) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        switch (result.outcome) {
          FocusTagOutcome.reservedTag => l10n.focusOnTagReserved,
          FocusTagOutcome.unusableTag => l10n.focusOnTagUnusable,
          _ => l10n.spaceUnavailable,
        },
      ),
    ),
  );
}
