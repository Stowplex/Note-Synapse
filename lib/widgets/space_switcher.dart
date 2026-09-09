import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/filter.dart';
import '../providers/app_provider.dart';
import '../services/service_locator.dart';
import '../services/tag_image_service.dart';
import 'custom_filter_dialog.dart';
import 'space_picker_dialog.dart';

/// AppBar title that names the active Space and switches between Spaces.
///
/// With no active Space it reads [fallbackTitle] ("Notes"); inside a Space it
/// reads that Space's name, prefixed with the first stamp tag's image when
/// [TagImageService] has one. Tapping opens the menu: *All notes*, one entry
/// per Space, then *Manage spaces…*.
///
/// The activation itself lives in [AppProvider] — `MainScreen` disposes the
/// notes screen on every tab switch, so nothing about the current Space may be
/// held in screen state.
class SpaceSwitcher extends StatelessWidget {
  /// Menu value for "leave every Space".
  static const String allNotesValue = '__all_notes__';

  /// Menu value for the management dialog.
  static const String manageValue = '__manage_spaces__';

  /// Menu value for *Add existing notes…*. Only offered while a Space is
  /// active — with none active there is nothing to add notes to.
  static const String addExistingValue = '__add_existing_notes__';

  /// The title shown when no Space is active.
  final String fallbackTitle;

  const SpaceSwitcher({super.key, required this.fallbackTitle});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final appProvider = context.watch<AppProvider>();
    final active = appProvider.activeSpace;
    // Copied before sorting: `spaces` is a derived list today, but sorting a
    // provider getter's result in place is exactly the aliasing bug M2 removed
    // from `getFilteredNotes`.
    final spaces = [...appProvider.spaces]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final avatar = active == null ? null : spaceAvatar(active);

    return PopupMenuButton<String>(
      tooltip: l10n.switchSpace,
      position: PopupMenuPosition.under,
      onSelected: (value) => _onSelected(context, value),
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        CheckedPopupMenuItem<String>(
          value: allNotesValue,
          checked: active == null,
          child: Text(l10n.allNotes),
        ),
        for (final space in spaces)
          CheckedPopupMenuItem<String>(
            value: space.id,
            checked: space.id == active?.id,
            child: Text(space.name),
          ),
        const PopupMenuDivider(),
        if (active != null)
          PopupMenuItem<String>(
            value: addExistingValue,
            child: Text(l10n.addExistingNotesMenu),
          ),
        PopupMenuItem<String>(
          value: manageValue,
          child: Text(l10n.manageSpaces),
        ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (avatar != null) ...[avatar, const SizedBox(width: 8)],
          Flexible(
            child: Text(
              active?.name ?? fallbackTitle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    );
  }

  Future<void> _onSelected(BuildContext context, String value) async {
    final appProvider = context.read<AppProvider>();
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);

    if (value == addExistingValue) {
      await showAddExistingNotesDialog(context);
      return;
    }

    if (value == manageValue) {
      await showDialog<void>(
        context: context,
        builder: (_) => const ManageSpacesDialog(),
      );
      return;
    }

    // `setActiveSpace` reports failure rather than throwing: the filter can
    // have been deleted, un-flagged or emptied between the menu opening and
    // the tap, and the only sane response is to stay where we are and say so.
    final ok = await appProvider.setActiveSpace(
      value == allNotesValue ? null : value,
    );
    if (!ok) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.spaceUnavailable)));
    }
  }
}

/// The Space's tag image, if the first stamp tag has one.
///
/// Null when the tag has no image, when the file is not resolvable, or when
/// [TagImageService] is not registered (a widget test that renders the
/// switcher alone).
Widget? spaceAvatar(Filter space) {
  if (space.includeTags.isEmpty) return null;
  if (!getIt.isRegistered<TagImageService>()) return null;
  final service = getIt<TagImageService>();
  final imagePath = service.getImagePathForTag(space.includeTags.first);
  if (imagePath == null) return null;

  ImageProvider provider;
  if (TagImageService.isBuiltin(imagePath)) {
    provider = AssetImage(
      TagImageService.builtinAssetPath(TagImageService.builtinName(imagePath)),
    );
  } else {
    final appDocsPath = service.appDocsPath;
    if (appDocsPath == null) return null;
    provider = FileImage(File('$appDocsPath/$imagePath'));
  }
  // The tag's image file can be gone (the tag row outlives it), and an
  // unhandled image-load error is a red frame, not a missing picture. Every
  // other tag-image renderer degrades the same way — see `NoteCard`,
  // `TagDetailDialog` and `TagSelectionDialog`, which all pass an errorBuilder.
  return CircleAvatar(
    radius: 12,
    backgroundImage: provider,
    onBackgroundImageError: (_, __) {},
  );
}

/// The Spaces half of the filter list: activate one, edit its criteria, or
/// stop using it as a Space.
///
/// Deleting the underlying filter stays on the filter tab strip, where it
/// already lives — this dialog only manages the Space *role*.
class ManageSpacesDialog extends StatelessWidget {
  const ManageSpacesDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final appProvider = context.watch<AppProvider>();
    final active = appProvider.activeSpace;
    final spaces = [...appProvider.spaces]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return AlertDialog(
      title: Text(l10n.manageSpacesTitle),
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
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final space in spaces)
                    ListTile(
                      leading: space.id == active?.id
                          ? const Icon(Icons.check)
                          : const Icon(Icons.workspaces_outlined),
                      title: Text(space.name),
                      subtitle: Text(space.includeTags.join(', ')),
                      onTap: () => _activate(context, space),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit, size: 18),
                            tooltip: l10n.editFilter,
                            onPressed: () => _edit(context, space),
                          ),
                          IconButton(
                            icon: const Icon(Icons.workspaces_outlined,
                                size: 18),
                            tooltip: l10n.stopUsingAsSpace,
                            onPressed: () => _stopUsingAsSpace(
                              context,
                              space,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.close),
        ),
      ],
    );
  }

  Future<void> _activate(BuildContext context, Filter space) async {
    final appProvider = context.read<AppProvider>();
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final ok = await appProvider.setActiveSpace(space.id);
    if (!ok) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.spaceUnavailable)));
      return;
    }
    navigator.pop();
  }

  Future<void> _edit(BuildContext context, Filter space) async {
    final appProvider = context.read<AppProvider>();
    final result = await showDialog<dynamic>(
      context: context,
      builder: (_) => CustomFilterDialog(
        // Empty on purpose: the dialog does not read this — see
        // CustomFilterDialog.availableTags.
        availableTags: const [],
        existingFilter: space,
      ),
    );
    if (result is Filter) {
      await appProvider.updateFilter(result);
    }
  }

  /// Drops the Space role, keeping the filter. `updateFilter` deactivates the
  /// Space for us when it was the active one.
  Future<void> _stopUsingAsSpace(BuildContext context, Filter space) async {
    final appProvider = context.read<AppProvider>();
    await appProvider.updateFilter(
      space.copyWith(isSpace: false, updatedAt: DateTime.now()),
    );
  }
}
