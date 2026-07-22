# Fix Plan: User App Bridge Note Writes Not Reflected in UI (rev 5)

## Symptom

Notes created or modified by user app (plugin) bridge functions do not appear/update
in the notes UI until the user taps the refresh button (which calls
`AppProvider.loadData()` to re-read the DB).

## Root Cause

The notes UI (`notes_screen.dart`) renders `AppProvider._notes`, an in-memory cache
that is only updated by `AppProvider`'s own mutation methods (`addNote`, `updateNote`,
`deleteNote`, `loadData`). Several bridge write paths persist to SQLite **directly**,
so the cache is never patched and `notifyListeners()` is never called:

| Bridge handler | Path | UI updates? |
|---|---|---|
| `saveNotes` | `buildNote` + `appProvider.addNote` | ✅ yes |
| `updateNotes` (full-replacement mode) | `appProvider.updateNote` | ✅ yes (but see gap 3) |
| `updateNotes` (granular `modification` mode) | `NoteModificationService.applyModifications` → `_db.updateNote` (user_app_runtime_bridge.dart:2502) | ❌ **bypasses provider** |
| `runQuery` with INSERT/UPDATE/DELETE | `SqlQueryService.executeQuery` → raw SQL (user_app_runtime_bridge.dart:449) | ❌ **bypasses provider** |
| `deleteNotes` | `appProvider.deleteNote` | ✅ yes |

Gaps in detail:

1. **Granular `updateNotes`** — `NoteModificationService.applyModifications`
   (note_modification_service.dart:62) writes with `_db.updateNote` and returns.
   Nothing tells `AppProvider`. Primary path for plugin note edits.
2. **`runQuery` writes** — plugins can create/modify notes via SQL; no cache
   invalidation happens. Explains "created notes don't show".
3. **`AppProvider.updateNote` silent skip** (app_provider.dart:166-171) — if the note
   id is not in `_notes`, the DB is updated but the cache update *and*
   `notifyListeners()` are both skipped.
4. **Direct writers outside the bridge** (see audit, Step 4b): agent tools
   (`note_tools.dart:845/921/1167` via `NoteModificationService`; **`delete_notes`
   at note_tools.dart:1240 via `DatabaseService` directly**),
   `content_ingestion_service.dart:240-246`, `StarterService`
   (starter_service.dart:128/132/288), `note_marker_service.dart:71/97/142`
   (metadata).

No change-notification mechanism exists on the persistence layer, so any DB-direct
write is invisible to the UI by construction.

## Design Principles

- **Post-commit UI sync is best-effort.** A committed DB write must never be
  reported as failed because a cache refresh threw; a failed write that partially
  committed must still invalidate what committed (avoided where possible by making
  writes transactional).
- **No persistence → UI dependency.** Writers depend on a small change-event
  service; `AppProvider` subscribes.
- **Two invalidation tiers, stated accurately** (review r5-5): **raw SQL is
  observed automatically** by the TEMP journal (including persistent-trigger
  cascades); **typed `DatabaseService`/service writes require explicit
  publication** by their owner. This is a convention enforced by the Step 4b audit
  + checklist, not a persistence-layer guarantee.
- **ALL provider cache mutations are serialized under one error-resilient lock.**
- **Tags are part of the note domain.** Cached `Note` objects embed tag names
  (filtering reads them, app_provider.dart:410-412).

## Fix Plan

### Step 1 — Testability: constructor injection into AppProvider

`AppProvider` hard-codes `final DatabaseService _databaseService = DatabaseService();`
(app_provider.dart:23) — a factory singleton, so GetIt mocks never reach it. Inject
both dependencies:

```dart
AppProvider({DatabaseService? databaseService, DataChangeNotifier? changeNotifier})
    : _databaseService = databaseService ?? DatabaseService(),
      _changeNotifier = changeNotifier ?? getIt<DataChangeNotifier>() {
  _subscription = _changeNotifier.addListener(_onDataChanged);
}
```

Subscription handle retained, cancelled in `dispose()`. `DataChangeNotifier`
registered in GetIt before `AppProvider`. No call-site changes.

### Step 2 — Change-event service: `DataChangeNotifier` (serialized async queue)

New service (`lib/services/data_change_notifier.dart`), constructor-injected into
every publisher (`NoteModificationService`, `SqlQueryService`, `DeleteNoteTool`).

**Event model.** Publish methods are `void` and never throw — they only enqueue:

```dart
class DataChangeEvent {
  final Set<String> noteIds;        // notes to upsert/remove
  final bool tagsChanged;
  final bool filtersChanged;
  final Set<String> relationshipNoteIds;
  final bool bulk;                  // unknown scope → full reload
}
```

**Serialized, coalescing dispatch:**

- One *pending* accumulator + one drain loop. `publish(event)` merges into the
  accumulator (union of id sets, OR of flags) and starts the drain if idle.
- The drain takes the accumulated event, clears the accumulator, **awaits** each
  listener (`typedef DataChangeListener = Future<void> Function(DataChangeEvent)`)
  inside try/catch (`LoggerService.error`), then loops if more accumulated.
- Exactly one batch in flight ⇒ no overlapping listener invocations; async errors
  cannot escape.
- **Custom listener list** — NOT a broadcast `Stream` (broadcast delivery doesn't
  await async subscribers). `addListener` returns a removable handle.
- **Listener contract (documented):** listeners must terminate; watchdog log if a
  dispatch exceeds ~30 s.

**Provider event handler `_onDataChanged(event)`** — one lock acquisition, one
notification per event (review r5-8):

- `event.bulk == true` → `scheduleReload()`; targeted work in that merged batch is
  skipped (redundant with the reload). Debounce stays for burst coalescing;
  ordering safety comes from the lock.
- else: a single private `_applyChangesLocked(event)` runs **under one
  `_withCacheLock` acquisition**: batch-fetch changed notes, refresh `_tags` if
  `tagsChanged`, refresh `_filters` if `filtersChanged` — then **one**
  `_dataVersion` bump + **one** `notifyListeners()` covering everything, giving
  the event a single cache-snapshot boundary. (Relationship ids don't add cache
  work; they just ensure the notification fires.)

### Step 3 — AppProvider: one error-resilient lock for ALL cache mutations

**Lock implementation** (review r5-4 — a naïve `_tail = _tail.then(action)` chain
is permanently poisoned by the first error):

```dart
Future<T> _withCacheLock<T>(Future<T> Function() action) {
  final prev = _lockTail;
  final completer = Completer<void>();
  _lockTail = completer.future;               // tail NEVER carries an error
  return prev.then((_) async {
    try { return await action(); }            // action's error → this caller only
    finally { completer.complete(); }         // release in finally, always
  });
}
```

Test: first locked action throws → its caller sees the error; second action still
runs and completes.

**Audit scope** (review r5-3 — not just a grep for field names). Wrap every method
that mutates provider cache state through **any** syntax: direct assignment
(`_notes = ...`), `.add`/`.addAll`/`.remove*`/`.clear`/indexed assignment
(`_notes[i] = ...`), and helpers that mutate indirectly. Known list from audit:
`_doLoadData`, `addNote`, `updateNote`, `updateNoteContent`, `updateTaskStatus`,
`toggleNotePin`, `deleteNote`, bulk import (app_provider.dart:398), tag mutations,
filter mutations, `refreshTags`, **`clearAllData` (app_provider.dart:720)**, and
the new `_applyChangesLocked`.

**`clearAllData` fixes** (review r5-2): acquire the lock; also clear **`_filters`**
— the DB clear deletes the filters table (database_service.dart:2902) but the
cache reset currently misses it (pre-existing stale-cache bug surfaced by this
audit). At implementation, check `DatabaseService.clearAllData`'s table list and
reset every corresponding provider cache (`_userApps` etc.) consistently. Test
against a concurrent load.

**Re-entrancy convention, applied consistently:** the lock is non-reentrant.
Public methods = lock acquire + private `_xxxLocked` core; provider-internal
cross-calls use cores only. This includes indirect paths: methods that internally
call `loadData()` (e.g. relationship methods) must call an unlocked
`_loadDataLocked` core (or schedule the public call after release), never the
public locked method from inside the lock. Implementation includes a call-graph
pass over `AppProvider` for provider-method → provider-method calls before
wrapping.

**`Future<void> refreshNotesFromDb(Set<String> ids)`** (used by
`_applyChangesLocked`; also exposed for direct use) — under the lock:

- Batch fetch via `getNotesByIds(ids)` (database_service.dart:1886; same
  `_batchLoadNotes` normalization as `getAllNotes`, incl. chunked >500KB content).
- Replace in place; append new (matches `addNote`'s append, app_provider.dart:143);
  ids absent from results = deleted → remove.
- One `_dataVersion` bump + one notify per batch. Batch failure → log, per-id
  `getNote` fallback (partial success), still notify.
- Never touches `_tags` (own event flag). Notifies even on identical data
  (matches existing methods).

**Fix `updateNote`** (app_provider.dart:166-171) to upsert instead of silently
skipping when the note isn't cached.

**`void scheduleReload()`** — debounced (~500 ms) `loadData()`: pending timer →
no-op; in-flight load → existing `_loadDataInFlight`/`_reloadRequested` coalescing;
timer + subscription cancelled in `dispose()`; callback try/catches + logs;
`fakeAsync` tests.

### Step 4 — Typed writers publish events post-commit

**4a. NoteModificationService — transactional writes first:**

- `applyModifications`: note persistence + link changes in one `db.transaction`,
  reusing the executor-based helpers `applyBatchModifications` already uses
  (`_persistNote(txn, ...)`, `_applyLinkModifications(..., txn: txn)`,
  note_modification_service.dart:120-130). All-or-nothing ⇒ "publish after
  commit" is accurate.
- `createNote`: insert + relationships in one transaction (extract an
  executor-based insert core if `_db.insertNote` can't run inside a txn; last
  resort: guarded-`finally` publishing only what committed).
- `applyBatchModifications`: already transactional; publish at the end.

Merged event after commit: `noteIds` always; `tagsChanged` when tags
added/removed/created; `relationshipNoteIds` computed **from the payload before
applying removals** (`{noteId}` ∪ added targets ∪ removed targets — the payload
names every affected endpoint since `deleteRelationshipBetween` only touches that
pair). Publishing is enqueue-only — cannot throw or alter return values.

**4b. Other direct writers** (review r5-1 — the choke point misses writers that
bypass `NoteModificationService`):

- **`DeleteNoteTool` (agent `delete_notes`, note_tools.dart:1240)** — deletes via
  `_databaseService.deleteNote` directly; agent-deleted notes currently stay in
  `_notes` until reload. Inject the notifier; after the deletion loop publish
  `DataChangeEvent(noteIds: deletedIds.toSet())` — only successfully deleted ids
  (partial success is already tracked in `deletedIds`).
- **`StarterService`** (starter_service.dart:128/132/288, direct
  insert/updateNote) — publish `noteIds` after its writes. Likely runs before the
  provider's first `loadData` (harmless either way — events on an empty cache
  upsert correctly), but publishing keeps the convention uniform.
- **`note_marker_service.dart:71/97/142`** (`updateNoteMetadata`) — decide at
  implementation whether cached `Note` objects surface metadata anywhere in list
  UI; publish `noteIds` if so, else document the exemption inline.
- **Implementation checklist item:** run
  `rg "\.(insertNote|updateNote|deleteNote|updateNoteMetadata)\(" lib/ --type dart`
  (excluding `app_provider.dart`, `database_service*.dart`,
  `note_modification_service.dart`) and confirm every hit either publishes or is
  explicitly exempted with a comment. Add the same audit note to Step 6.

### Step 5 — Raw SQL: domain journal captured inside DatabaseService

**5a. Execution categories** — some statements cannot run inside a transaction
(`VACUUM`, `PRAGMA journal_mode`, `ATTACH`/`DETACH`):

| Category | Execution | Invalidation |
|---|---|---|
| DML (`INSERT`/`UPDATE`/`DELETE`/**`REPLACE`**, incl. upsert; CTE-wrapped when parser-confident) | capture transaction (5b) | journal-driven event |
| Everything else non-read-only (DDL, writable/unknown PRAGMA, `VACUUM`, `ATTACH`, `other`, parse failure) | direct `rawQuery`, no wrapper | `bulk: true` |

No capture fidelity lost: persistent triggers only cascade from DML. DDL sets the
trigger re-verify flag (5d).

**`REPLACE` implementation detail** (review r5-6): `SqlQueryType` has no `replace`
member and fallback detection doesn't recognize the keyword, so today it would
land in `other` → bulk. Add `SqlQueryType.replace` (or normalize to `insert`) in
both AST detection (`InsertStatement` with replace mode) and
`_fallbackQueryTypeDetection` (`REPLACE INTO` prefix), and route it as DML — it is
delete-plus-insert semantics and must exercise the journal triggers for precision.

**5b. Ownership + transaction.** Capture mechanics live in `DatabaseService`;
`SqlQueryService` calls one API. The wrapper executes via `txn.rawQuery(...)`,
never re-entering `database` inside `db.transaction` (runRawQuery today:
database_service.dart:5065).

```dart
class RawWriteResult {
  final List<Map<String, dynamic>> rows;
  final Set<String> changedNoteIds;
  final Set<String> relationshipNoteIds;
  final bool tagsChanged;
  final bool filtersChanged;
  final bool captureComplete;   // false ⇒ journal may be incomplete (r5-7)
}
Future<RawWriteResult> runRawWriteWithChangeCapture(String sql);
```

`captureComplete` is set per execution from the install state at the time of the
write (review r5-7 — `SqlQueryService` must not read mutable `DatabaseService`
state afterward; returning it on the result avoids races and is directly
testable). One transaction: clear journal → `txn.rawQuery(sql)` → read journal →
clear again.

**5c. Domain journal.** One TEMP table records domains, not just note ids, so
indirect writes (persistent plugin trigger inserting into `tags`) still
invalidate:

```sql
CREATE TEMP TABLE IF NOT EXISTS _synapse_change_journal(kind TEXT, note_id TEXT);
```

| Table | Triggers | Journal rows |
|---|---|---|
| `notes` | AFTER INSERT / UPDATE / DELETE | `('notes', NEW.id / NEW.id / OLD.id)` |
| `subnotes` | AFTER INSERT / DELETE; AFTER UPDATE | `('notes', NEW.noteId / OLD.noteId)`; UPDATE records **both** OLD and NEW |
| `note_tags` | AFTER INSERT / DELETE; AFTER UPDATE | same, both sides on UPDATE (association moves) |
| `attachments` | AFTER INSERT / DELETE; AFTER UPDATE | same, both sides on UPDATE |
| `relationships` | AFTER INSERT / DELETE; AFTER UPDATE | `('relationships', fromNoteId)` + `('relationships', toNoteId)`, OLD and NEW on UPDATE |
| `tags` | AFTER INSERT; AFTER UPDATE; **BEFORE** DELETE | `('tags', NULL)` always; UPDATE/DELETE additionally `INSERT ... SELECT ('notes', noteId) FROM note_tags WHERE tagId = OLD.id` (BEFORE delete so join rows still exist regardless of cascade) |
| `filters` | AFTER INSERT / UPDATE / DELETE | `('filters', NULL)` |

**5d. Trigger installation lifecycle:**

- Keyed to the **connection**: in-flight `Future` + `Database` instance key; a
  different `Database` object (after `close()`, database_service.dart:2914-2917,
  incl. recovery/import reopen) ⇒ reinstall. `IF NOT EXISTS` ⇒ idempotent.
- `_captureInstalling` cleared in `finally` — a failed install must not poison
  later attempts; next write retries.
- **Per-table isolation:** approved DDL may drop/rename monitored tables. Install
  triggers table-by-table, each group try/caught + logged. Failed core-table
  groups ⇒ subsequent `RawWriteResult.captureComplete = false` — but writes still
  execute (a plugin-table INSERT must not fail because an invalidation trigger
  couldn't install).
- After any DDL (bulk path), set the re-verify flag so the next DML re-runs the
  per-table install.

**5e. Routing in SqlQueryService.** DML → `runRawWriteWithChangeCapture`; publish
from the journal result — unless `captureComplete == false`, then publish
`bulk: true` instead. Non-DML non-read-only → direct execution + `bulk: true`.
Classification (`getWrittenTables`) only picks the category — never decides which
domains changed.

**5f. PRAGMA — conservative heuristic:** allowlisted inspection pragmas
(`table_info`, `table_xinfo`, `index_info`, `index_list`, `foreign_key_list`, ...)
→ read-only, approval unchanged; other PRAGMAs with `=`/`(...)` → write
(approval + direct + bulk); bare PRAGMAs read-only. Tests verify no new approval
prompts for allowlisted forms.

### Step 6 — Tests

- **DataChangeNotifier**: coalescing mid-flight; async listener failure
  caught+logged, drain continues; strict serialization; unsubscribe stops
  delivery; slow-dispatch watchdog log.
- **AppProvider**:
  - Lock: `addNote` racing `loadData` — appended note survives the replace;
    targeted refresh queued during `loadData` reads post-load state;
    **error-resilience: first locked action throws, second still runs**;
    non-reentrancy call-graph (no deadlock across wrapped methods, incl.
    relationship methods that internally reload).
  - `refreshNotesFromDb`: upsert/append/remove; single notify; batch failure →
    per-id fallback, still notifies.
  - `_onDataChanged`: a merged notes+tags+filters event produces **one**
    notification; bulk supersedes targeted work.
  - `updateNote` upserts when absent. `clearAllData`: under lock, clears
    `_filters` too, safe against a concurrent load. `scheduleReload` fakeAsync
    coalescing; dispose cancels timer + subscription.
- **NoteModificationService**: right merged event post-commit incl. relationship
  endpoints from payload; **atomicity**: forced link failure rolls back the note
  update — nothing committed, nothing published, error propagates; publish never
  alters return values.
- **Direct writers**: `DeleteNoteTool` publishes exactly the successfully deleted
  ids (partial-failure case included); `StarterService` writes publish; the `rg`
  direct-writer audit from Step 4b is part of implementation done-criteria.
- **SQL classification** (pure unit): quoted + schema-qualified names,
  `INSERT ... SELECT`, `ON CONFLICT DO UPDATE`, **`REPLACE INTO` → DML capture
  path**, `WITH ... UPDATE/DELETE`, leading comments, PRAGMA
  allowlist/argumented/bare; category routing: `VACUUM` and
  `PRAGMA journal_mode=WAL` execute directly (no transaction) and publish `bulk`.
- **Journal capture** (real in-memory sqflite via sqflite_common_ffi):
  - DML on `notes` + each child table yields the right rows; association UPDATE
    records both sides; relationships both endpoints; `REPLACE INTO notes`
    exercises delete+insert triggers;
  - tag rename/delete → `('tags', NULL)` + per-note rows (with and without FK
    cascade); filter writes → `('filters', NULL)`;
  - persistent user trigger on a plugin table writing into `notes`/`tags` is
    captured; plugin-table-only writes capture nothing;
  - journal cleared before/after; `close()` + reopen reinstalls;
  - **degraded mode**: drop a monitored table → plugin-table DML still executes,
    `captureComplete == false`, `bulk` published; install failure doesn't poison
    retries.
- **End-to-end (bridge harness if available)**: granular `updateNotes` and a write
  `runQuery` each end in a provider notification; simulated refresh failure still
  returns success to the JS caller.

### Non-goals / notes

- Relationship data is not cached in `AppProvider`; `relationshipNoteIds` is a
  re-query signal only.
- `loadData()`'s multi-second cost (full `note.content` in `getAllNotes`) is a
  separate follow-up (summary column / lazy content) that would also cheapen the
  `bulk` fallback and lock-wait cost.
- Cache ordering: appends match existing `addNote` behavior; screens sort/filter.
- No l10n or DB schema changes; TEMP objects only; `recovery_screen.dart`
  untouched (journal/triggers are connection-local, never persisted).
