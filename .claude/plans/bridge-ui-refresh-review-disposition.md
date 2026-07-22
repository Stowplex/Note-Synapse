# Review Disposition — bridge UI refresh fix (commits 504ce66 + follow-up)

Two review rounds ran over commit 504ce66: an adversarial reviewer plus an
8-angle recall-biased code review (line-scan, removed-behavior, cross-file,
reuse, simplification, efficiency, altitude, conventions). Every candidate was
verified against the code before acting. Disposition below.

## Confirmed and fixed

| # | Finding (source) | Fix |
|---|---|---|
| 1 | `notes` AFTER UPDATE trigger journaled only NEW.id — `UPDATE notes SET id=...` left a ghost cached note (line-scan) | Trigger records OLD.id + NEW.id; test `UPDATE that rewrites the primary key captures BOTH ids` |
| 2 | TEMP journal grew unboundedly: triggers fired on every app write, cleared only inside capture txns (line-scan, removed-behavior, cross-file) | Triggers gated on `WHEN EXISTS(_synapse_capture_active)`; flag row armed only inside the capture transaction. Test: ordinary writes journal nothing |
| 3 | Capture install raced close()/reopen: in-flight future not connection-keyed; late continuations re-poisoned flags (line-scan) | Immutable `_CaptureState` keyed to the `Database` instance; per-call values; commit guarded by `identical(_database, db)`; keyed in-flight slot |
| 4 | `_persistNote`/`updateNote` wrote `toJson()`'s `metadata: null`, wiping markers on every save — notes loaded from DB never carry metadata (line-scan) | `json.remove('metadata')` in both paths (metadata is written only via `updateNoteMetadata`); marker-survival test |
| 5 | `updateNote` on a concurrently-deleted note re-created orphan `note_tags`/`subnotes`/`attachments` rows (removed-behavior) | Both paths check the UPDATE's row count: `updateNote` warns+returns, `_persistNote` throws (rolls back txn); orphan test |
| 6 | `content_ingestion` double-inserted the extracted note (createNote + addNote, same PK) — the publish made the previously-invisible fallout user-visible (cross-file) | Removed redundant `addNote`/`updateNote`; the service publishes are the UI refresh now |
| 7 | `AppProvider` fell back to a private orphan `DataChangeNotifier` no writer publishes to — silently inert wiring under misordered construction (multiple angles) | `DataChangeNotifier.shared()`: register-if-absent GetIt resolution used by every subscriber and publisher; six divergent fallbacks consolidated |
| 8 | Broad DML (>999 ids) hit the SQL variable limit then did an O(N²) upsert while holding the cache lock (cross-file, efficiency) | `maxTargetedRefreshIds = 200` cap in `SqlQueryService`; larger sets degrade to one debounced bulk reload; test |
| 9 | PRAGMA reclassification contradicted the plugin prompt doc ("PRAGMA executes immediately") (removed-behavior, cross-file, conventions) | `assets/prompts/user_app/api_documentation.md` updated: bare/inspection PRAGMAs immediate, assignments require approval. Approval for settings pragmas is retained deliberately — `PRAGMA foreign_keys=OFF` before a DELETE is an integrity hazard |
| 10 | Raw Data Manager tab writes bypassed all invalidation (removed-behavior) | Publishes `bulk` after raw writes |
| 11 | NoteMarkerService publishes forced full note refetches for metadata that is never cached (line-scan, efficiency) | Publishes removed; `data-change-exempt:` comment documents why |
| 12 | StarterService rebuilt published ids from a duplicated string literal (altitude) | Publishes the inserted `Note.id` |
| 13 | Test rewrite lost assertions: exact-tags consultation + rejection-persists-nothing (removed-behavior) | Restored via `captureAny` verification and DB-unchanged assertion |
| 14 | Publication convention unenforced — next direct writer silently regresses (altitude) | `test/data_writer_publish_audit_test.dart` source-scans `lib/` for typed note writes and fails on unaccounted writers |
| 15 | Dead `finally` re-arm in `_drain` with a wrong race comment (simplification) | Removed; comment explains why no interleaving point exists |
| 16 | `_capturedTables` vs trigger-spec switch: silent `default: []` uncaptures a newly listed table (simplification) | Default now throws `ArgumentError` |
| 17 | `createNote`'s `noteInserted` flag derivable from control flow (simplification) | Insert moved before try; flag removed |
| 18 | Duplicated `SqlQueryType` description switch, lockstep-edited by this very commit (reuse, conventions) | Static `SqlQueryService.describeQueryType`; widget keeps only its 'SQL' fallback |
| 19 | `_applyChangesLocked` fetched notes/tags/filters sequentially under the lock (efficiency) | `Future.wait` with per-branch error isolation |
| 20 | Non-reentrant lock enforced only by comment; wrapping one more method deadlocks silently (altitude) | Debug-mode Zone-based reentrancy assert in `_withCacheLock` |
| 21 | Hand-rolled test DDL already drifted from production schema (reuse) | `openRawNotesDb` now executes `DatabaseService.getSchema()` |

## Refuted / deliberately unchanged (basis)

- **Run `loadData` I/O outside the lock with generation counters** (efficiency):
  the lock-around-I/O trade-off was an explicit plan decision (rev 4 review):
  a mutation queuing behind a reload is the price of never losing it to the
  reload's snapshot replace. The fetch-then-commit redesign belongs with the
  planned lazy-content/summary-column follow-up that makes reloads cheap.
- **Skip capture for plugin-only tables via classification** (efficiency):
  rejected on correctness — persistent triggers on plugin tables can cascade
  into note tables (covered by a test); the journal must observe every DML
  regardless of its textual target. The WHEN-gate already removed the
  steady-state cost for ordinary writes.
- **Carry committed `Note` objects on events instead of ids** (efficiency):
  re-fetch is load-bearing — it applies read-side normalization (attachment
  path conversion, chunked >500KB content) exactly like the pre-existing
  `addNote`/`updateNote` re-fetch pattern; post-cap batches are small.
- **Append ordering breaks `pinned/createdAt` order for unsorted consumers**
  (cross-file): matches pre-existing `addNote` append behavior; screens sort
  (`notes_screen.dart` / `getFilteredNotes`). Documented in the plan.
- **Promote `synchronized` package for the mutex** (reuse): only a transitive
  dep today; the 20-line lock is documented, error-resilient, and covered by
  tests including the poisoned-tail case. Optional follow-up.
- **Consolidate the ~25 `_withCacheLock` + catch wrappers into one `_mutate`
  helper** (simplification): the variants genuinely differ (rethrow vs
  swallow, `_error` clearing); mechanical wrapping preserved each method's
  existing semantics exactly, which was the review-agreed goal. Follow-up
  refactor, not this change.
- **l10n for the `REPLACE (add or overwrite data)` string** (conventions):
  every sibling enum description is equally untranslated English; localizing
  the set is a pre-existing gap, out of scope here.

## Verification

- `flutter analyze`: 0 errors outside `third_party/`.
- Full suite after the fix batch: **1667 passed, 0 failed** (and re-run of the
  schema-helper change: green).
