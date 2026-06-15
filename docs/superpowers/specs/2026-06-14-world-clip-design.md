# Design: World Clip — video → note capture pipeline

**Status:** Approved design (brainstorm complete)
**Author:** liwen
**Date:** 2026-06-14
**Branch:** `kkspeed/world_clipper`
**Source idea:** the capture pipeline (part 1) of `story_book` PRD
(`/Users/liwen/develop/projects/story_book/PRD.md`), ported into Note Synapse.

---

## 1. Summary

World Clip turns a single video into a note. The user imports a video that pans
over physical or on-screen content — a book, a row of whiteboards, notice/poster
pages, or an app screen-recording — then uses an in-app editor to **select key
frames**, **optionally correct each frame** (crop, rotate, or perspective/mesh
dewarp), **reorder** them, and **compile** the result into a Note Synapse note as
either a **PDF attachment** or **inline page images**.

World Clip deliberately ships **no AI of its own**. Once the captured content is a
note with a PDF/image attachment, every existing Note Synapse capability applies
for free: multimodal Gemini (`generateWithAttachments`), the pdfrx viewer, PDF
AI-context page-windows/bookmarks, conversations, and tag-driven workflows. This is
why only "the first part" (capture) needs porting — Note Synapse already provides
the narration/chat/summarization layers that `story_book` would have had to build.

The atomic unit is a **clip** (a selected, optionally-corrected frame). The output
is an ordered set of clips materialized as a note.

## 2. Goals & Non-Goals

### Goals
- Import a video and extract frames at ~5fps with a scrubable proxy-thumbnail
  timeline.
- Auto-**suggest** stable/sharp/distinct key frames; let the user freely scrub the
  timeline to **add** or **delete** key frames (suggestions are a seed, never a
  constraint).
- Offer an **optional** per-frame correction toolbox: crop, rotate, and
  perspective **mesh dewarp** with user-draggable control points.
- Support **multi-quad / mesh** dewarp so curved or folded pages flatten correctly
  (more than single-homography keystone).
- Review/accept/reject/**drag-reorder** clips, then **compile** to a note as a PDF
  attachment **or** inline images (user chooses at compile time).
- Persist the editing session as a **cached, re-editable project** browsable from
  Settings; allow multiple projects from the same source video.
- Keep the capture path fully on-device; introduce **no** new DB migration, AI
  surface, or key storage.

### Non-Goals (v1)
- Any AI feature (narration, chat, summarization) — reused from existing Note
  Synapse, not built here.
- In-app camera recording — deferred behind the `VideoSource` seam (v1 imports
  from gallery; mobile in-app recording typically fires a camera intent anyway).
- Durable relational storage of capture projects (projects live in OS cache and
  may be flushed; the committed note is the durable artifact).
- Curved-gutter perfection beyond what the user-corrected mesh achieves.
- Audio: the source video's audio track is never read.

## 3. Architecture & module map

Feature module: `lib/services/world_clip/` + `lib/screens/world_clip/`. Each unit
sits behind a clear seam so it can be understood and tested in isolation.

| Module | Responsibility | v1 impl | Seam for later |
|---|---|---|---|
| `VideoSource` | Yield a source video file | `GalleryVideoSource` (image_picker `pickVideo`) | `CameraIntentVideoSource` |
| `FrameExtractor` | Decode at ~5fps; downsampled proxy thumbnails; full-res decode-on-seek | OpenCV `VideoCapture` | dedicated/native extractor |
| `FrameSelector` | Suggest stable/sharp/distinct frames (seed for manual editing) | OpenCV (Laplacian sharpness + frame-diff stability + scene-change) | ML selector |
| `FrameCorrection` | Optional toolbox applied per clip | `CropTool`, `RotateTool`, `MeshDewarpTool` behind one seam | neural dewarp |
| `ClipProjectStore` | CRUD cached project (JSON + frames) in cache dir; list in Settings | dart:io + JSON | — |
| `ClipCompiler` | Ordered corrected frames → PDF (existing `pdf` pkg) **or** inline-image markdown note; write permanent attachments + create note | both outputs | — |

**Integration boundary:** the feature ends at "a note with a PDF/image
attachment." It reuses the existing `notes` + `attachments` tables, the `FileUtils`
storage convention, the `pdf` package for PDF generation, and `DatabaseService`.
**No DB migration.**

## 4. Pipeline flow & editor UX

Staged editor screen `WorldClipFlowScreen`; each stage is isolated and testable.

- **Stage 0 — Source.** `VideoSource` yields a video (v1: gallery import). Copied
  into the project cache dir. Audio track never read.
- **Stage 1 — Extract & timeline.** `FrameExtractor` decodes at ~5fps into proxy
  thumbnails (decode-on-seek, one full-res frame at a time — OOM discipline). The
  timeline renders the proxy strip.
- **Stage 2 — Frame selection (timeline).** `FrameSelector` seeds **suggested** key
  frames. The user scrubs the timeline freely to inspect any frame, **adds** a key
  frame at the playhead, or **deletes** any tag (suggested or manual). Each tag is a
  candidate clip.
- **Stage 3 — Optional per-clip correction.** For each clip, the user may apply the
  `FrameCorrection` toolbox: crop, rotate, and/or perspective **mesh dewarp**.
  Mesh defaults to a 4-corner quad; the user drags control points to correct, and
  can **subdivide** (add a crease line) only when a page is folded/curved. Frames
  needing nothing (e.g. app screenshots) skip this stage. Live preview.
- **Stage 4 — Review & reorder.** A clip grid: accept / reject / **drag-reorder** /
  jump back to re-select or re-correct any clip. No text editing.
- **Stage 5 — Compile.** `ClipCompiler` renders ordered full-res corrected frames
  and asks the user the output choice:
  - **PDF attachment** → one PDF via the existing `pdf` package, attached to a new
    note (slots into the pdfrx viewer + PDF AI-context page-windows/bookmarks).
  - **Inline images** → each clip saved as an attachment, referenced as
    `![clip N](attachments/...)` in the note's markdown.
  Either output writes permanent files via
  `FileUtils.savePlatformFileToPrivateStorage` and creates the note via
  `DatabaseService.createNote`. The cached project survives for re-editing until the
  OS flushes cache.

**Entry points:**
1. Main screen **[+] button** modal sheet (`lib/screens/main_screen.dart:132`) →
   new **"World Clip"** `ListTile` placed directly **below** "New Note From
   Clipboard" (`main_screen.dart:213`).
2. **Settings → "World Clip Projects"** — list/resume/duplicate/delete cached
   projects; create a new project from the same source video.

## 5. Data shapes & persistence

Cache-resident project (flushable); the durable artifact is the committed note.

```
{cacheDir}/world_clip/{projectId}/
  project.json
  source.<ext>          # imported video (copied in)
  proxy/                # downsampled timeline thumbnails
  clips/{clipId}.png    # corrected frame previews (pre-commit)
```

```jsonc
// project.json
{
  "id": "...",
  "name": "Whiteboard 2026-06-14",
  "createdAt": "ISO-8601",
  "sourceVideo": "source.mp4",
  "clips": [
    {
      "id": "...",
      "frameTimestampMs": 12340,
      "order": 0,
      "corrections": [                 // empty = use raw frame as-is
        { "tool": "meshDewarp", "grid": { "rows": 2, "cols": 1, "points": [ /* ... */ ] } },
        { "tool": "crop", "rect": [0, 0, 100, 100] }
      ]
    }
  ]
}
```

On **Compile**: each clip's `corrections` are replayed at full-res → ordered
images → PDF or inline-image note → permanent attachments + note. Multiple projects
may reference the same source video with different corrections. No DB schema change.

## 6. Dependencies & technical risks

**New dependency:** `opencv_dart` (a.k.a. `dartcv`) — covers video frame decode,
frame-selection heuristics, and the correction toolbox (crop/rotate/mesh dewarp)
in one native dependency.

Risks, in priority order:

1. **OpenCV `VideoCapture` file decode on mobile (#1 spike).** Requires the FFmpeg
   backend compiled into the OpenCV build; not guaranteed on prebuilt iOS/Android
   binaries. **Mitigation/fallback:** a dedicated extractor (native method-channel
   frame grab, or `ffmpeg_kit_flutter_new`) behind the `FrameExtractor` seam.
   **Spike this on real iOS + Android before committing the architecture.**
2. **OOM on mobile.** Proxy thumbnails for the timeline, decode-on-seek, one
   full-res frame at a time, explicit `Mat` disposal (OpenCV memory is not
   GC-managed). Validate on a mid-tier reference device.
3. **Mesh-dewarp touch UX.** Dragging many control points on a phone is fiddly.
   Default to a 4-corner quad; subdivide (add a crease) only on demand.
4. **App size.** OpenCV native libs add binary weight; accepted for v1.
5. **iOS vs Android extraction parity.** Verify both in the spike.

No DB migration, no new AI surface, no new key storage.

### Spike result (2026-06-15)

- **Resolved package:** `opencv_dart ^2.2.1+4` (backed by `dartcv4 2.2.1+4`), **not**
  the `^1.3.5` the plan first guessed. `flutter pub get` resolved cleanly with no
  constraint conflicts. The compatibility shim `package:opencv_dart/opencv_dart.dart`
  still re-exports the full API, so `import ... as cv;` is unchanged.
- **API validation (host):** every symbol the plan relies on was confirmed present in
  2.2.1+4: `VideoCapture.fromFile` / `isOpened` / `get(int)` / `read()` → `(bool, Mat)`
  / `release()`; `imencode` → `(bool, Uint8List)`; `imdecode(Uint8List, int)`;
  `cvtColor`, `laplacian(src, ddepth)`, `meanStdDev` → `(Scalar, Scalar)`, `resize`
  (takes a `(int,int)` record), `absDiff`, `mean` → `Scalar`; `getRotationMatrix2D`,
  `warpAffine`, `getPerspectiveTransform2f`, `warpPerspective`; `Mat.create`,
  `Mat.zeros`, `Mat.region`, `clone`, `copyTo`, `Rect`, `Point2f`, `VecPoint2f.fromList`,
  `MatType.CV_8UC3` / `CV_64F`.
- **2.x deltas applied in implementation:** `meanStdDev` returns a `Scalar` (not a
  `Mat`), so sharpness reads `stddev.val1` rather than `stddev.at<double>(0,0)`. All
  other plan call sites are API-compatible with 2.x as written.
- **Decision: PASS (API), with a caveat.** `OpenCvFrameExtractor` (Task 8) uses
  `VideoCapture`. The on-device decode gate (real iOS + Android) from the original
  spike could **not** be executed in this headless environment; the host-OpenCV
  integration test (Task 8) skips gracefully when the host build lacks a video
  backend. The `FrameExtractor` seam preserves the documented fallback (native
  method-channel grab or `ffmpeg_kit_flutter_new`) should on-device decode fail
  QA — no architecture change is needed to switch backends.

## 7. Testing strategy

Follows the repo's mockito + `getIt` `resetForTesting()` pattern.

- **Unit:** `FrameSelector` heuristics (synthetic frame sequences → expected
  suggestions); `FrameCorrection` mesh math (warp a synthetic grid, assert
  round-trip); `ClipCompiler` (ordered images → PDF page count / inline-image
  markdown + attachment rows); `ClipProjectStore` (JSON round-trip, graceful
  behavior when the cache dir is missing/flushed).
- **Integration:** fixture video → run pipeline headless → assert produced note +
  N attachments.
- **Widget:** timeline add/delete-tag interactions; mesh corner-drag; review-screen
  reorder.
- **Manual corpus (quality gate):** a book pan, an app screen-recording, and a
  whiteboard pan — confirming clean, ordered, legible clips.
- **l10n:** new strings added to `app_en.arb` + `app_zh.arb` (and generated
  `app_localizations*.dart`).

## 8. Build order

1. **Spike** OpenCV `VideoCapture` frame decode on real iOS + Android (risk #1);
   confirm or fall back behind `FrameExtractor`.
2. `VideoSource` (gallery import) + `FrameExtractor` + proxy timeline (Stages 0–1).
3. `FrameSelector` suggestions + manual add/delete on the timeline (Stage 2).
4. `FrameCorrection` toolbox: crop/rotate, then mesh dewarp with subdivide
   (Stage 3).
5. Review/reorder (Stage 4) + `ClipCompiler` PDF and inline-image outputs
   (Stage 5).
6. `ClipProjectStore` + Settings "World Clip Projects" list (resume/duplicate/
   delete; new project from same video).
7. Entry point in main-screen [+] sheet; l10n strings.
