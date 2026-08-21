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
  /// neither the id, the createdAt-equivalent, nor in `syncScopeColumns` —
  /// typically an owner FK (`subnotes.noteId`, `app_revisions.appId`) or a
  /// required identity column (`user_apps.uuid`). No operation this
  /// protocol carries can ever supply it, so a receiving device can never
  /// build the row.
  unresolvableColumn,
}

/// Whether an entity table's rows can be created on a device that has only
/// ever seen this protocol's operations — and if not, why, and which column
/// is responsible.
class EntitySyncability {
  const EntitySyncability.ok() : blocker = null, blockingColumn = null;
  const EntitySyncability.blocked(this.blocker, this.blockingColumn);

  final EntitySyncBlocker? blocker;
  final String? blockingColumn;

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
/// receiving end; M2.10 makes it gate MINTING too.** Of the fourteen
/// sync-scope entity tables, six can never materialize on a peer — each
/// blocked by a `NOT NULL` column outside sync scope — and two more have
/// non-portable ids. Before this gate, those eight still minted operations,
/// pushed them, occupied backend log space, and produced a permanent
/// `missing_exists` queue row per field on *every* peer, *forever*: a
/// backlog that could never drain because the prerequisite it waits for can
/// never arrive. Gating the mint deletes that entire class.
///
/// The check is derived from `PRAGMA table_info` rather than a hardcoded
/// list, so a table that becomes syncable (by acquiring a default, or by
/// having its owner FK brought into sync scope) starts syncing with no code
/// change — and one that regresses stops, loudly, via the audit test.
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

  final createdAtColumn = syncEntityCreatedAtColumnByTable[scope.table];
  for (final column in columns) {
    final name = column['name'] as String;
    if (name == scope.idColumn) continue;
    if (name == createdAtColumn) continue;
    if (scope.syncScopeColumns.contains(name)) continue;
    final notNull = (column['notnull'] as int? ?? 0) != 0;
    final hasDefault = column['dflt_value'] != null;
    if (notNull && !hasDefault) {
      return EntitySyncability.blocked(
        EntitySyncBlocker.unresolvableColumn,
        name,
      );
    }
  }
  return const EntitySyncability.ok();
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
