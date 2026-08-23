// Shared schema-shape predicates and encodings for the sync engine —
// extracted in M2.10 so that the several places which have to answer "can
// this row's identity travel to another device?" and "what does a
// membership add-event carry?" answer them the SAME way.
//
// **Why this file exists at all.** Both questions were being answered by
// copy-pasted logic: `materializer.dart` had its own
// `_isNonPortableIntegerPrimaryKey` and `seed_scanner.dart` grew a second
// copy, and the membership payload encoding was about to be duplicated a
// third time in `outbox_drainer.dart`. That is exactly the drift class
// `SyncEntityCaptureScope`/`SyncSetCaptureScope` were made public to
// prevent (see their own doc comments in `database_service.dart`): a guard
// that exists in one of two places is a guard that will eventually be
// tightened in only one of them.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../database_service.dart';

/// `PRAGMA table_info` for [table], as returned by SQLite.
Future<List<Map<String, Object?>>> syncTableInfo(
  DatabaseExecutor txn,
  String table,
) => txn.rawQuery('PRAGMA table_info($table)');

/// Whether [columnInfo] (one `PRAGMA table_info` row) describes an
/// `INTEGER PRIMARY KEY` — i.e. a rowid alias whose value is assigned
/// locally by SQLite and means nothing on any other device.
bool isNonPortableIntegerPrimaryKey(Map<String, Object?> columnInfo) {
  final pk = columnInfo['pk'] as int? ?? 0;
  final type = (columnInfo['type'] as String? ?? '').toUpperCase();
  return pk != 0 && type.contains('INT');
}

/// Whether a row in [table] has an `entityId` (its [idColumn] value) that
/// means the same thing on another device.
///
/// **This is a correctness guard against silent cross-device corruption,
/// not an optimization, and it has to be applied on BOTH sides.**
/// `user_app_libraries`/`user_app_library_dependencies` key on `INTEGER
/// PRIMARY KEY AUTOINCREMENT`, so device A's row `1` and device B's row `1`
/// are unrelated rows that merely share a locally-assigned counter value.
/// Two independent consequences, both confirmed by reproduction:
///
///  1. **Materialization corrupts the wrong row.** `_materializeExists`
///     correctly refuses to INSERT a row under a foreign integer id — but
///     that guard alone is not enough, because a `field` operation for
///     `entityId = '1'` does not need an INSERT: it UPDATEs whatever local
///     row already occupies id `1`. Reproduced end-to-end from an ordinary,
///     everyday action with no update call site involved at all — importing
///     an app on device A (`insertUserAppLibrary`) fired the AFTER INSERT
///     capture trigger, drain minted `__exists__`/`name`/
///     `usage_instructions` at `entityId = '1'`, and on device B the
///     `__exists__` was skipped while the field operations silently renamed
///     B's unrelated library and gave it A's usage instructions. No conflict
///     copy, no queue entry, no error.
///  2. **`contentKey`s collide unconditionally**, not merely when content
///     happens to match: `__exists__` seeds carry the constant `true` and
///     `__deleted__` carries the same value on any untombstoned row, so the
///     GENESIS key is identical on both devices for genuinely different
///     rows.
///
/// So the guard is applied at every point that mints an operation for a
/// table (`outbox_drainer.dart`, `seed_scanner.dart`) AND at every point
/// that writes one into a real row (`materializer.dart`). Minting-side
/// alone would leave already-published operations from an older build
/// dangerous forever; materialization-side alone would leave these
/// operations travelling and consuming log space for data no device can
/// ever use.
Future<bool> hasPortableEntityId(
  DatabaseExecutor txn,
  String table,
  String idColumn, {
  Map<String, bool>? cache,
}) async {
  // Keyed on BOTH parameters. Every caller today passes one fixed
  // `idColumn` per table (from `SyncEntityCaptureScope`), so keying on the
  // table alone happens to be correct — but it is correct by coincidence,
  // and a caller that ever asked about two different columns of one table
  // would silently get the first answer for both. Cheap to make the key
  // match the question.
  final key = '$table.$idColumn';
  final cached = cache?[key];
  if (cached != null) return cached;
  final computed = await _computeHasPortableEntityId(txn, table, idColumn);
  cache?[key] = computed;
  return computed;
}

Future<bool> _computeHasPortableEntityId(
  DatabaseExecutor txn,
  String table,
  String idColumn,
) async {
  final columns = await syncTableInfo(txn, table);
  Map<String, Object?>? idInfo;
  for (final column in columns) {
    if (column['name'] == idColumn) {
      idInfo = column;
      break;
    }
  }
  // Unknown shape: treat as non-portable. Refusing to sync something is
  // always recoverable; corrupting an unrelated row is not.
  if (idInfo == null) return false;
  return !isNonPortableIntegerPrimaryKey(idInfo);
}

/// Each entity table's creation-timestamp column — the column every
/// `syncEntityCaptureScope` doc comment in `database_service.dart` means by
/// "id/createdAt excluded". `materializer.dart` fills it from the
/// `__exists__` operation's own HLC wall-clock component; the syncability
/// predicate below has to know about it for the same reason (it is
/// resolvable without being in `syncScopeColumns`).
///
/// **`app_revisions.revisionTimestamp` was missing from this map until
/// M2.14, and its absence was a real (if latent) misstatement rather than an
/// omission.** `database_service.dart`'s own scope comment for
/// `app_revisions` already calls `revisionTimestamp` "the createdAt-
/// equivalent... derived at materialization time from the `__exists__`
/// operation's own HLC", and `insertAppRevision` writes exactly
/// `revision.revisionTimestamp.millisecondsSinceEpoch` — the same unit and
/// meaning as every other entry here. Leaving it out made
/// [entitySyncability] report `revisionTimestamp` as the reason
/// `app_revisions` cannot sync, which is false: the column is perfectly
/// resolvable and the real blocker is `appCode` (see
/// [syncContentDeferredTables]). A health surface that names the wrong
/// column sends the next person to fix the wrong thing.
const Map<String, String> syncEntityCreatedAtColumnByTable = {
  'notes': 'createdAt',
  'subnotes': 'createdAt',
  'tags': 'createdAt',
  'filters': 'createdAt',
  'relationships': 'createdAt',
  'conversations': 'createdAt',
  'conversation_messages': 'timestamp',
  'conversation_attachments': 'createdAt',
  'attachments': 'createdAt',
  'user_apps': 'createdAt',
  'app_revisions': 'revisionTimestamp',
};

/// Tables whose ROWS sync but whose actual CONTENT does not yet, because
/// that content belongs to § Architecture 4's content-addressed blob
/// mechanism (M3) rather than to inline `valueJson` field sync.
///
/// Two different shapes, deliberately in one map, because they produce the
/// identical user-visible outcome — "the row is here, the thing it names is
/// not":
///
///  * **`app_revisions.appCode`** — the app's whole HTML/JS source, a
///    `TEXT NOT NULL` column with no default that is deliberately outside
///    `syncScopeColumns` (see its own doc comment in
///    `database_service.dart`). It is also, therefore, still an
///    [EntitySyncBlocker.unresolvableColumn]: M2.14 carries owner references
///    on `__exists__`, which unblocks `appId`, but nothing in this milestone
///    can supply a revision's source, so `app_revisions` rows still do not
///    materialize at all.
///  * **`attachments`/`conversation_attachments`** — these tables' rows sync
///    completely as of M2.14, but the FILE each row points at lives on disk
///    and has never been part of any operation. A peer therefore gets a real
///    attachment row whose file is not there.
///
/// **What each one is FOR, since a list nothing reads is the failure mode
/// this engine keeps rediscovering.** `app_revisions` is the input to
/// `seed_scanner_test.dart`'s audit, which fails if the carried-column rule
/// is ever widened enough to put one of these on the wire; it also names,
/// in one place, what `entitySyncability`'s remaining `unresolvable column`
/// blocker actually is. The two attachment tables are documentation of a
/// user-visible consequence, deliberately NOT wired to the health surface —
/// see `SyncHealthIssueKind.tablesNotSynced`'s doc comment for why a health
/// kind for them was written and then removed, and where the honest,
/// actionable signal lives instead.
///
/// It is a declared list rather than a derived one on purpose: "this column is really a blob" is a statement about what the
/// data MEANS, and `PRAGMA table_info` cannot see the difference between
/// `subnotes.noteId` (a uuid) and `app_revisions.appCode` (a megabyte of
/// HTML) — both are `TEXT NOT NULL`. See [entitySyncability]'s own doc
/// comment for how the carried-column rule avoids ever needing to.
const Map<String, List<String>> syncContentDeferredTables = {
  'app_revisions': ['appCode'],
  'attachments': ['<file bytes>'],
  'conversation_attachments': ['<file bytes>'],
  'user_app_library_dependencies': ['bytes'],
};

/// Each membership table's creation-timestamp column, where it has one —
/// the membership-side counterpart of [syncEntityCreatedAtColumnByTable],
/// deliberately the same shape (an explicit map, not name sniffing).
/// `note_tags`/`conversation_tags` have none: their two id columns are the
/// whole row.
const Map<String, String> syncMembershipCreatedAtColumnByTable = {
  'conversation_note_mapping': 'createdAt',
  'conversation_message_mapping': 'createdAt',
  'message_parents': 'createdAt',
};

/// Why an entity table's rows cannot be created from synced data alone.
enum EntitySyncBlocker {
  /// The table's primary key is an `INTEGER PRIMARY KEY` — a locally
  /// assigned value that identifies a different row on every device. See
  /// [hasPortableEntityId].
  nonPortableId,

  /// The table declares a `NOT NULL` column with no SQL default that is
  /// neither the id, the createdAt-equivalent, in `syncScopeColumns`, nor
  /// carried on `__exists__` (M2.14 — see [entitySyncability]'s
  /// carried-column rule). No operation this protocol carries can supply it,
  /// so a receiving device can never build the row.
  ///
  /// **After M2.14 this reason is left for exactly one column in the whole
  /// schema — `app_revisions.appCode` — and that is not an accident of the
  /// rule but the point of it.** Every other instance of this blocker was an
  /// owner reference or a required identity column, which `__exists__` now
  /// carries. `appCode` is a blob in a `TEXT` column
  /// ([syncContentDeferredTables]) and belongs to M3.
  unresolvableColumn,
}

/// Where one `__exists__`-carried column's value must already exist before
/// the row carrying it can be inserted — the `(table, column)` its declared
/// `FOREIGN KEY` points at.
typedef ExistsOwnerReference = ({String column, String table, String toColumn});

/// Whether an entity table's rows can be created on a device that has only
/// ever seen this protocol's operations — and if not, why, and which column
/// is responsible.
class EntitySyncability {
  const EntitySyncability.ok({
    this.existsCarriedColumns = const [],
    this.existsOwnerReferences = const [],
  }) : blocker = null,
       blockingColumn = null;
  const EntitySyncability.blocked(
    this.blocker,
    this.blockingColumn, {
    this.existsCarriedColumns = const [],
    this.existsOwnerReferences = const [],
  });

  final EntitySyncBlocker? blocker;
  final String? blockingColumn;

  /// The columns this table's `__exists__` operation carries, in the exact
  /// canonical order [encodeExistsPayloadJson] emits them. See
  /// [entitySyncability] for the selection rule.
  ///
  /// Populated whether or not [canSync] holds: a table blocked by ONE
  /// unresolvable column still has carried columns, and reporting them is
  /// what lets the blocker name the column that is genuinely left.
  final List<String> existsCarriedColumns;

  /// The subset of [existsCarriedColumns] that are declared foreign keys,
  /// with the row each requires to already exist. `materializer.dart` checks
  /// these before inserting a shell row and parks the operation under
  /// `missing_exists` when one is absent — a child cannot be inserted before
  /// its owner, and this codebase runs with `PRAGMA foreign_keys = ON`, so
  /// an unchecked insert is a thrown `FOREIGN KEY constraint failed`, not a
  /// silent no-op.
  final List<ExistsOwnerReference> existsOwnerReferences;

  bool get canSync => blocker == null;

  /// A short, stable, loggable/persistable description — used by the sync
  /// health surface so a user can be told WHICH tables are not syncing.
  String get reasonLabel => switch (blocker) {
    null => 'ok',
    EntitySyncBlocker.nonPortableId => 'non-portable id',
    EntitySyncBlocker.unresolvableColumn =>
      'unresolvable column '
          '${blockingColumn ?? '?'}',
  };
}

/// Can a device that has only ever seen operations build a row in
/// [scope]'s table?
///
/// **This is the predicate `_materializeExists` has always applied at the
/// receiving end; M2.10 makes it gate MINTING too.** Before that gate, a
/// table no peer could build still minted operations, pushed them, occupied
/// backend log space, and produced a permanent `missing_exists` queue row
/// per field on *every* peer, *forever*: a backlog that could never drain
/// because the prerequisite it waits for can never arrive. Gating the mint
/// deletes that entire class.
///
/// The check is derived from `PRAGMA table_info` rather than a hardcoded
/// list, so a table that becomes syncable (by acquiring a default, or by
/// having its owner FK brought into sync scope) starts syncing with no code
/// change — and one that regresses stops, loudly, via the audit test.
///
/// ---------------------------------------------------------------------
/// **M2.14: the carried-column rule, and why the obvious version of it is
/// wrong.**
/// ---------------------------------------------------------------------
/// M2.10 counted six tables blocked by an unresolvable column, and in five
/// of the six the ONLY such column was an owner pointer or a second
/// required identity column — `subnotes.noteId`, `attachments.noteId`,
/// `relationships.fromNoteId`/`toNoteId`,
/// `conversation_attachments.messageId`, `user_apps.uuid`. So M2.14 puts
/// those values ON the `__exists__` operation ([encodeExistsPayloadJson])
/// and this predicate stops counting them as blockers.
///
/// The sixth, `app_revisions`, is where the shape of the fix gets decided,
/// and the reported column was hiding two others behind it. `appId` is an
/// owner pointer and is now carried. `revisionTimestamp` was never really
/// unresolvable at all — it is this table's createdAt-equivalent and simply
/// had no entry in [syncEntityCreatedAtColumnByTable]. What is genuinely
/// left is `appCode`.
///
/// The tempting rule is "carry every `NOT NULL`, no-default column outside
/// sync scope" — i.e. carry exactly what used to block. **Measured against
/// the live schema, that rule carries `app_revisions.appCode` and
/// `user_app_library_dependencies.bytes`**: an entire mini-app's HTML/JS
/// source and a dependency's raw file bytes, inlined into an `__exists__`
/// payload and hashed into its GENESIS `contentKey`. Those are precisely
/// the two columns § Architecture 4's content-addressed blob mechanism
/// exists for and that CLAUDE.md's own "Database Columns (Large Data)" note
/// singles out. The rule has to be narrower, and it has to be narrower in a
/// way `PRAGMA` can actually see — `appCode` and `subnotes.noteId` are both
/// declared `TEXT NOT NULL`, so no type or nullability test tells them
/// apart.
///
/// **The rule used instead: `__exists__` carries REFERENCE and IDENTITY
/// columns, and nothing else.** A candidate column must be `NOT NULL` with
/// no default, must not be the id, the createdAt-equivalent, or in
/// `syncScopeColumns` — and must additionally be either
///
///  * the `from` side of a declared `FOREIGN KEY` (`PRAGMA
///    foreign_key_list`) — it points at another row; or
///  * the sole column of a non-partial `UNIQUE` index that is not the
///    primary key's (`PRAGMA index_list`/`index_info`) — it IS this row's
///    identity.
///
/// Both halves are `PRAGMA`-derived, so the "a table that becomes syncable
/// starts syncing with no code change" property above survives intact: give
/// a new owner column a `REFERENCES` clause and it is carried automatically.
/// And the rule **fails closed**: a `NOT NULL` column that is neither a key
/// nor a reference is still an [EntitySyncBlocker.unresolvableColumn], so
/// the table stops syncing loudly instead of silently shipping a blob. That
/// direction matters — refusing to sync something is recoverable, inlining
/// a megabyte into a permanent CRDT operation is not.
///
/// **Why "a key is always small" is a real argument and not a
/// rationalization.** A column is only selected here because SQLite itself
/// has been told it references another row or uniquely identifies this one.
/// Both are things you index and join on. `appCode` is neither, and could
/// not become either without someone declaring a `UNIQUE` index over a
/// megabyte of HTML — at which point this predicate's behaviour is the
/// smallest of that schema's problems.
///
/// **What is left after the rule is applied, checked against the live
/// schema rather than asserted:** of the fourteen entity tables, eleven now
/// have `canSync == true`. `app_revisions` is blocked by `appCode` alone
/// (M3); `user_app_libraries`/`user_app_library_dependencies` are blocked by
/// [EntitySyncBlocker.nonPortableId], which M2.14 does not address. Both
/// lists are pinned by `seed_scanner_test.dart`'s `syncability audit` group
/// — including a test that fails if the carried-column rule is ever widened
/// enough to select one of [syncContentDeferredTables]' blob columns.
///
/// **Gating is not silent.** Callers report what they skipped
/// (`DrainResult.nonPortableTablesSkipped`,
/// `SeedScanResult.nonPortableTablesSkipped`) into the sync health surface,
/// because "your data is not syncing and nothing told you" is the exact
/// failure class this milestone kept rediscovering.
/// [cache], when supplied, memoizes the answer per table for the caller's
/// own scope (one drain pass, one seed scan, one materializer instance).
///
/// **Not a micro-optimization.** `PRAGMA table_info` is a real round trip,
/// and the natural call sites are hot loops — once per touch row in
/// `OutboxDrainer.drain`, once per materialized field write. Re-deriving an
/// immutable schema fact thousands of times per sync measurably slowed a
/// round down. Caller-scoped rather than global on purpose: schema shape is
/// fixed for the life of an open database, but a process can open several
/// (every test does), and a global cache would let one leak into another.
Future<EntitySyncability> entitySyncability(
  DatabaseExecutor txn,
  SyncEntityCaptureScope scope, {
  Map<String, EntitySyncability>? cache,
}) async {
  final cached = cache?[scope.table];
  if (cached != null) return cached;
  final computed = await _computeEntitySyncability(txn, scope);
  cache?[scope.table] = computed;
  return computed;
}

Future<EntitySyncability> _computeEntitySyncability(
  DatabaseExecutor txn,
  SyncEntityCaptureScope scope,
) async {
  final columns = await syncTableInfo(txn, scope.table);
  Map<String, Object?>? idInfo;
  for (final column in columns) {
    if (column['name'] == scope.idColumn) idInfo = column;
  }
  if (idInfo == null || isNonPortableIntegerPrimaryKey(idInfo)) {
    return const EntitySyncability.blocked(
      EntitySyncBlocker.nonPortableId,
      null,
    );
  }

  final foreignKeys = await _foreignKeyTargets(txn, scope.table);
  final singleColumnUniques = await _singleColumnUniqueColumns(txn, scope.table);

  final createdAtColumn = syncEntityCreatedAtColumnByTable[scope.table];
  final carried = <String>[];
  String? blockingColumn;
  for (final column in columns) {
    final name = column['name'] as String;
    if (name == scope.idColumn) continue;
    if (name == createdAtColumn) continue;
    if (scope.syncScopeColumns.contains(name)) continue;
    final notNull = (column['notnull'] as int? ?? 0) != 0;
    final hasDefault = column['dflt_value'] != null;
    if (!notNull || hasDefault) continue;
    if (foreignKeys.containsKey(name) || singleColumnUniques.contains(name)) {
      carried.add(name);
      continue;
    }
    // Not a reference, not an identity — nothing this protocol carries can
    // supply it. Recorded rather than returned immediately so the carried
    // list is complete either way (see [EntitySyncability.existsCarried
    // Columns]); the FIRST such column is the one reported, matching the
    // pre-M2.14 behaviour every existing test and log line expects.
    blockingColumn ??= name;
  }

  // Canonical order: sorted, NOT `PRAGMA table_info` order. Two devices must
  // encode the identical payload string for the same logical row or their
  // GENESIS `contentKey`s diverge and the seeds stop deduping — and
  // declaration order is NOT stable across devices, because `ALTER TABLE ADD
  // COLUMN` appends, so a migrated database and a freshly-created one can
  // report the same columns in different orders. Sorting is the only order
  // both are guaranteed to agree on.
  carried.sort();
  final ownerReferences = <ExistsOwnerReference>[
    for (final column in carried)
      if (foreignKeys[column] case final target?)
        (column: column, table: target.$1, toColumn: target.$2),
  ];

  if (blockingColumn != null) {
    return EntitySyncability.blocked(
      EntitySyncBlocker.unresolvableColumn,
      blockingColumn,
      existsCarriedColumns: List.unmodifiable(carried),
      existsOwnerReferences: List.unmodifiable(ownerReferences),
    );
  }
  return EntitySyncability.ok(
    existsCarriedColumns: List.unmodifiable(carried),
    existsOwnerReferences: List.unmodifiable(ownerReferences),
  );
}

/// `column -> (referenced table, referenced column)` for every declared
/// `FOREIGN KEY` of [table].
///
/// A composite foreign key contributes one entry per column, which is
/// deliberately imprecise in the safe direction: each column individually
/// must still name a row that exists, and this codebase declares no
/// composite foreign key today.
///
/// `PRAGMA foreign_key_list` reports `to` as NULL when the clause omits the
/// referenced column (`REFERENCES notes` rather than `REFERENCES notes(id)`),
/// which means the target's PRIMARY KEY; resolved here rather than left
/// null, because the caller's owner-existence check needs a real column name
/// and a skipped check would hand an unchecked `INSERT` to a live
/// `FOREIGN KEY` constraint.
Future<Map<String, (String, String)>> _foreignKeyTargets(
  DatabaseExecutor txn,
  String table,
) async {
  final rows = await txn.rawQuery('PRAGMA foreign_key_list($table)');
  final targets = <String, (String, String)>{};
  for (final row in rows) {
    final from = row['from'] as String?;
    final toTable = row['table'] as String?;
    if (from == null || toTable == null) continue;
    var toColumn = row['to'] as String?;
    toColumn ??= await _primaryKeyColumn(txn, toTable);
    if (toColumn == null) continue;
    targets[from] = (toTable, toColumn);
  }
  return targets;
}

Future<String?> _primaryKeyColumn(DatabaseExecutor txn, String table) async {
  for (final column in await syncTableInfo(txn, table)) {
    if ((column['pk'] as int? ?? 0) != 0) return column['name'] as String;
  }
  return null;
}

/// Every column that is the SOLE column of a non-partial `UNIQUE` index on
/// [table] other than the primary key's own — i.e. every column that
/// independently identifies a row (`user_apps.uuid`).
///
/// **Sole-column and non-partial are both required, and both narrow the rule
/// on purpose.** A column that is one of several in a composite `UNIQUE` does
/// not identify a row by itself, and a PARTIAL unique index constrains only
/// some rows (`idx_tags_name_live` covers raw-live tags only) — neither is
/// the "this value IS the row's identity" property the carried-column rule
/// is selecting for. The primary key's own index is excluded because
/// `scope.idColumn` is already handled, and because a table whose id is
/// non-portable has been rejected long before this runs.
Future<Set<String>> _singleColumnUniqueColumns(
  DatabaseExecutor txn,
  String table,
) async {
  final indexes = await txn.rawQuery('PRAGMA index_list($table)');
  final columns = <String>{};
  for (final index in indexes) {
    if ((index['unique'] as int? ?? 0) == 0) continue;
    if ((index['partial'] as int? ?? 0) != 0) continue;
    if (index['origin'] == 'pk') continue;
    final info = await txn.rawQuery('PRAGMA index_info(${index['name']})');
    if (info.length != 1) continue;
    final name = info.first['name'] as String?;
    if (name != null) columns.add(name);
  }
  return columns;
}

// ---------------------------------------------------------------------------
// M2.14: the `__exists__` payload — owner references and identity columns.
// ---------------------------------------------------------------------------

/// The `__exists__` payload for a table with no carried columns at all: the
/// constant `true` this operation has always carried, byte for byte.
///
/// **Preserving it exactly is not tidiness, it is the compatibility
/// argument.** Ten of the fourteen entity tables select no carried column,
/// including every table that syncs today (`notes`, `tags`, `filters`,
/// `conversations`, `conversation_messages`, `tag_workflow_bindings`). For
/// those, M2.14 changes nothing on the wire: the same `true`, the same
/// GENESIS `contentKey`, the same dedup classes as every operation already
/// published to a backend. Only the tables that could never materialize
/// anyway get a new payload shape, and no correct operation for them exists
/// in the field to be compared against.
const String bareExistsPayloadJson = 'true';

/// Encodes one entity row's `__exists__` payload — the values of
/// [EntitySyncability.existsCarriedColumns], as a JSON object keyed by
/// column name in that list's (sorted) order, or [bareExistsPayloadJson]
/// when the table has none.
///
/// **This is what makes `subnotes`/`attachments`/`relationships`/
/// `conversation_attachments`/`user_apps` materializable on a peer at all**:
/// `materializer.dart`'s `_materializeExists` builds its shell-row `INSERT`
/// from `idColumn` + the createdAt-equivalent + `syncScopeColumns`
/// placeholders, and had no source whatsoever for a `NOT NULL` owner FK
/// outside all three. Now it reads it back from here.
///
/// **What this does to the GENESIS `contentKey`, stated because it is one of
/// the two arguments the constant `true` was load-bearing for.** The payload
/// is hashed into `genesisContentKey` like any other value, so two devices
/// seeding the same subnote must produce the same string here or their seeds
/// stop deduping. They do: `existsCarriedColumns` is sorted (not schema
/// order), the values are read from the two devices' own copies of the same
/// logical row, and the carried columns are by construction the ones this
/// codebase never reassigns (that is precisely why they are outside
/// `syncScopeColumns` — see each table's scope comment in
/// `database_service.dart`). So the two payloads are equal and dedup holds
/// exactly as it did for `true`.
///
/// **If they ever DID disagree** — two devices holding the same row uuid
/// under different owners, which needs a uuid collision or a hand-edited
/// database, not any ordinary flow — the two seeds get different
/// `contentKey`s, do not dedup, and become two concurrent candidates in the
/// `__exists__` register. Field conflict resolution then picks one
/// deterministically on `(hlc, authorId, authorSeq)`, so every device agrees
/// on WHICH owner the row has. See `materializer.dart`'s `_materializeExists`
/// for the one residual that survives that argument (a device which already
/// inserted the row under the losing payload does not rewrite it).
///
/// **The SECOND argument the constant was load-bearing for, and how it
/// changes.** M2.13 round 5 justified leaving `__exists__` conflicts
/// unresolved-in-any-special-way on the grounds that "either side
/// materializes the identical outcome" — true of a constant `true` by
/// definition. That is now a claim about DATA rather than a tautology, and
/// it has to be earned twice over: the carried columns are set once at
/// creation and never reassigned (so two candidates for one entity carry
/// equal values in every flow the app can produce), and even a
/// hypothetically unequal pair converges, because the register picks one
/// winner deterministically and every device reads the payload back out of
/// the register rather than off the operation in hand. What genuinely
/// weakens is that the outcome is now OBSERVABLE — a row's `noteId` — so
/// "identical outcome" is checkable instead of vacuous, and the one place
/// it can fail (a row already inserted under the loser) is named rather
/// than covered by the old slogan.
String encodeExistsPayloadJson(
  List<String> carriedColumns,
  Map<String, Object?> row,
) {
  if (carriedColumns.isEmpty) return bareExistsPayloadJson;
  return jsonEncode({for (final column in carriedColumns) column: row[column]});
}

/// Decodes what [encodeExistsPayloadJson] produced.
///
/// Returns an empty map for the bare sentinel, for `null`, and for anything
/// not shaped like a JSON object — which is exactly what an `__exists__`
/// operation minted by a build older than M2.14 looks like. Those operations
/// are real and are on real backends: every one of these tables minted and
/// published `__exists__` normally until M2.10 gated them, so a receiving
/// device WILL meet a `true` payload for a table that now needs owner
/// values. It must read it without throwing and conclude "no owner values
/// here", which leaves that entity exactly as unmaterializable as it was
/// before M2.14 — never a crash, and never a row inserted under a guessed
/// owner. `OutboxDrainer`'s legacy-payload upgrade pass is what eventually
/// replaces those registers; see its own doc comment.
Map<String, Object?> decodeExistsPayload(String? valueJson) {
  if (valueJson == null) return const {};
  final Object? decoded;
  try {
    decoded = jsonDecode(valueJson);
  } on FormatException {
    return const {};
  }
  if (decoded is! Map) return const {};
  return decoded.cast<String, Object?>();
}

/// Whether [payload] supplies a usable value for every one of
/// [carriedColumns] — the test both `materializer.dart` (may I insert this
/// row?) and `outbox_drainer.dart` (is this device's recorded `__exists__`
/// register stale?) apply, so the two can never disagree about what
/// "complete" means.
///
/// `null` counts as missing, not as present: every carried column is
/// `NOT NULL` by construction, so a payload carrying an explicit null
/// satisfies `containsKey` while satisfying nothing the column needs. That
/// exact `containsKey`-only gap was a reproduced sync outage one layer down
/// in `_insertMembershipRow`; it is not repeated here.
bool existsPayloadIsComplete(
  List<String> carriedColumns,
  Map<String, Object?> payload,
) {
  for (final column in carriedColumns) {
    if (payload[column] == null) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Shell-row defaults (M2.12) — the single definition of "what value will a
// receiving device's row already hold for this column before that column's
// own `field` operation arrives?"
// ---------------------------------------------------------------------------

/// The value `SyncMaterializer._materializeExists` writes into a brand-new
/// shell row for [columnInfo] (one `PRAGMA table_info` row) — its own
/// SQL-declared default where it has one, else a type-appropriate
/// empty/zero value for a `NOT NULL` column, else `NULL`.
///
/// **Extracted in M2.12 because a second caller now needs the identical
/// answer, and needs it to be identical by construction rather than by
/// coincidence.** `SeedScanner` skips seeding any field whose live value
/// already equals what the receiving device's shell row will hold — a seed
/// that transmits zero information but costs a permanent CRDT operation.
/// That skip is only sound if "what the shell row will hold" is computed by
/// the very function that fills the shell row; two independently-maintained
/// copies of this logic would eventually disagree, and the failure mode of
/// disagreement is silent (a field skipped on the sending side that the
/// receiving side never actually defaults to that value).
Object? shellRowPlaceholderValue(Map<String, Object?> columnInfo) =>
    decodeShellRowDefault(columnInfo).value;

/// [shellRowPlaceholderValue], plus whether the answer is a real, statically
/// resolvable SQL default (`known: true`) or a best-effort stand-in for a
/// default this function cannot evaluate (`known: false`).
///
/// The distinction exists because the two callers need different things from
/// the same computation. `_materializeExists` must write SOMETHING into a
/// shell row's column and a type-appropriate empty value is the least-wrong
/// choice; `SeedScanner`'s skip must be certain, and an uncertain answer has
/// to mean "do not skip" (seeding a field unnecessarily costs traffic;
/// skipping one wrongly costs data).
///
/// **The literal parsing here is deliberately broader than the original
/// inline version's**, which handled only single-quoted strings and bare
/// numbers. Three real gaps, all found in review:
///   * **Double-quoted defaults.** `user_apps.author`/`user_apps.license`
///     are declared `DEFAULT ""`, and SQLite reports `dflt_value` as the
///     two-character string `""`. The old parser returned that verbatim, so
///     `_materializeExists` would have written a literal `""` into the row
///     the moment `user_apps` became syncable. (It is `canSync == false`
///     today, which is the only reason this was latent rather than live.)
///   * **`DEFAULT NULL`.** Reported as the four-character string `NULL`, so
///     the old parser produced `int.tryParse('NULL') ?? 0` == `0` on an
///     INTEGER column. Treated here as equivalent to no default declared,
///     which is what SQLite itself does.
///   * **Non-literal defaults** (`CURRENT_TIMESTAMP`, a parenthesised
///     expression, a function call). SQLite evaluates these at INSERT time
///     and this function cannot; they now return `known: false`. No
///     sync-scope column declares one today.
({bool known, Object? value}) decodeShellRowDefault(
  Map<String, Object?> columnInfo,
) {
  final type = (columnInfo['type'] as String? ?? '').toUpperCase();
  final isInt = type.contains('INT');
  final isReal =
      type.contains('REAL') || type.contains('FLOA') || type.contains('DOUB');
  final notNull = (columnInfo['notnull'] as int? ?? 0) != 0;

  // What the column holds when no default applies: NULL if it may be, else
  // a type-appropriate empty value (a NOT NULL column has to hold
  // something, and every such column in sync scope is corrected in place by
  // its own field operation moments later).
  Object? implicit() {
    if (!notNull) return null;
    if (isInt) return 0;
    if (isReal) return 0.0;
    return '';
  }

  final raw = columnInfo['dflt_value'] as String?;
  if (raw == null) return (known: true, value: implicit());
  final text = raw.trim();
  if (text.toUpperCase() == 'NULL') return (known: true, value: implicit());

  final unquoted = _unquoteSqlStringLiteral(text);
  final literal = unquoted ?? text;

  if (isInt) {
    final parsed = int.tryParse(literal);
    return parsed == null
        ? (known: false, value: implicit())
        : (known: true, value: parsed);
  }
  if (isReal) {
    final parsed = double.tryParse(literal);
    return parsed == null
        ? (known: false, value: implicit())
        : (known: true, value: parsed);
  }
  if (unquoted != null) return (known: true, value: unquoted);

  // An untyped/TEXT column with an unquoted default: a bare number is a real
  // literal; anything else is an expression this function cannot evaluate.
  final asInt = int.tryParse(text);
  if (asInt != null) return (known: true, value: asInt);
  final asDouble = double.tryParse(text);
  if (asDouble != null) return (known: true, value: asDouble);
  return (known: false, value: implicit());
}

/// Strips the quotes from a SQL string literal, unescaping the doubled
/// quote form (`'it''s'`). Returns null if [text] is not a quoted literal.
///
/// Both quote characters are accepted: SQLite's own dialect treats a
/// double-quoted token as an identifier first and silently degrades it to a
/// string literal when no such column exists, which is how `DEFAULT ""` ends
/// up in this codebase's schema at all.
String? _unquoteSqlStringLiteral(String text) {
  if (text.length < 2) return null;
  final quote = text[0];
  if (quote != "'" && quote != '"') return null;
  if (!text.endsWith(quote)) return null;
  return text
      .substring(1, text.length - 1)
      .replaceAll('$quote$quote', quote);
}

/// Per-table overrides of [shellRowPlaceholderValue] — columns a shell-row
/// INSERT deliberately writes at something other than the column's own
/// declared default.
///
/// **`tags.__deleted__` is the one entry, and leaving it out would be a
/// real, silent data-loss bug rather than a missed optimization.**
/// `_materializeExists` forcibly writes `__deleted__ = 1` for a brand-new
/// `tags` shell row regardless of the column's SQL default of `0` (see
/// `materializer.dart`'s own doc comment on `idx_tags_name_live`: a raw-live
/// placeholder `name = ''` would occupy the partial unique index's slot for
/// `''`). So a live tag's `__deleted__ = 0` is NOT what the receiving
/// device's row already holds — it is the opposite — and skipping its seed
/// on the grounds that `0` "is the default" would leave every seeded tag
/// permanently tombstoned on every peer.
const Map<String, Map<String, Object?>> _shellRowForcedValues = {
  'tags': {'__deleted__': 1},
};

/// The forced shell-row column values for [table] — empty for every table
/// but `tags`. `materializer.dart`'s `_materializeExists` applies these on
/// top of the per-column [shellRowPlaceholderValue]s it just computed.
Map<String, Object?> shellRowForcedValuesFor(String table) =>
    _shellRowForcedValues[table] ?? const {};

/// What a receiving device's row for [table] will hold for [column] before
/// that column's own `field` operation has arrived — the column's shell-row
/// placeholder, with any per-table forced override applied.
///
/// Returns `known: false` when the answer is not certain, which callers must
/// treat as "cannot skip" rather than as any particular value. Three ways
/// that happens: the column is absent from [columns]; its default is not a
/// statically resolvable literal ([decodeShellRowDefault]); or a forced
/// override names a column this table does not have.
///
/// **The column-presence check is applied to the forced override too, and
/// that ordering is deliberate.** `_materializeExists` applies its forced
/// values on top of a row map that only ever contains `syncScopeColumns`
/// entries, i.e. `if (row.containsKey(...))`. Today's sole override
/// (`tags.__deleted__`) is in scope, so an unconditional lookup here would
/// agree with it — but only by luck. A future override naming a column
/// outside `syncScopeColumns` would be silently ignored by the materializer
/// and silently honoured here, breaking the agree-by-construction guarantee
/// this whole extraction exists to provide, in the one direction that loses
/// data (a skip against a value the receiving row never takes).
({bool known, Object? value}) shellRowValueFor({
  required String table,
  required String column,
  required List<Map<String, Object?>> columns,
}) {
  Map<String, Object?>? info;
  for (final candidate in columns) {
    if (candidate['name'] == column) {
      info = candidate;
      break;
    }
  }
  if (info == null) return (known: false, value: null);

  final forced = _shellRowForcedValues[table];
  if (forced != null && forced.containsKey(column)) {
    return (known: true, value: forced[column]);
  }
  return decodeShellRowDefault(info);
}

/// The bare-membership sentinel: the `set_add` payload for a membership
/// table with no [SyncSetCaptureScope.payloadColumns] at all (`note_tags`/
/// `conversation_tags`, whose two id columns ARE the whole row).
const String bareMembershipPayloadJson = 'true';

/// Encodes one membership row's add-event payload — the values of
/// [SyncSetCaptureScope.payloadColumns], in the scope's own declared order
/// (fixed in source, so two devices holding the same logical row always
/// produce the same string), or [bareMembershipPayloadJson] when the table
/// has none.
///
/// **Two independent consumers, and it matters that they agree.**
///  * `seed_scanner.dart` folds this into the seed's GENESIS `contentKey`
///    (§ Architecture 1's round-14 conversation-mapping correction: a
///    mapping's `createdAt` is real add-event data, and leaving it out of
///    the key would make two replicas with genuinely different historical
///    orderings dedup into one dot, permanently discarding one device's
///    real history).
///  * `materializer.dart` reads it back to fill the membership table's own
///    `NOT NULL` payload columns on the receiving device. This is the
///    reason the value is CARRIED on the operation rather than only hashed
///    into the key — an earlier version of this comment claimed the value
///    had to travel so the dedup-deciding fact stayed recoverable, which
///    was simply wrong: `contentKey` is itself transmitted
///    (`wire_format.dart`'s envelope), so that fact always travelled.
///    Materialization is the real reason, and without it the receiving
///    device has no value to write.
String encodeSetAddPayloadJson(
  SyncSetCaptureScope scope,
  Map<String, Object?> row,
) {
  if (scope.payloadColumns.isEmpty) return bareMembershipPayloadJson;
  return jsonEncode({
    for (final column in scope.payloadColumns) column: row[column],
  });
}

/// Decodes what [encodeSetAddPayloadJson] produced. Returns an empty map
/// for the bare-membership sentinel, for a `null` value (an operation
/// minted before M2.10 carried a payload at all), or for anything not
/// shaped like an object — a receiving device must never throw on an
/// operation an older or newer build wrote.
Map<String, Object?> decodeSetAddPayload(String? valueJson) {
  if (valueJson == null) return const {};
  final Object? decoded;
  try {
    decoded = jsonDecode(valueJson);
  } on FormatException {
    return const {};
  }
  if (decoded is! Map) return const {};
  return decoded.cast<String, Object?>();
}

/// A membership row's own surrogate `TEXT PRIMARY KEY`, where its table has
/// one (`message_parents.id`), derived deterministically from the two ids
/// the membership actually consists of.
///
/// Deterministic rather than a fresh uuid so that two devices materializing
/// the same logical membership produce the same row, and so that
/// re-materializing is naturally idempotent against the table's own
/// `UNIQUE(entityId, memberId)` constraint. **Deliberately not part of any
/// `contentKey`**: the origin device's real local `id` is a locally
/// generated uuid, so folding it in would give two devices seeding the same
/// logical parent-edge different keys and defeat GENESIS convergence for
/// `message_parents` entirely.
String deterministicMembershipRowId({
  required String membershipTable,
  required String entityId,
  required String memberUuid,
}) => sha256
    .convert(utf8.encode('$membershipTable:$entityId:$memberUuid'))
    .toString();
