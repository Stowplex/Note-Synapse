import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'database_service.dart';
import 'logger_service.dart';

/// Recovery-time, per-table merge logic used by `recovery_screen.dart`'s
/// backup-import flow (`RecoveryScreen._processBackupFile`).
///
/// Extracted into its own class, separate from `RecoveryScreen`'s
/// `State`, specifically so this logic can be exercised by dedicated,
/// isolated tests (M1.6 — design doc § M1 status, "recovery_screen.dart
/// consistency pass": "a rarely-exercised, high-stakes path (it runs when
/// the app failed to boot normally) warranting isolated testing, not
/// reliance on M1.3/M1.4's own test coverage") independent of the Flutter
/// widget/State machinery (file pickers, `BuildContext`, l10n, platform
/// channels) the rest of `RecoveryScreen` depends on. Before this
/// extraction there was no way to unit-test this logic at all — every
/// method here used to be a private method on `_RecoveryScreenState`, and
/// Dart's library-scoped privacy meant no test file could reach it without
/// driving the full widget.
///
/// Every method here takes two already-open sqflite `Database` handles —
/// `stagingDb` (a copy of the CURRENT device's own live database) and
/// `backupDb` (the imported backup, already migrated to the current
/// schema) — and merges `backupDb`'s rows INTO `stagingDb`. Every merge
/// here only ever ADDS or repoints rows in `stagingDb`; none of them ever
/// delete or overwrite content that was only present locally, matching
/// recovery's own purpose as a safety net (never make the current device
/// lose data it already has).
///
/// **Deliberately NOT merged, by design, and not merely omitted:**
///
/// - `multi_function_apps` (existing exclusion, undocumented until M1.6)
/// - `sync_field_state`, `sync_set_state`, `sync_grave`, `sync_touch_log`,
///   `sync_pending_ops`, `sync_state`, `sync_ack_frontier`,
///   `sync_device_labels`, `sync_view_cache`, `sync_blob_refs`,
///   `sync_publish_intent`, `sync_materialize_queue`,
///   `sync_conflict_copies`, `sync_dedup_index`, `sync_dot_redirects` (the
///   fifteen M1.1 CRDT-cloud-sync control-plane tables added in
///   `DatabaseService` — see `_syncControlPlaneTableStatements` there)
///
/// Per CLAUDE.md's standing "update recovery_screen.dart on database
/// changes" instruction, this is an explicit decision, not a silent gap:
/// these are sync *machinery* state — causal dots/frontiers, the outbox,
/// dedup/redirect bookkeeping, GC bookkeeping — not user content, and the
/// merge methods below exist to reconcile *user content* across two
/// divergent copies of the same dataset (`stagingDb`, a copy of this
/// device's own currently-running database, and `backupDb`, the imported
/// backup). Merging rows from two different local sync-machinery states
/// (e.g. two different `sync_pending_ops` outboxes, two different
/// `sync_dot_redirects` tables built against different author identities)
/// would not produce a meaningful combined sync state, the way a plain
/// insert-missing-rows merge does for content tables. `stagingDb` is a
/// copy of this device's own live database, so its sync tables already
/// hold this device's own real, in-progress sync state; leaving them
/// unmerged means recovery keeps this device's own sync identity/outbox
/// and simply does not import the backup's sync bookkeeping. Content rows
/// added by the merges below via direct SQL (bypassing the normal write
/// path, and therefore this device's mutation-capture triggers) are
/// consequently NOT automatically reflected in this device's outbox by
/// recovery itself — reconciling that gap (e.g. a post-recovery re-scan)
/// is left to the sync subsystem's own future milestones, not solved here.
class RecoveryMergeService {
  // M1.10 (design doc § Phased delivery, M1.10; CLAUDE.md's standing
  // "update recovery_screen.dart on database changes" instruction):
  // `notes` gained a `__deleted__` tombstone column and `deleteNote`
  // became soft-delete only. Investigated `mergeNotes`/`mergeSubNotes`/
  // `mergeRelationships`/`mergeNoteTags` (the four merges the design doc
  // calls out, run in exactly this order by
  // `RecoveryScreen._processBackupFile`) against every liveness
  // combination this introduces.
  //
  // `mergeNotes` itself needs no code change -- same reasoning class as
  // `mergeFilters` (M1.7) and `mergeTags`'s same-id case: `id` + an
  // `updatedAt`-recency comparison, and `_filterDataForTable` already
  // passes `__deleted__` through like any other column. `deleteNote`'s
  // tombstone write does not bump `updatedAt` (matching `deleteFilter`'s
  // own precedent), so a note tombstoned in one copy without any further
  // edit compares equal (not newer) against the other copy's last real
  // edit -- the existing recency check resolves a live-vs-tombstoned
  // conflict exactly the way it resolves any other field conflict, no
  // separate liveness branch required.
  //
  // `mergeRelationships` also needs no change to its OWN conflict logic,
  // per M1.8's already-recorded reasoning below (insert-only-if-
  // identity-absent, `__deleted__` passed through unaltered).
  //
  // A real, disclosed residual DOES exist, common to `mergeSubNotes`,
  // `mergeNoteTags`, and (not named by the design doc, but the same
  // shape) `mergeAttachments`: none of the three consults the owning
  // note's liveness in `stagingDb` before inserting a backup row. Before
  // this milestone this was moot -- `deleteNote` real-deleted the `notes`
  // row itself, so `mergeNotes` always unconditionally resurrected any
  // backup note missing from staging (its "insert new" branch has no
  // recency gate), meaning by the time these three ran, a note that
  // reappeared here always did so as a *full* resurrection (note +
  // children together) -- never a "note correctly stays tombstoned, but
  // its children get merged in anyway" split state, since a still-missing
  // note could never satisfy the `notes` row's own `id`/`noteId` foreign
  // key at all. Now that `mergeNotes` can leave an existing note
  // correctly tombstoned (backup not newer) while its physical row still
  // satisfies that same foreign key, `mergeSubNotes`/`mergeNoteTags`/
  // `mergeAttachments` can each merge in a stray child row for a note
  // recovery deliberately kept dead. This is judged low-severity and left
  // unfixed here, not silently missed: every read path a user can
  // actually reach filters notes through `__deleted__ = 0` first (M1.10),
  // so a tombstoned note's resurrected child rows are unreachable in
  // practice, not merely deprioritized -- inert extra rows, not a
  // user-visible correctness or data-loss bug. Recorded here on the same
  // terms M1.9 recorded the `tag_images`/`tag_ai_configs` residual: a
  // real, disclosed, accepted gap for a future milestone (whenever
  // recovery-merge is made note-liveness-cascade-aware end to end, if
  // ever prioritized) to close, not a silently-resolved one.
  //
  // **M1.11 re-audit** (design doc § Phased delivery, M1.11 --
  // `subnotes`/`attachments` gained their own `__deleted__` column,
  // consumed by `updateNote`/`_persistNote`'s rewritten diff logic):
  // re-examined every one of `mergeSubNotes`'/`mergeAttachments`' own
  // (not cross-table) conflict-resolution branches against the new
  // column, since it is exactly the kind of schema change the residual
  // above says would need re-checking. Conclusion: no code change needed
  // in either function, and the residual itself is unchanged (still
  // inert, for the same reason as before -- see above; that reasoning
  // never depended on whether `subnotes`/`attachments` had their own
  // liveness concept, only on `notes`' own). `_filterDataForTable` already
  // passes a row's `__deleted__` value through like any other column for
  // both tables now, exactly like `mergeNotes`/`mergeFilters` already did
  // for their own tables (no separate liveness branch was added to either
  // of *those* either) -- `mergeSubNotes` matches existing rows by its own
  // `id`, so a backup row's `__deleted__` value simply overwrites
  // staging's on the same id when the backup is newer by `createdAt`,
  // never creating a second row for one logical subnote; `mergeAttachments`
  // matches by `(noteId, filePath)` and only ever inserts when that pair
  // is entirely absent from staging (no update branch at all, `M1.8`-era
  // "insert-only-if-identity-absent" pattern, confirmed unchanged here) --
  // so a locally-tombstoned attachment whose `(noteId, filePath)` staging
  // already has a row for is correctly left alone (not resurrected) by an
  // older backup that still shows it live, since the existence check does
  // not distinguish live from tombstoned. Neither table's own id/path
  // identity model was disrupted by gaining a tombstone column, so neither
  // merge needed the kind of fix M1.7 made to `mergeTagWorkflowBindings`.
  Future<void> mergeNotes(Database stagingDb, Database backupDb) async {
    // Get all notes from backup
    final backupNotes = await backupDb.query('notes');

    for (final note in backupNotes) {
      // Check if note exists in staging
      final existingNotes = await stagingDb.query(
        'notes',
        where: 'id = ?',
        whereArgs: [note['id']],
      );

      if (existingNotes.isNotEmpty) {
        // Check if backup note is newer
        final existingNote = existingNotes.first;
        final existingUpdatedAt = existingNote['updatedAt'] as int;
        final backupUpdatedAt = note['updatedAt'] as int;

        if (backupUpdatedAt > existingUpdatedAt) {
          // Replace with backup note - filter to only existing columns
          final filteredData = await _filterDataForTable(
            stagingDb,
            'notes',
            note,
          );
          await stagingDb.update(
            'notes',
            filteredData,
            where: 'id = ?',
            whereArgs: [note['id']],
          );
        }
      } else {
        // Insert new note - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'notes',
          note,
        );
        await stagingDb.insert('notes', filteredData);
      }
    }
  }

  Future<void> mergeNoteAnnotations(
    Database stagingDb,
    Database backupDb,
  ) async {
    // note_annotations may not exist in older backups — skip gracefully
    final tables = await backupDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='note_annotations'",
    );
    if (tables.isEmpty) return;

    final backupAnnotations = await backupDb.query('note_annotations');

    for (final ann in backupAnnotations) {
      final id = ann['id'] as String;
      final existing = await stagingDb.query(
        'note_annotations',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );

      if (existing.isEmpty) {
        // Not in staging → insert, filtering to known columns for safety
        final filteredData = await _filterDataForTable(
          stagingDb,
          'note_annotations',
          ann,
        );
        await stagingDb.insert('note_annotations', filteredData);
      }
      // Same UUID found → skip (immutable record, idempotent)
    }
  }

  // M1.7 (design doc § Phased delivery, M1.7): `tag_workflow_bindings`
  // gained a `__deleted__` tombstone column and `deleteWorkflowBinding`
  // became soft-delete only. Before this milestone, an unconditional
  // `INSERT OR REPLACE` (matched by `pattern`, the primary key) was a safe
  // "backup's copy of this pattern's config wins" merge, since a row could
  // only ever be present or absent — there was no liveness dimension for a
  // blind overwrite to get wrong. That stopped being true once `__deleted__`
  // exists: `_filterDataForTable` passes it through like any other column
  // (same mechanism `mergeFilters`/`mergeUserApps` rely on), so the old
  // unconditional REPLACE would silently resurrect a binding staging
  // deliberately removed (backup's copy still live) or tombstone one
  // staging still has live and possibly edited since (backup's copy
  // already deleted) — exactly the kind of "overwrite content only present
  // locally" this class's own doc comment says these merges must never do.
  //
  // Fixed the same way `mergeTags` resolves its own same-id case (case 3
  // in its doc comment): this table has no `updatedAt`/HLC field to decide
  // which side is newer, so the conservative choice is to leave staging's
  // own row (in whatever liveness state) completely untouched whenever a
  // row already exists under the same pattern, and only ever insert the
  // backup's row when no row for that pattern exists in staging at all —
  // preserving the backup row's own `__deleted__` state as-is via the
  // usual `_filterDataForTable` pass-through.
  Future<void> mergeTagWorkflowBindings(
    Database stagingDb,
    Database backupDb,
  ) async {
    // tag_workflow_bindings may not exist in older backups — skip gracefully
    final tables = await backupDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='tag_workflow_bindings'",
    );
    if (tables.isEmpty) return;

    final backupBindings = await backupDb.query('tag_workflow_bindings');

    for (final binding in backupBindings) {
      final pattern = binding['pattern'] as String;
      final existing = await stagingDb.query(
        'tag_workflow_bindings',
        where: 'pattern = ?',
        whereArgs: [pattern],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        // Same identity already present in staging — keep staging's row,
        // see the doc comment above.
        continue;
      }

      final filteredData = await _filterDataForTable(
        stagingDb,
        'tag_workflow_bindings',
        binding,
      );
      await stagingDb.insert('tag_workflow_bindings', filteredData);
    }
  }

  // M1.10: can merge in a subnote for a note `mergeNotes` correctly left
  // tombstoned in staging -- a disclosed, accepted residual, not a fix
  // made here. See the doc comment above `mergeNotes` for the full
  // investigation.
  //
  // (Note: `mergeRelationships`, below, has the identical note-liveness
  // blind spot in principle -- it can insert a fresh relationship
  // involving a note `mergeNotes` correctly left tombstoned -- but
  // `relationships` already carries its own `__deleted__` tombstone
  // (M1.8) and every relationship read path already filters on it, so
  // this is strictly less severe than the subnotes/note_tags/attachments
  // case: the merged-in row is not just unreachable through a *different*
  // table's liveness, it can be tombstoned in its own right by a future
  // `deleteRelationshipsForNote` re-run, which subnotes/note_tags/
  // attachments have no equivalent of yet. Not treated as a new residual
  // requiring its own fix.)
  Future<void> mergeSubNotes(Database stagingDb, Database backupDb) async {
    final backupSubNotes = await backupDb.query('subnotes');

    for (final subNote in backupSubNotes) {
      // Check if subnote exists in staging
      final existingSubNotes = await stagingDb.query(
        'subnotes',
        where: 'id = ? AND noteId = ?',
        whereArgs: [subNote['id'], subNote['noteId']],
      );

      if (existingSubNotes.isNotEmpty) {
        // Check if backup subnote is newer
        final existingSubNote = existingSubNotes.first;
        final existingCreatedAt = existingSubNote['createdAt'] as int;
        final backupCreatedAt = subNote['createdAt'] as int;

        if (backupCreatedAt > existingCreatedAt) {
          // Replace with backup subnote - filter to only existing columns
          final filteredData = await _filterDataForTable(
            stagingDb,
            'subnotes',
            subNote,
          );
          await stagingDb.update(
            'subnotes',
            filteredData,
            where: 'id = ? AND noteId = ?',
            whereArgs: [subNote['id'], subNote['noteId']],
          );
        }
      } else {
        // Insert new subnote - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'subnotes',
          subNote,
        );
        await stagingDb.insert('subnotes', filteredData);
      }
    }
  }

  // M1.3 gave `tags` `__deleted__`/`redirectTarget` columns and dropped its
  // blanket `name` UNIQUE constraint (replaced by the partial index
  // `idx_tags_name_live`, `WHERE __deleted__ = 0 AND redirectTarget IS
  // NULL`) — but, per M1.3's own scoping, its actual code changes were
  // confined to `_getOrCreateTagId`'s two duplicated copies plus
  // `replaceTag`; this recovery-merge method's tag-identity lookup was
  // NOT updated at that time and had been running an unguarded, stale
  // `WHERE name = ?` match ever since M1.3 landed (confirmed against this
  // file's own git history — no commit between M1.3 and this one touched
  // it) — a real, live regression risk for exactly the reason described
  // below, not a hypothetical one.
  //
  // M1.6 (this milestone) is what actually fixes this: switches the
  // lookup to `DatabaseService.findLiveTagByName`'s liveness-aware
  // predicate, and re-audits the method against every TAG-liveness
  // combination reachable at a recovery merge, per the design doc's own
  // "recovery_screen.dart consistency pass" scope. Unlike
  // `_mergeUserApps`/`_insertPinnedRevisionForApp` below, no second gap
  // in the tag-liveness handling ITSELF was found beyond this one
  // lookup-predicate fix — the three cases below are already handled
  // correctly once the predicate is fixed. **This re-audit was scoped to
  // `mergeTags` in isolation; it does not cover a real, separate,
  // pre-existing gap in how this method's `continue` branch (case 1)
  // interacts with `mergeNoteTags`, called later in the same merge
  // sequence — see the comment directly on that `continue` branch below.
  // That gap predates M1 entirely (it exists in the original, unmodified
  // `_mergeNoteTags`/`_mergeTags` pairing) and is left unfixed here,
  // deliberately, as out of this milestone's scope — recorded here so a
  // future reader isn't misled into thinking "re-audited end-to-end"
  // means this interaction was checked.**
  //
  //  1. Backup tag's name matches a LIVE staging tag under a different id
  //     (regardless of whether the backup's own copy is itself live or
  //     tombstoned): `findLiveTagByName` finds the staging row, note_tags
  //     referencing the backup id are repointed to it, and the backup row
  //     itself is never inserted (`continue`) — the live staging tag wins,
  //     no partial-unique-index violation is possible since only one row
  //     is ever live per name. (This is the branch with the separate,
  //     pre-existing `mergeNoteTags` interaction gap noted above.)
  //  2. Backup tag's name matches NO live staging tag (staging has no row
  //     with that name, or only tombstoned ones) and the backup tag's own
  //     id doesn't already exist in staging: the backup row is inserted
  //     as-is, preserving its own live/tombstoned state. If staging
  //     already has a tombstoned row under the same name, the result is
  //     two rows sharing a name — one live (the newly inserted backup row
  //     if it's live) or two tombstoned rows (if the backup row is also
  //     tombstoned) — both satisfy the partial index, which only
  //     constrains live, non-redirecting rows.
  //  3. Backup tag's id already exists in staging (same id, e.g. the exact
  //     same tombstoned tag present in both copies, or a same-id row with
  //     a different liveness state than the backup's copy): nothing is
  //     inserted or updated. `tags` has no `updatedAt`/HLC field to compare
  //     against, so — consistent with how the rest of this file treats
  //     tables lacking one — the conservative choice is to keep staging's
  //     own existing row untouched rather than guess which side is
  //     "newer".
  //
  //  What remains explicitly out of scope, and genuinely unreachable
  //  today, not merely deferred: reconciling two independently
  //  tombstoned/redirecting copies of the SAME name via `redirectTarget`
  //  (a real `tagMerge`/cycle-suppression operation) needs the `tagMerge`
  //  machinery itself, which does not exist anywhere in this application
  //  codebase yet — `redirectTarget` is written by nothing today (see
  //  `_createTagsTable`'s own doc comment in database_service.dart) and
  //  stays that way until a real `tagMerge` operation is implemented.
  //  **M1.9 update**: `deleteTag`/`replaceTag` now tombstone `tags` rows
  //  instead of hard-deleting them, so a genuinely tombstoned `tags` row
  //  is an entirely ordinary result of everyday app usage today, not only
  //  something a raw write (e.g. a test) could produce as this comment
  //  previously (and, as of M1.9, incorrectly) claimed — cases 1-3 above
  //  were already written to handle exactly that (liveness-aware
  //  matching via `findLiveTagByName`, tolerating an arbitrary mix of
  //  live/tombstoned rows on either side), so no logic change was needed
  //  here, only this correction. `redirectTarget` itself, specifically,
  //  is still never written by anything, so there is still no live code
  //  path, recovery included, that could ever encounter a
  //  `redirectTarget`-bearing row to reconcile — that part of this
  //  comment remains accurate and this remains real future work (post
  //  sync-engine, M2+), not something M1.6 or M1.9 could complete.
  Future<void> mergeTags(Database stagingDb, Database backupDb) async {
    final backupTags = await backupDb.query('tags');

    for (final tag in backupTags) {
      final backupTagId = tag['id'] as String;
      final tagName = tag['name'] as String;

      // Match by LIVE name only (DatabaseService.findLiveTagByName's exact
      // predicate: `__deleted__ = 0 AND redirectTarget IS NULL`), not a
      // bare `WHERE name = ?`. Before this schema change, `tags.name` was
      // a table-wide UNIQUE constraint, so at most one row could ever
      // share a name — a bare match was safe. Now that an ordinary
      // deletion leaves a tombstoned row behind with its name intact, a
      // bare name match here would incorrectly treat a live backup tag as
      // "the same tag" as a *tombstoned* staging tag and repoint
      // note_tags onto the tombstoned row's id — exactly the
      // `_getOrCreateTagId` bug this milestone's schema change fixes
      // everywhere else; this call site must not reintroduce it.
      final existingLiveTag = await DatabaseService.findLiveTagByName(
        stagingDb,
        tagName,
      );

      if (existingLiveTag != null) {
        // A live tag with this name already exists in staging.
        final existingTagId = existingLiveTag['id'] as String;
        if (existingTagId != backupTagId) {
          // Update note_tags table to use the existing tag ID
          await stagingDb.update(
            'note_tags',
            {'tagId': existingTagId},
            where: 'tagId = ?',
            whereArgs: [backupTagId],
          );
        }
        // KNOWN, PRE-EXISTING, OUT-OF-SCOPE GAP (confirmed real, not
        // fixed here): the update above only repoints `note_tags` rows
        // ALREADY PRESENT in `stagingDb` at this point in the merge
        // sequence. `mergeNoteTags` (below, called later in
        // `recovery_screen.dart`'s own merge step ordering) subsequently
        // inserts the BACKUP's own `note_tags` rows verbatim, including
        // any row whose `tagId` is this exact `backupTagId` — which was
        // never inserted into `stagingDb.tags` (we `continue`d past that
        // insert precisely because a live staging tag already covers this
        // name). Those newly-inserted rows are left dangling, referencing
        // a `tags.id` that doesn't exist in `stagingDb`. `stagingDb`/
        // `migratedBackupDb` are opened via plain `openDatabase` in
        // `recovery_screen.dart`, not through `DatabaseService`'s own
        // `_onOpen` (which sets `PRAGMA foreign_keys = ON`), so this does
        // not throw — it silently produces an orphaned `note_tags` row.
        // This predates M1 entirely (the same structural gap existed
        // before M1.3's schema change, just without a name-liveness
        // dimension to it) and isn't named by any M1.1-M1.5 deferred-work
        // comment; fixing it would need either reordering the merge steps
        // so `mergeNoteTags` runs first, or `mergeTags` building and
        // returning an id-remap table for `mergeNoteTags` to consult —
        // left for a future, dedicated fix rather than folded into M1.6.
        continue;
      }

      // No live tag with this name in staging. Insert the backup row as
      // its own tag (preserving its own id/__deleted__/redirectTarget) —
      // unless a row with this exact id already exists in staging (e.g.
      // the same tombstoned tag present in both copies), in which case
      // there is nothing to insert.
      final existingById = await stagingDb.query(
        'tags',
        where: 'id = ?',
        whereArgs: [backupTagId],
        limit: 1,
      );
      if (existingById.isEmpty) {
        final filteredData = await _filterDataForTable(stagingDb, 'tags', tag);
        await stagingDb.insert('tags', filteredData);
      }
    }
  }

  Future<void> mergeTagImages(Database stagingDb, Database backupDb) async {
    // Check if tag_images table exists in backup DB
    final tableCheck = await backupDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='tag_images'",
    );
    if (tableCheck.isEmpty) return; // Old backup without tag_images

    final backupTagImages = await backupDb.query('tag_images');

    for (final tagImage in backupTagImages) {
      final tagId = tagImage['tagId'] as String;

      // Only import if the tag exists in staging
      final existingTag = await stagingDb.query(
        'tags',
        where: 'id = ?',
        whereArgs: [tagId],
      );
      if (existingTag.isEmpty) continue;

      // Only import if no image already set for this tag
      final existing = await stagingDb.query(
        'tag_images',
        where: 'tagId = ?',
        whereArgs: [tagId],
      );
      if (existing.isEmpty) {
        await stagingDb.insert('tag_images', {
          'tagId': tagId,
          'imagePath': tagImage['imagePath'] as String,
        });
      }
    }
  }

  // M1.10: same disclosed residual as `mergeSubNotes` above -- can merge
  // in a note_tags row for a note `mergeNotes` correctly left tombstoned.
  // See the doc comment above `mergeNotes` for the full investigation.
  Future<void> mergeNoteTags(Database stagingDb, Database backupDb) async {
    final backupNoteTags = await backupDb.query('note_tags');

    for (final noteTag in backupNoteTags) {
      // Check if note-tag relationship exists in staging
      final existingNoteTags = await stagingDb.query(
        'note_tags',
        where: 'noteId = ? AND tagId = ?',
        whereArgs: [noteTag['noteId'], noteTag['tagId']],
      );

      if (existingNoteTags.isEmpty) {
        // Insert new note-tag relationship - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'note_tags',
          noteTag,
        );
        await stagingDb.insert('note_tags', filteredData);
      }
    }
  }

  // M1.8 (design doc § Phased delivery, M1.8): `relationships` gained a
  // `__deleted__` tombstone column and `deleteRelationship`/
  // `deleteRelationshipBetween`/`deleteRelationshipsForNote` became
  // soft-delete only. Investigated for the same liveness-unaware-merge bug
  // `mergeTagWorkflowBindings` had before its M1.7 fix -- concluded no code
  // change is needed here, for a different reason than `mergeFilters`
  // needed none: this function never did an unconditional `INSERT OR
  // REPLACE`. It already only ever inserts the backup's row when no
  // existing row matches on identity ((fromNoteId, toNoteId, type) --
  // relationships have no natural single-column key), and otherwise leaves
  // staging's row (in whatever liveness state) untouched -- exactly the
  // conservative "skip if identity already present, insert-only otherwise"
  // shape `mergeTagWorkflowBindings` was changed *to*, not the buggy
  // unconditional-overwrite shape it was changed *from*. `_filterDataForTable`
  // already passes `__deleted__` through unaltered on the insert-new
  // branch, same mechanism as every other converted table, so a
  // tombstoned relationship in the backup is correctly inserted as
  // tombstoned (not silently resurrected) when staging has no row for that
  // identity at all.
  Future<void> mergeRelationships(Database stagingDb, Database backupDb) async {
    final backupRelationships = await backupDb.query('relationships');

    for (final relationship in backupRelationships) {
      // Check if relationship exists in staging
      final existingRelationships = await stagingDb.query(
        'relationships',
        where: 'fromNoteId = ? AND toNoteId = ? AND type = ?',
        whereArgs: [
          relationship['fromNoteId'],
          relationship['toNoteId'],
          relationship['type'],
        ],
      );

      if (existingRelationships.isEmpty) {
        // Insert new relationship - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'relationships',
          relationship,
        );
        await stagingDb.insert('relationships', filteredData);
      }
    }
  }

  // M1.7 (design doc § Phased delivery, M1.7): `filters` gained a
  // `__deleted__` tombstone column and `deleteFilter` became soft-delete
  // only. No code change was needed here, unlike `mergeTagWorkflowBindings`
  // below: `_filterDataForTable` already introspects the STAGING db's
  // actual columns and passes every matching backup column through
  // verbatim, so `__deleted__` flows through automatically on both the
  // insert-new and update-existing branches below — same mechanism M1.4's
  // own doc comment on `mergeUserApps` describes. The existing `id`-based
  // identity match and `updatedAt`-recency comparison ("backup newer ->
  // overwrite, else -> leave staging alone") are also both unaffected by
  // liveness the same way `user_apps.uuid` was: `filters.id` continues to
  // mean "the same filter" regardless of `__deleted__` state, and
  // `deleteFilter`'s tombstone write does not bump `updatedAt`, so a
  // filter tombstoned in one copy without any further edit compares equal
  // (not newer) against the other copy's last real edit — the existing
  // recency check already resolves a live-vs-tombstoned conflict the same
  // way it resolves any other field conflict, with no separate liveness
  // branch required.
  Future<void> mergeFilters(Database stagingDb, Database backupDb) async {
    final backupFilters = await backupDb.query('filters');

    for (final filter in backupFilters) {
      final id = filter['id'] as String;
      final backupUpdatedAt = filter['updatedAt'] as int;

      // Check if filter exists in staging by ID
      final existingFilters = await stagingDb.query(
        'filters',
        where: 'id = ?',
        whereArgs: [id],
      );

      if (existingFilters.isNotEmpty) {
        final existingFilter = existingFilters.first;
        final existingUpdatedAt = existingFilter['updatedAt'] as int;

        // If backup is newer, update the existing filter
        if (backupUpdatedAt > existingUpdatedAt) {
          final filteredData = await _filterDataForTable(
            stagingDb,
            'filters',
            filter,
          );
          await stagingDb.update(
            'filters',
            filteredData,
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      } else {
        // Insert new filter
        final filteredData = await _filterDataForTable(
          stagingDb,
          'filters',
          filter,
        );
        await stagingDb.insert('filters', filteredData);
      }
    }
  }

  // M1.4 (design doc § Architecture 10, 10): user_apps/app_revisions/
  // user_app_libraries/user_app_library_dependencies gained `__deleted__`
  // tombstone columns (app_revisions also gained `deletedAt`) and their
  // delete functions became soft-delete-only.
  //
  //  - `_filterDataForTable` (used throughout `mergeUserApps` and
  //    `_copyAppLibrariesAndDependencies`) introspects the STAGING db's
  //    actual columns via `_getTableColumns` and passes every matching
  //    backup column through verbatim — `__deleted__`/`deletedAt` included,
  //    automatically, with no hand-maintained column list to update.
  //    `backupDb` (this function's parameter) has already been migrated to
  //    the current schema before any merge method runs, so both sides
  //    already agree on these columns' shape.
  //  - `_insertPinnedRevisionForApp`'s hand-built `newRevision` map (below)
  //    does not set `__deleted__`/`deletedAt` explicitly, which is correct
  //    as-is: it is creating a brand new LIVE revision (a copy of the
  //    backup's *effective* pinned one — see below), and
  //    `app_revisions.__deleted__ INTEGER NOT NULL DEFAULT 0` /
  //    `deletedAt INTEGER` (nullable) already default to exactly that
  //    "live, never deleted" state for any column omitted from an INSERT.
  //  - The UUID-based identity match in `mergeUserApps` below is
  //    unaffected by this schema change the way M1.3's tag NAME-based match
  //    was (`mergeTags`, which had to switch to `findLiveTagByName` because
  //    `tags.name` stopped being a reliable identity key once a tombstoned
  //    row could keep it) — a `user_apps.uuid` value continues to mean
  //    "the same app" regardless of its `__deleted__` state, so no
  //    matching-predicate change is needed here.
  //
  // M1.6 gave this family's UUID-clash path (`_insertPinnedRevisionForApp`)
  // its own liveness-AWARE behavior, closing the two gaps M1.4's own doc
  // comment named as future M1.6 work:
  //
  //  1. A tombstoned backup app (raw `user_apps.__deleted__ = 1` in
  //     `backupDb`) is now skipped entirely — no new revision is inserted
  //     and staging's own copy of the app (if any) is left completely
  //     untouched, matching every other merge method's "only ever add,
  //     never remove or resurrect" philosophy.
  //  2. The revision actually copied over is now the backup's EFFECTIVE
  //     current revision — computed via
  //     `DatabaseService.computeAppRevisionVisibility` run against
  //     `backupDb` itself (passed as the `executor`, so it never touches
  //     this device's own live database) — rather than trusting the raw
  //     `selectedRevisionId` column literally. In ordinary single-device
  //     history `selectedRevisionId` always already points at a live
  //     revision (`deleteAppRevision`'s own guard keeps it that way), so
  //     this is a no-op change for the common case; it only matters for a
  //     backup whose own `selectedRevisionId` ended up pointing at a
  //     revision that is itself raw-tombstoned (reachable only via a prior
  //     cross-device merge, per `computeAppRevisionVisibility`'s own doc
  //     comment) — in that case the backup's actually-effective (possibly
  //     fallback-elected) revision is copied instead of a literally-dead
  //     row that would otherwise silently import stale/wrong content.
  Future<void> mergeUserApps(Database stagingDb, Database backupDb) async {
    final backupApps = await backupDb.query('user_apps');

    for (final app in backupApps) {
      // Check if app exists in staging by UUID
      final existingApps = await stagingDb.query(
        'user_apps',
        where: 'uuid = ?',
        whereArgs: [app['uuid']],
      );

      if (existingApps.isNotEmpty) {
        // UUID clash - insert PINNED revision as latest revision
        await _insertPinnedRevisionForApp(stagingDb, backupDb, app);
      } else {
        // Insert app - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'user_apps',
          app,
        );
        await stagingDb.insert('user_apps', filteredData);

        // Insert associated revisions
        final revisions = await backupDb.query(
          'app_revisions',
          where: 'appId = ?',
          whereArgs: [app['id']],
        );

        for (final revision in revisions) {
          // Insert revision - filter to only existing columns
          final filteredRevision = await _filterDataForTable(
            stagingDb,
            'app_revisions',
            revision,
          );
          await stagingDb.insert('app_revisions', filteredRevision);
        }

        // Insert associated libraries and dependencies
        await _copyAppLibrariesAndDependencies(
          stagingDb,
          backupDb,
          app['uuid'] as String,
        );
      }
    }
  }

  /// M1.6: skips the backup app entirely if it is raw-tombstoned in
  /// `backupDb`, and otherwise copies the backup's EFFECTIVE current
  /// revision (which may differ from the raw `selectedRevisionId` column —
  /// see the doc comment above `mergeUserApps`), not necessarily the
  /// literal pinned id.
  Future<void> _insertPinnedRevisionForApp(
    Database stagingDb,
    Database backupDb,
    Map<String, dynamic> app,
  ) async {
    final backupAppId = app['id'] as String;

    // Resolve the backup's effective revision visibility directly against
    // backupDb (the `executor` parameter means this never touches this
    // device's own live database). Returns `({}, null)` if the app itself
    // is tombstoned or has no revisions at all in the backup — either way
    // there is nothing meaningful to merge, so skip. Recovery only ever
    // adds content; it never propagates a deletion, so staging's own copy
    // of this app (if any) is left exactly as it already is.
    final visibility = await DatabaseService().computeAppRevisionVisibility(
      backupAppId,
      executor: backupDb,
    );
    if (visibility.visibleRevisionIds.isEmpty) {
      LoggerService.info(
        'Backup app ${app['uuid']} is tombstoned or has no revisions in '
        'the backup; skipping pinned-revision merge',
      );
      return;
    }

    // Prefer the raw selectedRevisionId if it is itself effectively
    // visible (the common case for an ordinary single-device backup).
    // Otherwise use the elected zero-live-revisions fallback if there is
    // one, or — if multiple live revisions exist but selectedRevisionId
    // doesn't point at any of them — the latest live revision by
    // revisionNumber, mirroring DatabaseService.getLatestAppRevision's own
    // tie-break.
    final storedSelectedRevisionId = app['selectedRevisionId'] as String?;
    String backupPinnedRevisionId;
    if (storedSelectedRevisionId != null &&
        visibility.visibleRevisionIds.contains(storedSelectedRevisionId)) {
      backupPinnedRevisionId = storedSelectedRevisionId;
    } else if (visibility.fallbackRevisionId != null) {
      backupPinnedRevisionId = visibility.fallbackRevisionId!;
    } else {
      final liveRevisions = await backupDb.query(
        'app_revisions',
        where: 'appId = ? AND __deleted__ = 0',
        whereArgs: [backupAppId],
        orderBy: 'revisionNumber DESC',
        limit: 1,
      );
      if (liveRevisions.isEmpty) {
        // Shouldn't happen given visibleRevisionIds was non-empty above,
        // but guard defensively rather than let recovery crash.
        LoggerService.warning(
          'App ${app['uuid']} reported visible revisions but none could be '
          'resolved concretely; skipping pinned-revision merge',
        );
        return;
      }
      backupPinnedRevisionId = liveRevisions.first['id'] as String;
    }

    LoggerService.info(
      'Inserting PINNED revision for app with UUID: ${app['uuid']} '
      '(effective revision $backupPinnedRevisionId)',
    );

    // 1. Get the effective pinned revision's row from the backup database
    final backupPinnedRevision = await backupDb.query(
      'app_revisions',
      where: 'id = ?',
      whereArgs: [backupPinnedRevisionId],
    );

    if (backupPinnedRevision.isEmpty) {
      LoggerService.warning(
        'Pinned revision $backupPinnedRevisionId not found in backup database, skipping',
      );
      return;
    }

    final pinnedRevisionData = backupPinnedRevision.first;

    // 2. Get the latest revision number from the staging database for the existing app
    final existingApp = await stagingDb
        .query('user_apps', where: 'uuid = ?', whereArgs: [app['uuid']])
        .then((apps) => apps.first);

    final existingAppId = existingApp['id'] as String;

    final latestRevisions = await stagingDb.query(
      'app_revisions',
      where: 'appId = ?',
      whereArgs: [existingAppId],
      orderBy: 'revisionNumber DESC',
      limit: 1,
    );

    final nextRevisionNumber = latestRevisions.isEmpty
        ? 1
        : (latestRevisions.first['revisionNumber'] as int) + 1;

    // 3. Create a new revision in staging database that copies the pinned revision from backup
    final newRevisionId = '${existingAppId}_rev_$nextRevisionNumber';
    final now = DateTime.now().millisecondsSinceEpoch;

    final newRevision = {
      'id': newRevisionId,
      'appId': existingAppId, // Use the existing app's ID in staging
      'revisionNumber': nextRevisionNumber,
      'revisionTimestamp': now,
      'userPrompt': pinnedRevisionData['userPrompt'],
      'aiResponse': pinnedRevisionData['aiResponse'],
      'appCode': pinnedRevisionData['appCode'],
      'attachmentPaths': pinnedRevisionData['attachmentPaths'],
    };

    // Insert the new revision - filter to only existing columns
    final filteredRevision = await _filterDataForTable(
      stagingDb,
      'app_revisions',
      newRevision,
    );
    await stagingDb.insert('app_revisions', filteredRevision);

    // Update the existing app to set the selectedRevisionId to the new revision
    await stagingDb.update(
      'user_apps',
      {'selectedRevisionId': newRevisionId},
      where: 'uuid = ?',
      whereArgs: [app['uuid']],
    );

    LoggerService.info(
      'Created new revision $newRevisionId (revision $nextRevisionNumber) from pinned revision $backupPinnedRevisionId for app UUID: ${app['uuid']}',
    );
  }

  Future<void> _copyAppLibrariesAndDependencies(
    Database stagingDb,
    Database backupDb,
    String appUuid,
  ) async {
    // Get libraries for this app
    final libraries = await backupDb.query(
      'user_app_libraries',
      where: 'app_uuid = ?',
      whereArgs: [appUuid],
    );

    for (final library in libraries) {
      // Insert library - filter to only existing columns
      final filteredLibrary = await _filterDataForTable(
        stagingDb,
        'user_app_libraries',
        library,
      );
      final libraryId = await stagingDb.insert(
        'user_app_libraries',
        filteredLibrary,
      );

      // Get dependencies for this library using chunked reading to avoid
      // cursor window issues.
      // M1.12: `__deleted__` must be selected explicitly here, the same
      // fix `mergeConversationMessages` needed (see its own doc comment) --
      // this query alone hand-picks its column list for chunked-BLOB-read
      // purposes, unlike the `library` row fetch above it (a plain
      // `backupDb.query('user_app_libraries', ...)`, which picks up
      // `__deleted__` for free). Before this fix, a tombstoned dependency
      // in the backup would import with `__deleted__` silently defaulting
      // back to 0 (live) -- predates M1.12 (the column has existed on this
      // table since M1.4), found while investigating the identical pattern
      // in `mergeConversationMessages` this milestone.
      final dependencies = await backupDb.rawQuery(
        '''
        SELECT id, original_url, local_path, library_id, __deleted__,
               CASE
                 WHEN length(bytes) > 0 THEN 'BLOB_DATA'
                 ELSE NULL
               END as has_blob
        FROM user_app_library_dependencies
        WHERE library_id = ?
      ''',
        [library['id']],
      );

      for (final dependency in dependencies) {
        final dependencyData = Map<String, dynamic>.from(dependency);
        dependencyData['library_id'] = libraryId;

        // Remove the temporary has_blob column before inserting
        dependencyData.remove('has_blob');

        // Read BLOB data in chunks to avoid cursor window issues
        if (dependency['has_blob'] != null) {
          try {
            final blobData = await _readBlobInChunks(
              backupDb,
              dependency['id'] as int,
            );
            dependencyData['bytes'] = Uint8List.fromList(blobData);
          } catch (e) {
            LoggerService.error(
              'Failed to read BLOB data for dependency ${dependency['id']}: $e',
              error: e,
            );
            dependencyData['bytes'] = Uint8List(0);
          }
        } else {
          dependencyData['bytes'] = Uint8List(0);
        }

        // Insert dependency - filter to only existing columns
        final filteredDependency = await _filterDataForTable(
          stagingDb,
          'user_app_library_dependencies',
          dependencyData,
        );
        await stagingDb.insert(
          'user_app_library_dependencies',
          filteredDependency,
        );
      }
    }
  }

  // M1.10: same disclosed residual as `mergeSubNotes`/`mergeNoteTags`
  // above (not itself one of the four functions the design doc names, but
  // the identical shape) -- can merge in an attachment for a note
  // `mergeNotes` correctly left tombstoned. See the doc comment above
  // `mergeNotes` for the full investigation.
  Future<void> mergeAttachments(Database stagingDb, Database backupDb) async {
    final backupAttachments = await backupDb.query('attachments');

    for (final attachment in backupAttachments) {
      final filePath = attachment['filePath'] as String;
      final isRelativePath = (attachment['isRelativePath'] as int) == 1;

      // Convert file path if needed
      String finalFilePath = filePath;
      if (isRelativePath) {
        // Path is already relative, keep as is
        finalFilePath = filePath;
      } else {
        // Convert absolute path to relative path
        final fileName = filePath.split('/').last;
        finalFilePath = 'attachments/$fileName';
      }

      // Check if attachment exists in staging (unique on noteId, filePath)
      final existingAttachments = await stagingDb.query(
        'attachments',
        where: 'noteId = ? AND filePath = ?',
        whereArgs: [attachment['noteId'], finalFilePath],
      );

      if (existingAttachments.isEmpty) {
        // Create new attachment record with proper path
        final newAttachment = Map<String, dynamic>.from(attachment);
        newAttachment['filePath'] = finalFilePath;
        newAttachment['isRelativePath'] = 1; // Always store as relative path

        // Insert attachment - filter to only existing columns
        final filteredAttachment = await _filterDataForTable(
          stagingDb,
          'attachments',
          newAttachment,
        );
        await stagingDb.insert(
          'attachments',
          filteredAttachment,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
  }

  /// Gets the list of column names that exist in the target table
  Future<List<String>> _getTableColumns(Database db, String tableName) async {
    final tableInfo = await db.rawQuery('PRAGMA table_info($tableName)');
    return tableInfo.map((col) => col['name'] as String).toList();
  }

  /// Filters data to only include columns that exist in the target table
  Future<Map<String, dynamic>> _filterDataForTable(
    Database db,
    String tableName,
    Map<String, dynamic> data,
  ) async {
    final validColumns = await _getTableColumns(db, tableName);
    final filtered = <String, dynamic>{};

    for (final entry in data.entries) {
      if (validColumns.contains(entry.key)) {
        filtered[entry.key] = entry.value;
      }
    }

    return filtered;
  }

  // M1.12 (design doc § Phased delivery, M1.12): `conversations` gained a
  // `__deleted__` tombstone column. Same investigation, same conclusion as
  // `mergeConversationAttachments`'s own M1.8 doc comment: this function
  // already only inserts the backup's row when no row with the same `id`
  // exists in staging at all (id is this table's actual primary key), and
  // otherwise leaves staging's row untouched regardless of liveness — the
  // safe shape. It fetches full rows via `backupDb.query('conversations')`
  // (not a hand-picked column list), so `__deleted__` flows through
  // `_filterDataForTable` on the insert-new branch automatically, no code
  // change needed. (Contrast `mergeConversationMessages` below, which DID
  // need a fix — see its own doc comment.)
  Future<void> mergeConversations(Database stagingDb, Database backupDb) async {
    final backupConversations = await backupDb.query('conversations');

    for (final conversation in backupConversations) {
      // Check if conversation exists in staging by id
      final existingConversations = await stagingDb.query(
        'conversations',
        where: 'id = ?',
        whereArgs: [conversation['id']],
      );

      if (existingConversations.isEmpty) {
        // Insert new conversation - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'conversations',
          conversation,
        );
        await stagingDb.insert('conversations', filteredData);
      }
    }
  }

  Future<void> mergeConversationMessages(
    Database stagingDb,
    Database backupDb,
  ) async {
    // Process messages in batches to avoid CursorWindow size limits
    int offset = 0;
    const int limit = 50;
    bool hasMore = true;

    while (hasMore) {
      // Select all columns except 'content' and 'metadata', which can be huge.
      // M1.12: `__deleted__` must be selected explicitly here, unlike every
      // other merge* function in this file (which all fetch full rows via
      // plain `db.query('table')` and so pick up `__deleted__` for free) --
      // this function alone hand-picks its column list for CursorWindow
      // safety, so a real, found-during-development bug: before this fix,
      // a tombstoned message in the backup would import with `__deleted__`
      // silently defaulting back to 0 (live), since the raw column was
      // never read at all, not merely mis-merged the way M1.7's
      // `mergeTagWorkflowBindings` bug was.
      final batch = await backupDb.rawQuery(
        '''
        SELECT id, type, timestamp, modelUsed, __deleted__, length(content) as content_length, length(metadata) as metadata_length
        FROM conversation_messages
        LIMIT ? OFFSET ?
        ''',
        [limit, offset],
      );

      if (batch.isEmpty) {
        hasMore = false;
        break;
      }

      for (final row in batch) {
        final messageId = row['id'] as String;
        final contentLength = (row['content_length'] as int?) ?? 0;
        final metadataLength = (row['metadata_length'] as int?) ?? 0;

        // Check if message exists in staging by id
        final existingMessages = await stagingDb.query(
          'conversation_messages',
          where: 'id = ?',
          whereArgs: [messageId],
        );

        if (existingMessages.isEmpty) {
          String content = '';
          String?
          metadata; // metadata is nullable in schema, treating as String?

          // --- Handle Content ---
          // If content is small (< 1MB), read it normally
          // Otherwise read in chunks
          if (contentLength < 1024 * 1024) {
            final contentResult = await backupDb.query(
              'conversation_messages',
              columns: ['content'],
              where: 'id = ?',
              whereArgs: [messageId],
            );
            if (contentResult.isNotEmpty) {
              content = contentResult.first['content'] as String;
            }
          } else {
            // Large content, read in chunks
            content = await _readStringInChunks(
              backupDb,
              messageId,
              'content',
              contentLength,
            );
          }

          // --- Handle Metadata ---
          // Metadata can be null or empty string in DB, usually stored as text
          if (metadataLength > 0) {
            if (metadataLength < 1024 * 1024) {
              final metaResult = await backupDb.query(
                'conversation_messages',
                columns: ['metadata'],
                where: 'id = ?',
                whereArgs: [messageId],
              );
              if (metaResult.isNotEmpty) {
                metadata = metaResult.first['metadata'] as String?;
              }
            } else {
              // Large metadata, read in chunks
              metadata = await _readStringInChunks(
                backupDb,
                messageId,
                'metadata',
                metadataLength,
              );
            }
          }

          // Construct full message map
          final message = Map<String, dynamic>.from(row);
          message['content'] = content;
          message['metadata'] = metadata;
          message.remove('content_length'); // Remove the helper column
          message.remove('metadata_length'); // Remove the helper column

          // Insert new message - filter to only existing columns
          final filteredData = await _filterDataForTable(
            stagingDb,
            'conversation_messages',
            message,
          );
          await stagingDb.insert('conversation_messages', filteredData);
        }
      }

      offset += limit;
      // Yield to event loop to prevent UI freeze during large imports
      await Future.delayed(Duration.zero);
    }
  }

  // M1.8 (design doc § Phased delivery, M1.8): `conversation_attachments`
  // gained a `__deleted__` tombstone column and `deleteConversationAttachment`
  // became soft-delete only (`_deleteMessagesBatch`'s own delete stays real,
  // deferred to M1.12 -- see the doc comment on that call site). Same
  // investigation and same conclusion as `mergeRelationships` above: this
  // function already only inserts the backup's row when no row with the
  // same `id` exists in staging at all, and otherwise leaves staging's row
  // untouched regardless of liveness -- the safe shape, not the buggy
  // unconditional-overwrite one. `id` is this table's actual primary key
  // (unlike `relationships`, which has no single natural key), so the
  // match is exact identity, not a content-tuple heuristic. `__deleted__`
  // flows through via `_filterDataForTable` on the insert-new branch same
  // as everywhere else.
  Future<void> mergeConversationAttachments(
    Database stagingDb,
    Database backupDb,
  ) async {
    final backupAttachments = await backupDb.query('conversation_attachments');

    for (final attachment in backupAttachments) {
      final filePath = attachment['filePath'] as String;

      String finalFilePath = filePath;
      if (filePath.startsWith('/')) {
        if (filePath.contains('/attachments/')) {
          final parts = filePath.split('/attachments/');
          if (parts.length > 1) {
            finalFilePath = 'attachments/${parts[1]}';
          } else {
            final fileName = attachment['fileName'] as String;
            finalFilePath = 'attachments/$fileName';
          }
        } else {
          final fileName = attachment['fileName'] as String;
          final messageId = attachment['messageId'] as String;
          finalFilePath = 'attachments/${messageId}_$fileName';
        }
      }

      // Check if attachment exists in staging by id
      final existingAttachments = await stagingDb.query(
        'conversation_attachments',
        where: 'id = ?',
        whereArgs: [attachment['id']],
      );

      if (existingAttachments.isEmpty) {
        final newAttachment = Map<String, dynamic>.from(attachment);
        newAttachment['filePath'] = finalFilePath;
        newAttachment['isRelativePath'] = 1;

        // Insert new attachment - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'conversation_attachments',
          newAttachment,
        );
        await stagingDb.insert('conversation_attachments', filteredData);
      }
    }
  }

  Future<void> mergeConversationMessageMappings(
    Database stagingDb,
    Database backupDb,
  ) async {
    final backupMappings = await backupDb.query('conversation_message_mapping');

    for (final mapping in backupMappings) {
      // Check if mapping exists in staging (unique by conversationId, messageId)
      final existingMappings = await stagingDb.query(
        'conversation_message_mapping',
        where: 'conversationId = ? AND messageId = ?',
        whereArgs: [mapping['conversationId'], mapping['messageId']],
      );

      if (existingMappings.isEmpty) {
        // Insert new mapping - filter to only existing columns, remove id if auto-increment
        var filteredData = await _filterDataForTable(
          stagingDb,
          'conversation_message_mapping',
          mapping,
        );
        // Remove id if it's auto-increment to let SQLite generate a new one
        if (filteredData.containsKey('id') && mapping['id'] is int) {
          filteredData.remove('id');
        }
        await stagingDb.insert('conversation_message_mapping', filteredData);
      }
    }
  }

  Future<void> mergeMessageParents(
    Database stagingDb,
    Database backupDb,
  ) async {
    final backupParents = await backupDb.query('message_parents');

    for (final parent in backupParents) {
      // Check if parent relationship exists in staging (unique by messageId, parentMessageId)
      final existingParents = await stagingDb.query(
        'message_parents',
        where: 'messageId = ? AND parentMessageId = ?',
        whereArgs: [parent['messageId'], parent['parentMessageId']],
      );

      if (existingParents.isEmpty) {
        // Insert new parent relationship - filter to only existing columns
        final filteredData = await _filterDataForTable(
          stagingDb,
          'message_parents',
          parent,
        );
        await stagingDb.insert('message_parents', filteredData);
      }
    }
  }

  Future<void> mergeConversationTagMappings(
    Database stagingDb,
    Database backupDb,
  ) async {
    final backupMappings = await backupDb.query('conversation_tags');

    for (final mapping in backupMappings) {
      final existingMappings = await stagingDb.query(
        'conversation_tags',
        where: 'conversationId = ? AND tagId = ?',
        whereArgs: [mapping['conversationId'], mapping['tagId']],
        limit: 1,
      );

      if (existingMappings.isEmpty) {
        final filteredData = await _filterDataForTable(
          stagingDb,
          'conversation_tags',
          mapping,
        );
        await stagingDb.insert('conversation_tags', filteredData);
      }
    }
  }

  Future<void> mergeConversationNoteMappings(
    Database stagingDb,
    Database backupDb,
  ) async {
    final backupMappings = await backupDb.query('conversation_note_mapping');

    for (final mapping in backupMappings) {
      // Check if mapping exists in staging (unique by conversationId, noteId)
      final existingMappings = await stagingDb.query(
        'conversation_note_mapping',
        where: 'conversationId = ? AND noteId = ?',
        whereArgs: [mapping['conversationId'], mapping['noteId']],
      );

      if (existingMappings.isEmpty) {
        // Insert new mapping - filter to only existing columns, remove id if auto-increment
        var filteredData = await _filterDataForTable(
          stagingDb,
          'conversation_note_mapping',
          mapping,
        );
        // Remove id if it's auto-increment to let SQLite generate a new one
        if (filteredData.containsKey('id') && mapping['id'] is int) {
          filteredData.remove('id');
        }
        await stagingDb.insert('conversation_note_mapping', filteredData);
      }
    }
  }

  // Helper method to read BLOB data in chunks to avoid cursor window issues
  Future<List<int>> _readBlobInChunks(Database db, int dependencyId) async {
    const int chunkSize = 1024 * 1024; // 1MB chunks
    final List<int> allBytes = [];

    try {
      // Get the total size of the BLOB
      final sizeResult = await db.rawQuery(
        '''
        SELECT length(bytes) as blob_size
        FROM user_app_library_dependencies
        WHERE id = ?
      ''',
        [dependencyId],
      );

      if (sizeResult.isEmpty) {
        return <int>[];
      }

      final int totalSize = sizeResult.first['blob_size'] as int;

      // Read BLOB in chunks
      for (int offset = 0; offset < totalSize; offset += chunkSize) {
        final int currentChunkSize = (offset + chunkSize > totalSize)
            ? totalSize - offset
            : chunkSize;

        final chunkResult = await db.rawQuery(
          '''
          SELECT substr(bytes, ?, ?) as chunk
          FROM user_app_library_dependencies
          WHERE id = ?
        ''',
          [offset + 1, currentChunkSize, dependencyId],
        );

        if (chunkResult.isNotEmpty && chunkResult.first['chunk'] != null) {
          final chunk = chunkResult.first['chunk'] as Uint8List;
          allBytes.addAll(chunk);
        }
      }

      return allBytes;
    } catch (e) {
      LoggerService.error('Error reading BLOB in chunks: $e', error: e);
      return <int>[];
    }
  }

  // Helper method to read String data in chunks to avoid cursor window issues
  Future<String> _readStringInChunks(
    Database db,
    String messageId,
    String columnName,
    int totalSize,
  ) async {
    // const int chunkSize = 1024 * 1024; // 1MB chunks (unused)
    final StringBuffer buffer = StringBuffer();

    try {
      // Read String in chunks using substr
      // SQLite substr is 1-based, and operates on characters/codepoints.
      // Note: If the text contains multi-byte characters, 'length' is in characters (usually).
      // However, CursorWindow limit is in BYTES (2MB).
      // So reading 1 million CHARACTERS might exceed 2MB bytes if they are multi-byte.
      // But for safety locally, we can read smaller chunks if needed.
      // 500k chars is safer for UTF-8 (max 4 bytes per char = 2MB).
      const int safeCharChunkSize = 500 * 1024;

      for (int offset = 0; offset < totalSize; offset += safeCharChunkSize) {
        final int currentChunkSize = (offset + safeCharChunkSize > totalSize)
            ? totalSize - offset
            : safeCharChunkSize;

        final chunkResult = await db.rawQuery(
          '''
          SELECT substr($columnName, ?, ?) as chunk
          FROM conversation_messages
          WHERE id = ?
        ''',
          [offset + 1, currentChunkSize, messageId],
        );

        if (chunkResult.isNotEmpty && chunkResult.first['chunk'] != null) {
          final chunk = chunkResult.first['chunk'] as String;
          buffer.write(chunk);
        }
      }

      return buffer.toString();
    } catch (e) {
      LoggerService.error('Error reading String in chunks: $e', error: e);
      return '';
    }
  }
}
