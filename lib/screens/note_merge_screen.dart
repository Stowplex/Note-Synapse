import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';

import '../l10n/app_localizations.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
import '../services/logger_service.dart';
import '../services/note_merge_service.dart';
import '../services/service_locator.dart';
import '../utils/merge_document.dart';
import '../widgets/block_diff_preview_dialog.dart';
import '../widgets/merge_arrange_list.dart';
import '../widgets/merge_source_tab.dart';
import '../widgets/synapse_note_editor.dart';
import 'note_selection_dialog.dart';

enum _MergeView { arrange, edit }

enum _SaveMode { newNote, replace }

class _SaveChoice {
  _SaveChoice({
    required this.mode,
    required this.tags,
    required this.linkBack,
    required this.archiveOthers,
    required this.keptAttachmentPaths,
  });

  final _SaveMode mode;
  final List<String> tags;
  final bool linkBack;
  final bool archiveOthers;

  /// Source attachments the content does not mention but the user chose to
  /// carry over anyway.
  final List<String> keptAttachmentPaths;
}

/// Colours that tell the sources apart, in the tab bar and on every block
/// taken from them. Cycles past the end.
const List<Color> kMergeSourcePalette = [
  Color(0xFF1E88E5), // blue
  Color(0xFFFB8C00), // orange
  Color(0xFF43A047), // green
  Color(0xFF8E24AA), // purple
  Color(0xFF00897B), // teal
  Color(0xFFD81B60), // pink
  Color(0xFF3949AB), // indigo
  Color(0xFF6D4C41), // brown
];

Color mergeSourceColor(MergeSource source) =>
    kMergeSourcePalette[source.colorIndex % kMergeSourcePalette.length];

/// Combine several notes into one by picking blocks from each.
///
/// Pops with the resulting [Note] after a save, or with null if the user
/// backed out.
class NoteMergeScreen extends StatefulWidget {
  const NoteMergeScreen({super.key, required this.notes});

  /// Initial sources, in tab order. May be a single note; the user is then
  /// asked to pick more.
  final List<Note> notes;

  @override
  State<NoteMergeScreen> createState() => _NoteMergeScreenState();
}

class _NoteMergeScreenState extends State<NoteMergeScreen>
    with TickerProviderStateMixin {
  final MergeDocument _doc = MergeDocument();
  late TabController _tabController;
  int _lastTab = 0;

  _MergeView _view = _MergeView.arrange;
  late final TextEditingController _titleController;
  late final CodeLineEditingController _codeController;
  final FocusNode _editorFocus = FocusNode();

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final note in widget.notes) {
      _doc.addSource(note);
    }
    _titleController = TextEditingController(
      text: widget.notes.isEmpty ? '' : widget.notes.first.title,
    );
    _codeController = CodeLineEditingController.fromText('');
    _codeController.addListener(_onEditorTextChanged);
    _tabController = _makeTabController(0);

    if (_doc.sources.length < 2) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _addNotes());
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _titleController.dispose();
    _codeController.removeListener(_onEditorTextChanged);
    _codeController.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ tabs

  TabController _makeTabController(int index) {
    final length = _doc.sources.length + 1;
    final controller = TabController(
      length: length,
      vsync: this,
      initialIndex: index.clamp(0, length - 1),
    );
    _lastTab = controller.index;
    controller.addListener(_onTabChanged);
    return controller;
  }

  void _rebuildTabController(int index) {
    final old = _tabController;
    old.removeListener(_onTabChanged);
    // A rebuilt controller does not notify, so the editor sync that a normal
    // tab switch would do has to happen here.
    final length = _doc.sources.length + 1;
    _syncEditor(from: _lastTab, to: index.clamp(0, length - 1));
    setState(() {
      _tabController = _makeTabController(index);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  /// Keeps the Edit view's text and the document in step across tab switches:
  /// leaving the Merged tab commits typed text, returning to it reloads.
  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final index = _tabController.index;
    if (index == _lastTab) return;
    _syncEditor(from: _lastTab, to: index);
    _lastTab = index;
    if (mounted) setState(() {});
  }

  void _syncEditor({required int from, required int to}) {
    if (_view != _MergeView.edit || from == to) return;
    if (from == 0) {
      _commitEditorText();
    } else if (to == 0) {
      _loadEditorText();
    }
  }

  /// Typed text counts as unsaved work: keep the discard guard and the Save
  /// button in step without re-parsing on every keystroke.
  bool _editorHasText = false;
  void _onEditorTextChanged() {
    final hasText = _codeController.text.trim().isNotEmpty;
    if (hasText != _editorHasText) {
      _editorHasText = hasText;
      if (mounted) setState(() {});
    }
  }

  void _commitEditorText() {
    _doc.replaceFromText(_codeController.text);
  }

  void _loadEditorText() {
    final text = _doc.flatten();
    if (_codeController.text != text) _codeController.text = text;
  }

  void _onDocumentChanged() {
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------ sources

  Future<void> _addNotes() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showDialog<List<Note>>(
      context: context,
      builder: (dialogContext) => NoteSelectionDialog(
        onNotesSelected: (notes) => Navigator.of(dialogContext).pop(notes),
        title: l10n.mergeSelectNotesTitle,
        initialSelectedNoteIds: _doc.sources.map((s) => s.id).toList(),
      ),
    );
    if (!mounted) return;

    final fresh = (picked ?? const <Note>[])
        .where((n) => _doc.sourceFor(n.id) == null)
        .toList();
    if (fresh.isEmpty) {
      if (_doc.sources.length < 2) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.mergeNeedsSecondNote)));
      }
      return;
    }

    MergeSource? first;
    for (final note in fresh) {
      first ??= _doc.addSource(note);
      _doc.addSource(note);
    }
    _rebuildTabController(_doc.sources.indexOf(first!) + 1);
  }

  Future<void> _removeSource(MergeSource source) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.mergeRemoveSource),
        content: Text(l10n.mergeRemoveSourceBody(source.note.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.mergeRemoveSource),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _doc.removeSource(source);
    _rebuildTabController(0);
  }

  // ------------------------------------------------------------ views

  void _switchView(_MergeView view) {
    if (view == _view) return;
    setState(() {
      if (view == _MergeView.edit) {
        _loadEditorText();
      } else {
        _commitEditorText();
      }
      _view = view;
    });
  }

  String get _combinedTitle =>
      _doc.sources.map((s) => s.note.title.trim()).where((t) => t.isNotEmpty).join(' + ');

  bool get _isDirty {
    if (!_doc.isEmpty) return true;
    if (_view == _MergeView.edit && _editorHasText) return true;
    return false;
  }

  // ------------------------------------------------------------ save

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (_view == _MergeView.edit && _tabController.index == 0) {
      _commitEditorText();
    }
    final content = _doc.flatten();
    if (content.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.mergeNothingToSave)));
      return;
    }

    final sources = _doc.sources.map((s) => s.note).toList();
    // Attachments linked by id can carry any label, so the file name alone
    // does not reveal that the merged note needs the file.
    final linkedPaths = await getIt<NoteMergeService>()
        .linkedSourceAttachmentPaths(content, sources.map((n) => n.id));
    if (!mounted) return;
    final choice = await _showSaveSheet(sources, content, linkedPaths);
    if (choice == null || !mounted) return;

    final target = sources.first;
    if (choice.mode == _SaveMode.replace) {
      final accepted = await BlockDiffPreviewDialog.show(
        context,
        original: target.content,
        transformed: content,
      );
      if (!accepted || !mounted) return;
    }

    setState(() => _saving = true);
    try {
      final merged = await _persist(
        content: content,
        sources: sources,
        choice: choice,
        linkedPaths: linkedPaths,
      );
      if (!mounted) return;
      Navigator.of(context).pop(merged);
    } catch (e, st) {
      LoggerService.error('Merge save failed: $e', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.mergeSaveFailed(e.toString()))),
      );
    }
  }

  Future<Note> _persist({
    required String content,
    required List<Note> sources,
    required _SaveChoice choice,
    required List<String> linkedPaths,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final service = getIt<NoteMergeService>();
    final appProvider = context.read<AppProvider>();
    final typedTitle = _titleController.text.trim();
    final title = typedTitle.isEmpty ? l10n.untitled : typedTitle;
    final sourceIds = sources.map((n) => n.id).toList();

    final Note merged;
    if (choice.mode == _SaveMode.newNote) {
      final draft = service.buildNewNote(
        title: title,
        content: content,
        tags: choice.tags,
        attachmentPaths: const [],
      );
      final copied = await service.copyNoteScopedImages(
        content: content,
        sourceNoteIds: sourceIds,
        targetNoteId: draft.id,
      );
      final fetched = await service.fetchMissingRemoteImages(
        content: content,
        targetNoteId: draft.id,
      );
      merged = draft.copyWith(
        attachmentPaths: NoteMergeService.referencedAttachmentPaths(
          content,
          sources,
          extraAttachmentPaths: [
            ...linkedPaths,
            ...choice.keptAttachmentPaths,
            ...copied,
            ...fetched,
          ],
        ),
      );
      await appProvider.addNote(merged);
    } else {
      final target = sources.first;
      final copied = await service.copyNoteScopedImages(
        content: content,
        sourceNoteIds: sourceIds.where((id) => id != target.id),
        targetNoteId: target.id,
      );
      final fetched = await service.fetchMissingRemoteImages(
        content: content,
        targetNoteId: target.id,
      );
      merged = service.buildReplacement(
        target,
        title: title,
        content: content,
        tags: choice.tags,
        attachmentPaths: NoteMergeService.referencedAttachmentPaths(
          content,
          sources,
          extraAttachmentPaths: [
            ...linkedPaths,
            ...choice.keptAttachmentPaths,
            ...copied,
            ...fetched,
          ],
        ),
      );
      await appProvider.updateNote(merged);
    }

    // Now that the merged note owns rows for the files, point attachment
    // links at them so deleting a source later cannot break the merged note.
    final adopted = await service.adoptSourceAttachments(
      mergedNoteId: merged.id,
      sourceNoteIds: sourceIds,
      content: content,
    );
    if (adopted != content) {
      final current = appProvider.notes.firstWhere(
        (n) => n.id == merged.id,
        orElse: () => merged,
      );
      await appProvider.updateNote(
        current.copyWith(content: adopted, updatedAt: DateTime.now()),
      );
    }

    if (choice.linkBack) {
      await service.linkToSources(
        merged.id,
        sourceIds.where((id) => id != merged.id),
      );
    }

    if (choice.archiveOthers) {
      for (final source in sources) {
        if (source.id == merged.id) continue;
        // Re-read: the snapshot handed to this screen may be stale, and a
        // whole-note write from it would undo anything that changed since.
        final fresh = appProvider.notes.firstWhere(
          (n) => n.id == source.id,
          orElse: () => source,
        );
        // Same rule as the notes list: pinned notes are never archived.
        if (fresh.isArchived || fresh.pinned) continue;
        await appProvider.updateNote(
          fresh.copyWith(isArchived: true, updatedAt: DateTime.now()),
        );
      }
    }

    return appProvider.notes.firstWhere(
      (n) => n.id == merged.id,
      orElse: () => merged,
    );
  }

  Future<_SaveChoice?> _showSaveSheet(
    List<Note> sources,
    String content,
    List<String> linkedPaths,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final target = sources.first;
    var mode = _SaveMode.newNote;
    final tags = NoteMergeService.unionTags(sources);
    var linkBack = true;
    var archiveOthers = false;
    final others = sources.length - 1;
    final hasPinnedOther = sources.skip(1).any((n) => n.pinned);
    final otherAttachments = NoteMergeService.unreferencedAttachmentPaths(
      content,
      sources,
      alsoReferenced: linkedPaths,
    );
    final kept = <String>{};

    return showModalBottomSheet<_SaveChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final theme = Theme.of(context);
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _titleController.text.trim().isEmpty
                          ? l10n.untitled
                          : _titleController.text.trim(),
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    RadioGroup<_SaveMode>(
                      groupValue: mode,
                      onChanged: (v) => setSheetState(() => mode = v!),
                      child: Column(
                        children: [
                          RadioListTile<_SaveMode>(
                            contentPadding: EdgeInsets.zero,
                            value: _SaveMode.newNote,
                            title: Text(l10n.mergeSaveAsNew),
                          ),
                          RadioListTile<_SaveMode>(
                            contentPadding: EdgeInsets.zero,
                            value: _SaveMode.replace,
                            title: Text(l10n.mergeReplaceNote(target.title)),
                            subtitle: mode == _SaveMode.replace
                                ? Text(
                                    l10n.mergeReplaceWarning(
                                      target.title,
                                      others,
                                    ),
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(l10n.tags, style: theme.textTheme.labelLarge),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final tag in tags)
                            InputChip(
                              label: Text(tag),
                              visualDensity: VisualDensity.compact,
                              onDeleted: () =>
                                  setSheetState(() => tags.remove(tag)),
                            ),
                        ],
                      ),
                    ],
                    if (otherAttachments.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        l10n.mergeOtherAttachments,
                        style: theme.textTheme.labelLarge,
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final path in otherAttachments)
                            FilterChip(
                              label: Text(path.split('/').last),
                              visualDensity: VisualDensity.compact,
                              selected: kept.contains(path),
                              onSelected: (v) => setSheetState(() {
                                if (v) {
                                  kept.add(path);
                                } else {
                                  kept.remove(path);
                                }
                              }),
                            ),
                        ],
                      ),
                    ],
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: linkBack,
                      onChanged: (v) => setSheetState(() => linkBack = v),
                      title: Text(l10n.mergeLinkBack),
                    ),
                    if (others > 0)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: archiveOthers,
                        onChanged: (v) =>
                            setSheetState(() => archiveOthers = v),
                        title: Text(l10n.mergeArchiveOthers),
                        subtitle: hasPinnedOther
                            ? Text(l10n.mergeArchiveOthersPinned)
                            : null,
                      ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(
                        context,
                        _SaveChoice(
                          mode: mode,
                          tags: List.of(tags),
                          linkBack: linkBack,
                          archiveOthers: archiveOthers,
                          keptAttachmentPaths: otherAttachments
                              .where(kept.contains)
                              .toList(),
                        ),
                      ),
                      child: Text(
                        mode == _SaveMode.newNote
                            ? l10n.mergeSaveAsNew
                            : l10n.mergeReplaceNote(target.title),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------ discard

  Future<void> _onPopInvoked(bool didPop, Object? result) async {
    if (didPop) return;
    final l10n = AppLocalizations.of(context)!;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.mergeDiscardTitle),
        content: Text(l10n.mergeDiscardBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.mergeDiscard),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.mergeNotes),
          actions: [
            if (_saving)
              const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              TextButton(
                onPressed: _isDirty ? _save : null,
                child: Text(l10n.save),
              ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(kTextTabBarHeight),
            child: Row(
              children: [
                Expanded(
                  child: TabBar(
                    controller: _tabController,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      Tab(text: l10n.mergeTabMerged(_doc.blockCount)),
                      for (final source in _doc.sources)
                        Tab(
                          child: GestureDetector(
                            onLongPress: () => _removeSource(source),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.circle,
                                  size: 10,
                                  color: mergeSourceColor(source),
                                ),
                                const SizedBox(width: 6),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 160,
                                  ),
                                  child: Text(
                                    source.note.title.trim().isEmpty
                                        ? l10n.untitled
                                        : source.note.title,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: l10n.mergeAddNotes,
                  icon: const Icon(Icons.add),
                  onPressed: _saving ? null : _addNotes,
                ),
              ],
            ),
          ),
        ),
        body: AbsorbPointer(
          absorbing: _saving,
          child: TabBarView(
            controller: _tabController,
            physics: _view == _MergeView.edit
                ? const NeverScrollableScrollPhysics()
                : null,
            children: [
              _buildMergedTab(l10n, theme),
              for (final source in _doc.sources)
                MergeSourceTab(
                  key: ValueKey('merge-source-${source.id}'),
                  document: _doc,
                  source: source,
                  color: mergeSourceColor(source),
                  onChanged: _onDocumentChanged,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMergedTab(AppLocalizations l10n, ThemeData theme) {
    final combined = _combinedTitle;
    final showCombinedHint =
        combined.isNotEmpty && _titleController.text.trim() != combined;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _titleController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: l10n.title,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: showCombinedHint
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () => setState(
                            () => _titleController.text = combined,
                          ),
                          child: Text(
                            l10n.mergeUseCombinedTitle(combined),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              SegmentedButton<_MergeView>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
                segments: [
                  ButtonSegment(
                    value: _MergeView.arrange,
                    icon: const Icon(Icons.view_agenda_outlined),
                    label: Text(l10n.mergeArrange),
                  ),
                  ButtonSegment(
                    value: _MergeView.edit,
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(l10n.mergeEdit),
                  ),
                ],
                selected: {_view},
                onSelectionChanged: (s) => _switchView(s.first),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: _view == _MergeView.arrange
              ? MergeArrangeList(
                  document: _doc,
                  colorOf: mergeSourceColor,
                  fallbackNoteId: _doc.sources.isEmpty
                      ? ''
                      : _doc.sources.first.id,
                  onChanged: _onDocumentChanged,
                )
              : SynapseNoteEditor(
                  controller: _codeController,
                  focusNode: _editorFocus,
                  language: 'markdown',
                ),
        ),
      ],
    );
  }
}
