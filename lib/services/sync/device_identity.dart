// Device identity — M2.3, § Architecture 11.1 ("Device identity and dataset
// bootstrap") of the CRDT-cloud-sync design
// (`plan-and-propse-the-glistening-dolphin.md`). This is the very first
// piece of sync-engine state anything else in M2.3-M2.8 depends on: every
// `authorId` namespace this device will ever mint operations under
// (ordinary `device_id`, `"seed:" + device_id`, `"external:" + device_id`)
// is built on top of the single stable id this file generates exactly once.
//
// `sync_state` (`database_service.dart`'s `_createSyncStateTable`) is a flat
// `(key TEXT PRIMARY KEY, value TEXT)` store — this class owns exactly one
// key, `device_id`, per § 11.1's "Proposed sync_state keys" list.

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database_service.dart';

/// The single `sync_state` key [DeviceIdentity] owns, named at top level
/// (M2.13) so `dataset_reset.dart` can read the outgoing id before clearing
/// it without re-typing the string.
const String deviceIdStateKey = 'device_id';

/// Generates and durably persists this installation's stable device
/// identity — a `Uuid().v4()`, generated exactly once, on first touch of the
/// sync engine (§ 11.1). Every subsequent call, from this process or a
/// future one, returns the same value without regenerating.
///
/// **Race safety.** [ensureDeviceId] must be safe to call from multiple
/// places without a race — two concurrent first-touches must not produce
/// two different ids. This is achieved with the transaction + `INSERT OR
/// IGNORE`-then-read pattern the M2.3 brief calls for: the read, the
/// (possibly no-op) insert, and the re-read that returns the authoritative
/// value all happen inside one `sync_state` transaction. sqflite already
/// fully serializes transactions against the same connection (single-writer
/// lock — see `deleteNote`'s doc comment in `database_service.dart` for the
/// same reasoning applied elsewhere in this codebase), so two overlapping
/// calls to this method are never actually interleaved mid-transaction; the
/// `INSERT OR IGNORE` + re-read shape is kept anyway so correctness does not
/// depend on that scheduling detail — if two transactions somehow *did*
/// race on `key = 'device_id'` (a `PRIMARY KEY` collision on the second
/// writer's plain `INSERT`), `OR IGNORE` turns that into a silent no-op
/// instead of a thrown constraint-violation, and the following `SELECT`
/// always returns whichever value actually won, regardless of which
/// transaction's own locally-generated uuid that was.
///
/// **"Exactly once" is now "exactly once per identity generation."** M2.13's
/// `DatasetReset` retires this device's id and clears the row, so the next
/// call here mints a fresh one — see `dataset_reset.dart`'s option-(c)
/// argument for why a reset must not continue or restart the old counter.
/// Nothing about the race argument above changes; what changes is that a
/// physical device can, over its lifetime, own more than one identity, and
/// § Architecture 2's "devices ever, including retired ones" bound now
/// counts reset generations too.
class DeviceIdentity {
  DeviceIdentity(this._databaseService);

  final DatabaseService _databaseService;

  static const _deviceIdKey = deviceIdStateKey;

  /// In-memory cache for the lifetime of this instance — device identity is
  /// immutable once minted, so there is no reason to re-hit the database on
  /// every call. Mirrors `GoogleDriveBackend._rootFolderId`'s caching
  /// pattern for the analogous "resolve once, reuse for this instance's
  /// lifetime" case.
  String? _cached;

  /// Returns this device's stable identity, generating and persisting it on
  /// first call if it doesn't exist yet. Safe to call concurrently and
  /// repeatedly; see the class doc comment for the race-safety argument.
  Future<String> ensureDeviceId() async {
    final cached = _cached;
    if (cached != null) return cached;

    final db = await _databaseService.database;
    late final String resolved;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'sync_state',
        where: 'key = ?',
        whereArgs: [_deviceIdKey],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        resolved = existing.first['value'] as String;
        return;
      }

      final candidate = const Uuid().v4();
      await txn.insert('sync_state', {
        'key': _deviceIdKey,
        'value': candidate,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

      // Re-read rather than trusting `candidate` directly — see the class
      // doc comment: this is what makes the outcome correct even if some
      // future scheduling change ever let two transactions race on this
      // key, without this method needing to know which one actually won.
      final after = await txn.query(
        'sync_state',
        where: 'key = ?',
        whereArgs: [_deviceIdKey],
        limit: 1,
      );
      resolved = after.first['value'] as String;

      // § 11.1's "Device labels" note: "After minting device_id, this
      // device should insert its own isCurrentDevice = 1 row." Only done in
      // the branch that actually minted a new id — an already-existing
      // device_id means this row was already inserted by whichever earlier
      // call (this process or an earlier one) first created it.
      // `OR IGNORE` here too: harmless if, despite the above, this branch
      // is somehow re-entered for an id that already has a label row (e.g.
      // a pre-M2.3 database that already had a device_id but no label row —
      // not expected, but not worth a special case to rule out).
      await txn.insert('sync_device_labels', {
        'deviceId': resolved,
        // No settings UI exists yet to let the user name this device (§
        // 11.1: "not obviously in scope for this section's... machinery
        // ... belongs with § Architecture 9's settings-UI wiring").
        // Falling back to the raw id is the same fallback the design doc
        // names for *other* devices' labels before that UI exists; using
        // it here too keeps this device's own row consistent with that
        // documented gap instead of inventing a different placeholder.
        'label': resolved,
        'isCurrentDevice': 1,
        'retiredAt': null,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });

    _cached = resolved;
    return resolved;
  }
}
