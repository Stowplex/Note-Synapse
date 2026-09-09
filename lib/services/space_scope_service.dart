import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/note.dart';
import 'logger_service.dart';
import 'service_locator.dart';

/// The id and membership tags of one Space, as seen by [SpaceScopeService].
///
/// A Space is a `Filter` with `isSpace == true` and non-empty `includeTags`;
/// only those two facts matter here. `AppProvider` pushes a fresh list in
/// whenever the filter list changes, which keeps this service free of any
/// dependency on the database or the provider.
@immutable
class SpaceSnapshot {
  final String id;
  final List<String> includeTags;

  const SpaceSnapshot({required this.id, required this.includeTags});

  @override
  bool operator ==(Object other) =>
      other is SpaceSnapshot &&
      other.id == id &&
      listEquals(other.includeTags, includeTags);

  @override
  int get hashCode => Object.hash(id, Object.hashAll(includeTags));

  @override
  String toString() => 'SpaceSnapshot($id, $includeTags)';
}

/// Holds the currently active Space and answers every "is this in scope?" and
/// "what tags should a new note get?" question.
///
/// Deliberately dependency-free: it knows tag lists and an id, nothing about
/// notes storage or the widget tree. `AppProvider` owns activation (it is the
/// only object that can resolve a space id against the filter list and notify
/// listeners) and pushes the resolved state in through [setActive] and
/// [setSpaceSnapshots].
class SpaceScopeService {
  /// Reserved tag marking a note (or skill) as visible from every Space, and
  /// from no Space at all.
  static const String allSpacesTag = 'all-spaces';

  /// `SharedPreferences` key holding the active space id. Device-local UI
  /// state, so prefs rather than the database.
  static const String prefsKey = 'active_space_id';

  /// The `agent-skill` tag, spelled out rather than imported from
  /// `SkillService`.
  ///
  /// `skill_service.dart` imports *this* file (M6 injects the scope into the
  /// skill index), so importing it back would close a cycle for one string.
  /// `SkillService.agentSkillTag` is asserted equal to this in
  /// `test/spaces/space_scope_service_test.dart`, so the two cannot drift
  /// apart silently — the same arrangement migration v47 uses for
  /// [allSpacesTag].
  static const String _agentSkillTag = 'agent-skill';

  /// Whether [tag] is reserved by the app and can therefore never be a
  /// Space's include-tag.
  ///
  /// Two tags carry meaning the app assigns, not meaning the user assigns:
  ///
  /// * [allSpacesTag] is the cross-Space escape (A1). A Space that included it
  ///   would stamp it onto **every** note created inside, in direct violation
  ///   of A2 — and it cascades: leaving that Space becomes a permanent no-op
  ///   (the leave-set keeps any tag another Space still requires, and this
  ///   "Space" requires it), and the scoped chip list hides the Space's own
  ///   tags, so `all-spaces` would disappear from it, inverting A9.
  /// * [_agentSkillTag] marks a note as an agent skill. A Space including it
  ///   would turn every note created inside into a malformed skill note and
  ///   would collide head-on with the [skillVisible] rules.
  ///
  /// Checked by `AppProvider._isUsableSpace`, which is the single definition
  /// of "is this filter a Space" — so every activation path, and a filter row
  /// restored from a backup, are covered by that one call.
  static bool isReservedTag(String tag) =>
      tag == allSpacesTag || tag == _agentSkillTag;

  /// The process-wide instance, registering it on first use.
  ///
  /// Mirrors `DataChangeNotifier.shared()`. Every fallback for an omitted
  /// `spaceScope` parameter must land here: a privately constructed
  /// `SpaceScopeService()` is permanently unset, so it silently stamps nothing
  /// while looking like a scope. `AppProvider` and `NoteModificationService`
  /// are both built directly (tests, widget trees) as well as through the
  /// service locator, so neither can rely on registration order.
  static SpaceScopeService shared() {
    if (!getIt.isRegistered<SpaceScopeService>()) {
      getIt.registerLazySingleton<SpaceScopeService>(() => SpaceScopeService());
    }
    return getIt<SpaceScopeService>();
  }

  String? _activeSpaceId;
  String? _activeSpaceName;
  List<String> _stampTags = const [];
  List<SpaceSnapshot> _spaceSnapshots = const [];
  int _scopeVersion = 0;

  /// Id of the active space filter, or null. May be non-null with empty
  /// [stampTags] between [load] and the first [setActive] — see [isActive].
  String? get activeSpaceId => _activeSpaceId;

  /// Display name of the active space, for surfaces that must *say* which
  /// space they are scoped to (the agent prompt block) and cannot reach the
  /// `Filter` — null when no space is active or the name is not known yet.
  String? get activeSpaceName => _activeSpaceName;

  /// The active space's include-tags: what new notes are stamped with and what
  /// membership is measured against. Empty when no space is active.
  List<String> get stampTags => _stampTags;

  /// Every known space, used to tell "filed in some space" from "unfiled".
  List<SpaceSnapshot> get spaceSnapshots => _spaceSnapshots;

  /// Increments whenever the scope changes. Holders of a cached, scope-derived
  /// index (skill indexes, mainly) compare this before reuse and rebuild when
  /// it moved, instead of subscribing to a listener.
  int get scopeVersion => _scopeVersion;

  /// Whether a space is active *and* actually narrows anything.
  ///
  /// A space always has non-empty include-tags (that is what makes it a
  /// space), so an id with no tags means "not resolved yet" and is treated as
  /// no active space rather than as a scope that matches everything.
  bool get isActive => _activeSpaceId != null && _stampTags.isNotEmpty;

  /// Activate [id] with its include-tags, or pass null to leave every space.
  /// Bumps [scopeVersion] only when the activation actually changed.
  ///
  /// [name] is carried for display only. A rename changes nothing about what
  /// is in scope, so it is adopted even on the unchanged-activation path and
  /// never bumps [scopeVersion] on its own — a cached scope-derived index
  /// built before a rename is still correct.
  void setActive(String? id, List<String> tags, {String? name}) {
    final nextTags = id == null
        ? const <String>[]
        : List<String>.unmodifiable(tags);
    final nextName = id == null ? null : name;
    if (id == _activeSpaceId && listEquals(nextTags, _stampTags)) {
      _activeSpaceName = nextName;
      return;
    }
    _activeSpaceId = id;
    _activeSpaceName = nextName;
    _stampTags = nextTags;
    _scopeVersion++;
  }

  /// Replace the known space list. Bumps [scopeVersion] only on a real change:
  /// [skillVisible]'s "no active space" answer depends on this list, so a
  /// cached index built against a stale list must be rebuilt.
  ///
  /// Both the outer list *and* each snapshot's tags are copied: callers build
  /// snapshots straight from `Filter.includeTags`, which is a growable list
  /// owned by a live `Filter`. Storing it by reference would let a caller
  /// change what [skillVisible] answers without a [scopeVersion] bump, which
  /// is precisely what a cached index cannot detect.
  void setSpaceSnapshots(List<SpaceSnapshot> snapshots) {
    if (listEquals(snapshots, _spaceSnapshots)) return;
    _spaceSnapshots = List<SpaceSnapshot>.unmodifiable(
      snapshots.map(
        (s) => SpaceSnapshot(
          id: s.id,
          includeTags: List<String>.unmodifiable(s.includeTags),
        ),
      ),
    );
    _scopeVersion++;
  }

  /// Add the active space's tags to [note], as a union that preserves the
  /// note's existing tag order. Idempotent, and a no-op with no active space.
  Note stamp(Note note) {
    if (_stampTags.isEmpty) return note;
    final merged = _unionWithStampTags(note.tags);
    if (merged.length == note.tags.length) return note;
    return note.copyWith(tags: merged);
  }

  /// [stamp] for the raw `Map` form that `NoteModificationService.createNote`
  /// takes. Tolerates a missing `tags` key, a `List<dynamic>`, and a value
  /// that is not a list at all (which cannot describe tags, so it is replaced
  /// rather than parsed). Returns the input unchanged when there is nothing to
  /// stamp; otherwise a new map, leaving the caller's map untouched.
  Map<String, dynamic> stampData(Map<String, dynamic> data) {
    if (_stampTags.isEmpty) return data;
    final raw = data['tags'];
    final existing = raw is List
        ? raw
              .map((e) => e?.toString() ?? '')
              .where((e) => e.isNotEmpty)
              .toList()
        : <String>[];
    return <String, dynamic>{...data, 'tags': _unionWithStampTags(existing)};
  }

  /// Whether a note carrying [noteTags] belongs to the active space.
  ///
  /// Membership is "carries all of the space's include-tags", ORed with the
  /// [allSpacesTag] escape. With no active space everything is in scope.
  ///
  /// **Tags-only approximation.** This service deliberately holds nothing but
  /// an id and a tag list, so it cannot see the space `Filter`'s `excludeTags`,
  /// `includeText` or `noteTypes`. `AppProvider.scopedNotes` (via
  /// `_isInSpace`) evaluates the whole filter and is the **authoritative**
  /// answer; use it wherever the `Filter` is reachable. This method exists for
  /// callers that only have tags — a skill index, a raw SQL row, an agent tool
  /// working off a tag column — and is *wider* than the authoritative
  /// predicate: for a space `{includeTags: [thesis], excludeTags: [draft]}` a
  /// note tagged `[thesis, draft]` is in scope here and out of scope there.
  bool noteInScope(List<String> noteTags) {
    if (!isActive) return true;
    if (noteTags.contains(allSpacesTag)) return true;
    return _stampTags.every(noteTags.contains);
  }

  /// Whether a skill carrying [noteTags] is reachable right now.
  ///
  /// | Skill carries      | In space S | In another space | No active space |
  /// |--------------------|------------|------------------|-----------------|
  /// | S's include-tags   | visible    | hidden           | hidden          |
  /// | [allSpacesTag]     | visible    | visible          | visible         |
  /// | neither (unfiled)  | hidden     | hidden           | visible         |
  ///
  /// The last column is the one deliberate asymmetry with notes: with no space
  /// active every *note* is visible, but a space-scoped *skill* stays hidden,
  /// so a space's skills never leak into unrelated work.
  bool skillVisible(List<String> noteTags) {
    if (noteTags.contains(allSpacesTag)) return true;
    if (isActive) return _stampTags.every(noteTags.contains);
    return !_matchesAnySpace(noteTags);
  }

  /// Splits a user-editable tag-chip list into the query's two tag arguments.
  ///
  /// Surfaces that seed their chips from the active Space (the conversation
  /// tree and its filters dialog) end up holding both the Space's tags and
  /// whatever the user added. The two must reach the query as **separate**
  /// lists: `getAllConversations` and `searchNotesFTS` OR the [allSpacesTag]
  /// escape around the *scope* group only, so merging them first turns "tag
  /// `urgent` in this Space" into "tag `urgent`, OR anything marked
  /// all-spaces" — every cross-Space row, none of them urgent. That is the M5
  /// blocker; one shared split is what keeps every consumer out of it.
  ///
  /// Both lists are null when empty, so a caller can pass them straight
  /// through. `orAllSpaces` is true only when something actually landed in the
  /// scope group: a chip list the user emptied of the Space's tags is a
  /// deliberate widening, and there is then no scope for the escape to widen.
  ({List<String>? tagNames, List<String>? scopeTags, bool orAllSpaces})
  partitionChips(List<String> chips) {
    final spaceTags = isActive ? _stampTags : const <String>[];
    final scoped = <String>[];
    final own = <String>[];
    for (final tag in chips) {
      (spaceTags.contains(tag) ? scoped : own).add(tag);
    }
    return (
      tagNames: own.isEmpty ? null : own,
      scopeTags: scoped.isEmpty ? null : scoped,
      orAllSpaces: scoped.isNotEmpty,
    );
  }

  /// Load the persisted active space id. The caller resolves it against the
  /// filter list and calls [setActive]; a dangling id is dropped there.
  ///
  /// `AppProvider` reloads on every data refresh, so this can run again long
  /// after a space was activated. A different id must therefore drop the old
  /// space's [stampTags] and bump [scopeVersion] immediately: reporting the
  /// new id with the previous space's tags — and with an unchanged version, so
  /// no cached scope-derived index rebuilds — would be worse than reporting
  /// nothing until the caller resolves the id and calls [setActive].
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _adoptLoadedId(prefs.getString(prefsKey));
    } catch (e) {
      LoggerService.error('Error loading active space: $e', error: e);
      _adoptLoadedId(null);
    }
  }

  /// Persist the active space id (or clear it when no space is active).
  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = _activeSpaceId;
      if (id == null) {
        await prefs.remove(prefsKey);
      } else {
        await prefs.setString(prefsKey, id);
      }
    } catch (e) {
      LoggerService.error('Error saving active space: $e', error: e);
    }
  }

  /// Adopt an id read from prefs, clearing any stamp tags that belonged to a
  /// different space. Unchanged ids are left completely alone so a reload
  /// never invalidates a scope that is still correct.
  void _adoptLoadedId(String? id) {
    if (id == _activeSpaceId) return;
    _activeSpaceId = id;
    _activeSpaceName = null;
    _stampTags = const [];
    _scopeVersion++;
  }

  List<String> _unionWithStampTags(List<String> existing) {
    final result = List<String>.from(existing);
    for (final tag in _stampTags) {
      if (!result.contains(tag)) result.add(tag);
    }
    return result;
  }

  bool _matchesAnySpace(List<String> noteTags) {
    for (final space in _spaceSnapshots) {
      if (space.includeTags.isEmpty) continue;
      if (space.includeTags.every(noteTags.contains)) return true;
    }
    return false;
  }
}
