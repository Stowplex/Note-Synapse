// M1.2 — permanent, automated hard-delete-call-site audit.
//
// Context (.claude/plans/plan-and-propse-the-glistening-dolphin.md, § Phased
// delivery / M1, "A significant gap, not previously found by any of the
// prior twenty review rounds"): every hard-delete bug against a synced-scope
// table found before this milestone was found by chasing a citation forward
// one sibling at a time (round 8's original three functions, then rounds 14,
// 15, 16 each finding "one more"), never by a systematic search — and a
// single grep, done once, found roughly ten more real, unconditional,
// UI-reachable hard deletes nobody had ever named (`deleteNote`, `deleteTag`,
// `replaceTag`, `deleteFilter`, `deleteConversation`,
// `deleteConversationMessage`, `deleteUserApp`, `clearAllData`, plus several
// more this test itself found beyond even that scoping pass — see below).
//
// This test is the permanent fix for that citation-chasing pattern: it does
// not trust any hand-maintained list (including this file's own baseline,
// which is why the baseline is asserted against a fresh re-scan on every
// run, not merely written down once and trusted).
//
// What it checks, every run:
//  1. Every `db.delete(...)`/`txn.delete(...)` call anywhere under `lib/`
//     that targets a table in the locked-in v1 sync scope (requirement 1)
//     is enumerated as a (file, enclosing function, table) triple — the
//     DIRECT set.
//  2. Every `ON DELETE CASCADE` foreign key in database_service.dart's
//     `CREATE TABLE` constants that points *into* a guarded table is
//     enumerated as a (parent table, child table) edge — the FK-EDGES set.
//     Deleting a row in the parent implicitly, silently deletes matching
//     child rows even though no `db.delete` call for the child exists.
//  3. Combining 1+2: for every function with a DIRECT delete against a
//     guarded parent table, every guarded table transitively reachable via
//     FK-EDGES is an indirect hard-delete site for that function too — the
//     CASCADE-ONLY set (entries already covered by a DIRECT entry for the
//     same function/table are omitted as redundant).
//
// All three sets are asserted to *exactly* match a checked-in baseline
// below. On mismatch the failure message names every added and removed
// entry so a genuinely new hard-delete call site (or a newly-introduced
// cascade edge) forces a deliberate, reviewed decision — add it to the
// baseline with justification, or fix the code — rather than shipping
// silently, which is exactly the failure mode rounds 8-16 exhibited.
//
// Design choice — symmetric fail on both ADD and REMOVE: a baseline entry
// disappearing is treated exactly like a new one appearing (test fails
// either way), not silently accepted or merely warned about. A removal
// could mean the code was fixed (e.g. a future milestone converts a
// function to soft-delete) or it could mean the regex silently stopped
// matching after an unrelated refactor (a false negative, arguably worse
// than a false positive since it reopens the exact hole this test exists to
// close). Both cases require a human to look and deliberately edit this
// file's baseline — that's the point.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The locked-in v1 sync scope (design doc § "Locked-in product
/// requirements", requirement 1): notes, subnotes, tags (+ tag_images,
/// tag_ai_configs, tag_workflow_bindings), filters, attachments,
/// relationships, User Apps + revision history, and AI conversation
/// history — expanded here to name every underlying table, including the
/// join/mapping tables, since the audit operates at the table level.
///
/// Deliberately excluded (per requirement 1 and the schema comment above
/// `_createSyncFieldStateTable` in database_service.dart): settings/
/// preferences, `multi_function_apps`, and the `sync_*` control-plane
/// tables themselves (M1.1) — none of these carry synced user content.
/// `note_annotations` is also excluded: it is not named anywhere in
/// requirement 1's list and carries no FK into/out of any guarded table
/// (its `note_id`/`attachment_id` columns are plain, FK-less references
/// enforced only by a CHECK constraint) — a boundary case worth a future,
/// explicit scoping decision if annotations are ever meant to sync, but out
/// of this milestone's scope as written today.
const Set<String> kGuardedTables = {
  'notes',
  'subnotes',
  'tags',
  'tag_images',
  'tag_ai_configs',
  'tag_workflow_bindings',
  'filters',
  'attachments',
  'relationships',
  'user_apps',
  'app_revisions',
  'user_app_libraries',
  'user_app_library_dependencies',
  'conversations',
  'conversation_messages',
  'conversation_attachments',
  'note_tags',
  'conversation_tags',
  'conversation_message_mapping',
  'message_parents',
  'conversation_note_mapping',
};

/// One (file, enclosing function, table) hard-delete site.
class HardDeleteSite implements Comparable<HardDeleteSite> {
  final String file;
  final String function;
  final String table;

  const HardDeleteSite(this.file, this.function, this.table);

  @override
  bool operator ==(Object other) =>
      other is HardDeleteSite &&
      other.file == file &&
      other.function == function &&
      other.table == table;

  @override
  int get hashCode => Object.hash(file, function, table);

  @override
  int compareTo(HardDeleteSite other) {
    final byFile = file.compareTo(other.file);
    if (byFile != 0) return byFile;
    final byFn = function.compareTo(other.function);
    if (byFn != 0) return byFn;
    return table.compareTo(other.table);
  }

  @override
  String toString() => "HardDeleteSite('$file', '$function', '$table')";
}

/// One `ON DELETE CASCADE` foreign-key edge, parent table -> child table.
class FkEdge implements Comparable<FkEdge> {
  final String parent;
  final String child;

  const FkEdge(this.parent, this.child);

  @override
  bool operator ==(Object other) =>
      other is FkEdge && other.parent == parent && other.child == child;

  @override
  int get hashCode => Object.hash(parent, child);

  @override
  int compareTo(FkEdge other) {
    final byParent = parent.compareTo(other.parent);
    if (byParent != 0) return byParent;
    return child.compareTo(other.child);
  }

  @override
  String toString() => "FkEdge('$parent', '$child')";
}

// ===========================================================================
// Checked-in baselines. Generated by scanning the actual codebase (see the
// scanner functions below, which this test re-runs on every invocation) and
// hand-reviewed line-by-line against a direct reading of
// lib/services/database_service.dart and lib/services/note_modification_
// service.dart before being locked in here. Do not hand-edit an entry
// without re-reading the corresponding source: the whole point of this file
// is that the checked-in list and the live source must be kept in sync
// deliberately, not by assumption.
// ===========================================================================

/// Direct `db.delete(...)`/`txn.delete(...)` call sites against a guarded
/// table, one entry per distinct (file, function, table) — a function that
/// issues more than one delete statement against the same table (e.g.
/// `replaceTag`'s two separate `note_tags` deletes, one for orphan cleanup
/// and one for the old tag's own rows) still gets a single baseline entry,
/// since the baseline records *which pairs exist*, not statement counts.
///
/// Cross-checked against the plan's own scoping-pass list of ~8
/// previously-unnamed sites (`deleteNote`, `deleteTag`, `replaceTag`,
/// `deleteFilter`, `deleteConversation`, `deleteConversationMessage`,
/// `deleteUserApp`, `clearAllData`) plus the earlier-named
/// `deleteAppRevision`/`deleteUserAppLibrary`/`deleteUserAppLibraryDependency`/
/// `deleteUserAppLibrariesForRevision` — all twelve originally appeared
/// below. **M1.4 update**: `deleteAppRevision`/`deleteUserAppLibrary`/
/// `deleteUserAppLibraryDependency`/`deleteUserApp` are now soft-delete
/// only (an ordinary `db.update(...)` tombstone write, not a `db.delete`
/// this scanner matches), and `deleteUserAppLibrariesForRevision` has been
/// removed from the codebase entirely — all five of those baseline entries
/// were deliberately removed below as part of that conversion (the audit's
/// own symmetric fail-on-removal design requires exactly this: a human
/// decision, recorded here, not a silent baseline drift). `deleteAppRevisions`
/// (plural, still a real, unconverted, currently-unused hard delete — see
/// its own entry below) is the only one of the original twelve still
/// present. This scan additionally found eighteen more the plan's own text
/// never named at all: `updateNote`/`_persistNote` (both unconditionally
/// delete-then-reinsert `subnotes`/`note_tags` on every note edit, not just on delete;
/// `attachments` uses a selective diff-based delete in both, not a blind
/// delete-all, so it's the same *pattern class* — deletes running far more
/// often than any explicit delete action — not an identical mechanism),
/// `removeTagImage`, `deleteRelationship`,
/// `deleteRelationshipBetween`, `deleteRelationshipsForNote`,
/// `deleteAppRevisions` (plural — distinct from `deleteAppRevision`),
/// `_deleteMessagesBatch`, `_cleanupEmptyConversations`,
/// `deleteConversationExplicitly`, `deleteConversationAttachment`,
/// `deleteEmptyConversations`, `deleteConversationNoteMapping(s)`,
/// `deleteNoteConversationMappings`, `setConversationTags`,
/// `removeTagFromConversation`, `updateTagExtractionPrompt`,
/// `deleteWorkflowBinding`, and `_applyLinkModifications`. **M1.7 update**:
/// `deleteFilter`/`deleteWorkflowBinding` are now soft-delete only (an
/// ordinary `db.update(...)` tombstone write, not a `db.delete` this
/// scanner matches) — both baseline entries were deliberately removed
/// below as part of that conversion, mirroring exactly how M1.4 removed
/// the User-App-family entries above (same symmetric fail-on-removal
/// design: a human decision, recorded here, not a silent baseline drift).
/// `clearAllData`'s own `filters` entry (below) is untouched by this —
/// `clearAllData` itself remains a real, unconverted hard delete across
/// the board until M1.13.
///
/// **M1.8 update**: `deleteRelationship`/`deleteRelationshipBetween`/
/// `deleteRelationshipsForNote`/`deleteConversationAttachment` are now
/// soft-delete only (an ordinary `db.update(...)` tombstone write, not a
/// `db.delete` this scanner matches) — all four baseline entries were
/// deliberately removed below. `_applyLinkModifications`'s entry was also
/// removed: both its `txn`- and non-`txn`-based removal paths now issue a
/// tombstone `UPDATE` (the `txn` path directly; the non-`txn` path via the
/// now-converted `deleteRelationshipBetween`), so no `db.delete`/
/// `txn.delete` call against a guarded table remains in that function's
/// body. `clearAllData`'s own `relationships`/`conversation_attachments`
/// entries and `_deleteMessagesBatch`'s own `conversation_attachments`
/// entry (both below) are untouched by this — deliberately deferred, see
/// the doc comments at their call sites in database_service.dart
/// (`clearAllData` until M1.13; `_deleteMessagesBatch`'s
/// `conversation_attachments` delete until `conversation_messages` itself
/// is converted in M1.12).
///
/// **M1.9 update**: `deleteTag`/`replaceTag`'s own `tags`-row delete
/// (the final statement in each function, distinct from their `note_tags`/
/// `conversation_tags` cleanup) is now soft-delete only (an ordinary
/// `db.update(...)` tombstone write reusing M1.3's `__deleted__` column,
/// not a `db.delete` this scanner matches) — both `(deleteTag, 'tags')`
/// and `(replaceTag, 'tags')` baseline entries were deliberately removed
/// below. Their `note_tags`/`conversation_tags` entries are untouched —
/// those remain real deletes of an OR-Set membership table, out of this
/// milestone's scope. This has a non-obvious knock-on effect on
/// [kCascadeOnlyBaseline], documented at its own doc comment below: with
/// no more DIRECT `tags` delete for either function, the `tag_ai_configs`/
/// `tag_images` cascade-only entries these two functions used to have are
/// gone too — not because the code changed further, but because the
/// cascade genuinely no longer fires (removed there, not here).
///
/// **M1.10 update**: `deleteNote`'s own `notes`-row delete (the function's
/// final statement, previously the only delete in the function) is now
/// soft-delete only (an ordinary `db.update(...)` tombstone write, not a
/// `db.delete` this scanner matches) — the `(deleteNote, 'notes')` baseline
/// entry was deliberately removed below. Unlike M1.7/M1.9's conversions,
/// this one does NOT just shrink `deleteNote`'s DIRECT footprint: the
/// function gained three brand-new DIRECT deletes of its own, added as
/// explicit replacements for cleanup the `ON DELETE CASCADE` from `notes`
/// used to do implicitly (cascades only fire on a real `DELETE`, and
/// `notes` no longer gets one) — `(deleteNote, 'note_tags')`,
/// `(deleteNote, 'subnotes')`, and `(deleteNote, 'attachments')` were
/// deliberately ADDED below. `note_tags` is a real delete because it is an
/// OR-Set membership table (correct, unaffected by this milestone, same
/// reasoning as `deleteTag`'s own `note_tags` cleanup). `subnotes`/
/// `attachments` are ALSO real deletes here, not tombstones — a deliberate
/// choice, not an oversight: as of M1.10 neither table had its own
/// `__deleted__` column yet (that was M1.11's job, alongside the rewrite
/// of `updateNote`/`_persistNote`'s diff-based subnote/attachment
/// handling). **M1.11 update**: both tables now DO have `__deleted__`
/// (consumed by `updateNote`/`_persistNote`, see those entries' own doc
/// comment below), but `deleteNote` itself was deliberately left
/// unconverted — out of M1.11's own scope — so these two baseline entries
/// are unaffected and remain real deletes; see `deleteNote`'s own doc
/// comment in database_service.dart for the full, current reasoning. A
/// real delete here is still the like-for-like replacement of what the
/// lost cascade used to do for both tables. `relationships`
/// and `conversation_note_mapping` do NOT get new DIRECT entries here even
/// though they too lost their cascade cleanup: `deleteNote` reuses
/// `deleteRelationshipsForNote` (already soft-delete since M1.8, an
/// `UPDATE` this scanner never matched even before this milestone) and
/// `deleteNoteConversationMappings` (a real delete, but its `db.delete`
/// call lives inside `deleteNoteConversationMappings`'s OWN function body,
/// not textually inside `deleteNote` — this scanner attributes a call to
/// its lexically-enclosing function, not its logical caller, so this was
/// already a separate, pre-existing DIRECT entry for
/// `deleteNoteConversationMappings` itself, entirely unaffected by this
/// milestone). This has the same non-obvious knock-on effect on
/// [kCascadeOnlyBaseline] that M1.9's `tags` conversion had: with no more
/// DIRECT `notes` delete for `deleteNote`, every cascade-only entry that
/// used to be derived FROM that direct `notes` entry disappears too — see
/// that baseline's own doc comment below for the full list.
///
/// **M1.11 update**: `updateNote`'s and `_persistNote`'s `subnotes`/
/// `attachments` deletes are now soft-delete only — both functions'
/// blind delete-then-reinsert (`subnotes`) and filePath-diffed delete
/// (`attachments`) were rewritten into a single shared, id-/filePath-
/// keyed diff (`DatabaseService.diffAndPersistSubNotes`/
/// `diffAndPersistAttachments`, called by both) that tombstones a removed
/// row (`db.update(...)`, not a `db.delete`/`txn.delete` this scanner
/// matches) instead of deleting it. Both `(updateNote, 'subnotes')`/
/// `(updateNote, 'attachments')` and `(_persistNote, 'subnotes')`/
/// `(_persistNote, 'attachments')` — four entries total — were
/// deliberately removed below: the shared diff helper issues zero
/// `db.delete`/`txn.delete` calls against either table, for either
/// caller, confirmed by inspection of the rewritten diff logic itself (a
/// tombstone write is always `.update(...)`), not merely inferred from
/// the milestone's intent. `(updateNote, 'note_tags')` and
/// `(_persistNote, 'note_tags')` are untouched — `note_tags` is an OR-Set
/// membership table, deliberately kept as a real delete-then-reinsert in
/// both functions, out of this milestone's scope (same table, same
/// reasoning `deleteNote`'s own `note_tags` entry already has).
/// `deleteNote`'s own three M1.10 entries (`attachments`, `note_tags`,
/// `subnotes`, above) are unaffected: `deleteNote` deliberately still
/// real-deletes `subnotes`/`attachments`, out of M1.11's own scope (see
/// `deleteNote`'s doc comment in database_service.dart) — this is a real,
/// disclosed inconsistency (a row can be tombstoned by an edit but hard-
/// deleted by a whole-note deletion), not an oversight the baseline
/// failed to catch.
///
/// **M1.12 update**: `conversations`/`conversation_messages` gained
/// `__deleted__`. `deleteConversation`, `deleteConversationExplicitly`,
/// `deleteConversationMessage` (which now delegates entirely to
/// `_deleteMessagesBatch`), and `_deleteMessagesBatch`'s own
/// `conversation_messages`/`conversation_attachments` deletes are now all
/// soft-delete only — every `(function, 'conversations')`/
/// `(function, 'conversation_messages')`/`(_deleteMessagesBatch,
/// 'conversation_attachments')` entry these four functions used to have
/// was deliberately removed below. `_deleteMessagesBatch` keeps its
/// `conversation_message_mapping`/`message_parents` entries (real deletes
/// of OR-Set membership tables, unaffected). A NEW shared helper,
/// `_purgeMembershipRowsForConversationIds`, gained three DIRECT entries
/// (`conversation_message_mapping`, `conversation_note_mapping`,
/// `conversation_tags`) — reused by `deleteConversation`/
/// `deleteConversationExplicitly` (as the explicit cascade replacement for
/// their now-inert `conversations -> {...}` `ON DELETE CASCADE`) and by
/// `_cleanupEmptyConversations`/`deleteEmptyConversations` (as safe OR-Set
/// garbage collection — see those two functions' own doc comment in
/// database_service.dart for why they no longer touch `conversations`
/// itself at all, the milestone's central, previously-unresolved design
/// decision). Because the actual `db.delete` calls now live inside this
/// one shared helper (not lexically inside any of its four callers, same
/// attribution rule `deleteNoteConversationMappings`'s entry already
/// relies on for `deleteNote` — see that entry's own note above),
/// `deleteConversation`/`deleteConversationExplicitly` end up with ZERO
/// remaining DIRECT entries of their own (both disappear from this
/// baseline entirely), and `_cleanupEmptyConversations`/
/// `deleteEmptyConversations` — which never had any other direct delete of
/// their own — disappear entirely too.
///
/// **M1.13 update (step 0, a load-bearing prerequisite for this
/// milestone's own hard-delete guard extension — see
/// `_hardDeleteGuardedTables`'s doc comment in database_service.dart)**:
/// `deleteNote`'s own `subnotes`/`attachments` deletes (added in M1.10,
/// deliberately left real/unconverted through M1.11 and M1.12 — see the
/// M1.10/M1.11 update notes above) are now soft-delete only, converted
/// alongside the rest of this milestone's guard rollout rather than left
/// for a future milestone to rediscover. `(deleteNote, 'attachments')` and
/// `(deleteNote, 'subnotes')` were deliberately removed below.
/// `(deleteNote, 'note_tags')` is untouched — still a real delete of an
/// OR-Set membership table, correct and out of scope. `clearAllData`'s own
/// nine entity-table entries (below) are deliberately UNTOUCHED by this
/// milestone despite `_hardDeleteGuardedTables` now covering all nine of
/// their tables: `clearAllData` keeps issuing real `db.delete` calls
/// against them on purpose (a full local reset/debug wipe, not an
/// ordinary CRDT-tracked deletion — ordinary tombstoning would leave
/// every row behind forever, defeating the point of "clear all data"),
/// and instead bypasses the guard for its own operation by dropping and
/// reinstalling those nine tables' guard triggers around its delete
/// block — see `clearAllData`'s own doc comment in database_service.dart
/// for the full reasoning. This scanner has no way to see that
/// drop/reinstall dance (it only matches `db.delete`/`txn.delete`/
/// `db.rawDelete` calls), so `clearAllData`'s baseline entries correctly
/// keep appearing here exactly as before — this is expected, not a gap:
/// the guard bypass is a deliberate, narrow, self-contained escape hatch
/// for one specific, non-CRDT-tracked function, not a hole in the
/// guarded-table coverage itself.
final List<HardDeleteSite> kDirectBaseline = [
  const HardDeleteSite(
    'lib/services/database_service.dart',
    '_deleteMessagesBatch',
    'conversation_message_mapping',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    '_deleteMessagesBatch',
    'message_parents',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    '_purgeMembershipRowsForConversationIds',
    'conversation_message_mapping',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    '_purgeMembershipRowsForConversationIds',
    'conversation_note_mapping',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    '_purgeMembershipRowsForConversationIds',
    'conversation_tags',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'attachments',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'conversation_attachments',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'conversation_message_mapping',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'conversation_messages',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'conversation_note_mapping',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'conversation_tags',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'conversations',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'filters',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'message_parents',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'note_tags',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'notes',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'relationships',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'subnotes',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'tags',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'deleteAppRevisions',
    'app_revisions',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'deleteConversationNoteMapping',
    'conversation_note_mapping',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'deleteConversationNoteMappings',
    'conversation_note_mapping',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'deleteNote',
    'note_tags',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'deleteNoteConversationMappings',
    'conversation_note_mapping',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'deleteTag',
    'conversation_tags',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'deleteTag',
    'note_tags',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'removeTagFromConversation',
    'conversation_tags',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'removeTagImage',
    'tag_images',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'replaceTag',
    'conversation_tags',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'replaceTag',
    'note_tags',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'setConversationTags',
    'conversation_tags',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'updateNote',
    'note_tags',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'updateTagExtractionPrompt',
    'tag_ai_configs',
  ),
  const HardDeleteSite(
    'lib/services/note_modification_service.dart',
    '_persistNote',
    'note_tags',
  ),
];

/// `ON DELETE CASCADE` edges out of every `CREATE TABLE` constant in
/// database_service.dart, parent -> child. `user_apps -> multi_function_apps`
/// is included for completeness/accuracy of the schema-fact check (it is a
/// real cascade edge) even though `multi_function_apps` itself is outside
/// guarded scope and therefore never contributes a CASCADE-ONLY entry below.
final List<FkEdge> kFkEdgeBaseline = [
  const FkEdge('conversation_messages', 'conversation_attachments'),
  const FkEdge('conversation_messages', 'conversation_message_mapping'),
  const FkEdge('conversation_messages', 'message_parents'),
  const FkEdge('conversations', 'conversation_message_mapping'),
  const FkEdge('conversations', 'conversation_note_mapping'),
  const FkEdge('conversations', 'conversation_tags'),
  const FkEdge('notes', 'attachments'),
  const FkEdge('notes', 'conversation_note_mapping'),
  const FkEdge('notes', 'note_tags'),
  const FkEdge('notes', 'relationships'),
  const FkEdge('notes', 'subnotes'),
  const FkEdge('tags', 'conversation_tags'),
  const FkEdge('tags', 'note_tags'),
  const FkEdge('tags', 'tag_ai_configs'),
  const FkEdge('tags', 'tag_images'),
  const FkEdge('user_app_libraries', 'user_app_library_dependencies'),
  const FkEdge('user_apps', 'app_revisions'),
  const FkEdge('user_apps', 'multi_function_apps'),
  const FkEdge('user_apps', 'user_app_libraries'),
];

/// Indirect hard-delete sites: for every function with a DIRECT delete
/// against a guarded parent table (per [kDirectBaseline]), every guarded
/// table transitively reachable from that parent via [kFkEdgeBaseline],
/// *excluding* pairs already present in [kDirectBaseline] for the same
/// function (those are already covered/visible there; repeating them here
/// would just be noise).
///
/// The most consequential entries (**pre-M1.10** — see that milestone's own
/// update note below for why this no longer holds): `deleteNote` used to
/// cascade into `attachments`, `conversation_note_mapping`, `note_tags`,
/// `relationships`, and `subnotes` purely via FK, with no explicit delete
/// statement for any of them visible in the function body; and every
/// conversation-deleting function (`deleteConversation`, `deleteConversationExplicitly`,
/// `deleteEmptyConversations`, `_cleanupEmptyConversations`) reaches
/// `conversation_message_mapping`, `conversation_note_mapping`, and
/// `conversation_tags` purely via FK.
/// **M1.4 update**: `deleteUserApp`/`deleteUserAppLibrary`/
/// `deleteUserAppLibrariesForRevision` used to reach
/// `user_app_library_dependencies` this same transitive-FK way (each had a
/// DIRECT delete against a parent table that cascades there); now that
/// `deleteUserApp`/`deleteUserAppLibrary` are soft-delete-only (no `db.delete`
/// call left at all) and `deleteUserAppLibrariesForRevision` has been
/// removed from the codebase entirely, none of the three has a DIRECT entry
/// left to derive a cascade from, so all three of their entries were
/// deliberately removed below alongside the [kDirectBaseline] removals.
/// **M1.9 update, the same structural change again**: `deleteTag`/
/// `replaceTag` used to reach `tag_ai_configs`/`tag_images` this same
/// transitive-FK way, on top of their own direct `note_tags`/
/// `conversation_tags`/`tags` deletes. Now that their `tags`-row delete is
/// soft-delete-only (see [kDirectBaseline]'s M1.9 update above), each
/// function's only remaining DIRECT entries are `note_tags`/
/// `conversation_tags` — neither of which is a parent of anything in
/// [kFkEdgeBaseline] (they're FK leaves, not parents), so there is no
/// surviving DIRECT `tags` entry for either function to derive a cascade
/// from. This is not a baseline bookkeeping choice: the actual `ON DELETE
/// CASCADE` from `tags` into `tag_ai_configs`/`tag_images` genuinely no
/// longer fires when `deleteTag`/`replaceTag` run, since neither issues a
/// real `DELETE FROM tags` anymore — the live scanner correctly stops
/// finding these four entries, so all four
/// (`deleteTag`/`tag_ai_configs`, `deleteTag`/`tag_images`,
/// `replaceTag`/`tag_ai_configs`, `replaceTag`/`tag_images`) were
/// deliberately removed below. This is exactly the design doc's own
/// M1.9 scope note in practice: "tag_images`/`tag_ai_configs` visibility
/// derivation... the existing `ON DELETE CASCADE` FK from `tags`→
/// `tag_images`/`tag_ai_configs` will simply never fire again for a
/// tombstoned tag" — read paths (`getAllTagImages`/`getTagImage`/
/// `getTagExtractionPrompt`) now derive visibility from the owning tag's
/// `__deleted__` state instead, since the cascade can no longer do it for
/// them. `clearAllData`'s own `tag_ai_configs`/`tag_images` cascade-only
/// entries (below) are untouched by this — `clearAllData` still issues a
/// real `DELETE FROM tags` today (deliberately deferred to M1.13), so its
/// cascade still fires and is still correctly represented here.
///
/// **M1.10 update, the same structural change a third time**: `deleteNote`
/// used to have exactly one DIRECT entry (`notes`, per [kDirectBaseline]
/// pre-M1.10), from which all five of the entries this doc comment's
/// opening paragraph describes were derived. Now that `notes`-row deletion
/// is soft-delete-only (see [kDirectBaseline]'s M1.10 update above),
/// `deleteNote` has no surviving DIRECT `notes` entry to derive a cascade
/// from — its three current DIRECT entries (`attachments`, `note_tags`,
/// `subnotes`) are themselves FK leaves in [kFkEdgeBaseline], not parents,
/// so none of them contributes a transitive cascade-only entry either. All
/// five original `deleteNote` cascade-only entries (`attachments`,
/// `conversation_note_mapping`, `note_tags`, `relationships`, `subnotes`)
/// were therefore deliberately removed below — not a bookkeeping choice:
/// the actual `ON DELETE CASCADE` from `notes` genuinely no longer fires
/// when `deleteNote` runs, since it no longer issues a real `DELETE FROM
/// notes`. Every one of those five child tables is still explicitly
/// cleaned up by `deleteNote` itself (three via its own new DIRECT
/// entries, `relationships` via `deleteRelationshipsForNote`, and
/// `conversation_note_mapping` via `deleteNoteConversationMappings` — see
/// `deleteNote`'s own doc comment in database_service.dart) — this
/// baseline change reflects that the cleanup mechanism changed from
/// implicit-cascade to explicit-statement, not that the cleanup stopped
/// happening. `clearAllData` is untouched by this: it already issues a
/// real `DELETE FROM notes` (deliberately deferred to M1.13) AND its own
/// direct deletes of every one of `notes`' cascade targets, so it never
/// contributed a `deleteNote`-style cascade-only entry for any of them in
/// the first place — nothing to remove here.
///
/// **M1.12 update, the same structural change a fourth time**:
/// `deleteConversation`/`deleteConversationExplicitly`/
/// `deleteConversationMessage`/`_cleanupEmptyConversations`/
/// `deleteEmptyConversations` used to reach `conversation_message_mapping`/
/// `conversation_note_mapping`/`conversation_tags`
/// (`deleteConversation`/`deleteConversationExplicitly`/
/// `_cleanupEmptyConversations`/`deleteEmptyConversations`, via the
/// `conversations -> {...}` cascade) or `conversation_attachments`/
/// `conversation_message_mapping`/`message_parents`
/// (`deleteConversationMessage`, via the `conversation_messages -> {...}`
/// cascade) this same transitive-FK way. Now that none of these five
/// functions has a surviving DIRECT `conversations`/`conversation_messages`
/// entry (see [kDirectBaseline]'s M1.12 update above — `deleteConversation`/
/// `deleteConversationExplicitly` have no DIRECT entries left at all,
/// `deleteConversationMessage` delegates entirely to
/// `_deleteMessagesBatch`, and `_cleanupEmptyConversations`/
/// `deleteEmptyConversations` never had any other direct delete of their
/// own), none of them has anything left to derive a cascade-only entry
/// from — all fifteen were therefore deliberately removed below. This is
/// not a baseline bookkeeping choice: every one of these cascades genuinely
/// no longer fires for any of these five functions, since none of them
/// issues a real `DELETE FROM conversations`/`DELETE FROM
/// conversation_messages` anymore. Every child table these functions used
/// to reach via cascade is still explicitly cleaned up (via the new
/// `_purgeMembershipRowsForConversationIds` helper, now a DIRECT entry of
/// its own per [kDirectBaseline], or — for `deleteConversationMessage` —
/// via `_deleteMessagesBatch`'s own unaffected DIRECT
/// `conversation_message_mapping`/`message_parents` entries plus its now-
/// tombstoned `conversation_attachments` write). `clearAllData` is
/// untouched by this: it already issues real `DELETE FROM
/// conversations`/`DELETE FROM conversation_messages` (deliberately
/// deferred to M1.13) AND its own direct deletes of every one of their
/// cascade targets, so it never contributed a cascade-only entry for any
/// of them in the first place.
final List<HardDeleteSite> kCascadeOnlyBaseline = [
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'tag_ai_configs',
  ),
  const HardDeleteSite(
    'lib/services/database_service.dart',
    'clearAllData',
    'tag_images',
  ),
];

// ===========================================================================
// Scanner. Deliberately a regex/text scan, not a Dart AST parser (a full
// parser is unnecessary for this codebase's consistently `dart format`-ted
// style — see the function-boundary heuristic below, which relies on that
// consistency and is validated against it).
// ===========================================================================

/// Matches a class-member function *declaration* line: exactly two leading
/// spaces (the class-body indent level this codebase's `dart format` always
/// uses), then a return-type-shaped prefix, then an identifier immediately
/// followed by `(`. Statements *inside* a method (loop bodies, awaits,
/// conditionals) are always indented four or more spaces in this codebase,
/// so they never match this pattern — the exact-two-space requirement is
/// what makes "nearest preceding match" a reliable enclosing-function
/// lookup without a real parser. The prefix character class deliberately
/// excludes `=`, so ordinary field initializers like
/// `final _uuid = Uuid();` cannot be mistaken for a declaration whose name
/// is `Uuid`: the disallowed `=` blocks the match from ever reaching past
/// it.
final RegExp _kFunctionStart = RegExp(
  r'^  (?:static\s+)?[A-Za-z_][\w<>,\.\?\s\[\]]*\s(_?[A-Za-z]\w*)\s*\(',
);

/// Matches a delete call whose receiver is `db` or `txn` — the only two
/// receiver names used anywhere in `lib/` for a `Database`/
/// `DatabaseExecutor` handle (verified: `grep -rhoE '\w+\.delete\('`
/// against `lib/` turns up only `db.delete(`, `txn.delete(`, plus unrelated
/// `File`/secure-storage/http-client `.delete(` calls on entirely different
/// receiver names, which this pattern does not match). Also matches
/// `.rawDelete(`, the raw-SQL sibling of `.delete(` — a currently-unused
/// but genuinely reachable path (nothing stops a future call site from
/// using it against a guarded table) that the audit must not silently
/// miss; see [_kRawDeleteTableArg] for how its table name is extracted.
final RegExp _kDeleteCall = RegExp(r'\b(db|txn)\.(delete|rawDelete)\(');

/// Extracts the (single-quoted) table-name argument from an ordinary
/// `.delete('table', ...)` call, tolerating the call spanning a couple of
/// lines (the common `dart format` style for calls with `where`/
/// `whereArgs` arguments).
final RegExp _kDeleteTableArg = RegExp(
  r"""\.delete\(\s*\n?\s*'([a-zA-Z_]+)'""",
);

/// Extracts the table name from a `.rawDelete('DELETE FROM table ...', ...)`
/// call's embedded SQL string — a structurally different shape from
/// `.delete('table', ...)`, since the table name isn't a positional
/// argument, it's inside the raw SQL text itself.
final RegExp _kRawDeleteTableArg = RegExp(
  r'''\.rawDelete\(\s*\n?\s*['"]DELETE\s+FROM\s+(\w+)''',
  caseSensitive: false,
);

/// Scans every `.dart` file under [root] for guarded-table delete call
/// sites, returning one [HardDeleteSite] per distinct (file, function,
/// table) triple found.
Set<HardDeleteSite> scanDirectHardDeleteSites({String root = 'lib'}) {
  final sites = <HardDeleteSite>{};
  final files = Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));

  for (final file in files) {
    final path = file.path.replaceAll('\\', '/');
    final lines = file.readAsStringSync().split('\n');

    // Build the ordered list of function-start (line index, name) pairs.
    final funcBoundaries = <MapEntry<int, String>>[];
    for (var i = 0; i < lines.length; i++) {
      final m = _kFunctionStart.firstMatch(lines[i]);
      if (m != null) funcBoundaries.add(MapEntry(i, m.group(1)!));
    }

    String enclosingFunction(int lineIdx) {
      var name = '<top-level>';
      for (final entry in funcBoundaries) {
        if (entry.key <= lineIdx) {
          name = entry.value;
        } else {
          break;
        }
      }
      return name;
    }

    for (var i = 0; i < lines.length; i++) {
      if (!_kDeleteCall.hasMatch(lines[i])) continue;

      // Gather up to 8 lines starting here (covers this codebase's longest
      // multi-line delete calls) so a table-name argument on a later line
      // is still found.
      final buf = StringBuffer();
      for (var j = i; j < lines.length && j < i + 8; j++) {
        buf.writeln(lines[j]);
        if (lines[j].contains(';')) break;
      }
      final bufStr = buf.toString();
      final table =
          _kDeleteTableArg.firstMatch(bufStr)?.group(1) ??
          _kRawDeleteTableArg.firstMatch(bufStr)?.group(1);
      if (table == null || !kGuardedTables.contains(table)) continue;

      sites.add(HardDeleteSite(path, enclosingFunction(i), table));
    }
  }
  return sites;
}

/// Matches one `static const String _createXTable = '''...''';` schema
/// constant block in database_service.dart.
final RegExp _kTableConstBlock = RegExp(
  r"static const String _create\w+Table = '''([\s\S]*?)''';",
);
final RegExp _kTableName = RegExp(r'CREATE TABLE(?:\s+IF NOT EXISTS)?\s+(\w+)');
final RegExp _kForeignKeyCascade = RegExp(
  r'REFERENCES\s+(\w+)\s*\([^)]*\)\s*ON DELETE CASCADE',
);

/// Parses every `ON DELETE CASCADE` foreign key out of database_service.
/// dart's `CREATE TABLE` schema constants, returning one [FkEdge] per
/// (parent, child) relationship found — regardless of whether either side
/// is in [kGuardedTables] (that filtering happens when the edges are used
/// to compute cascade closure, not here, so this function is a faithful,
/// complete re-parse of the actual current schema).
Set<FkEdge> scanFkCascadeEdges({
  String path = 'lib/services/database_service.dart',
}) {
  final src = File(path).readAsStringSync();
  final edges = <FkEdge>{};
  for (final block in _kTableConstBlock.allMatches(src)) {
    final body = block.group(1)!;
    final tableName = _kTableName.firstMatch(body)?.group(1);
    if (tableName == null) continue;
    for (final fk in _kForeignKeyCascade.allMatches(body)) {
      edges.add(FkEdge(fk.group(1)!, tableName));
    }
  }
  return edges;
}

/// Every guarded table transitively reachable from [table] by following
/// [edges] (parent -> child), i.e. every guarded table implicitly deleted
/// when a row in [table] is deleted, directly or via a chain of cascades
/// (e.g. `user_apps` -> `user_app_libraries` ->
/// `user_app_library_dependencies`).
Set<String> transitiveGuardedChildren(String table, Set<FkEdge> edges) {
  final byParent = <String, List<String>>{};
  for (final e in edges) {
    byParent.putIfAbsent(e.parent, () => []).add(e.child);
  }
  final seen = <String>{};
  final queue = [table];
  while (queue.isNotEmpty) {
    final t = queue.removeLast();
    for (final child in byParent[t] ?? const <String>[]) {
      if (kGuardedTables.contains(child) && seen.add(child)) {
        queue.add(child);
      }
    }
  }
  return seen;
}

/// Computes the CASCADE-ONLY set (see [kCascadeOnlyBaseline]'s doc comment)
/// from a freshly-scanned [directSites]/[fkEdges] pair, so the comparison
/// test below exercises today's real source, not the checked-in baselines
/// compared against each other.
Set<HardDeleteSite> computeCascadeOnlySites(
  Set<HardDeleteSite> directSites,
  Set<FkEdge> fkEdges,
) {
  final directKeys = {
    for (final s in directSites) '${s.file}|${s.function}|${s.table}',
  };
  final byFunctionTables = <String, Set<String>>{};
  for (final s in directSites) {
    byFunctionTables
        .putIfAbsent('${s.file}|${s.function}', () => {})
        .add(s.table);
  }

  final cascadeOnly = <HardDeleteSite>{};
  for (final entry in byFunctionTables.entries) {
    final parts = entry.key.split('|');
    final file = parts[0];
    final function = parts[1];
    for (final table in entry.value) {
      for (final child in transitiveGuardedChildren(table, fkEdges)) {
        final key = '$file|$function|$child';
        if (directKeys.contains(key)) continue; // already a direct entry
        cascadeOnly.add(HardDeleteSite(file, function, child));
      }
    }
  }
  return cascadeOnly;
}

/// Formats a clear "added/removed" diff between a live-scanned set and its
/// checked-in baseline for assertion failure messages.
String _diffMessage<T extends Comparable<T>>(
  String label,
  Set<T> live,
  Set<T> baseline,
) {
  final added = live.difference(baseline).toList()..sort();
  final removed = baseline.difference(live).toList()..sort();
  final buf = StringBuffer();
  if (added.isNotEmpty) {
    buf.writeln(
      '$label: ${added.length} entr${added.length == 1 ? 'y' : 'ies'} '
      'found in the live source but NOT in the checked-in baseline '
      '(new hard-delete site(s) — add to the baseline with justification, '
      'or fix the code):',
    );
    for (final a in added) {
      buf.writeln('  + $a');
    }
  }
  if (removed.isNotEmpty) {
    buf.writeln(
      '$label: ${removed.length} baseline entr${removed.length == 1 ? 'y' : 'ies'} '
      'no longer found in the live source (either the code was fixed — '
      'remove from the baseline deliberately — or the scan regressed and '
      'stopped matching; investigate before removing):',
    );
    for (final r in removed) {
      buf.writeln('  - $r');
    }
  }
  return buf.toString();
}

void main() {
  test(
    'FK cascade edges into guarded tables exactly match checked-in baseline',
    () {
      final live = scanFkCascadeEdges();
      final baseline = kFkEdgeBaseline.toSet();
      expect(
        live,
        equals(baseline),
        reason: _diffMessage('FK cascade edges', live, baseline),
      );
    },
  );

  test('direct hard-delete call sites against guarded tables exactly match '
      'checked-in baseline', () {
    final live = scanDirectHardDeleteSites();
    final baseline = kDirectBaseline.toSet();
    expect(
      live.length,
      greaterThan(0),
      reason:
          'Scanner found zero direct delete sites — this almost '
          'certainly means the scan itself regressed (e.g. the '
          'db./txn. receiver pattern or guarded-table filter broke), '
          'not that every hard delete was fixed. Investigate before '
          'trusting this result.',
    );
    expect(
      live,
      equals(baseline),
      reason: _diffMessage('Direct hard-delete sites', live, baseline),
    );
  });

  test('cascade-only indirect hard-delete sites exactly match checked-in '
      'baseline', () {
    final liveDirect = scanDirectHardDeleteSites();
    final liveEdges = scanFkCascadeEdges();
    final live = computeCascadeOnlySites(liveDirect, liveEdges);
    final baseline = kCascadeOnlyBaseline.toSet();
    expect(
      live,
      equals(baseline),
      reason: _diffMessage('Cascade-only hard-delete sites', live, baseline),
    );
  });

  test('no duplicate entries within either checked-in baseline', () {
    expect(
      kDirectBaseline.length,
      kDirectBaseline.toSet().length,
      reason: 'kDirectBaseline has a duplicate (function, table) entry',
    );
    expect(
      kCascadeOnlyBaseline.length,
      kCascadeOnlyBaseline.toSet().length,
      reason: 'kCascadeOnlyBaseline has a duplicate (function, table) entry',
    );
    expect(
      kFkEdgeBaseline.length,
      kFkEdgeBaseline.toSet().length,
      reason: 'kFkEdgeBaseline has a duplicate (parent, child) entry',
    );
    // No entry should appear in both DIRECT and CASCADE-ONLY for the same
    // (file, function, table) — CASCADE-ONLY is defined to exclude those.
    final overlap = kDirectBaseline.toSet().intersection(
      kCascadeOnlyBaseline.toSet(),
    );
    expect(
      overlap,
      isEmpty,
      reason:
          'These entries appear in both kDirectBaseline and '
          'kCascadeOnlyBaseline; cascade-only entries must exclude '
          'anything already covered by a direct entry: $overlap',
    );
  });
}
