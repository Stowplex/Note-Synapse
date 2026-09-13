# Cloud sync and indexing: existing-library release audit

Audited 2026-09-12 against the merged `origin/main` release history and the
cloud-sync/indexing implementation. The merge commit is `ffbf8ab`; the fixes
described below build on it. No production database or Drive dataset was used.

## Release OAuth configuration

The supplied installed-client JSON contains this public client ID:

```text
438894533578-g0tpgg76soku9srh76hj21p14to3kc4c.apps.googleusercontent.com
```

It matches `GoogleDriveClientConfig.releaseClientId`, Android release/profile
manifest placeholders, and the iOS Release/Profile callback configuration.
Debug uses a different client and callback, allowing the two Android variants
to coexist. The downloaded JSON was not copied into the repository.

The actual Android `processReleaseMainManifest` task passed and its merged
manifest registers the matching reversed-client-ID scheme. Xcode's resolved
Release build settings also contain the matching `GOOGLE_REVERSED_CLIENT_ID`.
These checks do not constitute a signed APK/IPA or a completed login test.

**Custom URI configuration resolved (owner-confirmed):** the owner confirmed
that **Advanced settings → Custom URI scheme** is now enabled for the Android
client. Retain the existing browser + PKCE flow and no-GMS implementation.
Enabling this setting is no longer an outstanding release action.

Before that change, an unauthenticated Google authorization preflight with
the release ID, configured redirect, `drive.file` scope, and PKCE returned
`400 invalid_request`: **“Custom URI scheme is not enabled for your Android
client.”** This is historical evidence, not the current configuration status.
The preflight has not been rerun since the owner's confirmation. Consent,
callback delivery, token refresh, and Drive access still need verification on
a signed release device. The JSON's `installed` key does not establish the
OAuth platform type; the server identified this registration as Android.

**Google's recommended Android approach:** Google Identity Services
`AuthorizationClient`, using the Android registration
whose package name and SHA-1 match the distributed app. Google recommends this
API for Drive permissions; Credential Manager serves the separate sign-in
purpose. After consent, subsequent `authorize()` calls can obtain access tokens
without interaction while permissions remain granted. Adopting this approach
would require adapting the current app-side refresh-token handling, including token
invalidation and cases requiring renewed consent. See
[Android's authorization guide](https://developer.android.com/identity/authorization).

**Repository constraint:** `google_drive_auth_service.dart` and
`test/no_gms_dependency_audit_test.dart` explicitly record a requirement to
operate without Google Play Services. `AuthorizationClient` requires Play
Services, so adopting it would change that supported-device requirement.
The current browser flow implements the no-GMS choice, with the custom-scheme
exception now enabled by the owner. No native-authorization migration is
required for this chosen approach.

The enabled **Advanced settings → Custom URI scheme** opt-in permits the
existing browser flow, but Google discourages it because custom schemes
allow app impersonation. It is an exception when the recommended API cannot
meet an app's needs, not the default release recommendation. See
[Google's Android custom-scheme policy](https://developers.googleblog.com/improving-user-safety-in-oauth-flows-through-new-oauth-custom-uri-scheme-restrictions/).

iOS requires its own iOS client registration and device verification; the
Android client ID currently copied into the iOS callback settings does not
satisfy that requirement. Registering a callback in Info.plist alone does not
prove Google will authorize it. See [Google's platform-client policy](https://developers.google.com/identity/protocols/oauth2/policies#register_an_appropriate_oauth_client).

## Upgrade and correctness fixes

Released `origin/main` migration numbers are preserved. The canonical order is:

| Versions | Migration family |
| --- | --- |
| Through 48 | Released main history; 47 is Spaces and 48 is app localization. |
| 49–63 | Cloud-sync schema, tombstones, guards, capture, and publication metadata. |
| 64 | Search chunks, embeddings, progress, and FTS tables. |
| 65 | Forward compatibility for earlier branch builds using the old numbering. |

A released database at version 48 upgrades directly to 49; it is never reinterpreted as 47.
Earlier branch databases retain their data and replay at most their last feature
step under the shifted numbering. Step 65 ensures their localization column and
capture trigger exist. Normal startup and backup recovery use the same sequence.

| Existing-library trigger | Problem | Result after the fixes |
| --- | --- | --- |
| Upgrade released main schema 48 | Main used version 48 for localization; the feature branch reused it for sync. | Keep released version 48 unchanged; apply sync 49–63 and indexing 64, then branch compatibility 65. |
| Several startup services open the database together | Separate open/backup/migration attempts could race. | Share one opening future; failed opens can be retried. |
| A reader prevents checkpointing recent committed WAL data | SQLite reports a busy checkpoint without throwing; copying only the main file could omit recent data from the safety backup. | Stop the upgrade before copying/migrating when checkpointing is busy or incomplete; retry safely after the lock clears. |
| Missing/empty version metadata, sentinel 999, or interrupted sync/index migration | Inferring completion from a handful of table names could skip required objects; replaying metadata migration could fail on an existing column. | Detect a conservative starting version and replay the idempotent sync/index steps. |
| Restore a database predating app UUID uniqueness | The old migration rebuilt `user_apps` using later columns and could rewrite child foreign keys to `user_apps_old`. | Enforce UUID uniqueness without that destructive rebuild; repair affected historical child definitions while preserving their actual data, indexes, triggers, and integer sequences. |
| Merge backups with the same tag name under different IDs | Imported memberships could reference a tag ID omitted during deduplication. | Carry an explicit backup-to-local tag ID map through note tags, conversation tags, and tag images. |
| First sync of old notes, messages, or app revisions | Creation dates were derived from first-sync time. | Carry original immutable dates in existence payloads; retain compatibility with older payloads. |
| Seed/drain/materialize a growing library | Casting primary keys to text disabled indexed lookup in repeated queries. | Use affinity-preserving primary-key lookups, verified with SQLite query plans. |
| A bulk import or cloud pull arrives during an index sweep | Coalescing into the current snapshot could permanently miss new rows until another event/restart. | Latch a follow-up completeness sweep. |
| Index large notes and annotations | Fingerprinting/chunking could block the UI isolate; annotation queries multiplied with attachment count. | Run CPU work in bounded workers, batch annotation ownership queries and chunk/FTS writes. |
| Large subnotes/annotations accompany a short note | Batch sizing counted only the note body. | Include child text in the batch estimate; one exceptionally large note still requires a batch of its own. |
| Existing large Unicode/NUL text or large policy metadata is read on Android | A result row could exceed CursorWindow limits, and character-based reads could truncate at NUL. | Read affected startup/index/extraction/embedding sources in bounded UTF-8 byte slices, preserving privacy metadata; abort failed snapshots rather than treating unreadable notes as absent. |
| Attachment rows contain old device absolute paths | Metadata could point outside the receiver's sandbox. | Copy accessible locally owned files into portable app storage, preserve originals, and reject absolute/traversal download destinations. |
| A file was already missing when its metadata first synced | No blob hash existed, so health could report success despite absent bytes; restoring the same path did not trigger another operation. | Report missing bytes even without a hash and publish a new operation when locally authored missing bytes become available. Published history stays unchanged. |
| A local app-code edit arrives during an older blob download | Finishing the download could overwrite the new local content. | Write only while the column remains empty and the same blob hash still wins. |
| Every PDF page fails extraction | A failed extraction could be marked complete and erase useful prior text. | Keep failure state retryable and preserve prior searchable content. |

The preceding merge also repaired atomic materialization/frontier handling,
missing OR-set dependency retries, chunked Unicode/large-value reads,
encrypted blob handling, blob-reference garbage collection, and stale index
or embedding writes after deletion/exclusion. Startup fingerprint sweeps
repair edits whose debounce was interrupted by shutdown. Regression coverage
exercises these behaviors with populated databases and simulated peers.

This retry guarantee covers the current-release-to-sync/index upgrade chain.
Some much older migrations (including 26, 28, 30, and 31) are not idempotent;
retrying an already partly migrated old backup can still require starting
again from the original backup copy. They are not exercised by a normal
released-schema-48 upgrade.

## Actual sync coverage and remaining gaps

Table names below are the real SQLite names, not model names. Sync is not a
complete backup of all application state.

| Data | Tables | Current behavior |
| --- | --- | --- |
| Notes, subnotes, tags, filters, relationships, workflow bindings | `notes`, `subnotes`, `tags`, `filters`, `relationships`, `tag_workflow_bindings` | Supported entity fields and tombstones sync. |
| Conversations and messages | `conversations`, `conversation_messages` | Supported entity fields and original creation dates sync. |
| Memberships and conversation structure | `note_tags`, `conversation_tags`, `conversation_note_mapping`, `conversation_message_mapping`, `message_parents` | Synced as OR-sets, not by transporting local autoincrement IDs. |
| Note/chat attachments | `attachments`, `conversation_attachments` | Metadata plus content-addressed file blobs; missing/inaccessible files cannot be reconstructed by metadata alone. |
| User apps and revision code | `user_apps`, `app_revisions` | Portable row IDs/owner references and content blobs; identity collisions remain a limitation below. |
| Files referenced by app revisions | `app_revisions.attachmentPaths` | The path-list metadata syncs; **the referenced files do not have blob transport or portable-path mapping.** App code arriving does not imply all its assets arrived. |
| Downloaded app libraries | `user_app_libraries`, `user_app_library_dependencies` | **Do not sync:** local integer primary keys are not portable. Dependency `bytes` also lacks implemented transport. Apps may arrive without the libraries needed to run offline. |
| Annotations and their embedded files | `note_annotations` | **Do not sync:** no capture/materialization scope or annotation-file transport. They are indexed locally. |
| Tag decoration and AI prompts | `tag_images`, `tag_ai_configs` | **Do not sync.** |
| Multi-function app selection/defaults | `multi_function_apps` | **Do not sync.** |
| Search chunks, FTS, embeddings, progress | `search_chunks`, `chunks_fts`, `chunk_embeddings`, `search_index_state` | Deliberately local and rebuilt from source data. Copying these across devices would carry stale/provider-specific derived state. |

Sync health now names populated unsupported user-content tables with readable
English/Chinese labels. Revision attachment paths are a field-level omission
and are not covered by that table-level warning. A receiving device cannot
detect data that never left the source, so this warning must be inspected on
the source device.

There is a separate app identity limitation: two independently installed copies
of the same app can have different `user_apps.id` values but the same unique
`user_apps.uuid`. Incoming rows are parked as an identity conflict rather than
overwriting local content. Deleting the local app only creates a tombstone and
does not release that UUID. Full automatic reconciliation needs an explicit
identity/child-reference migration; a sync reset is not a repair for this case.

Completing the omitted features requires portable library identities,
deletion semantics and capture/materialization for the additional tables, and
blob transport for their embedded files. Adding names to the scope list alone
would not make the features correct. These omissions remain release
limitations, now surfaced instead of silently reporting complete sync.

## First-run time, memory, and recovery

Upgrading a populated library has three distinct costs:

1. **Database backup and migration.** The pre-migration backup copies the
   database, so disk space and I/O scale with the existing file. The first
   database open waits for this work. Sync/index schema creation does not
   imply that historical records have been uploaded or indexed.
2. **Initial sync seed and transfer.** The seed scans existing rows because
   new mutation triggers cannot capture writes made by old releases. It
   persists operation/register state, skips already handled data on retry,
   reports progress within large tables, and records completed seeding.
   Upload still needs commit batches (at most 64 operations, targeting
   256 KiB of value data) and file blobs. The byte target is soft: a single
   larger operation is sent whole, and envelope/encryption overhead is extra.
   Very large note/message values can exceed it substantially.
   A large library or slow network
   can take minutes or longer; local seed timing excludes that work.
   Legacy absolute-path normalization also hashes and copies files before
   seeding. Originals are retained, so temporary disk requirements can be
   close to another copy of the affected media library.
3. **Local indexing.** Text fingerprints, chunks, and FTS are built in
   bounded batches. PDF text, OCR, figures, and embeddings add separate work;
   model availability, page limits, network gates, and user settings affect
   completion. Fingerprints avoid rechunking unchanged text on later sweeps.
   A single huge note/file can still dominate time and peak memory.

Attachment extraction checkpoints are per attachment rather than per page.
Killing the process partway through a large PDF can repeat that attachment's
work. The default PDF-text cap skips documents over 100 pages unless the
setting is raised; OCR can still process many pages and dominate the total
time. Text-index timings below should not be used as attachment estimates.

**Remaining large-file memory limit:** blob downloads and encrypted uploads
buffer entire files. Memory scales with file size and can include both
encrypted and plaintext buffers. Large videos/PDFs can exhaust phone memory;
bounded note-index batches do not solve this. Streaming/chunked encrypted
blob transport needs its own implementation and interoperability tests.

During incomplete lexical indexing, note-body substring search remains
available. That fallback does not reproduce attachment-page or figure search;
those results depend on their extraction/index stages. Offline/deferred
embedding work must remain retryable rather than being recorded as complete.
Indexes are derived: recovery excludes them and resumes rebuilding locally.

### Measured local workloads

These are one diagnostic run on this macOS desktop using Flutter tests and
real temporary SQLite databases. They are **not release-phone measurements**,
do not include real Google requests, PDF/OCR, or embedding inference, and may
include contention from other tests. No linear phone/network estimate should
be inferred from them.

| Workload | 1,000 notes | 2,000 notes |
| --- | ---: | ---: |
| Initial seed, simple notes | 7.521 s / 5,000 operations | 16.559 s / 10,000 operations |
| Already-completed seed scan | <1 ms | <1 ms |
| Initial lexical index, 2 subnotes and 1 attachment annotation per note | 4.953 s / 8,000 chunks | 9.583 s / 16,000 chunks |
| Unchanged index sweep | 0.118 s | 0.231 s |

The indexing fixtures contain approximately 7.52M and 15.04M source
characters plus two attachment metadata rows per note. Unchanged sweeps
rechunked zero notes. These index timings use the final source readers and
lookup indexes. The reproducible index diagnostic is
`test/search/note_index_upgrade_benchmark.dart`.
The seed diagnostic is `tool/benchmarks/sync_seed_benchmark_test.dart`.

## Validation and release follow-up

The final combined `flutter test --no-pub --reporter expanded` run passed
**4,736 tests in 5m57s**, with three existing environment skips: one missing
image fixture and two native PDFium integrations unavailable in the headless
runner. The new populated-upgrade, recovery, large-row, sync, and search
regressions are included. Both manual benchmark fixtures also passed.
The strengthened 29-case upgrade suite also passed separately, including
released-version boundaries, startup and backup upgrades from earlier branch
versions, and preservation of existing chunks, embeddings, and index progress.

Android release manifest processing and resolved iOS Release build settings
passed; the 25 OAuth configuration/auth tests passed separately and are also
in the full suite. `flutter analyze --no-pub lib test` reports **no errors**
and 661 existing lint findings; it exits nonzero for those findings.
Signed-device OAuth, native PDF/OCR end-to-end behavior, and real cloud
transfer performance were not validated by these tests.

The owner has confirmed that Android custom URI schemes are enabled; that
configuration action is complete. Before describing this as complete
cross-device sync, configure a separate iOS client, verify consent, callback,
token refresh, and Drive access on signed release builds for both platforms, and
complete the unsupported data families and app identity reconciliation above.
Use an existing-library fixture with substantial PDF/image attachments and
downloaded app dependencies for device timing, interrupt/resume, and offline
verification; a fresh empty installation cannot exercise those upgrade paths.
