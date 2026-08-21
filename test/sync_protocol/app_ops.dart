// User App revision/library/dependency identity and derived visibility
// (§ Architecture 10 of the plan — search "User Apps + revision history"
// and the following "User App visibility, extended to be the fallback's
// actual liveness root" paragraph). Built on top of a `Replica` exactly
// like `TagEngine`/`ConversationMappingEngine`: apps, revisions, libraries,
// and dependencies are ordinary `__exists__`/`__deleted__`-having entities
// (`mintExists`/`mintField`, no new Replica-level machinery), plus one
// derived, always-recomputed read for their effective visibility — the
// same "raw state -> a walk/computation -> an effective view" shape as
// `TagEngine.computeEffectiveState`/`MessageGcEngine.effectiveDeleted`.
//
// Ownership chain modeled here (round 8 codebase grounding + the plan's own
// "revision, libraries, dependencies, revision attachments" wording, §
// Architecture 10): app -> revision (`app_revisions.appId`) -> library
// (`user_app_libraries.revisionId`) -> dependency
// (`user_app_library_dependencies.libraryId`) — a dependency belongs to a
// LIBRARY, not directly to a revision, matching the real table's name
// (`user_app_library_dependencies`, a library's own dependencies) and the
// plan's explicit "revision -> libraries -> dependencies" transitive-graph
// phrasing (§ Architecture 10, "User App visibility" paragraph).
//
// **`deleteAppRevision` (round 14 fix, § Architecture 10)**: "the function
// becomes an ordinary soft-delete: write `__deleted__=true` on the revision
// itself (via the sync-aware write path) and nothing else. Libraries,
// dependencies, and revision attachments need no explicit write of their
// own — their visibility already derives from the revision's effective
// visibility." Modeled 1:1 below as `deleteAppRevision`: a single
// `mintField(__deleted__=true)` on the revision, full stop.
//
// **Effective revision visibility (round 8 fix, § Architecture 10, "User
// App visibility" paragraph, quoted verbatim)**: "a revision's effective
// visibility ... is `NOT __deleted__` OR `(currently serving as the
// zero-live-revisions fallback for its app)`. Libraries check *this*
// effective-visibility value for their owning revision (not raw
// `__deleted__`), so the whole transitive graph — revision, libraries,
// dependencies, revision attachments — stays consistently live together
// for exactly as long as the revision serves as fallback... The underlying
// `__deleted__` state is still never mutated ... only the *derived,
// effective* value used for visibility/liveness/purge-eligibility purposes
// changes."
//
// **Underspecified in the plan text, decided here**: the plan establishes
// the fallback CONCEPT (§ Architecture 10, above) but never writes out its
// tie-break formula the way it does for e.g. the canonical-winner rule
// (§ Architecture 1: lexicographically-smallest `(authorId, authorSeq)`) or
// the cycle-loser edge (§ Architecture 10: `hlcTieBreakWins`, higher
// `(hlc, authorId, authorSeq)` wins) — a full-text search of the plan finds
// no `revisionNumber`-based, `createdAt`-based, or any other concretely
// stated fallback-selection formula anywhere. This implementation picks
// **whichever revision's own `__deleted__=true` tombstone write has the
// highest `(hlc, authorId, authorSeq)`** — i.e. the revision that became
// non-live MOST RECENTLY — reusing `hlcTieBreakWins` (`model.dart`), the
// document's own sole established precedent for "which of several
// operations is most recent." Two reasons this was chosen over a
// `revisionNumber`-based rule: (1) the revision most recently made
// non-live is the one a user most recently still saw as their app's
// current version, a reasonable reading of "fallback" given the plan's own
// intent (round 8's fix, above) to keep the app usable rather than
// orphaned; (2) the plan itself (Codebase grounding,
// "No `UNIQUE` constraint on `(appId, revisionNumber)`") explicitly
// distrusts `revisionNumber` as a reliable ordering/identity key elsewhere
// in this exact document, so avoiding it here — using only the same
// dot-based tie-break every other deterministic rule in this design
// already relies on — is the more consistent choice, not an arbitrary one.
// This is deterministic and order-independent: every replica computes the
// identical fallback once it has observed every revision's `__deleted__`
// write, regardless of the order those writes were pulled in.

import 'model.dart';
import 'replica.dart';

/// Derived effective state for every known app-revision on a replica: which
/// revisions are effectively deleted (§ Architecture 10's formula above),
/// and which revision (if any) is currently serving as each app's
/// zero-live-revisions fallback.
class EffectiveAppState {
  final Map<String, bool> effectiveRevisionDeleted;
  final Map<String, String?> fallbackRevisionForApp;

  EffectiveAppState(this.effectiveRevisionDeleted, this.fallbackRevisionForApp);
}

class AppEngine {
  final Replica replica;
  int _counter = 0;

  AppEngine(this.replica);

  // ---- raw reads -----------------------------------------------------

  Set<String> _allIds(String table) {
    final ids = <String>{};
    final prefix = '$table:';
    const suffix = ':__exists__';
    for (final key in replica.fieldState.keys) {
      if (key.startsWith(prefix) && key.endsWith(suffix)) {
        ids.add(key.substring(prefix.length, key.length - suffix.length));
      }
    }
    return ids;
  }

  Set<String> get allAppIds => _allIds('user_app');
  Set<String> get allRevisionIds => _allIds('app_revisions');
  Set<String> get allLibraryIds => _allIds('user_app_libraries');
  Set<String> get allDependencyIds => _allIds('user_app_library_dependencies');

  Map? _existsValue(String table, String id) =>
      replica.fieldState['$table:$id:__exists__']?.value as Map?;

  String? appIdForRevision(String revisionId) =>
      _existsValue('app_revisions', revisionId)?['appId'] as String?;

  String? revisionIdForLibrary(String libraryId) =>
      _existsValue('user_app_libraries', libraryId)?['revisionId'] as String?;

  String? libraryIdForDependency(String dependencyId) =>
      _existsValue('user_app_library_dependencies', dependencyId)?['libraryId'] as String?;

  bool rawRevisionDeleted(String revisionId) =>
      replica.fieldValue<bool>('app_revisions', revisionId, '__deleted__') ?? false;

  bool rawLibraryDeleted(String libraryId) =>
      replica.fieldValue<bool>('user_app_libraries', libraryId, '__deleted__') ?? false;

  bool rawDependencyDeleted(String dependencyId) =>
      replica.fieldValue<bool>('user_app_library_dependencies', dependencyId, '__deleted__') ?? false;

  List<String> revisionsForApp(String appId) =>
      allRevisionIds.where((r) => appIdForRevision(r) == appId).toList();

  List<String> librariesForRevision(String revisionId) =>
      allLibraryIds.where((l) => revisionIdForLibrary(l) == revisionId).toList();

  List<String> dependenciesForLibrary(String libraryId) =>
      allDependencyIds.where((d) => libraryIdForDependency(d) == libraryId).toList();

  // ---- creation --------------------------------------------------------

  String createApp() {
    final id = '${replica.id}-app-${_counter++}';
    replica.mintExists(table: 'user_app', id: id, value: {});
    replica.mintField(table: 'user_app', id: id, field: '__deleted__', value: false);
    return id;
  }

  /// [revisionNumber] is carried purely as descriptive payload here — per
  /// this file's header comment, it is NOT consulted by fallback selection
  /// or by any other identity/ordering computation (the plan's own
  /// grounding section distrusts it as a reliable key).
  String createRevision(String appId, {int? revisionNumber}) {
    final id = '${replica.id}-rev-${_counter++}';
    replica.mintExists(table: 'app_revisions', id: id, value: {
      'appId': appId,
      'revisionNumber': revisionNumber ?? _counter,
    });
    replica.mintField(table: 'app_revisions', id: id, field: '__deleted__', value: false);
    return id;
  }

  String createLibrary(String revisionId) {
    final id = '${replica.id}-lib-${_counter++}';
    replica.mintExists(table: 'user_app_libraries', id: id, value: {'revisionId': revisionId});
    replica.mintField(table: 'user_app_libraries', id: id, field: '__deleted__', value: false);
    return id;
  }

  String createDependency(String libraryId) {
    final id = '${replica.id}-dep-${_counter++}';
    replica.mintExists(table: 'user_app_library_dependencies', id: id, value: {'libraryId': libraryId});
    replica.mintField(table: 'user_app_library_dependencies', id: id, field: '__deleted__', value: false);
    return id;
  }

  // ---- deletion / undeletion --------------------------------------------

  /// Round 14 fix, § Architecture 10 (quoted in this file's header
  /// comment): a single tombstone write on the revision, nothing else.
  /// Libraries/dependencies get no write of their own here — their
  /// visibility is entirely derived, below.
  void deleteAppRevision(String revisionId) {
    replica.mintField(table: 'app_revisions', id: revisionId, field: '__deleted__', value: true);
  }

  /// Generic entity undelete (§ Architecture 6) applied to a revision — the
  /// mechanism scenario (c) exercises: an app's fallback transfers away
  /// from whichever revision is currently protecting it once a DIFFERENT
  /// revision becomes raw-live again.
  void undeleteRevision(String revisionId) {
    replica.mintField(table: 'app_revisions', id: revisionId, field: '__deleted__', value: false);
  }

  /// The round-15 sibling fix (Codebase grounding: `deleteUserAppLibrary`)
  /// — an ordinary soft-delete written directly against the library,
  /// independent of its owning revision's state. Modeled so tests can
  /// confirm it composes correctly with revision-derived visibility (a
  /// library is invisible if EITHER its own raw tombstone is set OR its
  /// owning revision is effectively deleted).
  void deleteUserAppLibrary(String libraryId) {
    replica.mintField(table: 'user_app_libraries', id: libraryId, field: '__deleted__', value: true);
  }

  /// The round-15 sibling fix (Codebase grounding: `deleteUserAppLibraryDependency`).
  void deleteUserAppLibraryDependency(String dependencyId) {
    replica.mintField(table: 'user_app_library_dependencies', id: dependencyId, field: '__deleted__', value: true);
  }

  // ---- derived effective state -------------------------------------------

  /// Computes, for every known app, whether it currently has zero raw-live
  /// revisions and — if so — which revision is selected as its fallback
  /// (this file's header comment for the selection rule). Every revision's
  /// `effectiveRevisionDeleted` entry follows directly: unchanged from raw
  /// state for an app with at least one live revision (no fallback need);
  /// for a zero-live-revisions app, `false` for exactly the fallback
  /// revision and `true` for every other (raw-deleted) sibling.
  EffectiveAppState computeEffectiveState() {
    final effDeleted = <String, bool>{};
    final fallbackForApp = <String, String?>{};

    for (final appId in allAppIds) {
      final revisions = revisionsForApp(appId);
      if (revisions.isEmpty) continue;

      final hasLiveRevision = revisions.any((r) => !rawRevisionDeleted(r));
      if (hasLiveRevision) {
        fallbackForApp[appId] = null;
        for (final r in revisions) {
          effDeleted[r] = rawRevisionDeleted(r);
        }
        continue;
      }

      // Zero-live-revisions: select the fallback via the deterministic
      // rule (header comment) — highest (hlc, authorId, authorSeq) among
      // the revisions' own `__deleted__` tombstone writes.
      String? fallback;
      Operation? fallbackOp;
      for (final r in revisions) {
        final op = replica.fieldState['app_revisions:$r:__deleted__'];
        if (op == null) continue; // never explicitly tombstoned; can't have reached zero-live via this path
        if (fallbackOp == null || hlcTieBreakWins(op, fallbackOp)) {
          fallbackOp = op;
          fallback = r;
        }
      }
      fallbackForApp[appId] = fallback;
      for (final r in revisions) {
        effDeleted[r] = r != fallback;
      }
    }

    return EffectiveAppState(effDeleted, fallbackForApp);
  }

  bool effectiveRevisionDeleted(String revisionId, [EffectiveAppState? precomputed]) {
    final state = precomputed ?? computeEffectiveState();
    return state.effectiveRevisionDeleted[revisionId] ?? rawRevisionDeleted(revisionId);
  }

  /// A library is invisible if EITHER it was itself directly tombstoned
  /// (the round-15 sibling fix path, `deleteUserAppLibrary`) OR its owning
  /// revision is effectively deleted (never raw `__deleted__` — the round-8
  /// fix this file exists to validate).
  bool effectiveLibraryDeleted(String libraryId, [EffectiveAppState? precomputed]) {
    if (rawLibraryDeleted(libraryId)) return true;
    final revisionId = revisionIdForLibrary(libraryId);
    if (revisionId == null) return false; // orphaned library: not this engine's concern
    final state = precomputed ?? computeEffectiveState();
    return effectiveRevisionDeleted(revisionId, state);
  }

  /// Same composition one level further down the ownership chain: a
  /// dependency follows its owning library's EFFECTIVE (not raw) state.
  bool effectiveDependencyDeleted(String dependencyId, [EffectiveAppState? precomputed]) {
    if (rawDependencyDeleted(dependencyId)) return true;
    final libraryId = libraryIdForDependency(dependencyId);
    if (libraryId == null) return false;
    final state = precomputed ?? computeEffectiveState();
    return effectiveLibraryDeleted(libraryId, state);
  }

  /// Which revision (if any) is currently serving as [appId]'s
  /// zero-live-revisions fallback.
  String? fallbackRevisionFor(String appId, [EffectiveAppState? precomputed]) {
    final state = precomputed ?? computeEffectiveState();
    return state.fallbackRevisionForApp[appId];
  }

  // ---- purge eligibility --------------------------------------------------

  /// Mirrors `TagEngine.tagPurgeEligible`'s pattern: purge eligibility is
  /// exactly the derived, effective deletedness value — never raw
  /// `__deleted__` directly. Requirement 4 (a fallback's transitive
  /// descendants are never purge-eligible while it serves as fallback)
  /// falls out for free: the fallback revision's own `effectiveRevisionDeleted`
  /// is `false` while it serves, and every library/dependency beneath it
  /// composes off that same value.
  bool revisionPurgeEligible(String revisionId, [EffectiveAppState? precomputed]) =>
      effectiveRevisionDeleted(revisionId, precomputed);

  bool libraryPurgeEligible(String libraryId, [EffectiveAppState? precomputed]) =>
      effectiveLibraryDeleted(libraryId, precomputed);

  bool dependencyPurgeEligible(String dependencyId, [EffectiveAppState? precomputed]) =>
      effectiveDependencyDeleted(dependencyId, precomputed);
}
