// Announcing what a sync round wrote — the piece that connects the CRDT
// materializer to everything downstream of a write.
//
// **The gap this closes.** `materializer.dart` writes `notes`/`attachments`/
// `tags`/... rows with `txn.insert`/`txn.update`/`txn.delete` directly, on
// purpose (§ 11.6(c): `DatabaseService.updateNote`/`_persistNote` diff-and-
// reinsert `subnotes`/`note_tags` on every call, which a single-field CRDT
// materialization must not trigger). That decision is sound and is preserved
// — but it means neither of `DatabaseService`'s write-path hooks fires
// (`onNoteContentChanged`/`onNoteDeleted`, which `NoteIndexService` installs),
// and nothing published a [DataChangeEvent] either. So content that arrived
// by sync was never chunked, never OCR'd, never embedded, and `AppProvider`'s
// note/tag/filter caches stayed stale until the next app start: a note edited
// on device A and pulled on device B simply did not appear to change.
//
// Publishing a [DataChangeEvent] — rather than calling the indexer directly —
// is what makes one fix cover both halves: `AppProvider` and
// `NoteIndexService` are both already subscribers, and any future subscriber
// gets sync coverage for free.
//
// **Two rules this file exists to enforce.**
//
// 1. **Announce only what committed.** Collection happens inside the
//    materialization transaction; publication happens after it. A
//    [SyncChangeCollector] is built inside a transaction body and RETURNED
//    from it, so a rolled-back transaction's collector is discarded with the
//    writes it described — nothing announces a write that was undone. And
//    publishing from inside the transaction would let a listener re-enter the
//    database while the write lock is held.
// 2. **Announce nothing for a no-op.** `CausalEngine.apply` returns `null`
//    for an idempotent re-apply and `winnerChanged: false` when the resolved
//    winner is unchanged; both already exit `SyncMaterializer` before any row
//    is touched, so nothing is recorded and [SyncChangePublisher.publish]
//    drops the empty collector without even opening a query.
//
// **Owner resolution is deferred to publish time, deliberately.** A
// `subnotes`/`attachments` field write knows its own row id, not the note
// that owns it, and looking the owner up per operation would add a query to
// the hottest loop of a pull. Every such id is instead batched into one
// `WHERE id IN (...)` per table after the round, which is also correct: this
// engine soft-deletes (`__deleted__ = 1`, `_hardDeleteGuardedTables`) rather
// than removing entity rows, so an owner pointer is still readable after the
// write that tombstoned its row.
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../data_change_notifier.dart';
import '../logger_service.dart';

/// How one table's rows map onto [DataChangeEvent]'s fields.
///
/// The classification deliberately mirrors `DatabaseService`'s raw-SQL change
/// capture (`_capturedTables` / `_captureTriggerStatements`), which answers
/// the identical question for the identical consumers: the note-domain tables
/// are the ones whose writes reach the note list, the note detail and the
/// search index, and every other table's writes reach none of them.
enum SyncChangeScope {
  /// The row's own id IS a note id (`notes`), including a set membership
  /// whose OWNING entity is a note (`note_tags` — its capture scope's
  /// `entityTable` is `notes`).
  note,

  /// The row names its owning note in a `noteId` column (`subnotes`,
  /// `attachments`). Resolved in one batched lookup at publish time.
  ownedByNote,

  /// The row names its owner either directly (`note_id`) or through an
  /// attachment (`attachment_id`) — `note_annotations`, exactly the two-way
  /// resolution the capture trigger's own `annotationNote` performs.
  annotation,

  /// The row names two endpoint notes (`relationships.fromNoteId`/
  /// `toNoteId`). Reported through [DataChangeEvent.relationshipNoteIds],
  /// which is a re-query signal rather than a cache patch.
  relationship,

  /// The tag list changed. Also refreshes every note carrying the tag: a
  /// note's `meta` chunk embeds its tag NAMES (`note_chunker.dart`), so a tag
  /// renamed on another device leaves stale text in this device's index
  /// otherwise — the same reason the capture trigger for `tags` journals
  /// `notesWithTag` alongside its domain marker.
  tags,

  /// The filter list changed.
  filters,

  /// Deliberately note-irrelevant. Nothing in the note list, the note detail
  /// or the search index reads these tables, so a targeted event for them
  /// would be a full `AppProvider` reload and a full index sweep in exchange
  /// for no refreshed pixel. This is a positive determination per table, NOT
  /// the "silence" an unclassified table gets — see [SyncChangeCollector
  /// .recordRow], which degrades an UNKNOWN table to `bulk` precisely because
  /// it cannot make that determination.
  none,
}

/// Every table this sync engine can materialize into
/// (`DatabaseService.syncEntityCaptureScopes`, plus the note-domain tables
/// that are captured locally but not yet synced), classified.
///
/// Asserted complete against `syncEntityCaptureScopes` by
/// `sync_change_publish_test.dart`, so a table added to sync scope without a
/// decision here fails a test rather than silently degrading every sync round
/// to `bulk`.
const Map<String, SyncChangeScope> syncChangeScopeByTable = {
  'notes': SyncChangeScope.note,
  'subnotes': SyncChangeScope.ownedByNote,
  'attachments': SyncChangeScope.ownedByNote,
  // Not in `syncEntityCaptureScopes` today (annotations do not sync yet), and
  // classified anyway: it is a note-domain table whose text feeds the index,
  // so the day it joins sync scope the answer is already the right one rather
  // than a `bulk` storm nobody notices.
  'note_annotations': SyncChangeScope.annotation,
  'relationships': SyncChangeScope.relationship,
  'tags': SyncChangeScope.tags,
  'filters': SyncChangeScope.filters,
  // ── Deliberately note-irrelevant ──────────────────────────────────────
  'tag_workflow_bindings': SyncChangeScope.none,
  'conversations': SyncChangeScope.none,
  'conversation_messages': SyncChangeScope.none,
  'conversation_attachments': SyncChangeScope.none,
  'user_apps': SyncChangeScope.none,
  'app_revisions': SyncChangeScope.none,
  'user_app_libraries': SyncChangeScope.none,
  'user_app_library_dependencies': SyncChangeScope.none,
};

/// SQLite variable-limit-safe `IN (...)` batch size — the same 500 every
/// other batched lookup in this codebase uses (`getNotesByIds`,
/// `NoteIndexService._sqlVarChunk`).
const int _sqlVarChunk = 500;

/// What one materialization pass wrote, accumulated inside the transaction
/// that wrote it and resolved into a [DataChangeEvent] after it commits.
///
/// Mutable and cheap on purpose: one instance is built per transaction body
/// and merged into the round's accumulator only once the transaction has
/// returned.
class SyncChangeCollector {
  /// Ids that are already note ids.
  final Set<String> noteIds = {};

  /// Row ids still needing an owner lookup, per table (`subnotes`,
  /// `attachments`, `note_annotations`, `relationships`).
  final Map<String, Set<String>> unresolvedRowIds = {};

  /// Tags written this round — their own list changed, and so did the meta
  /// chunk of every note carrying them.
  final Set<String> tagIds = {};

  bool filtersChanged = false;

  /// Something was written that this file cannot attribute to a note. Always
  /// preferred over silence: `NoteIndexService._onDataChange` treats `bulk`
  /// as "scope unknown, run a completeness sweep", which is exactly right.
  bool bulk = false;

  bool get isEmpty =>
      noteIds.isEmpty &&
      unresolvedRowIds.isEmpty &&
      tagIds.isEmpty &&
      !filtersChanged &&
      !bulk;

  /// Records one row written into [table].
  ///
  /// [rowId] is the row's own primary key for an entity write, and the
  /// OWNING entity's id for an OR-Set membership write — which is why
  /// membership needs no separate mapping: `note_tags`' capture scope names
  /// `notes` as its entity table, so a membership add/remove records the note
  /// that owns it, and every other membership table's owner is a conversation
  /// or a message and correctly classifies as [SyncChangeScope.none].
  void recordRow(String table, String rowId) {
    switch (syncChangeScopeByTable[table]) {
      case SyncChangeScope.note:
        noteIds.add(rowId);
      case SyncChangeScope.ownedByNote:
      case SyncChangeScope.annotation:
      case SyncChangeScope.relationship:
        (unresolvedRowIds[table] ??= <String>{}).add(rowId);
      case SyncChangeScope.tags:
        tagIds.add(rowId);
      case SyncChangeScope.filters:
        filtersChanged = true;
      case SyncChangeScope.none:
        break;
      case null:
        // An unclassified table: something changed and this file cannot say
        // what. Degrade to a completeness sweep rather than reporting nothing
        // — the failure mode this whole file exists to end.
        bulk = true;
    }
  }

  void addAll(SyncChangeCollector other) {
    noteIds.addAll(other.noteIds);
    for (final entry in other.unresolvedRowIds.entries) {
      (unresolvedRowIds[entry.key] ??= <String>{}).addAll(entry.value);
    }
    tagIds.addAll(other.tagIds);
    filtersChanged = filtersChanged || other.filtersChanged;
    bulk = bulk || other.bulk;
  }
}

/// Resolves a [SyncChangeCollector] into a [DataChangeEvent] and publishes
/// it. Constructed once per phase; [publish] is called once per round, after
/// every transaction of that round has committed.
class SyncChangePublisher {
  SyncChangePublisher({DataChangeNotifier? changeNotifier})
    : _notifier = changeNotifier ?? DataChangeNotifier.shared();

  final DataChangeNotifier _notifier;

  /// Resolves and publishes [changes]. Never throws: a sync round that
  /// materialized correctly must not fail because its announcement did.
  ///
  /// **A resolution failure publishes `bulk` rather than nothing.** If the
  /// owner lookups throw, this file still knows that rows were written; the
  /// only thing it has lost is which notes they belong to, which is precisely
  /// what `bulk` means.
  Future<void> publish(DatabaseExecutor db, SyncChangeCollector changes) async {
    if (changes.isEmpty) return;
    DataChangeEvent event;
    try {
      event = await buildEvent(db, changes);
    } catch (e, stack) {
      LoggerService.error(
        '[SyncChangePublisher] Could not resolve what a sync round wrote; '
        'falling back to a bulk invalidation: $e',
        error: e,
        stackTrace: stack,
      );
      event = const DataChangeEvent(bulk: true);
    }
    _notifier.publish(event);
  }

  /// The event [changes] resolves to, without publishing it.
  @visibleForTesting
  Future<DataChangeEvent> buildEvent(
    DatabaseExecutor db,
    SyncChangeCollector changes,
  ) async {
    if (changes.isEmpty) return const DataChangeEvent();
    if (changes.bulk) return const DataChangeEvent(bulk: true);

    final noteIds = <String>{...changes.noteIds};
    final relationshipNoteIds = <String>{};

    for (final entry in changes.unresolvedRowIds.entries) {
      switch (entry.key) {
        case 'subnotes':
        case 'attachments':
          noteIds.addAll(
            await _lookupIds(db, entry.key, 'id', const ['noteId'], entry.value),
          );
        case 'note_annotations':
          final attachmentIds = <String>{};
          final rows = await _selectByIds(db, 'note_annotations', 'id', const [
            'note_id',
            'attachment_id',
          ], entry.value);
          for (final row in rows) {
            final noteId = row['note_id'] as String?;
            if (noteId != null) noteIds.add(noteId);
            final attachmentId = row['attachment_id'] as String?;
            if (attachmentId != null) attachmentIds.add(attachmentId);
          }
          noteIds.addAll(
            await _lookupIds(db, 'attachments', 'id', const [
              'noteId',
            ], attachmentIds),
          );
        case 'relationships':
          relationshipNoteIds.addAll(
            await _lookupIds(db, 'relationships', 'id', const [
              'fromNoteId',
              'toNoteId',
            ], entry.value),
          );
      }
    }

    // A tag write changes the tag list AND the meta chunk of every note
    // carrying that tag (tag names are indexed content, not just chrome).
    if (changes.tagIds.isNotEmpty) {
      noteIds.addAll(
        await _lookupIds(db, 'note_tags', 'tagId', const [
          'noteId',
        ], changes.tagIds),
      );
    }

    // **The large-pull degradation.** A first sync materializes thousands of
    // rows; the notifier would coalesce the ids into one event, but the
    // event's CONSUMERS are what the ceiling protects — `AppProvider`
    // re-fetches every id through a chunked `WHERE id IN (...)` while holding
    // its cache lock, and `NoteIndexService` arms one debounce timer per id.
    // Past a few hundred notes both cost more than the reload/completeness
    // sweep `bulk` triggers, which is why `SqlQueryService` already degrades
    // its own captured writes at exactly this count. One ceiling, one place.
    if (noteIds.length > DataChangeEvent.maxTargetedNoteIds) {
      return const DataChangeEvent(bulk: true);
    }

    return DataChangeEvent(
      noteIds: noteIds,
      tagsChanged: changes.tagIds.isNotEmpty,
      filtersChanged: changes.filtersChanged,
      relationshipNoteIds: relationshipNoteIds,
    );
  }

  /// Every non-null value of [valueColumns] on the rows of [table] whose
  /// [keyColumn] is in [keys], batched under the SQLite variable limit.
  Future<Set<String>> _lookupIds(
    DatabaseExecutor db,
    String table,
    String keyColumn,
    List<String> valueColumns,
    Set<String> keys,
  ) async {
    final rows = await _selectByIds(db, table, keyColumn, valueColumns, keys);
    return {
      for (final row in rows)
        for (final column in valueColumns)
          if (row[column] case final String value) value,
    };
  }

  Future<List<Map<String, Object?>>> _selectByIds(
    DatabaseExecutor db,
    String table,
    String keyColumn,
    List<String> valueColumns,
    Set<String> keys,
  ) async {
    if (keys.isEmpty) return const [];
    final all = keys.toList();
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < all.length; i += _sqlVarChunk) {
      final batch = all.sublist(
        i,
        i + _sqlVarChunk > all.length ? all.length : i + _sqlVarChunk,
      );
      final placeholders = List.filled(batch.length, '?').join(',');
      rows.addAll(
        await db.rawQuery(
          'SELECT ${valueColumns.join(', ')} FROM $table '
          'WHERE $keyColumn IN ($placeholders)',
          batch,
        ),
      );
    }
    return rows;
  }
}
