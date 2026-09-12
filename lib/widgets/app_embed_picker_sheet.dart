import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/user_app.dart';
import '../utils/user_app_localization.dart';
import '../providers/app_provider.dart';
import '../utils/synapse_resource_uri.dart';
import 'user_app_tile.dart';

/// Result returned by [AppEmbedPickerSheet] when the user taps Insert.
class AppEmbedInsertion {
  const AppEmbedInsertion({required this.markdown, this.selectionOffset = 0});

  /// Markdown text ready to be inserted at the caret.
  final String markdown;

  /// Offset (relative to the start of [markdown]) at which the caret should
  /// be placed after insertion, so the user can keep typing in a useful
  /// spot (e.g. inside the `params:` block of a fenced embed scaffold).
  final int selectionOffset;
}

enum _SizePreset { small, medium, large, custom }

enum _Step { pickApp, configure }

/// Bottom sheet that lets the user choose a user app, pick a size, and
/// insert a correctly-formed embed into the note they're editing.
///
/// Returns an [AppEmbedInsertion] when the user taps Insert; returns null
/// if dismissed.
class AppEmbedPickerSheet extends StatefulWidget {
  const AppEmbedPickerSheet({super.key});

  static Future<AppEmbedInsertion?> show(BuildContext context) {
    return showModalBottomSheet<AppEmbedInsertion>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const AppEmbedPickerSheet(),
    );
  }

  @override
  State<AppEmbedPickerSheet> createState() => _AppEmbedPickerSheetState();
}

class _AppEmbedPickerSheetState extends State<AppEmbedPickerSheet> {
  _Step _step = _Step.pickApp;
  String _query = '';
  bool _includeAllTypes = false;
  UserApp? _selectedApp;

  _SizePreset _sizePreset = _SizePreset.medium;
  final TextEditingController _customWidthController = TextEditingController(
    text: '480',
  );
  final TextEditingController _customHeightController = TextEditingController(
    text: '300',
  );

  bool _passCurrentNote = true;
  bool _advanced = false;

  @override
  void dispose() {
    _customWidthController.dispose();
    _customHeightController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, scrollController) {
        return switch (_step) {
          _Step.pickApp => _buildPickStep(scrollController),
          _Step.configure => _buildConfigureStep(scrollController),
        };
      },
    );
  }

  // ---------- Step 1: Pick ----------

  Widget _buildPickStep(ScrollController scrollController) {
    final l10n = AppLocalizations.of(context)!;
    return Consumer<AppProvider>(
      builder: (context, appProvider, _) {
        final apps = _filterApps(appProvider.userApps);
        return Column(
          children: [
            _buildSheetHeader(l10n.insertUserAppTitle),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: l10n.insertUserAppSearchHint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            CheckboxListTile(
              value: _includeAllTypes,
              onChanged: (v) => setState(() => _includeAllTypes = v ?? false),
              title: Text(l10n.insertUserAppIncludeAllTypes),
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            const Divider(height: 1),
            Expanded(
              child: apps.isEmpty
                  ? Center(child: Text(l10n.insertUserAppNoAppsMessage))
                  : ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: apps.length,
                      itemBuilder: (_, i) {
                        final app = apps[i];
                        return UserAppTile(
                          app: app,
                          onTap: () => setState(() {
                            _selectedApp = app;
                            _step = _Step.configure;
                          }),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  List<UserApp> _filterApps(List<UserApp> apps) {
    final q = _query.trim().toLowerCase();
    return apps.where((a) {
      if (!_includeAllTypes && a.type != UserAppType.normal) {
        return false;
      }
      if (q.isEmpty) return true;
      return a.searchableMetadata.any(
        (value) => value.toLowerCase().contains(q),
      );
    }).toList();
  }

  // ---------- Step 2: Configure ----------

  Widget _buildConfigureStep(ScrollController scrollController) {
    final l10n = AppLocalizations.of(context)!;
    final app = _selectedApp!;
    return Column(
      children: [
        _buildSheetHeader(
          l10n.insertUserAppConfigureTitle(app.displayName(context)),
          onBack: () => setState(() => _step = _Step.pickApp),
        ),
        Expanded(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _SectionLabel(label: l10n.insertUserAppSize),
              Wrap(
                spacing: 8,
                children: [
                  _sizeChip(
                    label: l10n.insertUserAppSizeSmall,
                    preset: _SizePreset.small,
                  ),
                  _sizeChip(
                    label: l10n.insertUserAppSizeMedium,
                    preset: _SizePreset.medium,
                  ),
                  _sizeChip(
                    label: l10n.insertUserAppSizeLarge,
                    preset: _SizePreset.large,
                  ),
                  _sizeChip(
                    label: l10n.insertUserAppSizeCustom,
                    preset: _SizePreset.custom,
                  ),
                ],
              ),
              if (_sizePreset == _SizePreset.custom) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _customWidthController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(
                          labelText: l10n.insertUserAppCustomWidth,
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _customHeightController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(
                          labelText: l10n.insertUserAppCustomHeight,
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              SwitchListTile(
                value: _passCurrentNote,
                onChanged: (v) => setState(() => _passCurrentNote = v),
                title: Text(l10n.insertUserAppPassCurrentNote),
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                value: _advanced,
                onChanged: (v) => setState(() => _advanced = v),
                title: Text(l10n.insertUserAppAdvanced),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => setState(() => _step = _Step.pickApp),
                  child: Text(l10n.insertUserAppBackButton),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: Text(l10n.insertUserAppInsertButton),
                  onPressed: _onInsertPressed,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sizeChip({required String label, required _SizePreset preset}) {
    return ChoiceChip(
      label: Text(label),
      selected: _sizePreset == preset,
      onSelected: (_) => setState(() => _sizePreset = preset),
    );
  }

  Widget _buildSheetHeader(String title, {VoidCallback? onBack}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack)
          else
            const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  // ---------- Insert ----------

  (int, int) _resolveSize() {
    switch (_sizePreset) {
      case _SizePreset.small:
        return (320, 200);
      case _SizePreset.medium:
        return (480, 300);
      case _SizePreset.large:
        return (640, 400);
      case _SizePreset.custom:
        final w = int.tryParse(_customWidthController.text.trim()) ?? 480;
        final h = int.tryParse(_customHeightController.text.trim()) ?? 300;
        return (w.clamp(50, 4096), h.clamp(50, 4096));
    }
  }

  void _onInsertPressed() {
    final app = _selectedApp;
    if (app == null) return;
    Navigator.of(context).pop(_buildPayload(app));
  }

  AppEmbedInsertion _buildPayload(UserApp app) {
    final (w, h) = _resolveSize();
    if (_advanced) {
      final notesLine = _passCurrentNote ? 'notes: [current]' : 'notes: []';
      final body =
          'app: ${app.uuid}\n'
          'width: $w\n'
          'height: $h\n'
          '$notesLine\n'
          'params:\n'
          '  # Add parameters here\n';
      final scaffold = '\n```synapse-app\n$body```\n\n';
      final caretOffset = scaffold.indexOf('  # Add parameters here');
      return AppEmbedInsertion(
        markdown: scaffold,
        selectionOffset: caretOffset < 0 ? 0 : caretOffset,
      );
    }

    final uri = SynapseResourceUri.appUri(
      app.uuid,
      params: _passCurrentNote ? const {'note': 'current'} : null,
    );
    return AppEmbedInsertion(
      markdown: '\n@[${w}x$h]($uri)\n\n',
      selectionOffset: 0,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
      child: Text(label, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}
