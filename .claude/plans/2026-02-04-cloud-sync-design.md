# Cloud Sync Design

Optional cloud sync for Note-Synapse. Local-first, BYOK, no server infrastructure. Users choose their own cloud storage provider.

## Principles

- Local DB is always the authority; remote is untrusted transport
- Remote corruption must never cascade to corrupt local state
- Encryption on by default to protect the weakest link in the device chain
- Open spec in every sync root so users can reconstruct their data without Note-Synapse
- BYOK: users supply their own cloud credentials and storage

## Sync Scope

**Continuously synced (oplog):**
- notes, subnotes, tags, note_tags, relationships
- conversations, conversation_messages, conversation_message_mapping, message_parents, conversation_note_mapping, conversation_tags
- attachments, conversation_attachments

**Packaged (manual export/import):**
- user_apps, app_revisions, user_app_libraries, user_app_library_dependencies
- Bundled as extended YAML + zip archives (reuses existing export format)

**Local only:**
- filters, multi_function_apps, _schema_version

## Sync Topology

Single-user, multi-device. One person syncing their own data across devices. Extensible later to read-only / limited-edit sharing with others (publish/subscribe model, no real-time CRDT needed).

## Storage Providers

### Provider Abstraction

```dart
abstract class SyncStorageProvider {
  Future<List<SyncFileInfo>> listFiles(String path);
  Future<Uint8List> readFile(String path);
  Future<void> writeFile(String path, Uint8List data);
  Future<void> deleteFile(String path);
  Future<bool> exists(String path);
  Future<SyncFileInfo> getFileInfo(String path);
}
```

### Implementations (priority order)

1. **FolderSyncProvider** -- reads/writes to a local directory (iCloud Drive folder, FolderSync-managed folder). Just `dart:io` file operations.
2. **WebDavSyncProvider** -- HTTP calls to a WebDAV endpoint (Nextcloud, Synology, etc.). Uses existing `rhttp` networking stack. User provides URL + username + password.
3. **OAuthCloudProvider** (future) -- Google Drive / Dropbox API. User supplies their own client ID + client secret (BYOK model, no dependency on Note-Synapse developer accounts).

### Platform considerations

| Platform | Primary path | Storage isolation |
|---|---|---|
| iOS | App's own iCloud container (`NSUbiquitousContainerIdentifier`) | Isolated from other apps |
| iOS (cross-platform) | Shared iCloud Drive folder | Exposed to other apps |
| Android | FolderSync to shared storage | Exposed to other apps |
| WebDAV | Remote server | Network-exposed |

iOS setup flow leads with the iCloud container option (simpler, more secure). Custom folder is an advanced alternative.

## Remote Storage Layout

```
<sync-root>/
├── SYNC_SPEC.md                              # Open spec (always unencrypted)
├── sync-config.json                          # Encryption flag, schema version, spec version
├── meta/
│   └── device-registry.json                  # Known devices + last-seen sequence + schema version
├── oplog/
│   ├── <deviceId>-<seqStart>-<seqEnd>.json   # Batched operations per sync cycle
│   └── ...
├── snapshots/
│   ├── latest.json                           # Full state snapshot
│   └── <timestamp>.json                      # Historical snapshots (prunable)
├── attachments/
│   ├── <uuid>.ext                            # Immutable binary blobs
│   └── ...
└── apps/
    └── <app-uuid>.zip                        # Packaged user apps
```

## Oplog Design

### Operation format

```json
{
  "id": "<uuid>",
  "deviceId": "<device-uuid>",
  "sequence": 42,
  "timestamp": "2026-02-04T10:30:00Z",
  "table": "notes",
  "rowId": "17",
  "action": "insert | update | delete",
  "fields": {
    "title": { "value": "My Note", "minVersion": 1 },
    "metadata": { "value": "{...}", "minVersion": 32 }
  },
  "schemaVersion": 36
}
```

### Key properties

- **`sequence`**: per-device monotonic counter. Total order within a device, partial order across devices.
- **`fields` with `minVersion`**: each field declares the minimum schema version needed to interpret it. Devices below that version preserve but don't apply the field.
- **Batching**: one sync cycle = one file containing an array of ops, named `<deviceId>-<seqStart>-<seqEnd>.json`.

### Merge rules

1. **Insert**: create the row, apply known fields, defer unknown fields.
2. **Update**: field-level merge. Different fields changed on different devices = both apply. Same field = highest timestamp wins. Timestamp tie = highest deviceId (lexicographic) as tiebreaker.
3. **Delete**: delete wins over update. Resurrect by re-creating.
4. **Conflict copies**: when same-field concurrent edits are detected, the "losing" value is saved as a conflict record for user review.

## Schema Version Handling

Devices running different schema versions can coexist:

### Existing table, new fields (common case)
- Device applies ops for fields it understands, ignores unknown fields
- Unknown field values are preserved in the oplog, not lost
- On upgrade, device replays deferred field values

### New table (rare case)
- Device buffers the entire op
- All ops referencing the new table are from the same or higher schema version, so they buffer as a group
- On upgrade, device replays all buffered ops in sequence order

### Snapshot compaction
- Only the device with the highest schema version may compact
- If oplog exceeds a threshold and current device isn't the latest version, surface a notification: "Update the app on this device to optimize sync"

### Field Version Registry

Static mapping of (table, field) -> minVersion, maintained alongside migration code:

```dart
// lib/services/sync/field_version_registry.dart
const fieldVersionRegistry = {
  'notes': {
    'id': 1, 'title': 1, 'content': 1, 'type': 1,
    'createdAt': 1, 'updatedAt': 1, 'pinned': 1,
    'isArchived': 1, 'scheduledAt': 8, 'completeBy': 12,
    'status': 15, 'completionPercentage': 15,
    'recurrenceRule': 28,
    // ... etc
  },
  'attachments': {
    'id': 1, 'noteId': 1, 'filePath': 1, 'fileName': 1,
    'fileType': 1, 'isRelativePath': 18,
    'includeInAIContext': 24, 'metadata': 32,
  },
  // ... every synced table
};
```

**Enforced by unit tests**: introspect live SQLite schema via `PRAGMA table_info()`, compare against registry, fail if any synced column is missing. Also verify no `minVersion` exceeds current `DATABASE_VERSION`.

**Maintenance rule recorded in CLAUDE.md**: when adding a database migration that introduces new columns, update the field version registry.

## Local Change Tracking

SQLite triggers on all synced tables, created only when sync is enabled:

```sql
CREATE TABLE sync_changelog (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name TEXT NOT NULL,
  row_id TEXT NOT NULL,
  action TEXT NOT NULL,       -- insert, update, delete
  changed_fields TEXT,        -- JSON: field names that changed
  old_values TEXT,            -- JSON: previous values (for conflict detection)
  timestamp TEXT NOT NULL,
  pushed INTEGER DEFAULT 0    -- 0 = pending, 1 = pushed
);
```

Triggers use `OLD` and `NEW` to detect which columns actually changed, producing minimal diffs. Pushed rows are periodically pruned.

When sync is disabled, triggers are dropped. No overhead for non-sync users.

## Encryption

### Sync-root level (no mixed mode)

Encryption is a property of the sync root, not individual devices. All data in the root is either encrypted or not. `sync-config.json` and `SYNC_SPEC.md` are always unencrypted.

### Default: ON

Setup wizard presents "Set a sync passphrase" as the primary step. "Skip encryption" is available but de-emphasized with a clear warning: only safe if all devices use isolated storage (e.g., iOS-only with iCloud container).

### Key derivation

- **KDF**: Argon2id (NIST-compliant)
- **Cipher**: pluggable, identified by string in `sync-config.json`
- **Salt**: random, stored in `sync-config.json`
- **KDF params**: stored in `sync-config.json` for reproducibility

### Supported ciphers (ship with at least two)

| Cipher ID | Algorithm | Status |
|---|---|---|
| `aes-256-gcm` | AES-256-GCM | Default |
| `xchacha20-poly1305` | XChaCha20-Poly1305 | Alternative / fallback |

Having two ciphers from day one means if one is compromised, the user can rotate immediately from sync settings -- no app update needed.

### Cipher rotation

Available in sync settings as "Change encryption cipher":
1. User selects a different cipher from the supported list
2. Device re-encrypts all remote data with the new cipher (same mechanism as unencrypted-to-encrypted upgrade)
3. Updates `sync-config.json` with new cipher ID + re-computed HMAC
4. Other devices pick up the change on next sync

If a completely new cipher is needed (not in the current build), that requires an app update first. But rotation between already-shipped ciphers is instant and user-initiated.

User's local DB is never at risk -- encryption is only for remote storage. Immediate rescue if a cipher is broken: rotate cipher in settings, or disable sync and wipe the remote sync root.

### Key storage

- Derived AES key stored in platform secure enclave (iOS Keychain / Android Keystore)
- Protected by biometric or device lock screen
- Passphrase itself is never stored -- only the derived key
- Recovery: re-enter passphrase on new device to re-derive the same key

### Cross-platform safety

If any device in the chain uses shared storage (Android FolderSync, shared iCloud Drive folder), encryption must be on from the start. Since FolderSync pulls files before Note-Synapse launches, reactive encryption leaves a window of exposure. Encryption-by-default eliminates this.

### Anti-downgrade protection

Prevents an attacker with sync-root access from flipping encryption to "none" and tricking a device into pushing unencrypted data.

**Defense 1 -- Local authority over encryption mode.** After initial setup, the device stores the encryption setting locally in secure storage alongside the derived key. On subsequent syncs, the device uses its LOCAL setting, never the remote config. If the remote `sync-config.json` disagrees with the local setting, the device refuses to sync and alerts: "Sync configuration has changed unexpectedly. Sync halted."

**Defense 2 -- HMAC on `sync-config.json`.** The config includes a signature computed with the derived key:

```json
{
  "specVersion": 1,
  "encryption": "aes-256-gcm",
  "kdf": "argon2id",
  "kdfParams": { "memory": 65536, "iterations": 3, "parallelism": 4 },
  "salt": "<base64>",
  "schemaVersion": 36,
  "hmac": "<HMAC-SHA256 of all above fields, keyed with derived AES key>"
}
```

- Every device verifies the HMAC before trusting the config
- New device joining: reads KDF params, asks user for passphrase, derives key, verifies HMAC. If HMAC fails, config has been tampered with -- abort setup.
- Attacker cannot forge the HMAC without the passphrase
- Existing devices ignore remote config changes entirely (local authority), so even a perfectly forged config has no effect

### Encryption upgrade path

**Pre-populated crypto scaffolding.** `sync-config.json` always includes KDF params and a pre-generated salt, even when encryption is `"none"`. This makes upgrading a matter of "derive key, encrypt files, flip the flag" with no structural changes.

```json
{
  "specVersion": 1,
  "encryption": "none",
  "kdf": "argon2id",
  "kdfParams": { "memory": 65536, "iterations": 3, "parallelism": 4 },
  "salt": "<pre-generated at sync root creation>",
  "schemaVersion": 36
}
```

**Path 1 -- In-app upgrade (primary).** User enables encryption from sync settings on any device:
1. Set a passphrase, derive key using existing salt + KDF params
2. Re-encrypt all remote data in place (snapshot, oplog files, attachments)
3. Update `sync-config.json`: set `encryption` to `aes-256-gcm`, add HMAC
4. Store derived key + encryption setting in local secure storage
5. Other devices on next sync: detect encryption change, prompt for passphrase, store locally

Must be done BEFORE adding a device on shared storage (e.g., Android via FolderSync) to avoid unencrypted data exposure.

**Path 2 -- Offline upgrade (emergency).** If the user has no device with the app but has the raw sync folder:
- `SYNC_SPEC.md` documents the full encryption procedure
- `sync-config.json` already has the KDF params and salt
- User (or a script) can: read the spec, choose a passphrase, derive a key, encrypt all files, update config, add HMAC
- No dependency on Note-Synapse software

## Attachment Sync

- Attachments are immutable blobs with UUID filenames (already the case)
- Synced as individual files under `<sync-root>/attachments/<uuid>.ext`
- **Upload order**: attachment file first, then the oplog entry referencing it (no dangling references)
- **Pending downloads**: if an op references an attachment not yet downloaded, the op is applied locally and the attachment is marked pending
- **Deletion**: attachment files stay on remote until next compaction. Snapshot records which attachments are referenced; unreferenced files are garbage-collected.

## App Packages

Extends the existing YAML export format:

```yaml
name: My App
uuid: abc-123
app_type: normal
description: A cool app
author: John
license: MIT
app_state: <base64-encoded JSON blob>       # NEW
libraries:
  - name: chart.js
    instructions: |
      Usage instructions here
    dependencies:
      - link: https://original-url.com/chart.js
        blob: <base64-encoded bytes>         # NEW: inline blob
code: <base64-encoded HTML/JS>
```

Changes from current format:
- **`app_state`**: base64-encoded appState JSON
- **`blob` on dependencies**: inline library bytes as base64 (fallback to URL download if missing, for backward compat)
- **Single revision only**: current active revision's code, no history
- **Zipped**: YAML + any attachment files in a `.zip`
- **Multi-app export**: multiple YAML files in one zip

For sync: apps in `<sync-root>/apps/` are discoverable. Import is manual -- sync UI shows "N new apps available" for user to choose.

## Sync Engine Flow (Manual Trigger)

### Pull phase
1. Read `device-registry.json` from remote
2. List oplog files newer than last-seen sequence per device
3. Download new oplog files
4. Validate each file (JSON parse, checksum, schema version check)
5. Copy local DB to `sync_staging.db`
6. Replay valid ops against staging DB (field-level merge, conflict detection)
7. Record conflicts as conflict copies
8. Validate staging DB (integrity check)
9. Atomic swap: staging DB replaces live DB (WAL checkpointed first)
10. Download pending attachments

### Push phase
1. Collect local changes from `sync_changelog` (pending rows)
2. Write oplog batch file to remote
3. Upload new attachment files to remote
4. Update device sequence in `device-registry.json`
5. Mark changelog rows as pushed

### Compaction (conditional)
1. Only if this device has highest schema version AND oplog count exceeds threshold
2. Write full snapshot from current local state
3. Delete oplog files older than snapshot

### Crash safety
- Pull phase operates on `sync_staging.db`. If app crashes during steps 5-8, live DB is untouched. Leftover staging file is discarded on next launch.
- DB access is paused during atomic swap (natural since manual sync shows a progress screen).
- Push phase is idempotent -- partial push is harmlessly re-pushed next cycle.

## Device Identity

- Device UUID generated on first app launch, stored in secure storage
- Reinstalling the app = new device UUID (correct behavior: fresh install does full sync pull)
- New device joining: registers in device registry, pulls latest snapshot as baseline, replays newer oplog entries, starts writing from sequence 1

## Disaster Recovery

### "Reset sync from this device"
Escape hatch for scenarios like stolen device or OS-capped app version:
1. Takes full snapshot of current device's local DB
2. Uploads as new baseline snapshot
3. Clears the oplog
4. Other devices detect the reset on next sync and re-import from new snapshot

**Warning shown**: "This will replace all synced data with this device's current state. Unsynced changes on other devices will be lost."

### Corrupted remote data
- **Corrupted oplog file**: detected on parse, skipped, warning shown. Next compaction re-establishes clean baseline.
- **Missing oplog file**: detected by sequence gap. Same recovery.
- **Mangled oplog state**: fall back to "Reset sync from this device."

Core invariant: **remote data is untrusted input**. The sync engine validates before applying, applies in transactions, never deletes local data based solely on remote state.

### Import sync bundle

An alternative inbound path: user zips up their sync root (or receives it via USB, AirDrop, download from cloud storage) and imports it directly -- no sync provider setup needed. Useful for iOS-to-Android migration or when the user just wants a one-time transfer.

**Flow:**
1. User picks the zip file on the new device
2. App extracts to a temp directory
3. If encrypted, prompts for passphrase and verifies HMAC
4. Runs the standard pull phase against the extracted folder (staging DB, replay, validate, atomic swap)
5. Copies attachments to local storage
6. Cleans up temp directory
7. Optionally prompts: "Set up continuous sync from this device?"

Reuses the sync engine's pull phase pointed at a local folder. No new replay logic. Sits alongside the existing recovery screen as a sibling option.

## Open Sync Specification

`SYNC_SPEC.md` in every sync root (always unencrypted):

1. **Format version** -- spec revision
2. **Cipher registry** -- all supported cipher IDs, their algorithms, key sizes, IV/nonce generation, and encryption/decryption procedures. Documented so that any cipher used by any version of Note-Synapse can be reproduced independently.
3. **KDF spec** -- Argon2id parameters, salt encoding, how the encryption key is derived from a passphrase
4. **Oplog format** -- JSON schema, action semantics, merge rules
5. **Snapshot format** -- JSON schema, table-by-table structure, how to reconstruct SQLite from snapshot
6. **Attachment convention** -- naming, deduplication, GC rules
7. **Replay algorithm** -- step-by-step pseudocode for oplog-to-database reconstruction
8. **SQLite schema** -- full CREATE TABLE statements at the snapshot's schema version

Goal: someone with the sync folder, this spec, the passphrase, and a script can reconstruct their full database without Note-Synapse.

`sync-config.json` references the spec:
```json
{
  "specVersion": 1,
  "encryption": "aes-256-gcm",
  "kdf": "argon2id",
  "kdfParams": { "memory": 65536, "iterations": 3, "parallelism": 4 },
  "salt": "<base64>",
  "schemaVersion": 36
}
```

## Future Extensions

- **Event-driven sync (C)**: automate the manual trigger on meaningful events (note saved, app backgrounded) with debounce. The engine is the same; only the trigger changes.
- **OAuth providers**: Google Drive / Dropbox API with user-supplied client ID + secret. New `SyncStorageProvider` implementation, no engine changes.
- **Read-only sharing**: publish a snapshot + attachment bundle to a shared location. Recipient imports as read-only. No conflict resolution needed.
