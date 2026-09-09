import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/note.dart';
import '../models/note_source.dart';
import '../models/relationship.dart';
import '../models/tag.dart';
import '../models/filter.dart';
import '../models/user_app.dart';
import '../models/app_revision.dart';
import '../models/model_config.dart';
import '../services/data_change_notifier.dart';
import '../services/database_service.dart';
import '../services/ai_service.dart';
import '../services/user_app_service.dart';
import '../services/conversation_service.dart';
import '../services/logger_service.dart';
import '../services/note_source_service.dart';
import '../services/service_locator.dart';
import '../services/model_storage_service.dart';
import '../services/space_scope_service.dart';
import '../services/tag_image_service.dart';
import '../models/generation_context.dart';

class AppProvider extends ChangeNotifier {
  AppProvider({
    DatabaseService? databaseService,
    DataChangeNotifier? changeNotifier,
    SpaceScopeService? spaceScope,
  }) : _databaseService = databaseService ?? DatabaseService(),
       _changeNotifier = changeNotifier ?? DataChangeNotifier.shared(),
       // The scope must be the *same* object the data-layer writers stamp with
       // (`NoteModificationService`), and `AppProvider` is constructed directly
       // in tests and widget trees as well as through the service locator, so
       // it cannot rely on registration order.
       _scope = spaceScope ?? SpaceScopeService.shared() {
    _changeSubscription = _changeNotifier.addListener(_onDataChanged);
  }

  final DatabaseService _databaseService;
  final DataChangeNotifier _changeNotifier;
  final SpaceScopeService _scope;
  late final DataChangeSubscription _changeSubscription;

  /// Tail of the cache-mutation queue (see [_withCacheLock]). The tail future
  /// never carries an error; each action's failure goes to its own caller.
  Future<void> _lockTail = Future.value();
  Timer? _reloadTimer;

  ConversationService get _conversationService => getIt<ConversationService>();
  UserAppService get _userAppService => getIt<UserAppService>();

  /// Stateless and bound to this provider's own database, so screens and
  /// services can read a note's sources without reaching for getIt.
  late final NoteSourceService _noteSourceService = NoteSourceService(
    _databaseService,
  );

  List<Note> _notes = [];
  List<Tag> _tags = [];
  List<Filter> _filters = [];
  List<UserApp> _userApps = [];
  final Map<String, List<AppRevision>> _appRevisions =
      {}; // Cache revisions by appId
  bool _isLoading = false;
  bool _hasLoadedOnce = false;
  bool _reloadRequested = false;
  Future<void>? _loadDataInFlight;
  List<String>? _availableTagsCache;
  List<String>? _scopedTagsCache;
  List<Note>? _scopedNotesCache;
  int _dataVersion = 0;
  String? _error;
  bool _isDarkMode = false;
  Locale _locale = const Locale('en', '');
  ModelConfig? _modelConfig;
  bool newNoteFromShare = false;
  List<String> _multiFunctionApps = [];
  String? _currentMultiFunctionAppId;
  bool _isHierarchyEnabled = false;
  bool _onboardingCompleted = false;

  bool get onboardingCompleted => _onboardingCompleted;

  List<Note> get notes => _notes;
  List<Tag> get tags => _tags;
  List<Filter> get filters => _filters;
  List<UserApp> get userApps => _userApps;
  Map<String, List<AppRevision>> get appRevisions => _appRevisions;
  bool get isLoading => _isLoading;
  int get dataVersion => _dataVersion;
  String? get error => _error;
  bool get isDarkMode => _isDarkMode;
  Locale get locale => _locale;
  ModelConfig? get modelConfig => _modelConfig;
  List<String> get multiFunctionApps => _multiFunctionApps;
  String? get currentMultiFunctionAppId => _currentMultiFunctionAppId;
  bool get isHierarchyEnabled => _isHierarchyEnabled;

  /// Serializes every cache mutation (`_notes`/`_tags`/`_filters`), including
  /// full reloads, so an older DB read can never overwrite newer cache state.
  ///
  /// NON-REENTRANT: a locked method must never call another locked method, or
  /// it deadlocks. Provider-internal cross-calls must target unlocked helpers.
  ///
  /// Error-resilient: the queue tail always completes; an action's error is
  /// returned only to its own caller and never poisons later actions.
  static const _cacheLockZoneKey = #appProviderCacheLock;

  Future<T> _withCacheLock<T>(Future<T> Function() action) {
    // Debug-mode tripwire for the non-reentrancy rule: a locked action that
    // awaits another locked method would deadlock silently in release; in
    // debug/tests it fails loudly instead.
    assert(
      Zone.current[_cacheLockZoneKey] != true,
      'Re-entrant _withCacheLock call: a locked AppProvider method must not '
      'invoke another locked method (this would deadlock).',
    );
    final prev = _lockTail;
    final release = Completer<void>();
    _lockTail = release.future;
    return prev.then((_) async {
      try {
        return await runZoned(
          action,
          zoneValues: {_cacheLockZoneKey: true},
        );
      } finally {
        release.complete();
      }
    });
  }

  /// Entry point for [DataChangeNotifier] events published by data-layer
  /// writers (plugin bridge SQL, NoteModificationService, agent tools).
  Future<void> _onDataChanged(DataChangeEvent event) async {
    if (event.bulk) {
      // Unknown scope supersedes targeted work in this merged batch; one
      // debounced full reload covers everything. Ordering safety comes from
      // the cache lock, not from timing.
      scheduleReload();
      return;
    }
    await _withCacheLock(() => _applyChangesLocked(event));
  }

  /// Applies a targeted change event under the cache lock: one lock
  /// acquisition, one notification, one cache-snapshot boundary per event.
  /// The three independent fetches run concurrently to shorten the locked
  /// window; each failure is isolated and logged.
  Future<void> _applyChangesLocked(DataChangeEvent event) async {
    var cacheTouched = false;
    await Future.wait([
      if (event.noteIds.isNotEmpty)
        _refreshNotesLocked(event.noteIds).then((_) => cacheTouched = true),
      if (event.tagsChanged)
        _databaseService
            .getAllTags()
            .then((tags) {
              _tags = tags;
              cacheTouched = true;
            })
            .catchError((Object e) {
              LoggerService.error(
                'Error refreshing tags for $event: $e',
                error: e,
              );
            }),
      if (event.filtersChanged)
        _databaseService
            .getAllFilters()
            .then((filters) async {
              _filters = filters;
              cacheTouched = true;
              // An external writer may have deleted or un-flagged the active
              // Space; re-resolve before anyone reads `scopedNotes`.
              await _syncSpaceState();
            })
            .catchError((Object e) {
              LoggerService.error(
                'Error refreshing filters for $event: $e',
                error: e,
              );
            }),
    ]);
    // Relationship changes carry no cache to patch (relationships are read
    // from the DB on demand) but dependent UI still needs a rebuild signal.
    if (cacheTouched || event.relationshipNoteIds.isNotEmpty) {
      _dataVersion++;
      notifyListeners();
    }
  }

  /// Re-fetches [noteIds] from the database and upserts them into `_notes`;
  /// ids missing from the DB are removed (deleted). Caller must hold the
  /// cache lock and is responsible for bumping `_dataVersion` and notifying.
  Future<void> _refreshNotesLocked(Set<String> noteIds) async {
    var fetched = <Note>[];
    // Ids whose fetch failed: unknown state, so leave any cached copy alone
    // rather than misreading a fetch error as a deletion.
    final failed = <String>{};
    try {
      fetched = await _databaseService.getNotesByIds(noteIds.toList());
    } catch (e) {
      LoggerService.error(
        'Batch note refresh failed, falling back to per-id fetch: $e',
        error: e,
      );
      for (final id in noteIds) {
        try {
          final note = await _databaseService.getNote(id);
          if (note != null) fetched.add(note);
        } catch (e2) {
          failed.add(id);
          LoggerService.error('Error refreshing note $id: $e2', error: e2);
        }
      }
    }

    final found = {for (final note in fetched) note.id: note};
    for (final id in noteIds) {
      final note = found[id];
      if (note != null) {
        final index = _notes.indexWhere((n) => n.id == id);
        if (index != -1) {
          _notes[index] = note;
        } else {
          _notes.add(note);
        }
      } else if (!failed.contains(id)) {
        _notes.removeWhere((n) => n.id == id);
      }
    }
  }

  /// Public targeted refresh: re-fetch [noteIds] and upsert/remove them in
  /// the cache with a single notification.
  Future<void> refreshNotesFromDb(Set<String> noteIds) {
    if (noteIds.isEmpty) return Future.value();
    return _withCacheLock(() async {
      await _refreshNotesLocked(noteIds);
      _dataVersion++;
      notifyListeners();
    });
  }

  /// Debounced full reload for changes of unknown scope. Coalesces bursts
  /// into one [loadData] pass.
  void scheduleReload() {
    if (_reloadTimer?.isActive ?? false) return;
    _reloadTimer = Timer(const Duration(milliseconds: 500), () {
      loadData().catchError((Object e) {
        LoggerService.error('Scheduled reload failed: $e', error: e);
      });
    });
  }

  @override
  void dispose() {
    _reloadTimer?.cancel();
    _changeSubscription.cancel();
    super.dispose();
  }

  Future<void> loadData() {
    // Coalesce concurrent callers onto the in-flight load instead of
    // re-running the full (expensive) load. A caller arriving mid-flight may
    // have just written to the database, and the in-flight pass may have read
    // before that write — so request one more full pass; all waiters resolve
    // only after it, guaranteeing every caller observes data written before
    // its call.
    if (_loadDataInFlight != null) {
      _reloadRequested = true;
      return _loadDataInFlight!;
    }
    _loadDataInFlight = () async {
      do {
        _reloadRequested = false;
        await _doLoadData();
      } while (_reloadRequested);
    }().whenComplete(() {
      _loadDataInFlight = null;
    });
    return _loadDataInFlight!;
  }

  Future<void> _doLoadData() => _withCacheLock(() async {
    if (!_hasLoadedOnce) {
      // Blank the notes region behind a spinner only on the first load;
      // refreshes update data in place.
      _setLoading(true);
    }
    try {
      LoggerService.info('Starting loadData');
      _notes = await _databaseService.getAllNotes();
      LoggerService.debug('Successfully loaded ${_notes.length} notes');

      _tags = await _databaseService.getAllTags();
      LoggerService.debug('Successfully loaded ${_tags.length} tags');

      _filters = await _databaseService.getAllFilters();
      LoggerService.debug('Successfully loaded ${_filters.length} filters');

      _userApps = await _userAppService.getAllUserApps();
      LoggerService.debug('Successfully loaded ${_userApps.length} user apps');

      _modelConfig = await getIt<ModelStorageService>().getActiveModel();

      await _refreshMultiFunctionApps();
      _currentMultiFunctionAppId = await _databaseService
          .getMultiFunctionDefaultAppId();

      await _loadHierarchyPreference();
      await _loadOnboardingStatus();

      // After `_filters`: the persisted space id is resolved against them, and
      // an id that no longer names a usable Space is dropped here.
      await _scope.load();
      await _syncSpaceState();

      _error = null;
      _hasLoadedOnce = true;
      LoggerService.info('loadData completed successfully');
      _dataVersion++;
    } catch (e) {
      _error = 'Error loading data: ${e.toString()}';
      LoggerService.error('Error in loadData: $e', error: e);
    } finally {
      // No-op flip on refreshes; always notifies so every pass ends with
      // listeners seeing the final state (data or _error).
      _setLoading(false);
    }
  });

  void updateModelConfig(ModelConfig newConfig) {
    _modelConfig = newConfig;
    notifyListeners();
  }

  /// Persists a new note.
  ///
  /// The active Space's tags are unioned onto it first ([applySpaceTags]),
  /// which is what files a note into the Space the user created it in. Pass
  /// `applySpaceTags: false` from creators that already showed the tags and
  /// let the user take them off — the stamp is a default, not a lock.
  /// Orthogonal to [fromShare], which only routes the post-save navigation.
  Future<void> addNote(
    Note note, {
    bool fromShare = false,
    bool applySpaceTags = true,
  }) => _withCacheLock(() async {
    try {
      // Stamped before the insert: the row is re-read below, so a stamp
      // applied afterwards would never be persisted.
      final stamped = applySpaceTags ? _scope.stamp(note) : note;
      await _databaseService.insertNote(stamped);

      // Reload the note from database to get properly converted attachment paths
      final addedNote = await _databaseService.getNote(stamped.id);
      if (addedNote != null) {
        _notes.add(addedNote);
        if (fromShare) {
          newNoteFromShare = true;
        }
        _dataVersion++;
        notifyListeners();
      }

      _error = null; // Clear any previous errors
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow; // Rethrow the error so the calling code can handle it
    }
  });

  Future<void> updateNote(Note note) => _withCacheLock(() async {
    try {
      await _databaseService.updateNote(note);

      // Reload the note from database to get properly converted attachment paths
      final updatedNote = await _databaseService.getNote(note.id);
      if (updatedNote != null) {
        final noteIndex = _notes.indexWhere((n) => n.id == note.id);
        if (noteIndex != -1) {
          _notes[noteIndex] = updatedNote;
        } else {
          // Note exists in the DB but not in the cache (e.g. created by a
          // plugin/agent write): upsert instead of silently dropping the
          // update on the floor.
          _notes.add(updatedNote);
        }
        _dataVersion++;
        notifyListeners();
      }

      _error = null; // Clear any previous errors
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow; // Rethrow the error so the calling code can handle it
    }
  });

  Future<void> updateNoteContent(String noteId, String newContent) =>
      _withCacheLock(() async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;

      final note = _notes[noteIndex];
      final updatedNote = note.copyWith(
        content: newContent,
        updatedAt: DateTime.now(),
      );

      // Update the note in the database
      await _databaseService.updateNote(updatedNote);

      // Update the local state immediately
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  });

  Future<void> updateTaskStatus(String noteId, TaskStatus status) =>
      _withCacheLock(() async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;

      final note = _notes[noteIndex];
      if (!note.isTask) return;

      final updatedNote = note.copyWith(
        status: status,
        updatedAt: DateTime.now(),
      );

      // Update the note in the database
      await _databaseService.updateNote(updatedNote);

      // Update the local state immediately
      _notes[noteIndex] = updatedNote;
      _dataVersion++;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  });

  Future<void> toggleNotePin(String noteId) => _withCacheLock(() async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;

      final note = _notes[noteIndex];
      final updatedNote = note.copyWith(
        pinned: !note.pinned,
        updatedAt: DateTime.now(),
      );

      // Update the note in the database
      await _databaseService.updateNote(updatedNote);

      // Update the local state immediately
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  });

  Future<void> deleteNote(String noteId) => _withCacheLock(() async {
    try {
      await _databaseService.deleteNote(noteId);

      // Remove from local state immediately instead of reloading from database
      _notes.removeWhere((note) => note.id == noteId);
      _dataVersion++;
      notifyListeners();

      _error = null; // Clear any previous errors
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow; // Rethrow the error so the calling code can handle it
    }
  });

  Future<void> addRelationship(Relationship relationship) async {
    try {
      await _databaseService.insertRelationship(relationship);
      await loadData();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> deleteRelationship(String relationshipId) async {
    try {
      await _databaseService.deleteRelationship(relationshipId);
      await loadData();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> createNoteRelationships(
    String fromNoteId,
    List<String> toNoteIds,
    String relationshipType,
  ) async {
    try {
      for (final toNoteId in toNoteIds) {
        // Check if relationship already exists
        final exists = await _databaseService.relationshipExists(
          fromNoteId,
          toNoteId,
          relationshipType,
        );
        if (!exists) {
          final relationship = Relationship(
            id: const Uuid().v4(),
            fromNoteId: fromNoteId,
            toNoteId: toNoteId,
            type: relationshipType,
            createdAt: DateTime.now(),
          );
          await _databaseService.insertRelationship(relationship);
        }
      }
      await loadData();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<List<Relationship>> getNoteRelationships(String noteId) async {
    try {
      return await _databaseService.getRelationships(noteId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return [];
    }
  }

  Future<List<Note>> getLinkedNotes(String noteId) async {
    try {
      final relationships = await _databaseService.getRelationships(noteId);
      final linkedNoteIds = relationships
          .map((r) => r.fromNoteId == noteId ? r.toNoteId : r.fromNoteId)
          .toList();
      return _notes.where((note) => linkedNoteIds.contains(note.id)).toList();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return [];
    }
  }

  /// Where [noteId]'s content was clipped from, in stored order; empty when
  /// it has none. Never throws (see [NoteSourceService.getSources]).
  Future<List<NoteSource>> getNoteSources(String noteId) =>
      _noteSourceService.getSources(noteId);

  Future<String> transformNote(
    Note note,
    String transformationPrompt, {
    List<PlatformFile>? attachedFiles,
    GenerationContext? generationContext,
  }) async {
    try {
      final response = await getIt<AIService>().transformNote(
        note,
        transformationPrompt,
        attachedFiles: attachedFiles,
        generationContext: generationContext,
      );

      return response;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<List<Note>> createNewNotes(
    String prompt,
    List<Note> contextNotes, {
    List<PlatformFile>? attachedFiles,
    bool persist = true,
    GenerationContext? generationContext,
  }) async {
    try {
      final newNotes = await getIt<AIService>().createNewNotes(
        prompt,
        contextNotes,
        attachedFiles: attachedFiles,
        generationContext: generationContext,
      );

      if (!persist) {
        return newNotes;
      }

      // Only persistence runs under the cache lock; the AI generation above
      // is slow and must not block other cache mutations.
      return await _withCacheLock(() async {
        // Save all new notes and reload them from database. This path bypasses
        // addNote entirely, so it has to apply the Space stamp itself.
        final List<Note> addedNotes = [];
        for (final note in newNotes) {
          final stamped = _scope.stamp(note);
          await _databaseService.insertNote(stamped);
          final addedNote = await _databaseService.getNote(stamped.id);
          if (addedNote != null) {
            addedNotes.add(addedNote);
          }
        }

        // Add to local state with properly converted paths
        _notes.addAll(addedNotes);
        _dataVersion++;
        notifyListeners();

        return addedNotes;
      });
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  List<Note> getNotesByTag(String tagName) {
    return _notes.where((note) => note.tags.contains(tagName)).toList();
  }

  Future<void> addTagToNote(String noteId, String tagName) =>
      _withCacheLock(() async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;

      final note = _notes[noteIndex];
      if (note.tags.contains(tagName)) return; // Tag already exists

      final updatedTags = List<String>.from(note.tags)..add(tagName);
      final updatedNote = note.copyWith(
        tags: updatedTags,
        updatedAt: DateTime.now(),
      );

      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      _tags = await _databaseService.getAllTags();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  });

  /// Every tag name in use, sorted.
  ///
  /// Scoped by default: inside a Space it lists the tags of [scopedNotes] and
  /// drops the Space's own include-tags, which every note in scope carries and
  /// which would therefore be a useless chip. With no active Space the two
  /// modes are identical (`scopedNotes == notes`, no tags to subtract).
  ///
  /// Both variants are cached — this scans every note and runs several times
  /// per build — and both are invalidated in [notifyListeners].
  List<String> getAllAvailableTags({bool scoped = true}) {
    if (!scoped) {
      return _availableTagsCache ??= _collectTags(_notes, const []);
    }
    return _scopedTagsCache ??= _collectTags(scopedNotes, spaceTags);
  }

  static List<String> _collectTags(List<Note> notes, List<String> exclude) {
    final allTags = <String>{};
    for (final note in notes) {
      allTags.addAll(note.tags);
    }
    allTags.removeAll(exclude);
    return List.unmodifiable(allTags.toList()..sort());
  }

  @override
  void notifyListeners() {
    _availableTagsCache = null;
    // Deliberately NOT keyed on _dataVersion: deleteTag, replaceTag,
    // batchUpdateTags, addTagToNote and upsertSubNoteInNote all rewrite
    // `_notes` and notify WITHOUT bumping it, and joining/leaving a Space goes
    // through batchUpdateTags — so a version-keyed scope would go stale
    // exactly when membership changes. Every mutator does reach here.
    _scopedTagsCache = null;
    _scopedNotesCache = null;
    super.notifyListeners();
  }

  Future<void> refreshTags() => _withCacheLock(() async {
    _tags = await _databaseService.getAllTags();
    notifyListeners();
  });

  // ===========================================================================
  // Spaces
  //
  // A Space is a Filter with `isSpace == true` and non-empty `includeTags`.
  // Activating one narrows every list (never access) and stamps newly created
  // notes with its include-tags. `SpaceScopeService` holds the activation and
  // does the tag arithmetic; this provider is the only object that can resolve
  // a persisted space id against the filter list, so it owns activation.
  //
  // Design: .claude/plans/2026-09-08-project-space-design.md
  // ===========================================================================

  /// Filters usable as a Space: flagged, and with something to scope by.
  List<Filter> get spaces => _filters.where(_isUsableSpace).toList();

  /// Whether [filter] can act as a Space.
  ///
  /// Flagged, with something to scope and stamp by, and with tags that survive
  /// storage: the `filters` table keeps `includeTags` **comma-joined**
  /// (`database_service.dart` `insertFilter`/`getAllFilters`), so a tag
  /// containing a comma comes back as two tags that no note carries. Such a
  /// filter would scope to nothing and stamp names that do not exist, so it is
  /// never a Space — it cannot be listed, activated, or stamped with, and a
  /// rename that puts a comma into a Space's tag retires that Space here
  /// rather than silently emptying it.
  ///
  /// A reserved tag ([SpaceScopeService.isReservedTag]) disqualifies a filter
  /// for the same reason: `all-spaces` as an include-tag would stamp the
  /// cross-Space escape onto every note created in the Space (A2), make
  /// leaving it a permanent no-op, and hide it from the chip list (A9); the
  /// `agent-skill` tag would turn every new note into a malformed skill.
  /// Migration v47 guarantees `all-spaces` exists as a real tag row, so it is
  /// offered by every tag picker — this is the one place that has to refuse
  /// it, and being the single definition of "is this filter a Space" it covers
  /// *Focus on this tag*, *Use as space*, *Activate as space* and a filter row
  /// restored from a backup at once.
  static bool _isUsableSpace(Filter filter) =>
      filter.isSpace &&
      filter.includeTags.isNotEmpty &&
      !filter.includeTags.any((tag) => tag.contains(',')) &&
      !filter.includeTags.any(SpaceScopeService.isReservedTag);

  /// The active Space's filter, or null when none is active — including when
  /// the persisted id no longer resolves to a usable space (a *dangling* id,
  /// which means "unscoped", never "empty list").
  Filter? get activeSpace => _spaceById(_scope.activeSpaceId);

  /// The active Space's include-tags: what membership is measured against and
  /// what new notes are stamped with. Empty when no Space is active.
  List<String> get spaceTags => activeSpace?.includeTags ?? const [];

  /// The notes visible in the active Space, in `notes` order.
  ///
  /// The predicate is the Space filter evaluated with `includeArchived` forced
  /// true (the Active/Pinned/Archived/All tabs decide archived-ness for
  /// themselves), ORed with "the note carries `all-spaces`" — an unconditional
  /// escape that also overrides the Space's excludeTags, includeText and
  /// noteTypes.
  ///
  /// With no active Space this holds every note, in `notes` order (A3: equal
  /// content — not the identical object).
  ///
  /// **Always unmodifiable, in both branches.** A caller that mutates the
  /// result must fail at the default state too, not only once a Space happens
  /// to be active. The no-Space branch is an [UnmodifiableListView], so it
  /// stays O(1) and stays live as `_notes` is rewritten in place.
  List<Note> get scopedNotes {
    final space = activeSpace;
    if (space == null) return UnmodifiableListView(_notes);
    return _scopedNotesCache ??= List.unmodifiable(
      _notes.where((n) => _isInSpace(space, n)).toList(),
    );
  }

  /// Whether [note] belongs to Space [space] (see [scopedNotes]).
  ///
  /// The authoritative membership predicate: the whole Space `Filter` is
  /// evaluated, so `excludeTags`, `includeText` and `noteTypes` all count.
  /// `SpaceScopeService.noteInScope` is the deliberately wider tags-only
  /// approximation for callers that cannot reach the `Filter`.
  static bool _isInSpace(Filter space, Note note) =>
      note.tags.contains(SpaceScopeService.allSpacesTag) ||
      _matchesFilterCriteria(space, note, includeArchived: true);

  Filter? _spaceById(String? id) {
    if (id == null) return null;
    for (final filter in _filters) {
      if (filter.id == id) {
        return _isUsableSpace(filter) ? filter : null;
      }
    }
    return null;
  }

  /// Activate the Space with [id], or pass null to leave every Space.
  ///
  /// Returns whether the request was honoured: a filter that is missing, not
  /// flagged `isSpace`, or carrying no include-tags is rejected outright
  /// (an empty stamp would scope nothing and tag nothing). Callers get a
  /// boolean rather than a thrown error because the UI's only reasonable
  /// response is to leave the current scope alone and say so.
  ///
  /// Runs under [_withCacheLock], which serializes it against `_doLoadData`.
  /// A reload holds the lock across `_scope.load()`; an activation slipping in
  /// there would be read back stale — `load()` would adopt the *previous* id,
  /// drop the stamp tags, and the reload's own `_syncSpaceState()` would
  /// re-activate the previous Space while prefs still named the new one.
  ///
  /// It calls only unlocked helpers ([_spaceById], [_applySpaceState] — which
  /// reaches no further than `_scope.save()`), so the non-reentrancy rule
  /// holds. The locked filter mutators must keep reaching this state through
  /// [_syncSpaceState] rather than through here.
  Future<bool> setActiveSpace(String? id) => _withCacheLock(() async {
    if (id != null && _spaceById(id) == null) return false;
    _scopedNotesCache = null;
    _scopedTagsCache = null;
    await _applySpaceState(id, persist: true);
    notifyListeners();
    return true;
  });

  /// Re-resolves the *current* activation against `_filters` and republishes
  /// it to [SpaceScopeService], together with a fresh snapshot of every Space.
  ///
  /// This is what the filter mutators call: an id whose filter was deleted,
  /// un-flagged or emptied deactivates here, and its persisted value is
  /// dropped so it cannot come back on the next launch.
  ///
  /// Lock-free on purpose: called from inside locked filter mutators, and
  /// [_withCacheLock] is non-reentrant.
  Future<void> _syncSpaceState() => _applySpaceState(_scope.activeSpaceId);

  Future<void> _applySpaceState(String? id, {bool persist = false}) async {
    _scope.setSpaceSnapshots([
      for (final filter in spaces)
        SpaceSnapshot(id: filter.id, includeTags: filter.includeTags),
    ]);

    final space = _spaceById(id);
    final wasSet = _scope.activeSpaceId != null;
    _scope.setActive(
      space?.id,
      space?.includeTags ?? const [],
      name: space?.name,
    );
    // A dangling or just-deleted id must not survive a restart either.
    if (persist || (wasSet && space == null)) await _scope.save();
  }

  /// Adds [noteIds] to the Space [spaceId] by stamping its include-tags.
  ///
  /// Returns false when [spaceId] is not a usable Space, or when the write
  /// failed ([batchUpdateTags] swallows its exception, so a caller that ignored
  /// the result would report a join that never happened). An empty [noteIds]
  /// is a vacuous success.
  ///
  /// The answer comes from [batchUpdateTags]'s own return value, never from
  /// the shared `_error` field: clearing `_error` to use it as a success flag
  /// would wipe an error the UI is showing and could blame this join for an
  /// unrelated queued failure.
  Future<bool> joinSpace(List<String> noteIds, String spaceId) async {
    final space = _spaceById(spaceId);
    if (space == null) return false;
    if (noteIds.isEmpty) return true;
    // Outside any lock by contract: batchUpdateTags takes the (non-reentrant)
    // cache lock itself.
    return batchUpdateTags(noteIds, space.includeTags, const []);
  }

  /// Removes [noteIds] from the Space [spaceId].
  ///
  /// Removes the Space's include-tags **minus** any tag another Space the note
  /// still belongs to also requires — leaving Thesis `{thesis, 2026}` on a note
  /// that is also in Reading `{reading, 2026}` drops `thesis` and keeps `2026`.
  /// `all-spaces` is never removed: it is not membership, it is an override.
  ///
  /// The removal set is per note, so notes are grouped by it and each group
  /// gets its own [batchUpdateTags] pass. Reports success the same way
  /// [joinSpace] does.
  Future<bool> leaveSpace(List<String> noteIds, String spaceId) async {
    final space = _spaceById(spaceId);
    if (space == null) return false;
    if (noteIds.isEmpty) return true;

    final others = spaces.where((s) => s.id != space.id).toList();
    final groups = <String, List<String>>{};
    final removals = <String, List<String>>{};
    for (final noteId in noteIds) {
      final note = _noteById(noteId);
      if (note == null) continue;
      final remove = _leaveSet(space, others, note);
      if (remove.isEmpty) continue;
      // Filters store their tag lists comma-joined, so a comma cannot
      // occur inside a Space tag and is a safe grouping separator.
      final key = (List<String>.from(remove)..sort()).join(',');
      groups.putIfAbsent(key, () => <String>[]).add(noteId);
      removals[key] = remove;
    }
    if (groups.isEmpty) return true;

    // Every group is attempted even after one fails — a partial leave is worse
    // than a complete one — and the caller is told if any of them did.
    var ok = true;
    for (final entry in groups.entries) {
      final passed = await batchUpdateTags(
        entry.value,
        const [],
        removals[entry.key]!,
      );
      ok = ok && passed;
    }
    return ok;
  }

  /// How many of [noteIds] the Space [spaceId] still does not show.
  ///
  /// A join stamps the Space's include-tags, but the Space's *own* criteria can
  /// go on rejecting the note — `noteTypes` (a tasks-only Space swallowing a
  /// note), `excludeTags`, `includeText`. That is the "M not shown because
  /// *Space* only shows tasks" half of the post-join feedback, and it must be
  /// measured with the whole filter, not with the tag stamp.
  ///
  /// Notes carrying `all-spaces` are shown unconditionally (A1) and so are
  /// never counted. Ids that no longer resolve to a note are skipped.
  int notesHiddenBySpace(List<String> noteIds, String spaceId) {
    final space = _spaceById(spaceId);
    if (space == null) return 0;
    var hidden = 0;
    for (final id in noteIds) {
      final note = _noteById(id);
      if (note == null) continue;
      if (!_isInSpace(space, note)) hidden++;
    }
    return hidden;
  }

  /// The tags [note] loses when it leaves [space], given the [others] it might
  /// still belong to (see [leaveSpace]).
  static List<String> _leaveSet(Filter space, List<Filter> others, Note note) {
    final keep = <String>{};
    for (final other in others) {
      // Membership is evaluated on the note as it stands. Only tags the other
      // Space does NOT require are ever removed, so its membership is
      // unaffected by the removal and needs no second evaluation.
      if (!other.includeTags.every(note.tags.contains)) continue;
      keep.addAll(other.includeTags);
    }
    return [
      for (final tag in space.includeTags)
        if (tag != SpaceScopeService.allSpacesTag &&
            !keep.contains(tag) &&
            note.tags.contains(tag))
          tag,
    ];
  }

  Note? _noteById(String id) {
    for (final note in _notes) {
      if (note.id == id) return note;
    }
    return null;
  }

  // ---------------------------------------------------------------- G8: tags
  //
  // A tag lives in two places: on notes, and inside `filters.includeTags` /
  // `excludeTags`. Renaming or deleting one used to rewrite the notes only,
  // which left every filter pointing at a name nothing carries. For a Space
  // that is not cosmetic: the include-tags ARE the scope and the stamp, so a
  // rename silently emptied the Space and a delete left it stamping nothing.

  List<String> _spacesInvalidatedByTags = const [];

  /// Names of Spaces that stopped being Spaces during the most recent
  /// [deleteTag] or [replaceTag], newest call wins.
  ///
  /// A Space is its include-tags; deleting the last one leaves nothing to scope
  /// or stamp by, so the flag is dropped and the Space deactivates. That is the
  /// one way a Space can disappear without the user asking for it, so the
  /// caller (the tag management screen) reads this straight after awaiting the
  /// call and says so. Empty on every call that invalidated nothing.
  List<String> get spacesInvalidatedByLastTagChange => _spacesInvalidatedByTags;

  /// Rewrites [tagName] out of every filter's tag lists — renamed to
  /// [replacement], or dropped when it is null.
  ///
  /// Matching is per **whole tag**: the lists are `List<String>`, so `thesis`
  /// never touches `thesis-2026`. Renaming onto a name a filter already carries
  /// dedups instead of duplicating. A Space left with no include-tags loses its
  /// `isSpace` flag, because an empty stamp is not a Space.
  ///
  /// Lock-free on purpose: called from inside the locked tag mutators, and
  /// [_withCacheLock] is non-reentrant. Returns whether anything changed.
  Future<bool> _rewriteFiltersForTag(String tagName, String? replacement) async {
    final spacesBefore = {for (final f in spaces) f.id: f.name};
    var changed = false;

    for (var i = 0; i < _filters.length; i++) {
      final filter = _filters[i];
      final include = _rewriteTagList(filter.includeTags, tagName, replacement);
      final exclude = _rewriteTagList(filter.excludeTags, tagName, replacement);
      if (include == null && exclude == null) continue;

      final nextInclude = include ?? filter.includeTags;
      var updated = filter.copyWith(
        includeTags: nextInclude,
        excludeTags: exclude ?? filter.excludeTags,
        updatedAt: DateTime.now(),
      );
      // Not a Space any more. Tested with the same predicate that decides
      // whether a Space is usable, not merely "empty": a rename to `a,b`
      // leaves a non-empty include-tag list that the comma-joined `filters`
      // column splits on the next launch, so un-flagging only on emptiness
      // wrote `isSpace: 1` back and the Space came back after a restart —
      // scoping to nothing and stamping two tag names that do not exist.
      if (updated.isSpace && !_isUsableSpace(updated)) {
        updated = updated.copyWith(isSpace: false);
      }

      await _databaseService.updateFilter(updated);
      _filters[i] = updated;
      changed = true;
    }

    _spacesInvalidatedByTags = changed
        ? [
            for (final entry in spacesBefore.entries)
              if (_spaceById(entry.key) == null) entry.value,
          ]
        : const [];
    return changed;
  }

  /// [tags] with [tagName] renamed to [replacement] (or removed when null),
  /// preserving order and dropping duplicates. Null when nothing matched, so
  /// the caller can skip the write.
  static List<String>? _rewriteTagList(
    List<String> tags,
    String tagName,
    String? replacement,
  ) {
    if (!tags.contains(tagName)) return null;
    final result = <String>[];
    for (final tag in tags) {
      final next = tag == tagName ? replacement : tag;
      if (next == null) continue;
      if (!result.contains(next)) result.add(next);
    }
    return result;
  }

  // --- Agent / AI Features ---

  Future<String?> getTagExtractionPrompt(String tagId) async {
    return await _databaseService.getTagExtractionPrompt(tagId);
  }

  Future<void> updateTagExtractionPrompt(String tagId, String? prompt) async {
    await _databaseService.updateTagExtractionPrompt(tagId, prompt);
    // We don't necessarily need to reload tags, but we could if we stored it in the Tag model.
    // For now, it is stored separately.
    notifyListeners();
  }

  Future<void> deleteTag(String tagName) => _withCacheLock(() async {
    _spacesInvalidatedByTags = const [];
    try {
      // Clean up tag image file before deleting the tag
      final tagImageService = getIt<TagImageService>();
      final tag = _tags.firstWhere(
        (t) => t.name == tagName,
        orElse: () => throw Exception('Tag not found'),
      );
      // removeTagImage handles file deletion and DB cleanup
      await tagImageService.removeTagImage(tag.id);

      await _databaseService.deleteTag(tagName);

      // Remove the tag from all notes in local state
      for (int i = 0; i < _notes.length; i++) {
        if (_notes[i].tags.contains(tagName)) {
          final updatedTags = List<String>.from(_notes[i].tags)
            ..remove(tagName);
          _notes[i] = _notes[i].copyWith(
            tags: updatedTags,
            updatedAt: DateTime.now(),
          );
        }
      }

      // Reload tags to update the list
      _tags = await _databaseService.getAllTags();

      // Filters carry the tag too, and a Space's include-tags ARE its scope.
      await _syncFiltersAfterTagRewrite(await _rewriteFiltersForTag(tagName, null));

      notifyListeners();
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  });

  Future<void> replaceTag(String oldTagName, String newTagName) =>
      _withCacheLock(() async {
    _spacesInvalidatedByTags = const [];
    try {
      // Migrate image from old tag to new tag if new tag has no image
      final tagImageService = getIt<TagImageService>();
      final oldTagImage = tagImageService.getImagePathForTag(oldTagName);
      final newTagImage = tagImageService.getImagePathForTag(newTagName);

      if (oldTagImage != null && newTagImage == null) {
        final newTag = _tags.firstWhere((t) => t.name == newTagName);
        await tagImageService.setTagImage(newTag.id, oldTagImage);
      }

      await _databaseService.replaceTag(oldTagName, newTagName);

      // Update the tag in all notes in local state
      for (int i = 0; i < _notes.length; i++) {
        if (_notes[i].tags.contains(oldTagName)) {
          final updatedTags = List<String>.from(_notes[i].tags);
          // Remove the old tag
          updatedTags.remove(oldTagName);
          // Only add the new tag if the note doesn't already have it
          // (handles dedup case where note has both A and B, and A is being replaced with B)
          if (!updatedTags.contains(newTagName)) {
            updatedTags.add(newTagName);
          }
          _notes[i] = _notes[i].copyWith(
            tags: updatedTags,
            updatedAt: DateTime.now(),
          );
        }
      }

      // Reload tags to update the list
      _tags = await _databaseService.getAllTags();

      // Rename the tag inside every filter as well, so a Space whose
      // include-tag was renamed keeps scoping and re-points its stamp instead
      // of silently emptying itself.
      await _syncFiltersAfterTagRewrite(
        await _rewriteFiltersForTag(oldTagName, newTagName),
      );

      notifyListeners();
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  });

  /// Republishes the Space state after a tag rewrite touched the filters.
  ///
  /// [_syncSpaceState] is what re-points the active Space's stamp at the new
  /// tag name — and what deactivates it when the rewrite left it unusable. The
  /// caller then calls [notifyListeners], which is how every filter mutation in
  /// this provider publishes itself ([addFilter], [updateFilter],
  /// [deleteFilter] do exactly this and nothing more).
  ///
  /// Deliberately does **not** `publish` a `filtersChanged`
  /// [DataChangeEvent]: that channel carries changes made *outside* the
  /// provider (raw plugin SQL, `NoteModificationService`) so the provider can
  /// refresh its caches, and `AppProvider` is its only subscriber. Publishing
  /// here would loop straight back into `_onDataChanged`, re-reading from the
  /// database the filters that were just written to it and rebuilding every
  /// listener a second time.
  Future<void> _syncFiltersAfterTagRewrite(bool changed) async {
    if (!changed) return;
    await _syncSpaceState();
  }

  List<Note> getTasksForDate(DateTime date) {
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return scopedNotes
        .where(
          (note) =>
              note.isTask &&
              !note.isArchived &&
              (note.scheduledAt == dateStr ||
                  note.completeBy == dateStr ||
                  (note.scheduledAt != null &&
                      note.completeBy != null &&
                      _isDateInRange(
                        dateStr,
                        note.scheduledAt!,
                        note.completeBy!,
                      ))),
        )
        .toList();
  }

  bool _isDateInRange(String dateStr, String startDate, String endDate) {
    final date = DateTime.tryParse(dateStr);
    final start = DateTime.tryParse(startDate);
    final end = DateTime.tryParse(endDate);

    if (date == null || start == null || end == null) return false;

    return date.isAfter(start.subtract(const Duration(days: 1))) &&
        date.isBefore(end.add(const Duration(days: 1)));
  }

  List<Note> getNotesForDate(DateTime date) {
    return scopedNotes
        .where(
          (note) =>
              !note.isArchived &&
              note.createdAt.year == date.year &&
              note.createdAt.month == date.month &&
              note.createdAt.day == date.day,
        )
        .toList();
  }

  double calculateTaskCompletionPercentage(Note task) {
    if (!task.isTask || task.subNotes.isEmpty) {
      return task.isCompleted ? 1.0 : 0.0;
    }

    final completedSubNotes = task.subNotes
        .where((sn) => sn.isCompleted)
        .length;
    return completedSubNotes / task.subNotes.length;
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void toggleTheme() {
    _isDarkMode = !_isDarkMode;
    _saveThemePreference();
    notifyListeners();
  }

  Future<void> _saveThemePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_dark_mode', _isDarkMode);
    } catch (e) {
      LoggerService.error('Error saving theme preference: $e', error: e);
    }
  }

  Future<void> loadThemePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isDarkMode = prefs.getBool('is_dark_mode') ?? false;
      notifyListeners();
    } catch (e) {
      LoggerService.error('Error loading theme preference: $e', error: e);
      _isDarkMode = false; // Default to light mode
    }
  }

  void changeLanguage(Locale locale) {
    _locale = locale;
    _saveLanguagePreference();
    notifyListeners();
  }

  Future<void> _saveLanguagePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('language_code', _locale.languageCode);
      await prefs.setString('country_code', _locale.countryCode ?? '');
    } catch (e) {
      LoggerService.error('Error saving language preference: $e', error: e);
    }
  }

  Future<void> loadLanguagePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final languageCode = prefs.getString('language_code') ?? 'en';
      final countryCode = prefs.getString('country_code') ?? '';
      _locale = Locale(languageCode, countryCode);
      notifyListeners();
    } catch (e) {
      LoggerService.error('Error loading language preference: $e', error: e);
      _locale = const Locale('en', ''); // Default to English
    }
  }

  void toggleHierarchy() {
    _isHierarchyEnabled = !_isHierarchyEnabled;
    _saveHierarchyPreference();
    notifyListeners();
  }

  Future<void> _saveHierarchyPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_hierarchy_enabled', _isHierarchyEnabled);
    } catch (e) {
      LoggerService.error('Error saving hierarchy preference: $e', error: e);
    }
  }

  Future<void> _loadHierarchyPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isHierarchyEnabled = prefs.getBool('is_hierarchy_enabled') ?? false;
    } catch (e) {
      LoggerService.error('Error loading hierarchy preference: $e', error: e);
      _isHierarchyEnabled = false;
    }
  }

  Future<void> _loadOnboardingStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _onboardingCompleted = prefs.getBool('onboarding_completed') ?? false;
      notifyListeners();
    } catch (e) {
      LoggerService.error('Error loading onboarding status: $e', error: e);
      _onboardingCompleted = false;
    }
  }

  Future<void> setOnboardingCompleted(bool completed) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('onboarding_completed', completed);
      _onboardingCompleted = completed;
      notifyListeners();
    } catch (e) {
      LoggerService.error('Error saving onboarding status: $e', error: e);
    }
  }

  Future<void> clearAllData() => _withCacheLock(() async {
    _setLoading(true);
    try {
      // Clear all data from the database
      await _databaseService.clearAllData();

      // Reset local state. The DB clear wipes notes, tags, AND filters
      // (user apps are untouched), so reset all three caches.
      _notes = [];
      _tags = [];
      _filters = [];
      _error = null;

      // The Space's filter is gone with the rest, so the activation goes too.
      await _syncSpaceState();

      // Reset theme to default (light mode)
      _isDarkMode = false;
      await _saveThemePreference();

      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _setLoading(false);
    }
  });

  // SubNote management methods
  Future<void> addSubNoteToNote(String noteId, SubNote subNote) =>
      _withCacheLock(() async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;

      final note = _notes[noteIndex];
      final updatedSubNotes = List<SubNote>.from(note.subNotes)..add(subNote);
      final updatedNote = note.copyWith(
        subNotes: updatedSubNotes,
        updatedAt: DateTime.now(),
      );

      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  });

  Future<void> updateSubNoteInNote(
    String noteId,
    SubNote updatedSubNote,
  ) => _withCacheLock(() async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;

      final note = _notes[noteIndex];
      final updatedSubNotes = note.subNotes
          .map((sn) => sn.id == updatedSubNote.id ? updatedSubNote : sn)
          .toList();

      final updatedNote = note.copyWith(
        subNotes: updatedSubNotes,
        updatedAt: DateTime.now(),
      );

      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  });

  Future<void> deleteSubNoteFromNote(String noteId, String subNoteId) =>
      _withCacheLock(() async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;

      final note = _notes[noteIndex];
      final updatedSubNotes = note.subNotes
          .where((sn) => sn.id != subNoteId)
          .toList();

      final updatedNote = note.copyWith(
        subNotes: updatedSubNotes,
        updatedAt: DateTime.now(),
      );

      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  });

  Future<void> toggleSubNoteCompletion(String noteId, String subNoteId) =>
      _withCacheLock(() async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;

      final note = _notes[noteIndex];
      final updatedSubNotes = note.subNotes.map((sn) {
        if (sn.id == subNoteId) {
          return sn.copyWith(isCompleted: !sn.isCompleted);
        }
        return sn;
      }).toList();

      final updatedNote = note.copyWith(
        subNotes: updatedSubNotes,
        updatedAt: DateTime.now(),
      );

      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  });

  Future<void> removeTagFromNote(String noteId, String tagName) =>
      _withCacheLock(() async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;

      final note = _notes[noteIndex];
      if (!note.tags.contains(tagName)) return; // Tag doesn't exist

      final updatedTags = List<String>.from(note.tags)..remove(tagName);
      final updatedNote = note.copyWith(
        tags: updatedTags,
        updatedAt: DateTime.now(),
      );

      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      _tags = await _databaseService.getAllTags();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  });

  /// Adds and removes tags across [noteIds] in one pass.
  ///
  /// Returns whether the pass succeeded. Failures are *also* surfaced through
  /// `error` for the UI, but callers that need to know the outcome of their own
  /// call must use the return value: `_error` is shared mutable state, so
  /// reading it back cannot distinguish this failure from an error that was
  /// already on screen or from an unrelated queued write's.
  Future<bool> batchUpdateTags(
    List<String> noteIds,
    List<String> tagsToAdd,
    List<String> tagsToRemove,
  ) => _withCacheLock(() async {
    try {
      bool hasChanges = false;

      for (final noteId in noteIds) {
        final noteIndex = _notes.indexWhere((n) => n.id == noteId);
        if (noteIndex == -1) continue;

        final note = _notes[noteIndex];
        final currentTags = Set<String>.from(note.tags);
        bool noteChanged = false;

        // Add tags
        for (final tag in tagsToAdd) {
          if (currentTags.add(tag)) {
            noteChanged = true;
          }
        }

        // Remove tags
        for (final tag in tagsToRemove) {
          if (currentTags.remove(tag)) {
            noteChanged = true;
          }
        }

        if (noteChanged) {
          final updatedNote = note.copyWith(
            tags: currentTags.toList(),
            updatedAt: DateTime.now(),
          );

          await _databaseService.updateNote(updatedNote);
          _notes[noteIndex] = updatedNote;
          hasChanges = true;
        }
      }

      if (hasChanges) {
        _tags = await _databaseService.getAllTags();
        notifyListeners();
      }
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  });

  // Upsert subnote - either add new or update existing
  Future<void> upsertSubNoteInNote(String noteId, SubNote subNote) =>
      _withCacheLock(() async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;

      final note = _notes[noteIndex];
      final existingSubNoteIndex = note.subNotes.indexWhere(
        (sn) => sn.id == subNote.id,
      );

      List<SubNote> updatedSubNotes;
      if (existingSubNoteIndex >= 0) {
        // Update existing subnote
        updatedSubNotes = List<SubNote>.from(note.subNotes);
        updatedSubNotes[existingSubNoteIndex] = subNote;
      } else {
        // Add new subnote
        updatedSubNotes = List<SubNote>.from(note.subNotes)..add(subNote);
      }

      final updatedNote = note.copyWith(
        subNotes: updatedSubNotes,
        updatedAt: DateTime.now(),
      );

      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  });

  // Reparent subnote from one note to another
  Future<void> reparentSubNote(
    String fromNoteId,
    String toNoteId,
    SubNote subNote,
  ) => _withCacheLock(() async {
    try {
      // Find source and destination notes
      final fromNoteIndex = _notes.indexWhere((note) => note.id == fromNoteId);
      final toNoteIndex = _notes.indexWhere((note) => note.id == toNoteId);

      if (fromNoteIndex == -1 || toNoteIndex == -1) return;

      final fromNote = _notes[fromNoteIndex];
      final toNote = _notes[toNoteIndex];

      // Remove subnote from source note
      final updatedFromSubNotes = fromNote.subNotes
          .where((sn) => sn.id != subNote.id)
          .toList();
      final updatedFromNote = fromNote.copyWith(
        subNotes: updatedFromSubNotes,
        updatedAt: DateTime.now(),
      );

      // Add subnote to destination note
      final updatedToSubNotes = List<SubNote>.from(toNote.subNotes)
        ..add(subNote);
      final updatedToNote = toNote.copyWith(
        subNotes: updatedToSubNotes,
        updatedAt: DateTime.now(),
      );

      // Update both notes in database
      await _databaseService.updateNote(updatedFromNote);
      await _databaseService.updateNote(updatedToNote);

      // Update local state
      _notes[fromNoteIndex] = updatedFromNote;
      _notes[toNoteIndex] = updatedToNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  });

  // Filter management methods
  Future<void> addFilter(Filter filter) => _withCacheLock(() async {
    try {
      await _databaseService.insertFilter(filter);
      _filters.add(filter);
      await _syncSpaceState();
      notifyListeners();
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  });

  Future<void> updateFilter(Filter filter) => _withCacheLock(() async {
    try {
      await _databaseService.updateFilter(filter);
      final filterIndex = _filters.indexWhere((f) => f.id == filter.id);
      if (filterIndex != -1) {
        _filters[filterIndex] = filter;
        // Un-flagging `isSpace` or emptying its include-tags deactivates the
        // Space; editing them re-points the stamp.
        await _syncSpaceState();
        notifyListeners();
      }
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  });

  Future<void> deleteFilter(String filterId) => _withCacheLock(() async {
    try {
      await _databaseService.deleteFilter(filterId);
      _filters.removeWhere((filter) => filter.id == filterId);
      // Deleting the active Space's filter deactivates it.
      await _syncSpaceState();
      notifyListeners();
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  });

  /// Notes matching [filter], pinned first and newest first.
  ///
  /// [base] is the list to filter, defaulting to every note. Scoped callers
  /// pass [scopedNotes]: this method is what backs the saved-filter tabs, so
  /// without an explicit base a saved filter selected inside a Space would
  /// reach straight past the Space and show notes from outside it.
  List<Note> getFilteredNotes(Filter filter, {List<Note>? base}) {
    final filteredNotes = (base ?? _notes)
        .where(
          (note) => _matchesFilterCriteria(
            filter,
            note,
            includeArchived: filter.includeArchived,
          ),
        )
        .toList();

    // Sort by pinned status first, then by creation date
    filteredNotes.sort((a, b) {
      if (a.pinned && !b.pinned) return -1;
      if (!a.pinned && b.pinned) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });

    return filteredNotes;
  }

  /// Whether [note] satisfies [filter]'s criteria.
  ///
  /// [includeArchived] overrides the filter's own flag so the Space scope can
  /// evaluate the same criteria with archived notes kept in: inside a Space,
  /// archived-ness is decided by the tab, not by the Space's filter.
  static bool _matchesFilterCriteria(
    Filter filter,
    Note note, {
    required bool includeArchived,
  }) {
    if (!includeArchived && note.isArchived) return false;

    final text = filter.includeText;
    if (text != null && text.isNotEmpty) {
      final query = text.toLowerCase();
      final matchesText =
          note.title.toLowerCase().contains(query) ||
          note.content.toLowerCase().contains(query) ||
          note.tags.any((tag) => tag.toLowerCase().contains(query));
      if (!matchesText) return false;
    }

    // Include tags are ANDed: the note must carry all of them.
    if (!filter.includeTags.every(note.tags.contains)) return false;

    if (note.tags.any(filter.excludeTags.contains)) return false;

    if (filter.noteTypes.isNotEmpty && !filter.noteTypes.contains(note.type)) {
      return false;
    }

    return true;
  }

  // User App management methods
  Future<void> addUserApp(UserApp app) async {
    try {
      await _userAppService.saveUserApp(app);
      _userApps.add(app);
      notifyListeners();
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> refreshUserApps() async {
    try {
      _userApps = await _userAppService.getAllUserApps();
      notifyListeners();
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateUserApp(UserApp app) async {
    try {
      await _userAppService.updateUserApp(app);
      final appIndex = _userApps.indexWhere((a) => a.id == app.id);
      if (appIndex != -1) {
        _userApps[appIndex] = app;
        notifyListeners();
      }
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<AppRevision> saveManualCodeEdit({
    required UserApp originalApp,
    required String newCode,
    List<String>? attachmentPaths,
  }) async {
    try {
      final revision = await _userAppService.saveManualCodeEdit(
        originalApp: originalApp,
        newCode: newCode,
        attachmentPaths: attachmentPaths,
      );

      // Update the app in our local list
      final appIndex = _userApps.indexWhere((app) => app.id == originalApp.id);
      if (appIndex != -1) {
        final updatedApp = await _databaseService.getUserApp(originalApp.id);
        if (updatedApp != null) {
          _userApps[appIndex] = updatedApp;
        }
      }

      // Clear and refresh revisions cache for this app
      clearAppRevisionsCache(originalApp.id);
      await refreshAppRevisions(originalApp.id);

      _error = null;
      return revision;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> deleteUserApp(String appId) async {
    try {
      await _userAppService.deleteUserApp(appId);
      _userApps.removeWhere((app) => app.id == appId);
      notifyListeners();
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<UserApp> createUserApp({
    required String name,
    required String description,
    required List<String> steps,
    UserAppType type = UserAppType.normal,
    List<String>? attachmentPaths,
    List<Note>? contextNotes,
    List<UserAppLibraryInfo>? libraries,
    GenerationContext? generationContext,
  }) async {
    try {
      // Construct user prompt from the provided information
      final promptBuffer = StringBuffer()
        ..write(
          'Create a $name app. Description: $description. Steps: ${steps.join(', ')}.',
        );
      if (contextNotes != null && contextNotes.isNotEmpty) {
        final titles = contextNotes.map((note) => note.title).join(', ');
        promptBuffer
          ..write(' Note context provided from: ')
          ..write(titles);
      }
      final userPrompt = promptBuffer.toString();

      final app = await _userAppService.createUserApp(
        name: name,
        description: description,
        steps: steps,
        type: type,
        userPrompt: userPrompt,
        attachmentPaths: attachmentPaths,
        contextNotes: contextNotes,
        libraries: libraries,
        generationContext: generationContext,
      );
      _userApps.add(app);
      notifyListeners();
      _error = null;
      return app;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<AppRevision> editUserApp({
    required UserApp originalApp,
    required String editSuggestion,
    List<String>? attachmentPaths,
    List<Note>? contextNotes,
    List<UserAppLibraryInfo>? libraries,
    GenerationContext? generationContext,
  }) async {
    try {
      final revision = await _userAppService.editUserApp(
        originalApp: originalApp,
        editSuggestion: editSuggestion,
        attachmentPaths: attachmentPaths,
        contextNotes: contextNotes,
        libraries: libraries,
        generationContext: generationContext,
      );

      // Update the app in our local list
      final appIndex = _userApps.indexWhere((app) => app.id == originalApp.id);
      if (appIndex != -1) {
        final updatedApp = await _databaseService.getUserApp(originalApp.id);
        if (updatedApp != null) {
          _userApps[appIndex] = updatedApp;
        }
      }

      // Clear and refresh revisions cache for this app
      clearAppRevisionsCache(originalApp.id);
      await refreshAppRevisions(originalApp.id);

      // Automatically pin the latest revision after editing
      final latestRevisions = _appRevisions[originalApp.id] ?? [];
      if (latestRevisions.isNotEmpty) {
        // Find the latest revision (highest revision number)
        final latestRevision = latestRevisions.reduce(
          (a, b) => a.revisionNumber > b.revisionNumber ? a : b,
        );
        await setSelectedRevision(originalApp.id, latestRevision.id);
      }

      _error = null;
      return revision;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> getAppState(String appId) async {
    try {
      return await _userAppService.getAppState(appId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<void> saveAppState(String appId, Map<String, dynamic> state) async {
    try {
      await _userAppService.saveAppState(appId, state);
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // App Revisions management
  Future<List<AppRevision>> getAppRevisions(String appId) async {
    try {
      // Check if we have cached revisions for this app
      if (_appRevisions.containsKey(appId)) {
        return _appRevisions[appId]!;
      }

      // Load revisions from database
      final revisions = await _userAppService.getAppRevisions(appId);

      // Cache the revisions (already sorted by revisionNumber ASC from database)
      _appRevisions[appId] = revisions;

      return revisions;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<AppRevision?> getAppRevision(String revisionId) async {
    try {
      return await _userAppService.getAppRevision(revisionId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> deleteAppRevision(String revisionId) async {
    try {
      // Find which app this revision belonged to before deletion
      String? appId;
      for (final id in _appRevisions.keys) {
        final revisions = _appRevisions[id]!;
        if (revisions.any((r) => r.id == revisionId)) {
          appId = id;
          break;
        }
      }

      if (appId == null) {
        throw Exception('Revision not found in any app');
      }

      await _userAppService.deleteAppRevision(revisionId);

      // Clear and refresh revisions cache for this app
      clearAppRevisionsCache(appId);
      await refreshAppRevisions(appId);

      // Also refresh the app data in case the pinned revision changed
      final updatedApp = await _databaseService.getUserApp(appId);
      if (updatedApp != null) {
        final appIndex = _userApps.indexWhere((app) => app.id == appId);
        if (appIndex != -1) {
          _userApps[appIndex] = updatedApp;
        }
      }

      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setSelectedRevision(String appId, String revisionId) async {
    try {
      await _userAppService.setSelectedRevision(appId, revisionId);

      // Update the app in our local list
      final appIndex = _userApps.indexWhere((app) => app.id == appId);
      if (appIndex != -1) {
        final updatedApp = await _databaseService.getUserApp(appId);
        if (updatedApp != null) {
          _userApps[appIndex] = updatedApp;
        }
      }

      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Refresh revisions for a specific app
  Future<void> refreshAppRevisions(String appId) async {
    try {
      final revisions = await _userAppService.getAppRevisions(appId);
      _appRevisions[appId] = revisions;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Clear revisions cache for an app (useful when revisions are modified)
  void clearAppRevisionsCache(String appId) {
    _appRevisions.remove(appId);
    notifyListeners();
  }

  Future<AppRevision> createInitialRevision(String appId) async {
    try {
      final revision = await _userAppService.createInitialRevision(appId);

      // Update the app in our local list
      final appIndex = _userApps.indexWhere((app) => app.id == appId);
      if (appIndex != -1) {
        final updatedApp = await _databaseService.getUserApp(appId);
        if (updatedApp != null) {
          _userApps[appIndex] = updatedApp;
        }
      }

      notifyListeners();
      return revision;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  bool isWebViewSupported() {
    return UserAppService.isWebViewSupported();
  }

  // Conversation management methods
  Future<void> deleteConversation(String conversationId) async {
    try {
      await _conversationService.deleteConversation(conversationId);
      await refreshTags();
      notifyListeners(); // Notify listeners that conversation was deleted
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<int> getNoteConversationCount(String noteId) async {
    try {
      return await _databaseService.getNoteConversationCount(noteId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<List<String>> getNoteConversationIds(String noteId) async {
    try {
      return await _databaseService.getNoteConversationIds(noteId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Multi-function Apps Methods

  Future<void> _refreshMultiFunctionApps() async {
    _multiFunctionApps = await _databaseService.getMultiFunctionApps();
  }

  Future<void> addAppToMultiFunction(String appId) async {
    try {
      await _databaseService.addAppToMultiFunction(appId);
      await _refreshMultiFunctionApps();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> removeAppFromMultiFunction(String appId) async {
    try {
      await _databaseService.removeAppFromMultiFunction(appId);
      await _refreshMultiFunctionApps();

      // If the removed app was the current default, clear it
      if (_currentMultiFunctionAppId == appId) {
        _currentMultiFunctionAppId = null;
      }

      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> setMultiFunctionDefaultApp(String appId) async {
    try {
      await _databaseService.setMultiFunctionDefaultApp(appId);
      _currentMultiFunctionAppId = appId;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> clearMultiFunctionDefaultApp() async {
    try {
      await _databaseService.clearMultiFunctionDefaultApp();
      _currentMultiFunctionAppId = null;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> setCurrentMultiFunctionApp(String? appId) async {
    try {
      if (appId == null) {
        await _databaseService.clearMultiFunctionDefaultApp();
      } else {
        await _databaseService.setMultiFunctionDefaultApp(appId);
      }
      _currentMultiFunctionAppId = appId;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> toggleFilterPin(String filterId) => _withCacheLock(() async {
    try {
      final filterIndex = _filters.indexWhere((f) => f.id == filterId);
      if (filterIndex == -1) return;

      final filter = _filters[filterIndex];
      final updatedFilter = filter.copyWith(
        isPinned: !filter.isPinned,
        updatedAt: DateTime.now(),
      );

      await _databaseService.updateFilter(updatedFilter);
      _filters[filterIndex] = updatedFilter;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  });
}
