# Note Index: Layered Search + Figure Retrieval

## Context

Three pain points drive this work:
1. The search bar is a pure substring filter (`notes_screen.dart:570-578`, with 3 real duplicates of the predicate elsewhere) — no ranking, no snippets, runs synchronously in `build()` on every keystroke.
2. Nothing semantic works, and PDFs are entirely unsearchable: no text extraction, no OCR, no embeddings anywhere in the repo. A working FTS4 index (`notes_fts`) exists but is only wired to the AI's `search_notes` tool — and it quotes the whole query as one phrase (`database_service.dart:5094`), breaking multi-term search.
3. AI chat can generate images (expensive) but cannot *retrieve and embed a figure that already lives in a note* — tool results are strings only, and the chat renderer can't resolve note-attachment images (`ChipAwareAiMessageContent` is built without `noteId` at `conversation_chat_screen.dart:3748` / `chat_panel.dart:478`; `synapseresource://attachment/<id>` works only as a tap-link, never as an image source).

**Architecture (user-decided, do not revisit):**
- **Layered, fused search.** FTS4/BM25 lexical is the always-on, offline, zero-config floor. Each layer the user enables or leaves on (embedding provider, OCR, multimodal) improves results. Layers fuse via Reciprocal Rank Fusion.
- **No FTS5** — user explicitly rejected it (Android/iOS consistency). BM25 comes from FTS4 `matchinfo()` decoded in Dart.
- **Embedding provider abstraction** mirroring the existing `AIModel` pattern (`lib/services/models/ai_model.dart`: Gemini / OpenAI-compatible / local, YAML presets). No vendor lock-in; no forced local-model download; everything works with zero providers.
- **Chat figures**: prefer *searching and embedding an existing figure* over image generation — a `search_figures` tool + renderer fixes.
- **OCR is a primary layer** (user-decided): on-device ML Kit OCR runs over all PDF pages and raster images — default on, toggleable — supplying both novel text and the bounding boxes that drive figure detection. Not a "text layer too short" fallback.

**Verified facts the plan relies on** (fact-checked by design review):
- `flutter_gemma` 0.16.4 (already a dep): `EmbeddingModel.generateEmbedding(text, taskType)` + batch variant + `getDimension()`; installation is `FlutterGemma.installEmbedder()` via `EmbeddingInstallationBuilder` which needs **model + tokenizer** files — so the existing single-file `LocalModelService`/preset structure must be *extended*, not reused as-is.
- pdfrx 2.2.24 (already a dep): unused per-page `loadStructuredText()` / `PdfPageText.fullText` (pdfrx_engine 0.3.9). `PdfPageText` also exposes **per-character rects (`charRects`) and fragments with bounds**, and `PdfPage.render(x, y, width, height, fullWidth, fullHeight)` renders **any sub-region of a page at arbitrary resolution** — together these enable figure/table region extraction (verified in pdfrx_engine `pdf_page.dart:68-90`, `pdf_text.dart:33-54`). pdfrx has no embedded-image page-object API, so figure regions must be inferred geometrically, not enumerated.
- `ImmersiveNoteScreen` accepts `initialPage` (0-based) + `initialAttachmentPath`. The existing converter at `interactive_checkbox_markdown.dart:314-317` maps 1-based `?page=` URI params → 0-based `initialPage`; `PdfThumbnailService.renderPage` is 0-based. **Convention: `?page=` in all URIs is 1-based**; convert at the boundary.
- `SynapseResourceUri.attachmentUri(attachmentId, {page})` exists (`synapse_resource_uri.dart:122-128`).
- Vector search: sqflite can't load sqlite-vec (platform-channel sqlite). At mobile scale (<10k chunks × 768 dims ≈ 30 MB) a brute-force dot-product scan is <50 ms. Store L2-normalized float32 BLOBs; cosine = dot. No ANN needed.
- Gemini embeddings: `gemini-embedding-001` (text, `task_type` RETRIEVAL_QUERY/DOCUMENT, needs re-normalization after Matryoshka truncation); `gemini-embedding-2` (multimodal: text/images/PDF≤6pp in one vector space, `output_dimensionality`, outputs already L2-normalized — normalize-if-needed per model). REST `:batchEmbedContents` on `generativelanguage.googleapis.com/v1beta` (same base URL `gemini_model.dart` already targets). Verify batch endpoint support for the embedding-2 preview model during implementation; fall back to per-item `:embedContent` if unsupported.

**Platform risk (FTS4)**: Android system sqlite ships FTS3/4; iOS system sqlite currently has FTS4 (the shipped `notes_fts` proves it), but Apple already removed FTS3/4 from macOS 15+ — the repo compiles its own sqlite3 amalgamation for desktop/tests for exactly this reason (`pubspec.yaml:179-207`). Mitigation: a startup capability probe (`CREATE VIRTUAL TABLE temp.fts_probe USING fts4(x)` in try/catch) that flips search to the substring fallback if FTS4 is missing; named escape hatch if iOS ever drops FTS4: move mobile to `sqflite_common_ffi` riding the existing custom sqlite3 native-asset build (keeps FTS4 — consistent with the no-FTS5 decision). Web (`databaseFactoryFfiWeb`, wasm build is FTS5-only): migration 62 (renumbered from 47 when this branch merged with cloud sync, which had already consumed 47..61) must wrap the FTS4 CREATE in try/catch and degrade to substring search, never hard-fail the upgrade.

---

## Phase 1 — Chunk index + lexical BM25 + search UX

### 1.1 Schema (migration 61→62, `database_service.dart:94`)

```sql
CREATE TABLE search_chunks (
  id INTEGER PRIMARY KEY,       -- rowid alias: STABLE under VACUUM (raw SQL/VACUUM is exposed to user+AI)
  chunkKey TEXT NOT NULL,       -- "{noteId}:{sourceType}:{sourceId|-}:{seq}" logical identity
  noteId TEXT NOT NULL,
  sourceType TEXT NOT NULL,     -- meta|note_body|subnote|annotation|attachment_text|attachment_ocr|figure
  sourceId TEXT, page INTEGER,  -- page is 1-based
  seq INTEGER NOT NULL,
  text TEXT NOT NULL,           -- RAW text (snippets + embedding input)
  meta TEXT,                    -- JSON: figure chunks {caption, rect, derivedAssetPath}; attachment_ocr chunks {blockBounds, renderScale}
  contentHash TEXT NOT NULL, updatedAt INTEGER NOT NULL);
CREATE UNIQUE INDEX idx_search_chunks_key ON search_chunks(chunkKey);
CREATE INDEX idx_search_chunks_noteId ON search_chunks(noteId);
CREATE INDEX idx_search_chunks_source ON search_chunks(sourceType, sourceId);
CREATE VIRTUAL TABLE chunks_fts USING fts4(content);  -- NORMALIZED text, docid = search_chunks.id
CREATE TABLE chunk_embeddings (
  chunkId INTEGER NOT NULL, providerKey TEXT NOT NULL,  -- "{type}:{model}:{dims}"
  modality TEXT NOT NULL, dims INTEGER NOT NULL,
  vector BLOB NOT NULL,         -- float32 LE, L2-normalized
  contentHash TEXT NOT NULL, PRIMARY KEY (chunkId, providerKey));
CREATE TABLE search_index_state (
  scopeType TEXT NOT NULL, scopeId TEXT NOT NULL,       -- note|attachment|global
  stage TEXT NOT NULL,          -- chunks|pdf_text|ocr|embed:<key>|figures:<key>
  contentHash TEXT, status TEXT NOT NULL, errorMessage TEXT, updatedAt INTEGER NOT NULL,
  PRIMARY KEY (scopeType, scopeId, stage));
CREATE INDEX idx_attachments_noteId ON attachments(noteId);  -- currently missing, used per-note in AI context
```

**No triggers on `chunks_fts`** — the indexer writes normalized content explicitly (CJK bigrams must be computed in Dart). Wrap the FTS4 CREATE in try/catch (web / future-iOS degradation; record availability). Register: table constants, `_onCreate`, `_createIndexes` (the new indexes), migration registry (~line 875-905), `getSchema()` (:471-494). **Recovery** (`recovery_screen.dart` — the flow is a table-by-table *merge* into a staging DB, :540-620): add **no merge steps** for `search_chunks`/`chunk_embeddings`/`search_index_state` (they materialize empty via `_onCreate`); after swap, clear the global-complete flag so the indexer re-backfills. Index data is derivable — never restore rows. Pause/ignore indexer events while recovery is swapping databases.

**Storage cost (stated deliberately):** raw chunk text + normalized FTS content ≈ 2–3× the corpus text on disk. Add `search_chunks.text` to CLAUDE.md's large-column list during implementation; exclude the three index tables from export/backup paths.

### 1.2 Normalizer + chunker (new, pure Dart)
- `lib/services/search/search_text_normalizer.dart`
  - `normalizeForIndex(raw)`: NFKC, lowercase, strip markdown syntax (keep alt/link text), treat CJK punctuation (、。「」《》 etc.) as run-breakers, expand CJK runs to space-separated overlapping bigrams (`中文搜索` → `中文 文搜 搜索`); a lone CJK char (run of length 1, e.g. "A中B") is indexed as a unigram.
  - `buildFtsQuery(userQuery)`: ASCII terms → `term*` implicit-AND; `"quoted"` → phrase; CJK run of ≥2 chars → phrase-of-overlapping-bigrams (preserves substring semantics — consecutive token positions); single-CJK-char query → `字*` prefix (matches its bigrams and unigrams). Escape `"`, reject bare operators. Known accepted limitation (document + test): CJK↔ASCII boundary substrings ("文abc" matching inside "中文abc") don't match — bigram tokens don't cross script boundaries.
- `lib/services/search/note_chunker.dart`: markdown-aware — split at headings then paragraphs, ~1200 chars target, heading breadcrumb prepended; one `meta` chunk = title + tags (restores tag matching `notes_fts` lacks); `chunkPdfPage()` for phase 3.
- Share the NFKC/lowercase normalization with `lib/utils/note_text_match.dart` (the extracted substring predicate) so saved-filter matching and index matching agree on case/width handling.

### 1.3 Indexer + write-path hooks
`lib/services/search/note_index_service.dart`, registered in `service_locator.dart` (constructor injection: `DatabaseService`, later the provider registry):
- `reindexNote(noteId)` — chunk-diff by `contentHash` (upsert by `chunkKey`, delete stale); `removeNote(noteId)` — delete chunks/embeddings/state (no FK cascade exists on these tables); `scheduleReindex(noteId)` — 2 s per-note debounce; `backfillAll()` — resumable via `search_index_state`, chunking in `compute()` batches; `progress` ValueListenable.
- **Hooks (critical — `DataChangeNotifier` alone is NOT sufficient):** the main UI write path (`AppProvider.addNote/updateNote/deleteNote/...`, `app_provider.dart:317,341,369,443,…`) calls `DatabaseService` directly and never publishes. Primary hook: call `scheduleReindex`/`removeNote` from the `DatabaseService` note/subnote/annotation/attachment mutation methods (single choke point covers AppProvider, tools, and services). Secondary: keep the `DataChangeNotifier` subscription (`DataChangeEvent.noteIds`, `bulk` → backfill check) to catch raw-SQL writes captured by `sql_query_service`. Raw-SQL capture currently journals only `notes`/`relationships`/`tags`/`filters` kinds (`database_service.dart:5400-5415`) — a raw `UPDATE attachments/subnotes ...` reaches neither hook. Extend the capture: add `attachments`/`subnotes` kinds (mapped to owning noteIds), or conservatively map raw-SQL writes touching those tables to `bulk`.
- Global completeness: `search_index_state('global','all','chunks') = done` set only when every note's chunk stage is complete; cleared on recovery/rebuild. This flag — not table row counts — gates the fallback (1.5).
- **Per-note / per-attachment index policy (cost control):** note-body lexical indexing is cheap and always on, but expensive stages are opt-out/opt-in at item granularity, stored as JSON in the existing `metadata` columns (mirroring the `PdfAiContextConfig` pattern in `attachment.dart`):
  - `notes.metadata.searchIndex.exclude = true` → note (and its attachments) fully excluded from the index; toggle in the note's overflow menu.
  - `attachments.metadata.searchIndex = {text: auto|off, ocr: on|off, embed: on|off}` — toggle surfaced in the attachment context menu and PDF viewer.
  - **Size-gated defaults**: PDF text extraction runs automatically up to a page cap (default ~100 pages); larger PDFs (e.g., a clipped 500-page PDF) default to **not indexed**. The "Index this PDF for search?" prompt fires **at attach/clip time** (snackbar/inline chip when a >cap PDF lands — the natural decision moment, and the only surface that intercepts the later silent-miss where a query matches only unindexed PDF text); excluded attachments are also listed in search settings ("3 large PDFs not indexed — review") and on the in-note attachment chip. OCR and embedding stages always honor the per-attachment flags; the phase-2 consent dialog's cost estimate counts only attachments currently opted in, and calls out the excluded-large-PDF count.
  - **Purge-on-toggle**: flipping an exclude flag (or turning off a stage) promptly deletes the affected chunks, embeddings, and derived figure assets, and incrementally patches the in-memory vector matrix — excluded content stops appearing in results (and stops existing as off-device-derived data) immediately.
  - **Completeness accounting**: policy-excluded notes/attachments count as *done* for the global backfill-complete flag (1.5) — otherwise a single permanent exclusion would pin search to substring fallback forever.
  - **Fallback caveat (deliberate, documented)**: the substring fallback scans in-memory note content, so an excluded *note* can still surface there. The flag is cost control, not privacy — acceptable; state it in the toggle's subtitle if user confusion shows up.
- **Never** trigger `AppProvider.loadData`.

### 1.4 Lexical query + BM25
- `DatabaseService.searchChunksLexical(ftsQuery)` — two-step to avoid rank truncation: (1) `SELECT docid, matchinfo(chunks_fts,'pcnalx') FROM chunks_fts WHERE content MATCH ?` for **all** matches (matchinfo blobs are tiny; cap at 5000 rows as a runaway guard), (2) rank in Dart, then fetch `search_chunks` rows for the top ~100 only.
- `lib/services/search/bm25.dart`: decode matchinfo (copy the BLOB into an aligned buffer before `asUint32List` — sqflite Uint8Lists aren't guaranteed 4-byte-aligned), BM25 k1=1.2 b=0.75. Snippets/highlights computed Dart-side from raw `search_chunks.text` (FTS snippet() would show bigram-mangled text).

### 1.5 SearchService (fusion core)
`lib/services/search/search_service.dart`:
- `searchLexical(query, {filter})`, `searchFused(query, {filter})` (== lexical until phase 2), `semanticAvailable`.
- Grouping happens **per layer, at note level, before fusion**: within a layer, note score = max chunk + 0.1·log(1+extraHits) (bonus applied exactly once, inside the layer); RRF then fuses the note-level lists. Best chunk supplies snippet + `attachmentId`/`page` deep link.
- **Visibility filters**: results respect the caller's archived scope (`NoteFilterContext` carries includeArchived, matching saved-filter semantics at `app_provider.dart:1252-1254`); the notes screen passes the active tab's scope. (Lexical indexing itself indexes everything not policy-excluded (1.3) — filtering is at query time.)
- **Audience filter (privacy)**: `searchLexical`/`searchFused` take an `audience` parameter (`user` | `ai`). AI-facing callers (`NoteSearchTool`, `search_figures`, any future tool) pass `ai`, which excludes chunks whose source attachment has `includeInAIContext = false` — including phase-3 `attachment_text`/`attachment_ocr` snippets. The user's own search (`user`) sees everything; the includeInAIContext contract is about the AI, not the user.
- **Fallback rule** (probe + completeness, not row counts): substring predicate is used when (a) the FTS4 probe failed, or (b) the global backfill-complete flag is unset — during backfill, substring runs *exclusively* so partially-indexed corpora never silently miss notes (worst for zh users). Additionally, a completed-index query returning zero hits re-runs as substring (status-quo cost, deliberate). Stale-query cancellation: sequence tokens; drop responses for superseded queries.

### 1.6 UI wiring + UX states
- `notes_screen.dart`: replace text-match in `_filterNotes` (570-578); 250 ms debounce; move filtering off the `build()` path; `textInputAction: TextInputAction.search` + `onSubmitted` (currently absent). Empty query keeps today's pinned-first/newest browse order untouched (:580-585).
- Result rows: snippet + **source-provenance badge** ("PDF · p.4", "Image", "Sub-note", "Tag") derived from `sourceType`/`page` — not retrieval-layer jargon. Tap with page → `ImmersiveNoteScreen(initialPage: page-1, initialAttachmentPath:)`.
- **Pending/empty states**: while any layer (or the substring fallback) is in flight show "Searching…"; render "No notes found" only after all layers returned empty — no empty-state flash. Sweep the currently hardcoded English at `notes_screen.dart:437-439` into l10n.
- **First-run banner**: one-time dismissible strip under the search bar ("Building search index… N%"), auto-dismisses at completion; substring fallback means nothing is broken meanwhile.
- `note_selection_service.dart:18-42` → route through `SearchService`. Extract the shared substring predicate to `lib/utils/note_text_match.dart`; saved filters (`app_provider.dart:1248-1297`) keep substring semantics.
- `NoteSearchTool` (`note_tools.dart:27-86`) → `searchFused` with real snippets. Delete dead `searchNotes` LIKE method (`database_service.dart:5428-5439`).
- l10n (en + zh) for all new strings.

**Verify:** unit tests — normalizer (CJK bigrams, lone-char unigrams, CJK punctuation run-breaking, script-boundary limitation documented), `buildFtsQuery` (prefix/phrase/escaping/single-CJK-char), chunker, BM25 vs hand-computed matchinfo fixtures (including unaligned-buffer case), per-layer grouping + RRF; integration — Chinese fixture notes assert substring-equivalent recall, hook coverage test (note edit via AppProvider path → chunks update; note delete → chunks gone), migration 61→62, FTS4-probe-failure degradation; manual — latency, recovery round-trip re-backfills.

---

## Phase 2 — Embedding provider abstraction + text semantic

### 2.1 Interface (`lib/services/search/embedding/embedding_provider.dart`), mirrors `AIModel`
```dart
abstract class EmbeddingProvider {
  String get providerKey;          // "{type}:{model}:{dims}" — row-level invalidation key
  String get displayName;
  int get dimensions;              // default 768
  bool get supportsImages;
  int get maxBatchSize;
  Future<bool> isReady();
  Future<List<Float32List>> embedDocuments(List<EmbeddingInput> inputs); // text and/or bytes+mime
  Future<Float32List> embedQuery(String query);
}
```
Implementations: `gemini_embedding_provider.dart` (REST `:batchEmbedContents`, HTTP layer patterned on `gemini_model.dart`; 001 text w/ task_type + re-normalize after truncation, embedding-2 multimodal w/ `output_dimensionality`, normalize-if-needed), `openai_embedding_provider.dart` (`POST {endpoint}/v1/embeddings` with a **user-editable full base URL** — presets like DeepSeek/Doubao are prefills only; a "Custom (OpenAI-compatible)" option takes free-form endpoint URL + model name + dimensions + optional API key, supporting self-hosted servers such as Ollama/vLLM/TEI/LiteLLM, where keyless endpoints are valid; the custom form has a **"Test connection"** action that embeds a probe string, auto-detects/verifies `dimensions` from the response vector length, and gates enabling on a successful probe — a wrong dims value must not produce a broken index discovered only via background errors), `local_embedding_provider.dart` (flutter_gemma `installEmbedder()` — model **+ tokenizer** download via `EmbeddingInstallationBuilder`; extend the `LocalModelPresets`/`LocalModelService` structure to two-file embedding presets — this is an extension of the existing download UX, not pure reuse; strictly opt-in), `embedding_provider_registry.dart` (`EmbeddingProvider? get active`).

### 2.2 Presets + settings UX
- `assets/embedding_presets/*.yaml` mirroring `assets/model_presets/` style + `dimensions`, `supports_images` (+ tokenizer URL for local); loader patterned on `model_preset_service.dart`; register asset dir in pubspec.
- `lib/screens/search_settings_screen.dart`, reached from a **top-level Settings tile whose subtitle shows live state** ("Lexical only" / "Gemini · indexing 62%" / "2 errors"). Contents: provider picker incl. "None (lexical only)" and "Custom (OpenAI-compatible)" with editable endpoint/model/dims/key fields, API-key reuse from matching chat provider, index progress, Rebuild, OCR/figures toggles (phases 3–4), and the large-PDF page-cap default (1.3).
- **Privacy + cost consent (cloud providers)**: one-time confirmation on enable stating what leaves the device ("~N chunks of note text[, ~M images/PDF pages] will be sent to X") with order-of-magnitude counts from the index; **wifi-only backfill defaults ON for cloud providers** (query embeddings still go over any network). OCR toggle subtitle says "on-device" to preempt the opposite fear.
- **Error surfacing**: settings shows failed-count + last error + Retry; 401/403 halts backfill immediately with a visible message (no retry burn); transient errors back off and auto-retry. `search_index_state.errorMessage` is the store, settings is the surface.
- **Rebuild** button: confirmation dialog with scope ("re-index N notes, re-embed M chunks"); disabled with progress shown while a backfill runs.

### 2.3 Pipeline + fusion
- Indexer embedding stage: gaps by `(chunkId, providerKey)` + `contentHash`, batch-embed, store. **Skip chunks whose source attachment has `includeInAIContext = false`** (`attachments` :191) — the existing privacy contract extends to embedding uploads; note text itself is governed by the provider consent above.
- **Provider-switch lifecycle (explicit state machine)** — semantic queries require the query embedded by the *same* provider as the stored vectors, which dictates the transition behavior:
  - **Switch A → B (A still usable)**: B's backfill runs in background (after B's consent dialog); semantic search keeps serving from A's vectors (queries embedded via A) until B's backfill completes, then atomically switches the active key and lazily GCs A's rows. Settings shows "Switching to B — 40% re-indexed; semantic search served by A until complete." **Active disclosure**: B's consent dialog states "Until re-indexing completes, searches will continue to use A", with a secondary "Stop using A now" option that degrades to lexical-only immediately (the A-revoked path below). A dims change within the same provider is a providerKey change and follows this same flow.
  - **A turned off / key revoked, then B enabled**: semantic layer degrades to lexical-only immediately (A can no longer embed queries); B serves once its backfill completes. A's rows GC'd.
  - **Switch to "None"**: semantic off instantly. Stored vectors are *kept* by default (re-enabling the same providerKey later needs no re-embed and no new consent); an explicit "Delete stored embeddings" action covers storage/privacy. Search itself never breaks in any transition — the lexical floor is always there.
- `lib/services/search/vector_search.dart`: `topK(query, providerKey, k)` — **long-lived search isolate** holding the matrix (avoid 30 MB `compute()` copies; `TransferableTypedData` for initial load); on note edits patch the cached matrix incrementally (add/remove rows), don't reload from SQLite.
- `searchFused`: lexical ∥ semantic, each grouped to note level, RRF `Σ 1/(60+rank)`, results tagged with contributing layers (internal; UI shows source provenance).
- **Fusion UX**: primary trigger is `onSubmitted`; secondary is ~1.5 s idle (not 600 ms — avoids paid API calls per typing pause). Session-scoped query-embedding cache. Semantic wait capped at ~2 s, then lexical order stands. Once the user scrolls or taps, the pending re-rank is dropped; when a re-rank does land, show a subtle "refining…" affordance and animate row moves.

**Verify:** `@GenerateMocks([EmbeddingProvider])`; RRF math, gap/invalidation, per-model normalization, request/response parsing with canned JSON, includeInAIContext exclusion; manual — airplane mode degrades to lexical, single-note edit re-embeds only changed chunks, bad-API-key halts visibly.

---

## Phase 3 — PDF text layer + OCR (OCR is a PRIMARY layer, not a fallback)

- `lib/services/search/attachment_text_extractor.dart`:
  - Text layer (free, on-device): pdfrx per-page `loadStructuredText().fullText` → `attachment_text` chunks with 1-based `page`; resolve paths via `file_utils.dart getFullFilePath`.
  - **OCR — primary, runs on ALL pages and raster images** (no "text layer < N chars" gating; it's on-device and cheap, and its output is load-bearing for figure detection): `google_mlkit_text_recognition` (+ Chinese script recognizer), pages rendered via `pdf_thumbnail_service.dart` (0-based renderPage — convert). Package choice researched: ML Kit is on-device/free/fast with zh support and returns hierarchical block/line/element **bounding boxes**; `flutter_tesseract_ocr` rejected (slower on mobile, `.traineddata` assets bloat app size); Apple Vision rejected (iOS-only). No manual `project.pbxproj` edits (pod-managed).
  - **Merge policy**: the PDF text layer is authoritative where present; OCR text is deduped against it (normalized-overlap suppression) and contributes only *novel* text — text inside figures/charts, scanned regions, image attachments → `attachment_ocr` chunks.
  - **Bounding boxes retained**: OCR block/line bounds are persisted with the extraction intermediates (chunk `meta`) — they are a primary input to §4.1's figure-region inference (caption detection on scanned pages; text-free-region computation over the union of text-layer `charRects` and OCR block bounds; picture regions = areas with no text blocks).
  - **Render + coordinate spec** (specced, not discovered): OCR input pages render at ~2× page size **bypassing the thumbnail LRU** (`PdfThumbnailService.renderPage` defaults to width=200 px — useless for OCR, and full-res pages must not evict the UI's thumbnail cache); the render scale is persisted alongside the bounds in chunk `meta`; ML Kit bounds (raster pixels, y-down) are mapped back to PDF page coordinates (y-up) by the inverse of the §4.1 transform before the region-inference union.
  - Guards: ≤2 concurrent pages, skip on low battery, and the OCR stage runs **preferentially while charging/idle** (a large default-on backfill is sustained CPU); the first-run banner and settings progress name the stage ("Recognizing text in PDFs — 120/900 pages") so the longer backfill reads as deliberate work. OCR layer is **enabled by default** (on-device, nothing leaves the device) but remains toggleable globally and per-attachment (1.3 policy).
- Resumable per-attachment via `search_index_state`; attachment add/delete flows through the DatabaseService choke-point hook (1.3).
- UX: PDF hits show "p. N", deep-link to the page.

**Verify:** fixture PDFs (text-layer, scanned, Chinese) in `test/fixtures/`; extractor unit tests; manual — phrase existing only on page 7 → tap → lands on page 7 (1-based/0-based conversion covered by test).

---

## Phase 4 — Multimodal figures + chat integration

### 4.1 Figure extraction + indexing — precise figures/tables, NOT page thumbnails
A whole PDF page is never presented as a "figure" in AI answers (low-res thumbnail, no value over a tappable page link). Instead, a **figure-region extraction pipeline** produces high-res crops of actual figures/tables:

- `lib/services/search/figure_region_extractor.dart` (start with a validation **spike** on representative PDFs before hardening — extraction quality is the main risk):
  1. **Caption anchors** from *both* text sources: fragments matching `^(Figure|Fig\.|Table|图|表)\s*[\d一二三…]` via `PdfPageText.fragments` bounds AND ML Kit OCR block bounds (phase 3 persists them) — OCR is a first-class signal, not a scanned-page fallback.
  2. **Region inference**: compute the text-free rectangle adjacent to each caption (above for figures, either side for tables) over the **union** of text-layer `charRects` and OCR block bounds, expanded to column margins / nearest text boundaries. Pages with large text-free areas but no caption become caption-less candidates (lower confidence, kept behind a threshold).
  3. **High-res crop render** via `PdfPage.render(x, y, width, height, fullWidth, fullHeight)` at 2–3× → derived asset saved under `attachments/derived/<attachmentId>_p<N>_f<i>.png`; recorded in the figure chunk's `meta` JSON (`{caption, rect, derivedAssetPath}`). **Coordinate transform (specced, not discovered)**: text `bounds`/`charRects` are in PDF page coordinates (y-up, origin bottom-left); `render` takes raster pixels within `fullWidth × fullHeight` (y-down, origin top-left) — map as `x_px = rect.left·scale`, `y_px = (pageHeight − rect.top)·scale`, `w_px = rect.width·scale`, `h_px = rect.height·scale`. Derived assets are regenerable — excluded from export/backup (implementation must locate the actual export/backup paths that copy the attachments dir and exclude `derived/` there, same task as excluding the three index tables), rebuilt on demand if missing.
- `figure` chunks: one per **extracted region** and one per raster image attachment (not per page). `text` = caption + fileName + markdown alt text + region OCR text → lexically findable with no provider. **SVG attachments are lexical-only** (filename/alt) unless rasterized first — `Image.file` can't render SVG, ML Kit can't OCR it, Gemini image input rejects `image/svg+xml`.
- If `active.supportsImages`: embed the **derived figure crops** and raster images (`modality=image`, downscaled to ~768 px longest side) — cheaper and sharper than embedding whole pages. Whole-page embeddings (when enabled) serve *search* (locating the right page, surfaced as a page deep **link**), never *display*. **`includeInAIContext = false` attachments are excluded from figure indexing entirely** (never surfaced to the model or uploaded). Per-attachment index policy (1.3) governs whether extraction runs at all.

### 4.2 `search_figures` tool + "Figure Answers" agent skill
The reply-quality guidance lives in a **user-installable agent skill**, not the tool description — Note Synapse's skill system (notes tagged `agent-skill` with YAML frontmatter, indexed by `SkillService.buildSkillIndex`, loaded on demand via the `load_skill` tool) exists for exactly this: keep tool schemas lean, put workflow instruction where the user can inspect, edit, and disable it.

**Tool** (`lib/services/tools/figure_tools.dart`) — mechanical contract only:
- Input `{query, noteId?, limit?}`; output: numbered String list — caption/source note title/page + ready-to-embed markdown `![caption](synapseresource://figure/<figureId>)` resolving to the high-res derived crop. **`figureId` is content-addressed** — `<chunkKey>~<contentHash-prefix>` — so a URI embedded in an old chat message can never silently resolve to a *different* region after re-extraction renumbers `seq`: on resolve, hash mismatch (or missing chunk) renders the dangling-figure placeholder, never a wrong figure with a confident provenance bar (raster image attachments use `synapseresource://attachment/<id>`). Page-level hits (no extracted region) are returned as **plain links** `[title, p.N](synapseresource://attachment/<id>?page=N)`. The tool result also reports which search layers are currently off (data for the skill's no-match phrasing). Uses `SearchService` over figure chunks (semantic when multimodal provider active, else lexical), honoring includeInAIContext + archived scope. Tool description stays to a few lines: what it searches, the output format, one sentence "figures embed as images; pages are links, never images; prefer retrieval over generating images" as the minimal always-present guardrail for users without the skill.
- Register in `agent_service.dart nativeTools` (:1172-1204), `conversation_chat_screen.dart _buildActiveToolsMap` (:698-770), `chat_tool_session.dart` (:~308). Tool results stay Strings — URIs carry the payload. Reads the live index, so deleted figures naturally stop being offered (test this).

**Skill** (`assets/starter/skills/Figure_Answers.md`, installed via `StarterService` like the bundled Knowledge Exploration skill — deduped by `skill_ref`, user-editable/disable-able as a note):
- Frontmatter: `name: Figure Answers`, `skill_ref: figure-answers`, `description:` a one-liner tuned to make the model load it whenever a reply could benefit from a visual from the user's notes.
- Body carries the bulk: when to call `search_figures` (before ever generating an image; when the user asks about diagrams/tables/charts/screenshots; when explaining something a stored figure shows), how to choose among hits, embedding format and caption phrasing, provenance ("from *Note title*, p.N"), figures-as-images vs pages-as-links, no-match behavior (state it plainly; using the tool's layer-state report, mention only layers currently off; never silently fall back to image generation), and cost guidance (retrieval is free; generation is expensive — retrieval first).
- The previously planned system-prompt line shrinks to nothing: the skill-index entry (name + description, prompt-injected) is the discovery surface; the tool's one-line guardrail covers skill-less sessions.
- Discoverability cross-link: when figure indexing is enabled in search settings and the skill isn't installed, show "Install the Figure Answers skill for better figure replies" linking to the starter-skill install.

### 4.3 Renderer fixes (load-bearing)
- `interactive_checkbox_markdown.dart`: image builder resolves `synapseresource://figure/<figureId>` (→ derived asset file after hash verification, re-extracting on demand if the asset is missing) and `synapseresource://attachment/<id>` (image attachments) **without requiring noteId** (gate at :675, `_resolveLocalImageSource` :1128-1243); look up via `AttachmentLinkService`/`DatabaseService` → `Image.file`. `synapseresource://attachment/<id>?page=N` stays a **tap-link only** (existing behavior) — pages are never rendered as inline images. Fixes chat bubbles (`ChipAwareAiMessageContent` already has an optional `noteId` param — the resolution just must not require it).
- **New URI type**: register `figure/<figureId>` in `synapse_resource_uri.dart` (currently note|conversation|attachment|app) and `AttachmentLinkService`.
- **Provenance**: figures resolved from `synapseresource://figure/...` or `attachment/...` get an info bar showing the owning note's title + "p.N"; tapping it navigates to `ImmersiveNoteScreen(initialAttachmentPath, initialPage)` (nav already exists in `_handleSynapseResourceLink` :309-332); fullscreen zoom stays as secondary action.
- **Dangling figures**: attachment URI resolving to a missing attachment renders an l10n'd placeholder ("Figure no longer available — source note was deleted"), no network fallback, no retry spinner.
- Behavioral guidance lives in the Figure Answers skill (4.2); no new system-prompt text beyond the skill-index entry.
- Hardening: in `ConversationService.addAIResponse` (:515-575), promote `synapsetemp:///` images via `ConversationAttachmentService.processContentForAttachments` (:42) so AI-generated figures survive temp-cache eviction (mirrors the note path).
- Stated non-goal: `synapseresource://` figure URIs in exported/shared content resolve only inside the app; export paths keep their existing attachment rendering, chat-figure export is out of scope.

**Verify:** extractor spike report on representative PDFs (figure/table/Chinese-caption fixtures — precision of caption detection + region bounds); widget test — `![x](synapseresource://figure/<figureId>)` renders the high-res crop without noteId and shows the provenance bar, while `attachment/<id>?page=3` stays a tap-link; deleted-attachment and hash-mismatch placeholder tests; `search_figures` stops offering deleted figures; skill tests — `parseSkillMetadata` accepts the Figure Answers frontmatter, StarterService install/dedupe by `skill_ref`; mock-provider figure ranking; manual chat (skill installed) — "show me the architecture diagram from my notes" → model loads the skill, calls `search_figures`, embeds the inline high-res figure with tap-through to source, no image generation, no page thumbnails; manual chat (skill absent) — tool's one-line guardrail still prevents page-as-image and generation-first behavior.

---

## Risks / mitigations
- **CJK regression**: bigram normalization + phrase-of-bigram queries + lone-char unigrams + CJK punctuation run-breakers; substring-exclusive fallback until backfill completes; zh fixtures. Accepted gap: cross-script boundary substrings.
- **FTS4 platform availability**: startup probe + substring degradation; escape hatch = mobile ffi + existing custom sqlite3 amalgamation (FTS4-preserving). Web: try/catch migration, substring-only.
- **Index size**: ~3 KB/chunk at 768 dims (~30 MB @10k chunks) + 2–3× text duplication; Matryoshka 256-dim option; exclude index tables from export/backup; document `search_chunks.text` as a large column.
- **Embedding cost/privacy**: contentHash skip, batching, per-layer opt-in, consent dialog with counts, wifi-only default for cloud backfill, pausable; includeInAIContext honored end-to-end.
- **Ranking truncation**: matchinfo-for-all-matches (capped 5000) before Dart BM25; text fetched only for top N.
- **Rowid stability**: `INTEGER PRIMARY KEY` rowid alias + `chunkKey` unique index — VACUUM-safe.
- **Recovery drift**: no merge steps for index tables; clear global flag → re-backfill; indexer paused during recovery.
- **Local model size**: strictly opt-in, two-file (model+tokenizer) preset download.
- **Figure-extraction quality**: caption/region inference will miss caption-less figures and can mis-crop unusual layouts — de-risked by the upfront spike, a confidence threshold on caption-less candidates, and graceful degradation (a page-level *link* result is always available when no region is extracted).
- **Indexing cost surprises**: size-gated defaults (large PDFs opt-in), per-note/per-attachment policy flags, and consent-dialog counts keep a clipped 500-page PDF from silently triggering extraction/OCR/embedding.

## Delivery order
Phase 1 alone fixes the worst pain (ranked search, tags/subnotes coverage, CJK-safe) with zero config; phases 2–4 are purely additive, matching the layered-architecture constraint. Run `dart run build_runner build --delete-conflicting-outputs` after mock/model changes; `flutter analyze` + `flutter test` per phase.
