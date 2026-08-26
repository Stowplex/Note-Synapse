import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import '../widgets/note_card.dart';
import '../widgets/multi_select_tag_filter.dart';
import '../widgets/share_dialog.dart';
import '../widgets/filter_tab_strip.dart';
import '../widgets/tag_selection_dialog.dart';
import '../models/filter.dart';
import 'note_detail_screen.dart';
import 'ai_action_screen.dart';
import 'subnote_edit_screen.dart';
import 'note_action_app_selection_screen.dart';
import 'conversation_chat_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/import_service.dart';
import '../services/logger_service.dart';
import '../services/service_locator.dart';
import '../services/attachment_link_service.dart';
import '../services/database_service.dart';
import '../services/search/bm25.dart';
import '../services/search/note_index_service.dart';
import '../services/search/notes_search_controller.dart';
import '../services/search/search_service.dart';
import '../utils/search_result_presentation.dart';
import 'immersive_note_screen.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  static const String _indexBannerDismissedPrefKey =
      'search_index_banner_dismissed';

  final _searchController = TextEditingController();
  late final NotesSearchController _search;

  /// Persisted index-banner dismissal, or null while the (async)
  /// SharedPreferences read is still in flight. Null keeps the banner hidden
  /// so an already-dismissed banner does not flash on the first frame(s).
  bool? _indexBannerDismissed;
  List<Note> _selectedNotes = [];
  bool _isMultiSelectMode = false;
  Set<String> _selectedTags = {};
  // _availableTags removed - using provider directly

  Set<String> _selectedFilterIds = {
    'default',
  }; // 'default', 'pinned', 'archived', 'all', or custom filter IDs

  /// Note ids of the search results as last rendered, and a counter bumped
  /// whenever the SAME notes come back in a DIFFERENT order — i.e. a landed
  /// semantic re-rank (plan §2.3). It keys the results list so that re-rank
  /// cross-fades instead of snapping rows into new positions.
  List<String>? _renderedResultOrder;
  int _rerankGeneration = 0;

  /// Whether the results list is scrolled to the top. A re-rank is dropped
  /// once the user starts scrolling, so this is normally true; when it is
  /// not, the cross-fade is skipped (rebuilding the list would reset the
  /// scroll offset).
  bool _resultsAtTop = true;

  @override
  void initState() {
    super.initState();
    _search = NotesSearchController(getIt<SearchService>());
    _search.addListener(_onSearchStateChanged);
    _loadIndexBannerDismissed();
  }

  void _onSearchStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadIndexBannerDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getBool(_indexBannerDismissedPrefKey) ?? false;
    if (mounted && dismissed != _indexBannerDismissed) {
      setState(() => _indexBannerDismissed = dismissed);
    }
  }

  Future<void> _dismissIndexBanner() async {
    setState(() => _indexBannerDismissed = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_indexBannerDismissedPrefKey, true);
  }

  @override
  void dispose() {
    _search.removeListener(_onSearchStateChanged);
    _search.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // _loadTags method removed

  Future<void> _importFromZip() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );

      if (result != null && result.files.single.path != null) {
        if (!mounted) return;

        // Show loading indicator
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => const Center(child: CircularProgressIndicator()),
        );

        final file = File(result.files.single.path!);
        final stats = await ImportService().importFromMarkdownZip(
          file,
          context.read<AppProvider>(),
        );

        if (!mounted) return;
        Navigator.of(context).pop(); // Dismiss loader

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import Complete: $stats'),
            backgroundColor: Colors.green,
          ),
        );

        // Refresh
        context.read<AppProvider>().loadData();
      }
    } catch (e) {
      if (!mounted) return;
      // Close loader if open?
      // Hard to know if dialog is open easily without tracking.
      // But standard interaction ensures we pop if we error after showing.
      // Assuming loader acts as barrier.
      try {
        Navigator.of(context).pop();
      } catch (_) {}

      LoggerService.error('Import Error', error: e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Import Failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final appProvider = context.watch<AppProvider>();
    // Browse pipeline (tab/tag scopes + pinned-first/newest order). Text
    // search no longer runs here (plan §1.6: off the build path): for a
    // non-empty query the ranked async results are intersected with this
    // list, so tab/tags/type act as post-filters on the search results.
    final browseNotes = _filterNotes(appProvider.notes, appProvider);
    final searchActive = _search.hasActiveQuery;
    List<_SearchRow>? searchRows;
    if (searchActive && _search.results != null) {
      final byId = {for (final n in browseNotes) n.id: n};
      searchRows = [
        for (final r in _search.results!)
          if (byId.containsKey(r.noteId)) _SearchRow(byId[r.noteId]!, r),
      ];
    }
    final notes = searchActive
        ? [for (final row in searchRows ?? const <_SearchRow>[]) row.note]
        : browseNotes;

    final allSelected =
        notes.isNotEmpty &&
        notes.every((note) => _selectedNotes.contains(note));
    final noneSelected =
        notes.isNotEmpty && !notes.any((note) => _selectedNotes.contains(note));
    final allArchived =
        _selectedNotes.isNotEmpty &&
        _selectedNotes.every((note) => note.isArchived);

    return Scaffold(
      appBar: AppBar(
        title: _isMultiSelectMode
            ? Text('${_selectedNotes.length} ${l10n.selected}')
            : Text(l10n.notes),
        actions: [
          if (_isMultiSelectMode) ...[
            IconButton(
              icon: const Icon(Icons.link),
              onPressed: _selectedNotes.length >= 2 ? _linkSelectedNotes : null,
              tooltip: l10n.linkSelectedNotes,
            ),
            IconButton(
              icon: const Icon(Icons.chrome_reader_mode),
              onPressed: _selectedNotes.isNotEmpty ? _openImmersiveMode : null,
              tooltip: l10n.immersiveMode,
            ),
            IconButton(
              icon: const Icon(Icons.psychology),
              onPressed: _selectedNotes.isNotEmpty ? _openAIAction : null,
              tooltip: l10n.openAIAction,
            ),
            IconButton(
              icon: const Icon(Icons.apps),
              onPressed: _selectedNotes.isNotEmpty ? _openNoteActionApps : null,
              tooltip: 'Run Note Action App',
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: MaterialLocalizations.of(context).showMenuTooltip,
              onSelected: (value) {
                switch (value) {
                  case 'selectAll':
                    _selectAll(notes);
                    break;
                  case 'deselectAll':
                    _deselectAll(notes);
                    break;
                  case 'share':
                    if (_selectedNotes.isNotEmpty) {
                      _shareSelectedNotes();
                    }
                    break;
                  case 'tags':
                    if (_selectedNotes.isNotEmpty) {
                      _selectTagsForSelectedNotes();
                    }
                    break;
                  case 'delete':
                    if (_selectedNotes.isNotEmpty) {
                      _deleteSelectedNotes();
                    }
                    break;
                  case 'archive_all':
                    if (_selectedNotes.isNotEmpty) {
                      _toggleArchiveSelected(archive: true);
                    }
                    break;
                  case 'unarchive_all':
                    if (_selectedNotes.isNotEmpty) {
                      _toggleArchiveSelected(archive: false);
                    }
                    break;
                }
              },
              itemBuilder: (context) => [
                if (!allSelected)
                  PopupMenuItem(
                    value: 'selectAll',
                    child: Row(
                      children: [
                        const Icon(Icons.select_all, size: 20),
                        const SizedBox(width: 8),
                        const Text('Select All'),
                      ],
                    ),
                  ),
                if (!noneSelected)
                  PopupMenuItem(
                    value: 'deselectAll',
                    child: Row(
                      children: [
                        const Icon(Icons.deselect, size: 20),
                        const SizedBox(width: 8),
                        const Text('Deselect All'),
                      ],
                    ),
                  ),
                PopupMenuItem(
                  value: 'share',
                  enabled: _selectedNotes.isNotEmpty,
                  child: Row(
                    children: [
                      const Icon(Icons.share, size: 20),
                      const SizedBox(width: 8),
                      Text(l10n.shareSelectedNotes),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'tags',
                  enabled: _selectedNotes.isNotEmpty,
                  child: Row(
                    children: [
                      const Icon(Icons.label, size: 20),
                      const SizedBox(width: 8),
                      Text('Select Tags'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  enabled: _selectedNotes.isNotEmpty,
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete,
                        color: Theme.of(context).colorScheme.error,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        l10n.deleteSelectedNotes,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: allArchived ? 'unarchive_all' : 'archive_all',
                  enabled: _selectedNotes.isNotEmpty,
                  child: Row(
                    children: [
                      Icon(
                        allArchived ? Icons.unarchive : Icons.archive,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(allArchived ? l10n.unarchiveAll : l10n.archiveAll),
                    ],
                  ),
                ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _exitMultiSelectMode,
              tooltip: l10n.exitMultiSelectMode,
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.chat),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const ConversationChatScreen(),
                  ),
                );
              },
              tooltip: 'AI Conversation',
            ),
            MultiSelectTagFilter(
              availableTags: [
                'all',
                ...context.watch<AppProvider>().getAllAvailableTags(),
              ],

              selectedTags: _selectedTags,
              onSelectionChanged: (selectedTags) {
                setState(() {
                  _selectedTags = selectedTags;
                });
              },
              allNotesLabel: l10n.allNotes,
              filterLabel: l10n.filter,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                context.read<AppProvider>().loadData();
              },
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                if (value == 'import_zip') {
                  _importFromZip();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'import_zip',
                  child: Row(
                    children: [
                      Icon(Icons.file_upload, size: 20),
                      SizedBox(width: 8),
                      Text('Import Markdown Zip'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
        bottom: _isMultiSelectMode
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(120),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Column(
                    children: [
                      // Search bar
                      TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: l10n.searchNotes,
                          prefixIcon: const Icon(Icons.search),
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                        ),
                        textInputAction: TextInputAction.search,
                        onChanged: _search.onQueryChanged,
                        onSubmitted: _search.submit,
                      ),
                      const SizedBox(height: 8),
                      // Filter tab strip
                      FilterTabStrip(
                        selectedFilterIds: _selectedFilterIds,
                        additionalSelectedTags: _selectedTags,
                        customFilters: appProvider.filters,
                        availableTags: [
                          'all',
                          ...appProvider.getAllAvailableTags(),
                        ],
                        onFilterSelected: _onFilterSelected,
                        onFilterCreated: _onFilterCreated,
                        onFilterUpdated: _onFilterUpdated,
                        onFilterDeleted: _onFilterDeleted,
                        onTagsUpdated: (tags) {
                          setState(() {
                            _selectedTags = tags;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
      ),
      body: Consumer<AppProvider>(
        builder: (context, appProvider, child) {
          // Load tags when data becomes available or when provider notifies of changes
          // Load tags callback removed

          if (appProvider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (appProvider.error != null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error, size: 64, color: Colors.red[300]),
                  const SizedBox(height: 16),
                  Text(
                    l10n.errorLoadingNotes(appProvider.error!),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => appProvider.loadData(),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          // final notes = _filterNotes(appProvider.notes, appProvider);
          // Already calculated in build method

          return Column(
            children: [
              _buildIndexBanner(l10n),
              Expanded(
                child: _buildNotesBody(l10n, searchActive, notes, searchRows),
              ),
            ],
          );
        },
      ),
    );
  }

  /// First-run "Building search index…" strip (plan §1.6): visible while the
  /// backfill runs and the user has not dismissed it; auto-hides at
  /// completion. Dismissal persists across launches (SharedPreferences).
  Widget _buildIndexBanner(AppLocalizations l10n) {
    return ValueListenableBuilder<IndexProgress>(
      valueListenable: getIt<NoteIndexService>().progress,
      builder: (context, progress, _) {
        if (!shouldShowIndexBanner(
          progress: progress,
          dismissed: _indexBannerDismissed,
        )) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        return Material(
          color: theme.colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.buildingSearchIndex(indexProgressPercent(progress)),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: l10n.dismiss,
                  onPressed: _dismissIndexBanner,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Note list / pending / empty states. The no-results empty state renders
  /// ONLY after the active search completed empty (plan §1.6: no empty-state
  /// flash while a search is in flight).
  Widget _buildNotesBody(
    AppLocalizations l10n,
    bool searchActive,
    List<Note> notes,
    List<_SearchRow>? searchRows,
  ) {
    if (searchActive && _search.isSearching && _search.results == null) {
      // First search for this query still in flight: nothing to show yet.
      return _buildSearchingIndicator(l10n);
    }

    if (notes.isEmpty) {
      if (searchActive && _search.isSearching) {
        // A refinement is in flight; don't flash "no notes found".
        return _buildSearchingIndicator(l10n);
      }
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.note_add, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              searchActive || _selectedTags.isNotEmpty
                  ? l10n.noNotesFound
                  : l10n.createFirstNote,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              searchActive || _selectedTags.isNotEmpty
                  ? searchActive
                        ? l10n.searchTryAdjustingTerms
                        : l10n.searchTryDifferentTags
                  : l10n.createFirstNoteHint,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final Widget list = NotificationListener<ScrollNotification>(
      // Fusion UX (plan §2.3): once the user scrolls, a pending semantic
      // re-rank is dropped rather than moving rows under their finger.
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          _search.notifyUserInteraction();
        }
        _resultsAtTop = notification.metrics.pixels <= 0;
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: notes.length,
        itemBuilder: (context, index) {
          if (searchActive) {
            final row = searchRows![index];
            return Padding(
              key: ValueKey('search-${row.note.id}'),
              padding: const EdgeInsets.only(bottom: 8),
              child: _buildSearchResultRow(row),
            );
          }
          final note = notes[index];
          return Padding(
            key: ValueKey('note-${note.id}'),
            padding: const EdgeInsets.only(bottom: 8),
            child: GestureDetector(
              onTap: () => _handleNoteTap(note),
              onLongPress: () => _handleNoteLongPress(note),
              child: _buildNoteCard(note),
            ),
          );
        },
      ),
    );
    final Widget body = searchActive
        // A landed re-rank reorders rows that are already on screen; cross-
        // fading is the cheap way to make that legible instead of abrupt.
        // The key only changes on a reorder, so a new query (different
        // result set) still rebuilds in place, scroll position included.
        ? AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: KeyedSubtree(
              key: ValueKey<int>(_trackResultOrder(searchRows)),
              child: list,
            ),
          )
        : list;
    if (searchActive && (_search.isSearching || _search.isRefining)) {
      // Search or semantic refinement in flight over existing results:
      // lightweight indicator, results keep standing.
      return Column(
        children: [
          const LinearProgressIndicator(minHeight: 2),
          Expanded(child: body),
        ],
      );
    }
    return body;
  }

  /// Records the rendered result order and returns the cross-fade key for
  /// the results list: it changes ONLY when the same notes come back in a
  /// different order (a landed semantic re-rank) while the list is at the
  /// top. Every other change — new query, added/removed notes, a scrolled
  /// list — keeps the key and rebuilds the list in place.
  int _trackResultOrder(List<_SearchRow>? rows) {
    final order = [for (final row in rows ?? const <_SearchRow>[]) row.note.id];
    final previous = _renderedResultOrder;
    _renderedResultOrder = order;
    if (previous == null || previous.length != order.length || !_resultsAtTop) {
      return _rerankGeneration;
    }
    var reordered = false;
    for (var i = 0; i < order.length; i++) {
      if (previous[i] != order[i]) {
        reordered = true;
        break;
      }
    }
    if (!reordered) return _rerankGeneration;
    // A re-rank permutes the notes it was handed; anything with different
    // membership is a new result set, not a reorder.
    if (!previous.toSet().containsAll(order)) return _rerankGeneration;
    return ++_rerankGeneration;
  }

  Widget _buildSearchingIndicator(AppLocalizations l10n) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.searchInProgress,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  /// Today's browse card, shared by the browse list and degraded search rows.
  Widget _buildNoteCard(Note note) {
    return NoteCard(
      note: note,
      isSelected: _selectedNotes.contains(note),
      onTap: () => _handleNoteTap(note),
      onLongPress: () => _handleNoteLongPress(note),
      onStatusChanged: note.isTask
          ? (status) => _updateTaskStatus(note.id, status)
          : null,
      onAddSubNote: () => _addSubNote(note),
      onPinToggle: () => _toggleNotePin(note.id),
      onArchiveToggle: () => _toggleNoteArchive(note.id),
      onShare: () => _shareNote(note),
      onContentChanged: (newContent) => _updateNoteContent(note.id, newContent),
    );
  }

  /// One ranked search hit: title + highlighted snippet + provenance badge.
  /// Rows without a snippet (substring-fallback results can carry none)
  /// degrade to today's card rendering.
  Widget _buildSearchResultRow(_SearchRow row) {
    final snippet = row.result.best.snippet;
    if (snippet.text.trim().isEmpty) {
      return GestureDetector(
        onTap: () => _handleNoteTap(row.note),
        onLongPress: () => _handleNoteLongPress(row.note),
        child: _buildNoteCard(row.note),
      );
    }

    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final note = row.note;
    final isSelected = _selectedNotes.contains(note);
    final badge = deriveSearchBadge(
      sourceType: row.result.best.sourceType,
      page: row.result.best.page,
    );
    final badgeLabel = _badgeLabel(badge, l10n);

    return Card(
      shape: isSelected
          ? RoundedRectangleBorder(
              side: BorderSide(color: theme.colorScheme.primary, width: 2),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _handleSearchResultTap(row),
        onLongPress: () => _handleNoteLongPress(note),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      note.title,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isSelected)
                    Icon(
                      Icons.check_circle,
                      color: theme.colorScheme.primary,
                      size: 20,
                    ),
                ],
              ),
              const SizedBox(height: 6),
              RichText(
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  children: _snippetSpans(snippet, theme),
                ),
              ),
              if (badgeLabel != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(badgeLabel, style: theme.textTheme.labelSmall),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// TextSpans for [snippet] with bold-highlighted match ranges
  /// (Snippet.matches are UTF-16 ranges). Every whitespace CHARACTER is
  /// replaced by one space so the snippet renders on a single line; runs are
  /// not collapsed (`\n\n` becomes two spaces), which keeps the replacement
  /// 1:1 and match offsets valid.
  List<TextSpan> _snippetSpans(Snippet snippet, ThemeData theme) {
    final text = snippet.text.replaceAll(RegExp(r'\s'), ' ');
    final highlight = TextStyle(
      fontWeight: FontWeight.bold,
      color: theme.colorScheme.primary,
    );
    final spans = <TextSpan>[];
    if (snippet.truncatedStart) spans.add(const TextSpan(text: '…'));
    var cursor = 0;
    for (final match in snippet.matches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: highlight,
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    if (snippet.truncatedEnd) spans.add(const TextSpan(text: '…'));
    return spans;
  }

  String? _badgeLabel(SearchSourceBadge badge, AppLocalizations l10n) {
    switch (badge.kind) {
      case SearchBadgeKind.none:
        return null;
      case SearchBadgeKind.pdfPage:
        return l10n.searchBadgePdfPage(badge.page!);
      case SearchBadgeKind.attachment:
        return l10n.searchBadgeAttachment;
      case SearchBadgeKind.image:
        return l10n.searchBadgeImage;
      case SearchBadgeKind.subnote:
        return l10n.searchBadgeSubnote;
      case SearchBadgeKind.tag:
        return l10n.searchBadgeTag;
      case SearchBadgeKind.annotation:
        return l10n.searchBadgeAnnotation;
    }
  }

  /// Attachment-derived hits deep-link into the attachment (at its 1-based
  /// [NoteSearchResult.page], converted to the screen's 0-based initialPage)
  /// instead of opening the note editor. Everything else falls through to
  /// the normal note tap (which also handles multi-select toggling).
  Future<void> _handleSearchResultTap(_SearchRow row) async {
    // Fusion UX (plan §2.3): a tap drops any pending semantic re-rank.
    _search.notifyUserInteraction();
    final result = row.result;
    if (!_isMultiSelectMode && result.attachmentId != null) {
      try {
        final resolved = await AttachmentLinkService(
          getIt<DatabaseService>(),
        ).resolveAttachmentLink(result.attachmentId!);
        if (resolved != null) {
          final path = await resolved.attachment.getAbsolutePath();
          if (!mounted) return;
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => ImmersiveNoteScreen(
                notes: [resolved.note],
                initialAttachmentPath: path,
                initialPage: result.page != null && result.page! > 0
                    ? result.page! - 1
                    : null,
              ),
            ),
          );
          return;
        }
      } catch (e) {
        LoggerService.error('Search deep link failed: $e', error: e);
      }
    }
    _handleNoteTap(row.note);
  }

  void _onFilterSelected(Set<String> filterIds) {
    setState(() {
      _selectedFilterIds = filterIds;
    });
  }

  void _onFilterCreated(Filter filter) {
    context.read<AppProvider>().addFilter(filter);
  }

  void _onFilterUpdated(Filter filter) {
    context.read<AppProvider>().updateFilter(filter);
  }

  void _onFilterDeleted(String filterId) {
    context.read<AppProvider>().deleteFilter(filterId);
    // If the deleted filter was selected, remove it
    if (_selectedFilterIds.contains(filterId)) {
      setState(() {
        _selectedFilterIds.remove(filterId);
        if (_selectedFilterIds.isEmpty) {
          _selectedFilterIds = {'default'};
        }
      });
    }
  }

  List<Note> _filterNotes(List<Note> notes, AppProvider appProvider) {
    List<Note> filteredNotes = notes;

    // Combine notes from all selected filters (Union)
    Set<String> noteIds = {};
    List<Note> unionNotes = [];

    // If 'all' is selected, it overrides everything else
    if (_selectedFilterIds.contains('all')) {
      // No filtering needed for 'all' (except search/tags later)
      // But we need to handle other filters if 'all' is NOT selected.
      // Wait, if 'all' is selected, we start with ALL notes.
      // If we have 'all' AND 'pinned', do we show all? Yes.
      // So if 'all' is present, we can just use 'notes' as base.
      filteredNotes = notes;
    } else {
      for (final filterId in _selectedFilterIds) {
        List<Note> subset = [];
        if (filterId == 'default') {
          subset = notes.where((note) => !note.isArchived).toList();
        } else if (filterId == 'pinned') {
          subset = notes
              .where((note) => note.pinned && !note.isArchived)
              .toList();
        } else if (filterId == 'archived') {
          subset = notes.where((note) => note.isArchived).toList();
        } else {
          // Custom filter
          try {
            final customFilter = appProvider.filters.firstWhere(
              (filter) => filter.id == filterId,
            );
            subset = appProvider.getFilteredNotes(customFilter);
          } catch (e) {
            // Filter might not exist (deleted?), skip
            continue;
          }
        }

        for (final note in subset) {
          if (noteIds.add(note.id)) {
            unionNotes.add(note);
          }
        }
      }
      filteredNotes = unionNotes;
    }

    // Filter by tags (OR logic - show notes that have ANY of the selected tags)
    if (_selectedTags.isNotEmpty) {
      filteredNotes = filteredNotes.where((note) {
        return _selectedTags.any(
          (selectedTag) => note.tags.contains(selectedTag),
        );
      }).toList();
    }

    // Text search is handled by NotesSearchController (SearchService) — this
    // pipeline only applies the non-text scopes and the browse order.

    // Sort by pinned status first, then by creation date
    filteredNotes.sort((a, b) {
      if (a.pinned && !b.pinned) return -1;
      if (!a.pinned && b.pinned) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });

    return filteredNotes;
  }

  void _handleNoteTap(Note note) {
    _search.notifyUserInteraction();
    if (_isMultiSelectMode) {
      setState(() {
        if (_selectedNotes.contains(note)) {
          _selectedNotes.remove(note);
        } else {
          _selectedNotes.add(note);
        }
      });
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => NoteDetailScreen(note: note)),
      );
    }
  }

  void _handleNoteLongPress(Note note) {
    if (!_isMultiSelectMode) {
      setState(() {
        _isMultiSelectMode = true;
        _selectedNotes = [note];
      });
    }
  }

  void _exitMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = false;
      _selectedNotes.clear();
    });
  }

  void _selectAll(List<Note> currentNotes) {
    setState(() {
      for (final note in currentNotes) {
        if (!_selectedNotes.contains(note)) {
          _selectedNotes.add(note);
        }
      }
    });
  }

  void _deselectAll(List<Note> currentNotes) {
    setState(() {
      for (final note in currentNotes) {
        _selectedNotes.remove(note);
      }
      // If no notes selected at all, exit multi-select mode?
      // User said: "If none are selected, 'Deselect All' will not be visible."
      // This implies we stay in the mode but with 0 selected?
      // But usually 0 selected means exit.
      // Let's check _handleNoteTap logic. It removes note.
      // If list is empty, it doesn't exit mode automatically there.
      // But _exitMultiSelectMode is called by 'X' button.
      // So we can stay in mode with 0 items.
    });
  }

  void _deleteSelectedNotes() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Notes'),
        content: Text(
          'Are you sure you want to delete ${_selectedNotes.length} note(s)?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              for (final note in _selectedNotes) {
                context.read<AppProvider>().deleteNote(note.id);
              }
              _exitMultiSelectMode();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _openImmersiveMode() {
    if (_selectedNotes.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            ImmersiveNoteScreen(notes: List<Note>.from(_selectedNotes)),
      ),
    );
  }

  void _openAIAction() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AIActionScreen(selectedNotes: _selectedNotes),
      ),
    );
  }

  void _openNoteActionApps() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            NoteActionAppSelectionScreen(selectedNotes: _selectedNotes),
      ),
    );
  }

  void _updateTaskStatus(String noteId, TaskStatus status) {
    context.read<AppProvider>().updateTaskStatus(noteId, status);
  }

  void _toggleNotePin(String noteId) {
    context.read<AppProvider>().toggleNotePin(noteId);
  }

  void _toggleNoteArchive(String noteId) {
    final appProvider = context.read<AppProvider>();
    final note = appProvider.notes.firstWhere((n) => n.id == noteId);

    // Check if trying to archive a pinned note
    if (!note.isArchived && note.pinned) {
      final l10n = AppLocalizations.of(context)!;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Cannot Archive Pinned Note'),
          content: const Text(
            'Please unpin the note first before archiving it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.yes),
            ),
          ],
        ),
      );
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final action = note.isArchived ? 'unarchive' : 'archive';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          action == 'archive' ? l10n.archiveNote : l10n.unarchiveNote,
        ),
        content: Text(
          action == 'archive'
              ? 'Are you sure you want to archive this note?'
              : 'Are you sure you want to unarchive this note?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              final updatedNote = note.copyWith(
                isArchived: !note.isArchived,
                pinned: note.isArchived
                    ? note.pinned
                    : false, // Unpin when archiving
                updatedAt: DateTime.now(),
              );
              appProvider.updateNote(updatedNote);
            },
            child: Text(
              action == 'archive' ? l10n.archiveNote : l10n.unarchiveNote,
            ),
          ),
        ],
      ),
    );
  }

  void _linkSelectedNotes() {
    if (_selectedNotes.length < 2) return;

    final firstNote = _selectedNotes.first;
    final otherNotes = _selectedNotes.skip(1).toList();

    showDialog(
      context: context,
      builder: (context) => _LinkNotesDialog(
        fromNote: firstNote,
        toNotes: otherNotes,
        onLink: (relationshipType) {
          Navigator.pop(context);
          context.read<AppProvider>().createNoteRelationships(
            firstNote.id,
            otherNotes.map((n) => n.id).toList(),
            relationshipType,
          );
          _exitMultiSelectMode();
        },
      ),
    );
  }

  void _addSubNote(Note note) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SubNoteEditScreen(parentNote: note),
      ),
    );
  }

  void _updateNoteContent(String noteId, String newContent) async {
    final appProvider = context.read<AppProvider>();
    await appProvider.updateNoteContent(noteId, newContent);
  }

  void _shareNote(Note note) {
    showDialog(
      context: context,
      builder: (context) => ShareDialog(notes: [note], title: note.title),
    );
  }

  void _shareSelectedNotes() {
    showDialog(
      context: context,
      builder: (context) => ShareDialog(
        notes: _selectedNotes,
        title: '${_selectedNotes.length} Notes',
      ),
    );
  }

  void _selectTagsForSelectedNotes() async {
    if (_selectedNotes.isEmpty) return;

    // Calculate common tags
    final commonTags =
        _selectedNotes.fold<Set<String>?>(null, (common, note) {
          if (common == null) {
            return note.tags.toSet();
          }
          return common.intersection(note.tags.toSet());
        }) ??
        {};

    final appProvider = context.read<AppProvider>();
    final l10n = AppLocalizations.of(context)!;

    // Show tag selection dialog
    final finalTags = await showDialog<List<String>>(
      context: context,
      builder: (context) => TagSelectionDialog(
        initialSelectedTags: commonTags.toList(),

        title: l10n.selectTagsForNotes(_selectedNotes.length),
      ),
    );

    if (finalTags == null) return;

    // Calculate tags to add and remove
    final tagsToAdd = finalTags
        .where((tag) => !commonTags.contains(tag))
        .toList();
    final tagsToRemove = commonTags
        .where((tag) => !finalTags.contains(tag))
        .toList();

    if (tagsToAdd.isEmpty && tagsToRemove.isEmpty) return;

    // Apply changes
    await appProvider.batchUpdateTags(
      _selectedNotes.map((n) => n.id).toList(),
      tagsToAdd,
      tagsToRemove,
    );

    _exitMultiSelectMode();
  }

  void _toggleArchiveSelected({required bool archive}) {
    final appProvider = context.read<AppProvider>();
    final l10n = AppLocalizations.of(context)!;

    // Check for pinned notes if archiving
    if (archive) {
      final pinnedNotes = _selectedNotes.where((n) => n.pinned).toList();
      if (pinnedNotes.isNotEmpty) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Cannot Archive Pinned Notes'),
            content: Text(
              'There are ${pinnedNotes.length} pinned notes selected. Please unpin them first before archiving.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.yes),
              ),
            ],
          ),
        );
        return;
      }
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(archive ? l10n.archiveAll : l10n.unarchiveAll),
        content: Text(
          archive
              ? 'Are you sure you want to archive ${_selectedNotes.length} notes?'
              : 'Are you sure you want to unarchive ${_selectedNotes.length} notes?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              for (final note in _selectedNotes) {
                // If archiving: set isArchived=true, pinned=false (done by check above but safe to enforce)
                // If unarchiving: set isArchived=false.
                final updatedNote = note.copyWith(
                  isArchived: archive,
                  pinned: archive ? false : note.pinned,
                  updatedAt: DateTime.now(),
                );
                appProvider.updateNote(updatedNote);
              }
              _exitMultiSelectMode();
            },
            child: Text(archive ? l10n.archiveAll : l10n.unarchiveAll),
          ),
        ],
      ),
    );
  }
}

/// A ranked search hit paired with its (post-filter-visible) note.
class _SearchRow {
  const _SearchRow(this.note, this.result);

  final Note note;
  final NoteSearchResult result;
}

class _LinkNotesDialog extends StatefulWidget {
  final Note fromNote;
  final List<Note> toNotes;
  final Function(String) onLink;

  const _LinkNotesDialog({
    required this.fromNote,
    required this.toNotes,
    required this.onLink,
  });

  @override
  State<_LinkNotesDialog> createState() => _LinkNotesDialogState();
}

class _LinkNotesDialogState extends State<_LinkNotesDialog> {
  String _selectedRelationshipType = RelationshipType.related;
  final TextEditingController _customTypeController = TextEditingController();

  @override
  void dispose() {
    _customTypeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(l10n.linkNotesDialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.linkNoteTo(widget.fromNote.title),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...widget.toNotes.map(
              (note) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '• ${note.title}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.relationshipType,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _selectedRelationshipType,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              items: [
                ...RelationshipType.predefined.map(
                  (type) => DropdownMenuItem(
                    value: type,
                    child: Row(
                      children: [
                        Icon(RelationshipType.getIcon(type), size: 20),
                        const SizedBox(width: 8),
                        Text(RelationshipType.getDisplayName(type)),
                      ],
                    ),
                  ),
                ),
                DropdownMenuItem(
                  value: 'custom',
                  child: Row(
                    children: [
                      Icon(Icons.edit, size: 20),
                      const SizedBox(width: 8),
                      Text(l10n.customEllipsis),
                    ],
                  ),
                ),
              ],
              onChanged: (value) {
                setState(() {
                  _selectedRelationshipType = value!;
                });
              },
            ),
            if (_selectedRelationshipType == 'custom') ...[
              const SizedBox(height: 16),
              TextField(
                controller: _customTypeController,
                decoration: InputDecoration(
                  labelText: l10n.customRelationshipType,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (value) {
                  setState(() {
                    _selectedRelationshipType = value;
                  });
                },
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          onPressed: () {
            final relationshipType = _selectedRelationshipType == 'custom'
                ? _customTypeController.text.trim()
                : _selectedRelationshipType;
            if (relationshipType.isNotEmpty) {
              widget.onLink(relationshipType);
            }
          },
          child: Text(l10n.link),
        ),
      ],
    );
  }
}
