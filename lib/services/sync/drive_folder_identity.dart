// Durable identity of the Drive folder that holds one dataset — M2.11,
// § Architecture 8.1/8.4 and § 11.1.
//
// ---------------------------------------------------------------------
// **Why this file exists: a folder resolved by NAME is not an identity.**
// ---------------------------------------------------------------------
// Until M2.11, `GoogleDriveBackend` found its sync root by listing folders
// called `'Note Synapse Sync'` and, on more than one match, taking
// `existing.first.id`. Three separate defects fell out of that, and all
// three are properties of name-resolution itself rather than bugs in the
// listing code:
//
//   1. The name was a hardcoded string the user never chose, so every
//      dataset landed in one fixed place in Drive's root.
//   2. Two folders sharing the name — one made by hand, one left by an
//      earlier run, one left by a Drive cleanup — resolved arbitrarily, and
//      *which* one won could differ between runs and between devices. Two
//      devices resolving differently is a silent split-brain: each syncs
//      happily against a different dataset and neither ever notices.
//   3. Resolution was re-done from the name on every run, so renaming the
//      folder in Drive orphaned the dataset: the app created a fresh empty
//      one beside it and (before M2.13) marked itself Ready against it.
//
// The fix is to stop treating the name as the identity. Drive's file id is
// the identity; it is stable across renames and moves, and it is what every
// call after the first addresses. The name survives only as (a) a
// creation-time convenience so the folder is called something the user
// picked, and (b) the one-shot discovery key used at first setup and by the
// upgrade path, where there is no id yet.
//
// ---------------------------------------------------------------------
// **The coupling between those two roles, stated once, here.**
// ---------------------------------------------------------------------
// (a) and (b) are not independent, and the milestone talks about them as
// though they were: "the name is just a convenience" is true of a folder
// that already has an id recorded, and false of every device that does not
// yet have one. Concretely: **two devices whose users choose different
// folder names never discover each other and never converge.** Device A
// creates "Bruce's Notes"; device B, set up by name, looks for whatever B's
// user typed, finds nothing, creates its own, is told it created one, and
// syncs a second dataset forever. Nothing detects this, because from each
// device's position everything worked.
//
// It is disclosed rather than mechanised, because the alternatives are all
// worse: a fixed, non-user-visible name is defect 1 again; searching every
// `datasetRoot`-tagged folder regardless of name makes any second dataset
// (deliberate or leftover) ambiguous for everyone; and there is no
// server-side registry to consult. What the design does instead is make
// the ID the recommended path and say so in the UI — `cloudSyncFolderNameHelp`
// tells the user that a second device can only find the folder by name if
// it is given the same name, and `cloudSyncFolderJoinHelp` names the ID as
// the dependable route — and make the wrong outcome visible after the fact
// via the created-vs-joined line on the settings screen, which is the same
// mechanism the unverified `drive.file` listing question relies on.
//
// ---------------------------------------------------------------------
// **Where it lives, and why not in `sync_backend.dart`.**
// ---------------------------------------------------------------------
// "Root folder" is a backend-implementation concept, not a `SyncBackend`
// one: § 8.1 scopes a backend instance to "one already-configured
// connection to one already-selected root location", and connection setup
// is explicitly outside the interface. The conformance suite runs unmodified
// against `MockSyncBackend`, `GoogleDriveBackend` and (later) a WebDAV
// backend, so nothing here may appear on `SyncBackend`. It is injected into
// `GoogleDriveBackend`'s constructor instead, exactly like its
// `OAuthTokenManager` and `http.Client`.
//
// The store is an interface rather than a direct `DatabaseService`
// dependency for the same reason: `GoogleDriveBackend` has never depended on
// SQLite and giving it one for two key/value rows would make every backend
// test carry a database. [InMemoryDriveFolderIdentityStore] is the default,
// which keeps this class's pre-M2.11 behaviour (resolve once per instance,
// cache in memory) for every caller that doesn't ask for durability.

import 'package:sqflite/sqflite.dart';

import '../database_service.dart';

/// `sync_state` key holding the Drive file id of this dataset's root folder.
///
/// **Authoritative once written.** After it exists, the folder is addressed
/// by id on every call and the name is never consulted for resolution again
/// — which is what makes renaming or moving the folder in Drive harmless.
///
/// Declared at top level alongside the other `sync_state` key constants
/// (`datasetBootstrapStatusKey`, `syncHealthStateKey`,
/// `divergedAuthorLogsStateKey`, `postResetRecessiveSeedStateKey`) because
/// more than one file reads it: the store below writes it, and
/// `dataset_reset.dart` names it in its preserved-key list.
///
/// **No schema migration was needed for this**, and none should be added:
/// `sync_state` is a deliberately open `(key TEXT PRIMARY KEY, value TEXT)`
/// store (`database_service.dart`), which is exactly the flexibility its own
/// doc comment says it exists to provide.
const String driveRootFolderIdStateKey = 'drive_root_folder_id';

/// `sync_state` key holding the folder name the user chose at setup.
///
/// **Display and creation only — never load-bearing for resolution once
/// [driveRootFolderIdStateKey] is set.** It is read in exactly two places:
/// as the name to give a folder this device is about to create, and as the
/// one-shot discovery key on a device that has no id yet (first setup, or
/// the upgrade path for an install that predates M2.11).
const String driveRootFolderNameStateKey = 'drive_root_folder_name';

/// The default folder name, used when the user has not chosen one.
///
/// **Deliberately NOT localized, and that is a correctness decision rather
/// than a translation oversight.** This string is (a) the name an existing,
/// pre-M2.11 install's folder actually has in Drive, so the upgrade path in
/// `GoogleDriveBackend._findRootFolder` must search for this exact literal,
/// and (b) the discovery key a second device would search for if it ever
/// sets up by name. A localized default would mean a phone in Chinese and a
/// phone in English looked for two different folders and each created its
/// own — the split-brain this milestone exists to remove, reintroduced by a
/// translation file. The UI around the field is localized; the default value
/// in it is not.
const String defaultDriveRootFolderName = 'Note Synapse Sync';

/// The durable identity of one dataset's Drive root folder.
///
/// Both fields are nullable and the two are independently set: a user can
/// pick a name at setup before any folder exists ([folderId] still null),
/// and an id can be adopted directly from a pasted folder id without the
/// name being known ([folderName] still null, filled in from Drive).
class DriveFolderIdentity {
  const DriveFolderIdentity({this.folderId, this.folderName});

  /// Drive's file id for the root folder. Authoritative once non-null.
  final String? folderId;

  /// The name the folder was created with / was last seen under. Never used
  /// to resolve once [folderId] is known.
  ///
  /// **"Last seen under" is now literally true** —
  /// `GoogleDriveBackend._findRootFolder` refreshes this from what Drive
  /// reports whenever the id resolves to a differently-named folder. It was
  /// not true as originally shipped (a rename in Drive left the settings
  /// screen showing the old name forever, and would have re-created a
  /// deleted folder under a name the user had moved away from), which is
  /// why the claim is called out rather than assumed.
  final String? folderName;

  static const DriveFolderIdentity empty = DriveFolderIdentity();

  bool get isEmpty => folderId == null && folderName == null;

  /// Field-wise update. A null argument means "leave this field alone",
  /// which is what makes `copyWith(folderName: x)` safe to call on a device
  /// that already has an id.
  ///
  /// **[clearFolderId] exists because null cannot mean two things.** Review
  /// round 2 (finding F1) found that no caller anywhere could express
  /// "forget the recorded id": `disconnect`, `resetSyncState` and the folder
  /// dialog all left it in place, so a valid-but-wrong pasted id welded the
  /// device to the wrong dataset with no way back short of reinstalling.
  /// `DriveFolderIdentityStore.write` has always cleared a null field — the
  /// gap was purely that nothing could *build* the cleared value from an
  /// existing one.
  DriveFolderIdentity copyWith({
    String? folderId,
    String? folderName,
    bool clearFolderId = false,
  }) => DriveFolderIdentity(
    folderId: clearFolderId ? null : (folderId ?? this.folderId),
    folderName: folderName ?? this.folderName,
  );

  @override
  String toString() =>
      'DriveFolderIdentity(folderId: $folderId, folderName: $folderName)';
}

/// Durable home for a [DriveFolderIdentity].
///
/// Deliberately tiny and backend-shaped rather than database-shaped, so
/// `GoogleDriveBackend` can take one without taking a `DatabaseService`.
abstract class DriveFolderIdentityStore {
  Future<DriveFolderIdentity> read();

  /// Replaces the stored identity wholesale. A null field clears its row —
  /// callers that mean to change one field pass
  /// `(await read()).copyWith(...)`.
  Future<void> write(DriveFolderIdentity identity);
}

/// Process-lifetime store — the default when no durable one is injected.
///
/// This is exactly `GoogleDriveBackend`'s pre-M2.11 behaviour (a
/// `String? _rootFolderId` field), which is why every existing test and the
/// conformance suite keep passing unmodified: without a durable store the
/// backend still resolves once per instance and caches, it just no longer
/// picks arbitrarily when the name is ambiguous.
class InMemoryDriveFolderIdentityStore implements DriveFolderIdentityStore {
  InMemoryDriveFolderIdentityStore([
    this._identity = DriveFolderIdentity.empty,
  ]);

  DriveFolderIdentity _identity;

  @override
  Future<DriveFolderIdentity> read() async => _identity;

  @override
  Future<void> write(DriveFolderIdentity identity) async {
    _identity = identity;
  }
}

/// The production store: two rows in `sync_state`.
class SyncStateDriveFolderIdentityStore implements DriveFolderIdentityStore {
  SyncStateDriveFolderIdentityStore(this._databaseService);

  final DatabaseService _databaseService;

  @override
  Future<DriveFolderIdentity> read() async {
    final db = await _databaseService.database;
    final rows = await db.query(
      'sync_state',
      columns: const ['key', 'value'],
      where: 'key IN (?, ?)',
      whereArgs: [driveRootFolderIdStateKey, driveRootFolderNameStateKey],
    );
    String? valueFor(String key) {
      for (final row in rows) {
        if (row['key'] == key) {
          final value = row['value'] as String?;
          return (value == null || value.isEmpty) ? null : value;
        }
      }
      return null;
    }

    return DriveFolderIdentity(
      folderId: valueFor(driveRootFolderIdStateKey),
      folderName: valueFor(driveRootFolderNameStateKey),
    );
  }

  @override
  Future<void> write(DriveFolderIdentity identity) async {
    final db = await _databaseService.database;
    await db.transaction((txn) async {
      await _put(txn, driveRootFolderIdStateKey, identity.folderId);
      await _put(txn, driveRootFolderNameStateKey, identity.folderName);
    });
  }

  Future<void> _put(DatabaseExecutor txn, String key, String? value) async {
    if (value == null) {
      await txn.delete('sync_state', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await txn.insert('sync_state', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
