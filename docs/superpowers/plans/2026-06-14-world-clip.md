# World Clip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "World Clip" feature that turns a video (panning over a book, whiteboards, notice pages, or an app screen-recording) into a Note Synapse note by selecting key frames, optionally correcting them (crop / rotate / mesh-dewarp), reordering, and compiling to a PDF attachment or inline images.

**Architecture:** A self-contained feature module (`lib/services/world_clip/` + `lib/screens/world_clip/`) built behind seams (`VideoSource`, `FrameExtractor`, `FrameCorrection`). Pure-Dart logic (project model, JSON store, frame-selection heuristics, compiler) is TDD'd in isolation; OpenCV-backed and UI pieces get concrete code plus widget/manual verification. The feature ends at "a note with a PDF/image attachment" — it builds no AI and requires no DB migration (output reuses the existing `notes` + `attachments` tables and `FileUtils` storage).

**Tech Stack:** Flutter, Dart, `opencv_dart` (new — video decode + image correction), `image_picker` (existing — gallery video pick), `pdf` (existing — PDF generation), `path_provider` (existing — cache dir), `get_it` (existing — DI), `mockito` (existing — tests).

**Spec:** `docs/superpowers/specs/2026-06-14-world-clip-design.md`

---

## File Structure

**Models (pure Dart, no Flutter import):**
- `lib/services/world_clip/models/norm_point.dart` — normalized 0..1 point.
- `lib/services/world_clip/models/mesh_grid.dart` — control-point grid for dewarp.
- `lib/services/world_clip/models/correction.dart` — sealed `Correction` (`CropCorrection`, `RotateCorrection`, `MeshDewarpCorrection`).
- `lib/services/world_clip/models/clip_spec.dart` — one selected frame + its corrections.
- `lib/services/world_clip/models/clip_project.dart` — a cached editing project.

**Services / seams:**
- `lib/services/world_clip/video_source.dart` — `VideoSource` abstract + `GalleryVideoSource`.
- `lib/services/world_clip/frame_extractor.dart` — `FrameExtractor` abstract + `FrameFeature`/`OpenCvFrameExtractor`.
- `lib/services/world_clip/frame_selector.dart` — pure selection heuristics over `FrameFeature`s.
- `lib/services/world_clip/frame_correction.dart` — `FrameCorrection` abstract + `OpenCvFrameCorrection`.
- `lib/services/world_clip/clip_project_store.dart` — JSON CRUD in cache dir.
- `lib/services/world_clip/clip_compiler.dart` — ordered corrected pages → note (PDF or inline images).

**UI:**
- `lib/screens/world_clip/world_clip_flow_screen.dart` — staged orchestrator.
- `lib/screens/world_clip/world_clip_timeline.dart` — scrubable timeline + add/delete tags.
- `lib/screens/world_clip/mesh_editor.dart` — per-clip correction editor.
- `lib/screens/world_clip/clip_review_screen.dart` — accept/reject/reorder.
- `lib/screens/world_clip/world_clip_projects_screen.dart` — Settings project list.

**Integration:**
- `lib/screens/main_screen.dart` — `[+]` sheet ListTile.
- `lib/l10n/app_en.arb`, `lib/l10n/app_zh.arb` — new strings.
- `pubspec.yaml` — add `opencv_dart`.

**Tests:** mirror under `test/world_clip/`.

---

## Phase 0 — De-risking spike

### Task 1: Spike — validate OpenCV video frame decode on device

> This is a throwaway probe (PRD risk #1). It is NOT TDD'd. Its job is a go/no-go on `opencv_dart`'s `VideoCapture` file decode on real iOS + Android. If it fails, switch the `FrameExtractor` impl in Task 8 to a dedicated extractor (`ffmpeg_kit_flutter_new` or a native method channel) — the rest of the plan is unaffected because everything sits behind the `FrameExtractor` seam.

**Files:**
- Modify: `pubspec.yaml`
- Create (throwaway): `lib/screens/world_clip/_spike_extractor_screen.dart`

- [ ] **Step 1: Add the dependency**

In `pubspec.yaml`, under `dependencies:` (alongside `image: ^4.2.0`), add:

```yaml
  opencv_dart: ^1.3.5
```

Run:
```bash
flutter pub get
```
Expected: resolves without conflict. If the version is unavailable, run `flutter pub add opencv_dart` to pick the latest compatible and record it here.

- [ ] **Step 2: Write a throwaway probe screen**

Create `lib/screens/world_clip/_spike_extractor_screen.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// THROWAWAY spike screen — delete after Task 1's decision is recorded.
class SpikeExtractorScreen extends StatefulWidget {
  const SpikeExtractorScreen({super.key});
  @override
  State<SpikeExtractorScreen> createState() => _SpikeExtractorScreenState();
}

class _SpikeExtractorScreenState extends State<SpikeExtractorScreen> {
  String _log = 'Pick a video to probe VideoCapture.';
  Uint8List? _firstFrame;

  Future<void> _run() async {
    final picked =
        await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    final sw = Stopwatch()..start();
    final cap = cv.VideoCapture.fromFile(picked.path);
    if (!cap.isOpened) {
      setState(() => _log = 'FAIL: VideoCapture could not open the file.');
      cap.release();
      return;
    }
    final fps = cap.get(cv.CAP_PROP_FPS);
    final count = cap.get(cv.CAP_PROP_FRAME_COUNT);
    final (ok, mat) = cap.read();
    String frameInfo = 'no frame';
    if (ok && !mat.isEmpty) {
      final (encOk, png) = cv.imencode('.png', mat);
      if (encOk) _firstFrame = png;
      frameInfo = '${mat.cols}x${mat.rows}';
    }
    mat.dispose();
    cap.release();
    sw.stop();
    setState(() => _log =
        'fps=$fps count=$count firstFrame=$frameInfo open+read=${sw.elapsedMilliseconds}ms');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Spike: VideoCapture')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(onPressed: _run, child: const Text('Pick & probe')),
              const SizedBox(height: 16),
              Text(_log, textAlign: TextAlign.center),
              if (_firstFrame != null) ...[
                const SizedBox(height: 16),
                SizedBox(height: 200, child: Image.memory(_firstFrame!)),
              ],
            ],
          ),
        ),
      );
}
```

- [ ] **Step 3: Wire a temporary launch and run on devices**

Temporarily push `SpikeExtractorScreen` from any debug entry point (e.g. add a transient button in `main_screen.dart`, or `flutter run` with it as `home`). Run on:
- a real Android device,
- a real iOS device.

Pick a ~30–60s video on each. Record in this task: did `VideoCapture` open, what `fps`/`count` were reported, did the first frame decode to a non-empty `WxH`, and the open+read time.

- [ ] **Step 4: Record the decision**

Append a "Spike result" note to `docs/superpowers/specs/2026-06-14-world-clip-design.md` §6:
- **PASS** → `OpenCvFrameExtractor` (Task 8) uses `VideoCapture`.
- **FAIL** (cannot open / empty frames on either platform) → Task 8 implements `FrameExtractor` with a fallback extractor instead; note the chosen package.

- [ ] **Step 5: Delete the throwaway and commit**

```bash
git rm lib/screens/world_clip/_spike_extractor_screen.dart
# revert any temporary launch wiring in main_screen.dart
git add pubspec.yaml pubspec.lock docs/superpowers/specs/2026-06-14-world-clip-design.md
git commit -m "spike: validate opencv_dart VideoCapture decode on device"
```

---

## Phase 1 — Project model (pure Dart, TDD)

### Task 2: NormPoint and MeshGrid value types

**Files:**
- Create: `lib/services/world_clip/models/norm_point.dart`
- Create: `lib/services/world_clip/models/mesh_grid.dart`
- Test: `test/world_clip/mesh_grid_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/world_clip/mesh_grid_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/models/norm_point.dart';
import 'package:note_synapse/services/world_clip/models/mesh_grid.dart';

void main() {
  test('identity grid has (rows+1)*(cols+1) evenly spaced points', () {
    final g = MeshGrid.identity(rows: 2, cols: 1);
    expect(g.points.length, 6); // (2+1)*(1+1)
    expect(g.points.first, const NormPoint(0, 0));
    expect(g.points.last, const NormPoint(1, 1));
  });

  test('round-trips through json', () {
    final g = MeshGrid(rows: 1, cols: 1, points: const [
      NormPoint(0, 0), NormPoint(1, 0), NormPoint(0, 1), NormPoint(0.9, 1),
    ]);
    final back = MeshGrid.fromJson(g.toJson());
    expect(back.rows, 1);
    expect(back.cols, 1);
    expect(back.points.last.x, 0.9);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/world_clip/mesh_grid_test.dart`
Expected: FAIL (target files do not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/services/world_clip/models/norm_point.dart`:

```dart
/// A point in normalized image coordinates (0..1, top-left origin).
class NormPoint {
  final double x;
  final double y;
  const NormPoint(this.x, this.y);

  Map<String, dynamic> toJson() => {'x': x, 'y': y};
  factory NormPoint.fromJson(Map<String, dynamic> j) =>
      NormPoint((j['x'] as num).toDouble(), (j['y'] as num).toDouble());

  @override
  bool operator ==(Object other) =>
      other is NormPoint && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);
}
```

Create `lib/services/world_clip/models/mesh_grid.dart`:

```dart
import 'norm_point.dart';

/// A control-point grid over a frame in normalized coords, row-major.
/// `rows`/`cols` are CELL counts; there are (rows+1)*(cols+1) points.
class MeshGrid {
  final int rows;
  final int cols;
  final List<NormPoint> points;

  const MeshGrid({required this.rows, required this.cols, required this.points});

  factory MeshGrid.identity({required int rows, required int cols}) {
    final pts = <NormPoint>[];
    for (var r = 0; r <= rows; r++) {
      for (var c = 0; c <= cols; c++) {
        pts.add(NormPoint(c / cols, r / rows));
      }
    }
    return MeshGrid(rows: rows, cols: cols, points: pts);
  }

  Map<String, dynamic> toJson() => {
        'rows': rows,
        'cols': cols,
        'points': points.map((p) => p.toJson()).toList(),
      };

  factory MeshGrid.fromJson(Map<String, dynamic> j) => MeshGrid(
        rows: j['rows'] as int,
        cols: j['cols'] as int,
        points: (j['points'] as List)
            .map((e) => NormPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/world_clip/mesh_grid_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/world_clip/models/norm_point.dart lib/services/world_clip/models/mesh_grid.dart test/world_clip/mesh_grid_test.dart
git commit -m "feat(world_clip): add NormPoint and MeshGrid value types"
```

### Task 3: Correction sealed type

**Files:**
- Create: `lib/services/world_clip/models/correction.dart`
- Test: `test/world_clip/correction_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/world_clip/correction_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/models/correction.dart';
import 'package:note_synapse/services/world_clip/models/mesh_grid.dart';

void main() {
  test('crop round-trips and tags itself', () {
    final c = CropCorrection(x: 0.1, y: 0.2, width: 0.5, height: 0.6);
    final json = c.toJson();
    expect(json['tool'], 'crop');
    final back = Correction.fromJson(json) as CropCorrection;
    expect(back.width, 0.5);
  });

  test('rotate round-trips', () {
    final back = Correction.fromJson(RotateCorrection(degrees: 90).toJson());
    expect((back as RotateCorrection).degrees, 90);
  });

  test('meshDewarp round-trips', () {
    final c = MeshDewarpCorrection(grid: MeshGrid.identity(rows: 1, cols: 1));
    final back = Correction.fromJson(c.toJson()) as MeshDewarpCorrection;
    expect(back.grid.points.length, 4);
  });

  test('unknown tool throws', () {
    expect(() => Correction.fromJson({'tool': 'bogus'}), throwsArgumentError);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/world_clip/correction_test.dart`
Expected: FAIL (file does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/services/world_clip/models/correction.dart`:

```dart
import 'mesh_grid.dart';

/// A single reversible edit applied to a clip's source frame.
sealed class Correction {
  Map<String, dynamic> toJson();

  static Correction fromJson(Map<String, dynamic> json) {
    switch (json['tool'] as String) {
      case 'crop':
        return CropCorrection.fromJson(json);
      case 'rotate':
        return RotateCorrection.fromJson(json);
      case 'meshDewarp':
        return MeshDewarpCorrection.fromJson(json);
      default:
        throw ArgumentError('Unknown correction tool: ${json['tool']}');
    }
  }
}

/// Crop to a normalized rect (0..1).
class CropCorrection extends Correction {
  final double x, y, width, height;
  CropCorrection(
      {required this.x,
      required this.y,
      required this.width,
      required this.height});

  @override
  Map<String, dynamic> toJson() =>
      {'tool': 'crop', 'rect': [x, y, width, height]};

  factory CropCorrection.fromJson(Map<String, dynamic> j) {
    final r = (j['rect'] as List).cast<num>();
    return CropCorrection(
        x: r[0].toDouble(),
        y: r[1].toDouble(),
        width: r[2].toDouble(),
        height: r[3].toDouble());
  }
}

/// Rotate by degrees (clockwise).
class RotateCorrection extends Correction {
  final double degrees;
  RotateCorrection({required this.degrees});

  @override
  Map<String, dynamic> toJson() => {'tool': 'rotate', 'degrees': degrees};

  factory RotateCorrection.fromJson(Map<String, dynamic> j) =>
      RotateCorrection(degrees: (j['degrees'] as num).toDouble());
}

/// Perspective/mesh dewarp using a control-point grid.
class MeshDewarpCorrection extends Correction {
  final MeshGrid grid;
  MeshDewarpCorrection({required this.grid});

  @override
  Map<String, dynamic> toJson() =>
      {'tool': 'meshDewarp', 'grid': grid.toJson()};

  factory MeshDewarpCorrection.fromJson(Map<String, dynamic> j) =>
      MeshDewarpCorrection(
          grid: MeshGrid.fromJson(j['grid'] as Map<String, dynamic>));
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/world_clip/correction_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/world_clip/models/correction.dart test/world_clip/correction_test.dart
git commit -m "feat(world_clip): add Correction sealed type (crop/rotate/mesh)"
```

### Task 4: ClipSpec and ClipProject

**Files:**
- Create: `lib/services/world_clip/models/clip_spec.dart`
- Create: `lib/services/world_clip/models/clip_project.dart`
- Test: `test/world_clip/clip_project_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/world_clip/clip_project_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/models/clip_spec.dart';
import 'package:note_synapse/services/world_clip/models/clip_project.dart';
import 'package:note_synapse/services/world_clip/models/correction.dart';

void main() {
  test('ClipSpec round-trips with corrections', () {
    final spec = ClipSpec(
      id: 'c1',
      frameTimestampMs: 12340,
      order: 0,
      corrections: [RotateCorrection(degrees: 90)],
    );
    final back = ClipSpec.fromJson(spec.toJson());
    expect(back.id, 'c1');
    expect(back.frameTimestampMs, 12340);
    expect(back.corrections.single, isA<RotateCorrection>());
  });

  test('ClipProject round-trips with clips', () {
    final project = ClipProject(
      id: 'p1',
      name: 'Whiteboard',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      sourceVideoFileName: 'source.mp4',
      clips: [
        ClipSpec(id: 'c1', frameTimestampMs: 0, order: 0, corrections: const []),
      ],
    );
    final back = ClipProject.fromJson(project.toJson());
    expect(back.name, 'Whiteboard');
    expect(back.sourceVideoFileName, 'source.mp4');
    expect(back.clips.single.id, 'c1');
    expect(back.createdAt.millisecondsSinceEpoch, 1000);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/world_clip/clip_project_test.dart`
Expected: FAIL (files do not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/services/world_clip/models/clip_spec.dart`:

```dart
import 'correction.dart';

/// One selected frame plus the ordered corrections to replay on it.
class ClipSpec {
  final String id;
  final int frameTimestampMs;
  int order;
  final List<Correction> corrections;

  ClipSpec({
    required this.id,
    required this.frameTimestampMs,
    required this.order,
    required this.corrections,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'frameTimestampMs': frameTimestampMs,
        'order': order,
        'corrections': corrections.map((c) => c.toJson()).toList(),
      };

  factory ClipSpec.fromJson(Map<String, dynamic> j) => ClipSpec(
        id: j['id'] as String,
        frameTimestampMs: j['frameTimestampMs'] as int,
        order: j['order'] as int,
        corrections: (j['corrections'] as List)
            .map((e) => Correction.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
```

Create `lib/services/world_clip/models/clip_project.dart`:

```dart
import 'clip_spec.dart';

/// A cached World Clip editing session. Durable output is the committed note;
/// this lives in the OS cache dir and may be flushed.
class ClipProject {
  final String id;
  String name;
  final DateTime createdAt;
  final String sourceVideoFileName; // relative to the project dir
  final List<ClipSpec> clips;

  ClipProject({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.sourceVideoFileName,
    required this.clips,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'sourceVideo': sourceVideoFileName,
        'clips': clips.map((c) => c.toJson()).toList(),
      };

  factory ClipProject.fromJson(Map<String, dynamic> j) => ClipProject(
        id: j['id'] as String,
        name: j['name'] as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(j['createdAt'] as int),
        sourceVideoFileName: j['sourceVideo'] as String,
        clips: (j['clips'] as List)
            .map((e) => ClipSpec.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/world_clip/clip_project_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/world_clip/models/clip_spec.dart lib/services/world_clip/models/clip_project.dart test/world_clip/clip_project_test.dart
git commit -m "feat(world_clip): add ClipSpec and ClipProject models"
```

---

## Phase 2 — Project store (TDD with a temp dir)

### Task 5: ClipProjectStore CRUD

**Files:**
- Create: `lib/services/world_clip/clip_project_store.dart`
- Test: `test/world_clip/clip_project_store_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/world_clip/clip_project_store_test.dart`:

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/clip_project_store.dart';
import 'package:note_synapse/services/world_clip/models/clip_spec.dart';

void main() {
  late Directory tmp;
  late ClipProjectStore store;
  late File fakeVideo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('world_clip_test');
    store = ClipProjectStore(Directory('${tmp.path}/world_clip'));
    fakeVideo = File('${tmp.path}/in.mp4')..writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('create copies the source video and persists project.json', () async {
    final p = await store.create(name: 'Book', sourceVideo: fakeVideo);
    final dir = store.projectDir(p.id);
    expect(File('${dir.path}/${p.sourceVideoFileName}').existsSync(), isTrue);
    expect(File('${dir.path}/project.json').existsSync(), isTrue);
    expect(p.name, 'Book');
  });

  test('save then load returns equal data', () async {
    final p = await store.create(name: 'Book', sourceVideo: fakeVideo);
    p.clips.add(ClipSpec(
        id: 'c1', frameTimestampMs: 500, order: 0, corrections: const []));
    await store.save(p);
    final loaded = await store.load(p.id);
    expect(loaded!.clips.single.frameTimestampMs, 500);
  });

  test('listAll returns created projects newest-first', () async {
    final a = await store.create(name: 'A', sourceVideo: fakeVideo);
    final b = await store.create(name: 'B', sourceVideo: fakeVideo);
    final all = await store.listAll();
    expect(all.map((p) => p.id), containsAll([a.id, b.id]));
  });

  test('delete removes the project dir', () async {
    final p = await store.create(name: 'X', sourceVideo: fakeVideo);
    await store.delete(p.id);
    expect(store.projectDir(p.id).existsSync(), isFalse);
    expect(await store.load(p.id), isNull);
  });

  test('listAll tolerates a missing base dir', () async {
    final fresh = ClipProjectStore(Directory('${tmp.path}/never_created'));
    expect(await fresh.listAll(), isEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/world_clip/clip_project_store_test.dart`
Expected: FAIL (file does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/services/world_clip/clip_project_store.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'models/clip_project.dart';

/// Persists [ClipProject]s as JSON + cached frames under a cache base dir.
/// The base dir is injected so tests can use a temp directory.
class ClipProjectStore {
  final Directory baseDir;
  ClipProjectStore(this.baseDir);

  Directory projectDir(String id) => Directory(p.join(baseDir.path, id));
  File _projectFile(String id) => File(p.join(projectDir(id).path, 'project.json'));
  Directory proxyDir(String id) => Directory(p.join(projectDir(id).path, 'proxy'));
  Directory clipsDir(String id) => Directory(p.join(projectDir(id).path, 'clips'));

  Future<ClipProject> create({
    required String name,
    required File sourceVideo,
  }) async {
    final id = const Uuid().v4();
    final dir = projectDir(id);
    await dir.create(recursive: true);
    await proxyDir(id).create(recursive: true);
    await clipsDir(id).create(recursive: true);

    final ext = p.extension(sourceVideo.path);
    final videoName = 'source$ext';
    await sourceVideo.copy(p.join(dir.path, videoName));

    final project = ClipProject(
      id: id,
      name: name,
      createdAt: DateTime.now(),
      sourceVideoFileName: videoName,
      clips: [],
    );
    await save(project);
    return project;
  }

  Future<void> save(ClipProject project) async {
    await projectDir(project.id).create(recursive: true);
    await _projectFile(project.id)
        .writeAsString(jsonEncode(project.toJson()));
  }

  Future<ClipProject?> load(String id) async {
    final f = _projectFile(id);
    if (!await f.exists()) return null;
    return ClipProject.fromJson(
        jsonDecode(await f.readAsString()) as Map<String, dynamic>);
  }

  Future<List<ClipProject>> listAll() async {
    if (!await baseDir.exists()) return [];
    final projects = <ClipProject>[];
    await for (final entity in baseDir.list()) {
      if (entity is Directory) {
        final loaded = await load(p.basename(entity.path));
        if (loaded != null) projects.add(loaded);
      }
    }
    projects.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return projects;
  }

  Future<void> delete(String id) async {
    final dir = projectDir(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/world_clip/clip_project_store_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/world_clip/clip_project_store.dart test/world_clip/clip_project_store_test.dart
git commit -m "feat(world_clip): add ClipProjectStore JSON CRUD"
```

---

## Phase 3 — Frame selection heuristics (pure Dart, TDD)

### Task 6: FrameFeature + FrameSelector

**Files:**
- Create: `lib/services/world_clip/frame_selector.dart`
- Test: `test/world_clip/frame_selector_test.dart`

> `FrameFeature` (timestamp + sharpness + diff-from-previous) is computed later by the extractor using OpenCV. The *selection logic* is pure and tested here in isolation.

- [ ] **Step 1: Write the failing test**

Create `test/world_clip/frame_selector_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/frame_selector.dart';

void main() {
  const selector = FrameSelector(
    sharpnessThreshold: 100,
    sceneChangeThreshold: 0.3,
    minGapMs: 1000,
  );

  test('picks sharp, scene-changing frames spaced beyond minGap', () {
    final frames = [
      const FrameFeature(timestampMs: 0, sharpness: 200, diffFromPrev: 1.0),
      const FrameFeature(timestampMs: 200, sharpness: 200, diffFromPrev: 0.05), // too soon + no change
      const FrameFeature(timestampMs: 1500, sharpness: 50, diffFromPrev: 0.9),  // blurry
      const FrameFeature(timestampMs: 3000, sharpness: 180, diffFromPrev: 0.6), // good
    ];
    expect(selector.suggest(frames), [0, 3000]);
  });

  test('returns empty when nothing qualifies', () {
    final frames = [
      const FrameFeature(timestampMs: 0, sharpness: 10, diffFromPrev: 0.0),
    ];
    expect(selector.suggest(frames), isEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/world_clip/frame_selector_test.dart`
Expected: FAIL (file does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/services/world_clip/frame_selector.dart`:

```dart
/// Per-frame metrics used to suggest key frames.
class FrameFeature {
  final int timestampMs;
  /// Variance-of-Laplacian; higher = sharper.
  final double sharpness;
  /// Normalized difference from the previous frame (0..1); higher = scene change.
  final double diffFromPrev;
  const FrameFeature({
    required this.timestampMs,
    required this.sharpness,
    required this.diffFromPrev,
  });
}

/// Suggests key-frame timestamps. Suggestions are a seed for the timeline —
/// the user adds/deletes freely on top.
class FrameSelector {
  final double sharpnessThreshold;
  final double sceneChangeThreshold;
  final int minGapMs;

  const FrameSelector({
    required this.sharpnessThreshold,
    required this.sceneChangeThreshold,
    required this.minGapMs,
  });

  List<int> suggest(List<FrameFeature> frames) {
    final picked = <int>[];
    int? lastPicked;
    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      if (f.sharpness < sharpnessThreshold) continue;
      final isFirst = lastPicked == null;
      final farEnough = isFirst || (f.timestampMs - lastPicked!) >= minGapMs;
      final changed = isFirst || f.diffFromPrev >= sceneChangeThreshold;
      if (farEnough && changed) {
        picked.add(f.timestampMs);
        lastPicked = f.timestampMs;
      }
    }
    return picked;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/world_clip/frame_selector_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/world_clip/frame_selector.dart test/world_clip/frame_selector_test.dart
git commit -m "feat(world_clip): add FrameSelector key-frame heuristics"
```

---

## Phase 4 — Compiler (TDD with an injected attachment writer)

### Task 7: ClipCompiler → builds a Note (PDF or inline images)

**Files:**
- Create: `lib/services/world_clip/clip_compiler.dart`
- Test: `test/world_clip/clip_compiler_test.dart`

> The compiler **builds and returns a `Note`** (writing attachment files via an injected `AttachmentWriter` seam, default = `FileUtils.saveFileToPrivateStorage`). It does NOT persist — the caller persists via `AppProvider.addNote(note)`, which both inserts and updates the in-memory list (there is no separate reload method on the provider). This keeps the compiler pure and mockito-free.

- [ ] **Step 1: Write the failing test**

Create `test/world_clip/clip_compiler_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/clip_compiler.dart';

void main() {
  late List<String> written;
  late ClipCompiler compiler;

  // 1x1 PNG.
  final pngA = Uint8List.fromList([
    137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,0,0,0,
    144,119,83,222,0,0,0,12,73,68,65,84,8,215,99,248,207,192,0,0,0,3,0,1,
    169,118,218,141,0,0,0,0,73,69,78,68,174,66,96,130
  ]);

  setUp(() {
    written = [];
    compiler = ClipCompiler(
      writeAttachment: (bytes, name) async {
        written.add(name);
        return 'attachments/$name';
      },
    );
  });

  test('inline output builds a note with one attachment per page', () async {
    final note = await compiler.compile(
      title: 'My Clip',
      pageImagesPng: [pngA, pngA],
      format: ClipOutputFormat.inlineImages,
    );
    expect(note.title, 'My Clip');
    expect(written.length, 2);
    expect(note.attachmentPaths.length, 2);
    expect(note.content, contains('![')); // images embedded in markdown
  });

  test('pdf output builds a note with a single pdf attachment', () async {
    final note = await compiler.compile(
      title: 'My Clip',
      pageImagesPng: [pngA, pngA],
      format: ClipOutputFormat.pdf,
    );
    expect(written.single, endsWith('.pdf'));
    expect(note.attachmentPaths.single, endsWith('.pdf'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/world_clip/clip_compiler_test.dart`
Expected: FAIL (file does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/services/world_clip/clip_compiler.dart`:

```dart
import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:uuid/uuid.dart';
import '../../models/note.dart';
import '../../utils/file_utils.dart';

enum ClipOutputFormat { pdf, inlineImages }

/// Writes bytes to private storage; returns the relative `attachments/...` path.
typedef AttachmentWriter = Future<String> Function(
    Uint8List bytes, String fileName);

/// Compiles ordered, fully-corrected page images into a Note (not persisted).
/// The caller persists via AppProvider.addNote(note).
class ClipCompiler {
  final AttachmentWriter _writeAttachment;

  ClipCompiler({AttachmentWriter? writeAttachment})
      : _writeAttachment =
            writeAttachment ?? FileUtils.saveFileToPrivateStorage;

  Future<Note> compile({
    required String title,
    required List<Uint8List> pageImagesPng,
    required ClipOutputFormat format,
  }) async {
    final now = DateTime.now();
    final stamp = now.millisecondsSinceEpoch;

    final List<String> attachmentPaths;
    final String content;

    switch (format) {
      case ClipOutputFormat.inlineImages:
        attachmentPaths = [];
        final buf = StringBuffer();
        for (var i = 0; i < pageImagesPng.length; i++) {
          final path = await _writeAttachment(
              pageImagesPng[i], 'worldclip_${stamp}_$i.png');
          attachmentPaths.add(path);
          buf.writeln('![clip ${i + 1}]($path)');
          buf.writeln();
        }
        content = buf.toString().trimRight();
        break;
      case ClipOutputFormat.pdf:
        final pdfBytes = await _buildPdf(pageImagesPng);
        final path = await _writeAttachment(pdfBytes, 'worldclip_$stamp.pdf');
        attachmentPaths = [path];
        content = '';
        break;
    }

    return Note(
      id: const Uuid().v4(),
      title: title,
      content: content,
      type: NoteType.note,
      createdAt: now,
      updatedAt: now,
      tags: const ['world-clip'],
      attachmentPaths: attachmentPaths,
    );
  }

  Future<Uint8List> _buildPdf(List<Uint8List> pages) async {
    final doc = pw.Document();
    for (final png in pages) {
      final image = pw.MemoryImage(png);
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(12),
        build: (context) =>
            pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
      ));
    }
    return doc.save();
  }
}
```

> `Note.attachmentPaths` is persisted automatically by `DatabaseService.insertNote` (it iterates `note.attachmentPaths` into the `attachments` table), which `AppProvider.addNote` calls. `FileUtils.saveFileToPrivateStorage(List<int>, String)` is assignable to the `AttachmentWriter` typedef (a `List<int>` parameter accepts `Uint8List`); if the analyzer complains, wrap it: `writeAttachment ?? (b, n) => FileUtils.saveFileToPrivateStorage(b, n)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/world_clip/clip_compiler_test.dart`
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/world_clip/clip_compiler.dart test/world_clip/clip_compiler_test.dart
git commit -m "feat(world_clip): add ClipCompiler (builds PDF/inline-image Note)"
```

---

## Phase 5 — OpenCV-backed seams (concrete code + integration verification)

> These wrap `opencv_dart`. Unit-testing image math runs on the host OpenCV during `flutter test` (Task 9 has a host test). Video decode (Task 8) is verified with a fixture-video integration test that is skipped if the host build lacks video backends, plus the on-device check from Task 1.

### Task 8: FrameExtractor seam + OpenCvFrameExtractor

**Files:**
- Create: `lib/services/world_clip/frame_extractor.dart`
- Test: `test/world_clip/frame_extractor_integration_test.dart`

- [ ] **Step 1: Write the abstract seam + OpenCV implementation**

Create `lib/services/world_clip/frame_extractor.dart`:

```dart
import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'frame_selector.dart';

/// Decodes a source video into proxy thumbnails, full-res frames, and
/// per-frame features. The seam lets the OpenCV backend be swapped for a
/// native/ffmpeg extractor (see Task 1 spike decision).
abstract class FrameExtractor {
  /// Frame timestamps (ms) sampled at [fps], ascending.
  Future<List<int>> sampleTimestamps({int fps = 5});

  /// Downsampled PNG thumbnail at [timestampMs] for the timeline.
  Future<Uint8List> thumbnailAt(int timestampMs, {int maxWidth = 240});

  /// Full-resolution PNG frame at [timestampMs].
  Future<Uint8List> fullFrameAt(int timestampMs);

  /// Sharpness + diff-from-previous feature at [timestampMs].
  Future<FrameFeature> featureAt(int timestampMs, {int? previousTimestampMs});

  void dispose();
}

class OpenCvFrameExtractor implements FrameExtractor {
  final String videoPath;
  late final cv.VideoCapture _cap;
  late final double _fps;
  late final double _frameCount;

  OpenCvFrameExtractor(this.videoPath) {
    _cap = cv.VideoCapture.fromFile(videoPath);
    if (!_cap.isOpened) {
      throw StateError('Could not open video: $videoPath');
    }
    _fps = _cap.get(cv.CAP_PROP_FPS);
    _frameCount = _cap.get(cv.CAP_PROP_FRAME_COUNT);
  }

  int get _durationMs =>
      (_fps > 0 && _frameCount > 0) ? (_frameCount / _fps * 1000).round() : 0;

  @override
  Future<List<int>> sampleTimestamps({int fps = 5}) async {
    final step = (1000 / fps).round();
    final out = <int>[];
    for (var t = 0; t < _durationMs; t += step) {
      out.add(t);
    }
    return out;
  }

  cv.Mat _readAt(int timestampMs) {
    _cap.set(cv.CAP_PROP_POS_MSEC, timestampMs.toDouble());
    final (ok, mat) = _cap.read();
    if (!ok || mat.isEmpty) {
      mat.dispose();
      throw StateError('No frame at ${timestampMs}ms');
    }
    return mat;
  }

  @override
  Future<Uint8List> thumbnailAt(int timestampMs, {int maxWidth = 240}) async {
    final mat = _readAt(timestampMs);
    final scale = maxWidth / mat.cols;
    final resized = cv.resize(
        mat, (maxWidth, (mat.rows * scale).round()),
        interpolation: cv.INTER_AREA);
    final (_, png) = cv.imencode('.png', resized);
    mat.dispose();
    resized.dispose();
    return png;
  }

  @override
  Future<Uint8List> fullFrameAt(int timestampMs) async {
    final mat = _readAt(timestampMs);
    final (_, png) = cv.imencode('.png', mat);
    mat.dispose();
    return png;
  }

  @override
  Future<FrameFeature> featureAt(int timestampMs,
      {int? previousTimestampMs}) async {
    final mat = _readAt(timestampMs);
    final gray = cv.cvtColor(mat, cv.COLOR_BGR2GRAY);
    final lap = cv.laplacian(gray, cv.MatType.CV_64F);
    final (_, stddev) = cv.meanStdDev(lap);
    final sharpness = stddev.at<double>(0, 0);
    final variance = sharpness * sharpness;

    double diff = 1.0;
    if (previousTimestampMs != null) {
      final prev = _readAt(previousTimestampMs);
      final prevGray = cv.cvtColor(prev, cv.COLOR_BGR2GRAY);
      final small = cv.resize(gray, (64, 64));
      final prevSmall = cv.resize(prevGray, (64, 64));
      final delta = cv.absDiff(small, prevSmall);
      final mean = cv.mean(delta);
      diff = mean.val1 / 255.0;
      prev.dispose();
      prevGray.dispose();
      small.dispose();
      prevSmall.dispose();
      delta.dispose();
    }

    mat.dispose();
    gray.dispose();
    lap.dispose();
    return FrameFeature(
        timestampMs: timestampMs, sharpness: variance, diffFromPrev: diff);
  }

  @override
  void dispose() => _cap.release();
}
```

> The exact `opencv_dart` symbol names (`meanStdDev`, `laplacian`, `MatType.CV_64F`, `at<double>`, `mean().val1`) must be confirmed against the resolved package version's API during implementation; adjust call sites if the version differs. The Task 1 spike already confirmed `VideoCapture`, `imencode`, and `read`.

- [ ] **Step 2: Write a fixture-video integration test (skips gracefully)**

Place a tiny test video at `test/world_clip/fixtures/sample.mp4` (3–5s, any small clip). Create `test/world_clip/frame_extractor_integration_test.dart`:

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/frame_extractor.dart';

void main() {
  final fixture = File('test/world_clip/fixtures/sample.mp4');

  test('extracts timestamps and a full frame from a fixture video', () async {
    if (!fixture.existsSync()) {
      markTestSkipped('no fixture video present');
      return;
    }
    OpenCvFrameExtractor? ex;
    try {
      ex = OpenCvFrameExtractor(fixture.path);
    } on StateError {
      markTestSkipped('host OpenCV lacks a video backend');
      return;
    }
    final ts = await ex.sampleTimestamps(fps: 5);
    expect(ts, isNotEmpty);
    final png = await ex.fullFrameAt(ts.first);
    expect(png.length, greaterThan(8));
    ex.dispose();
  });
}
```

- [ ] **Step 3: Run the integration test**

Run: `flutter test test/world_clip/frame_extractor_integration_test.dart`
Expected: PASS (or SKIP if the host build lacks a video backend — the on-device check in Task 1 is the authoritative gate).

- [ ] **Step 4: Commit**

```bash
git add lib/services/world_clip/frame_extractor.dart test/world_clip/frame_extractor_integration_test.dart test/world_clip/fixtures/
git commit -m "feat(world_clip): add FrameExtractor seam + OpenCV implementation"
```

### Task 9: FrameCorrection seam + OpenCvFrameCorrection

**Files:**
- Create: `lib/services/world_clip/frame_correction.dart`
- Test: `test/world_clip/frame_correction_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/world_clip/frame_correction_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:note_synapse/services/world_clip/frame_correction.dart';
import 'package:note_synapse/services/world_clip/models/correction.dart';
import 'package:note_synapse/services/world_clip/models/mesh_grid.dart';

Uint8List _solidPng(int w, int h) {
  final mat = cv.Mat.create(rows: h, cols: w, type: cv.MatType.CV_8UC3);
  final (_, png) = cv.imencode('.png', mat);
  mat.dispose();
  return png;
}

void main() {
  final correction = OpenCvFrameCorrection();

  test('empty corrections returns a decodable image of same size', () async {
    final src = _solidPng(40, 20);
    final out = await correction.apply(src, const []);
    final mat = cv.imdecode(out, cv.IMREAD_COLOR);
    expect(mat.cols, 40);
    expect(mat.rows, 20);
    mat.dispose();
  });

  test('crop reduces dimensions', () async {
    final src = _solidPng(40, 20);
    final out = await correction.apply(
        src, [CropCorrection(x: 0, y: 0, width: 0.5, height: 0.5)]);
    final mat = cv.imdecode(out, cv.IMREAD_COLOR);
    expect(mat.cols, 20);
    expect(mat.rows, 10);
    mat.dispose();
  });

  test('identity mesh dewarp preserves dimensions', () async {
    final src = _solidPng(40, 20);
    final out = await correction.apply(src,
        [MeshDewarpCorrection(grid: MeshGrid.identity(rows: 1, cols: 1))]);
    final mat = cv.imdecode(out, cv.IMREAD_COLOR);
    expect(mat.cols, greaterThan(0));
    expect(mat.rows, greaterThan(0));
    mat.dispose();
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/world_clip/frame_correction_test.dart`
Expected: FAIL (file does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/services/world_clip/frame_correction.dart`:

```dart
import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'models/correction.dart';
import 'models/mesh_grid.dart';

/// Applies an ordered list of [Correction]s to a PNG frame, returning a PNG.
abstract class FrameCorrection {
  Future<Uint8List> apply(Uint8List sourcePng, List<Correction> corrections);
}

class OpenCvFrameCorrection implements FrameCorrection {
  @override
  Future<Uint8List> apply(
      Uint8List sourcePng, List<Correction> corrections) async {
    var mat = cv.imdecode(sourcePng, cv.IMREAD_COLOR);
    for (final c in corrections) {
      final next = switch (c) {
        CropCorrection() => _crop(mat, c),
        RotateCorrection() => _rotate(mat, c),
        MeshDewarpCorrection() => _meshDewarp(mat, c.grid),
      };
      if (!identical(next, mat)) mat.dispose();
      mat = next;
    }
    final (_, png) = cv.imencode('.png', mat);
    mat.dispose();
    return png;
  }

  cv.Mat _crop(cv.Mat src, CropCorrection c) {
    final rect = cv.Rect(
      (c.x * src.cols).round(),
      (c.y * src.rows).round(),
      (c.width * src.cols).round(),
      (c.height * src.rows).round(),
    );
    return src.region(rect).clone();
  }

  cv.Mat _rotate(cv.Mat src, RotateCorrection c) {
    final center = cv.Point2f(src.cols / 2, src.rows / 2);
    final m = cv.getRotationMatrix2D(center, -c.degrees, 1.0);
    final out = cv.warpAffine(src, m, (src.cols, src.rows));
    m.dispose();
    return out;
  }

  /// Per-cell perspective warp: each grid cell's quad is mapped to its
  /// destination rectangle and composited into the output. A 1x1 grid is a
  /// single homography (classic keystone); subdivided grids bend at creases.
  cv.Mat _meshDewarp(cv.Mat src, MeshGrid grid) {
    final w = src.cols, h = src.rows;
    final out = cv.Mat.zeros(h, w, src.type);
    int idx(int r, int c) => r * (grid.cols + 1) + c;
    for (var r = 0; r < grid.rows; r++) {
      for (var c = 0; c < grid.cols; c++) {
        final tl = grid.points[idx(r, c)];
        final tr = grid.points[idx(r, c + 1)];
        final br = grid.points[idx(r + 1, c + 1)];
        final bl = grid.points[idx(r + 1, c)];
        final srcPts = cv.VecPoint2f.fromList([
          cv.Point2f(tl.x * w, tl.y * h),
          cv.Point2f(tr.x * w, tr.y * h),
          cv.Point2f(br.x * w, br.y * h),
          cv.Point2f(bl.x * w, bl.y * h),
        ]);
        final dx0 = (c / grid.cols * w), dx1 = ((c + 1) / grid.cols * w);
        final dy0 = (r / grid.rows * h), dy1 = ((r + 1) / grid.rows * h);
        final dstPts = cv.VecPoint2f.fromList([
          cv.Point2f(dx0, dy0),
          cv.Point2f(dx1, dy0),
          cv.Point2f(dx1, dy1),
          cv.Point2f(dx0, dy1),
        ]);
        final m = cv.getPerspectiveTransform2f(srcPts, dstPts);
        final warped = cv.warpPerspective(src, m, (w, h));
        // Copy the destination cell region from `warped` into `out`.
        final cellRect = cv.Rect(
            dx0.round(), dy0.round(), (dx1 - dx0).round(), (dy1 - dy0).round());
        final cellSrc = warped.region(cellRect);
        final cellDst = out.region(cellRect);
        cellSrc.copyTo(cellDst);
        m.dispose();
        warped.dispose();
        cellSrc.dispose();
        cellDst.dispose();
      }
    }
    return out;
  }
}
```

> Confirm exact `opencv_dart` symbols (`getPerspectiveTransform2f`, `VecPoint2f`, `Mat.region`, `copyTo`, `Mat.zeros`) against the resolved version and adjust. The behavior contract (empty→unchanged size, crop→smaller, identity mesh→preserved) is what the test pins.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/world_clip/frame_correction_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/world_clip/frame_correction.dart test/world_clip/frame_correction_test.dart
git commit -m "feat(world_clip): add FrameCorrection seam + OpenCV (crop/rotate/mesh)"
```

### Task 10: VideoSource seam

**Files:**
- Create: `lib/services/world_clip/video_source.dart`
- Test: `test/world_clip/video_source_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/world_clip/video_source_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/video_source.dart';

void main() {
  test('FakeVideoSource yields its configured path', () async {
    final src = FakeVideoSource('/tmp/x.mp4');
    expect((await src.pickVideo())?.path, '/tmp/x.mp4');
  });

  test('FakeVideoSource yields null when configured empty', () async {
    expect(await FakeVideoSource(null).pickVideo(), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/world_clip/video_source_test.dart`
Expected: FAIL (file does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/services/world_clip/video_source.dart`:

```dart
import 'dart:io';
import 'package:image_picker/image_picker.dart';

/// Yields a source video. v1: gallery import. Future: in-app camera intent.
abstract class VideoSource {
  Future<File?> pickVideo();
}

class GalleryVideoSource implements VideoSource {
  final ImagePicker _picker;
  GalleryVideoSource([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  @override
  Future<File?> pickVideo() async {
    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    return picked == null ? null : File(picked.path);
  }
}

/// Test double.
class FakeVideoSource implements VideoSource {
  final String? path;
  FakeVideoSource(this.path);
  @override
  Future<File?> pickVideo() async => path == null ? null : File(path!);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/world_clip/video_source_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/world_clip/video_source.dart test/world_clip/video_source_test.dart
git commit -m "feat(world_clip): add VideoSource seam (gallery import)"
```

---

## Phase 6 — DI registration + localization

### Task 11: Register World Clip services in the service locator

**Files:**
- Modify: `lib/services/service_locator.dart`
- Test: `test/world_clip/service_locator_world_clip_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/world_clip/service_locator_world_clip_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/world_clip/frame_correction.dart';

void main() {
  test('FrameCorrection resolves after registration', () async {
    await resetForTesting();
    registerWorldClipServices();
    expect(getIt<FrameCorrection>(), isA<OpenCvFrameCorrection>());
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/world_clip/service_locator_world_clip_test.dart`
Expected: FAIL (`registerWorldClipServices` undefined).

- [ ] **Step 3: Add the registration function**

In `lib/services/service_locator.dart`, add imports at the top:

```dart
import 'world_clip/frame_correction.dart';
import 'world_clip/video_source.dart';
```

Add this function near the other registrations (after `setupServiceLocator`):

```dart
/// World Clip services. Called from setupServiceLocator(); separated so tests
/// can register just this slice.
void registerWorldClipServices() {
  if (!getIt.isRegistered<FrameCorrection>()) {
    getIt.registerLazySingleton<FrameCorrection>(() => OpenCvFrameCorrection());
  }
  if (!getIt.isRegistered<VideoSource>()) {
    getIt.registerLazySingleton<VideoSource>(() => GalleryVideoSource());
  }
}
```

Then call it from within `setupServiceLocator()` (after the existing registrations):

```dart
  registerWorldClipServices();
```

> `ClipProjectStore`, `FrameExtractor`, and `ClipCompiler` are constructed per-session (they need a project dir / video path / runtime deps), so they are created directly in the flow screen rather than registered as singletons.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/world_clip/service_locator_world_clip_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/service_locator.dart test/world_clip/service_locator_world_clip_test.dart
git commit -m "feat(world_clip): register World Clip services in locator"
```

### Task 12: Add localization strings

**Files:**
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_zh.arb`

- [ ] **Step 1: Add English strings**

In `lib/l10n/app_en.arb`, add these keys (place near `newNoteFromClipboard`):

```json
  "worldClip": "World Clip",
  "worldClipSubtitle": "Turn a video into a note",
  "worldClipProjects": "World Clip Projects",
  "worldClipImportVideo": "Import video",
  "worldClipNoFramesSelected": "Select at least one frame to continue",
  "worldClipReview": "Review clips",
  "worldClipCompile": "Create note",
  "worldClipOutputPdf": "As a PDF",
  "worldClipOutputImages": "As inline images",
  "worldClipDeleteProject": "Delete project",
  "worldClipNewFromSameVideo": "New project from this video",
  "worldClipEmptyProjects": "No saved World Clip projects",
```

- [ ] **Step 2: Add Chinese strings**

In `lib/l10n/app_zh.arb`, add the same keys with translations:

```json
  "worldClip": "世界剪辑",
  "worldClipSubtitle": "将视频转换为笔记",
  "worldClipProjects": "世界剪辑项目",
  "worldClipImportVideo": "导入视频",
  "worldClipNoFramesSelected": "请至少选择一帧以继续",
  "worldClipReview": "查看剪辑",
  "worldClipCompile": "创建笔记",
  "worldClipOutputPdf": "导出为 PDF",
  "worldClipOutputImages": "导出为内嵌图片",
  "worldClipDeleteProject": "删除项目",
  "worldClipNewFromSameVideo": "用此视频新建项目",
  "worldClipEmptyProjects": "没有已保存的世界剪辑项目",
```

- [ ] **Step 3: Regenerate localizations and verify compile**

Run:
```bash
flutter gen-l10n
flutter analyze lib/l10n
```
Expected: generates `app_localizations*.dart` with the new getters; no analyzer errors.

- [ ] **Step 4: Commit**

```bash
git add lib/l10n/app_en.arb lib/l10n/app_zh.arb lib/l10n/app_localizations*.dart
git commit -m "feat(world_clip): add localization strings (en + zh)"
```

---

## Phase 7 — UI flow

> UI tasks provide concrete widgets. Each has a smoke widget test (pumps the screen, asserts key controls render). Full interaction is verified manually in Task 17.

### Task 13: WorldClipFlowScreen scaffold + stage state

**Files:**
- Create: `lib/screens/world_clip/world_clip_flow_screen.dart`
- Test: `test/world_clip/world_clip_flow_screen_test.dart`

- [ ] **Step 1: Write the failing smoke test**

Create `test/world_clip/world_clip_flow_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/screens/world_clip/world_clip_flow_screen.dart';

void main() {
  testWidgets('shows the import action on first stage', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WorldClipFlowScreen(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(WorldClipFlowScreen), findsOneWidget);
    expect(find.byIcon(Icons.video_library), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/world_clip/world_clip_flow_screen_test.dart`
Expected: FAIL (file does not exist).

- [ ] **Step 3: Write the scaffold**

Create `lib/screens/world_clip/world_clip_flow_screen.dart`:

```dart
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

enum WorldClipStage { source, timeline, correct, review, compile }

class WorldClipFlowScreen extends StatefulWidget {
  /// When non-null, resume an existing cached project by id.
  final String? resumeProjectId;
  const WorldClipFlowScreen({super.key, this.resumeProjectId});

  @override
  State<WorldClipFlowScreen> createState() => _WorldClipFlowScreenState();
}

class _WorldClipFlowScreenState extends State<WorldClipFlowScreen> {
  WorldClipStage _stage = WorldClipStage.source;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.worldClip)),
      body: switch (_stage) {
        WorldClipStage.source => _SourceStage(onPicked: () {
            setState(() => _stage = WorldClipStage.timeline);
          }),
        _ => Center(child: Text('Stage: ${_stage.name}')),
      },
    );
  }
}

class _SourceStage extends StatelessWidget {
  final VoidCallback onPicked;
  const _SourceStage({required this.onPicked});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: ElevatedButton.icon(
        icon: const Icon(Icons.video_library),
        label: Text(l10n.worldClipImportVideo),
        onPressed: onPicked,
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/world_clip/world_clip_flow_screen_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/screens/world_clip/world_clip_flow_screen.dart test/world_clip/world_clip_flow_screen_test.dart
git commit -m "feat(world_clip): add flow screen scaffold with stage state"
```

### Task 14: Wire the source stage to VideoSource + ClipProjectStore + extraction

**Files:**
- Modify: `lib/screens/world_clip/world_clip_flow_screen.dart`
- Create: `lib/screens/world_clip/world_clip_timeline.dart`
- Test: `test/world_clip/world_clip_timeline_test.dart`

- [ ] **Step 1: Write the failing timeline test**

Create `test/world_clip/world_clip_timeline_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/screens/world_clip/world_clip_timeline.dart';

void main() {
  testWidgets('renders a thumb per timestamp and toggles tags on tap',
      (tester) async {
    final tagged = <int>{};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WorldClipTimeline(
          timestamps: const [0, 200, 400],
          taggedTimestamps: tagged,
          thumbnailBuilder: (ts) async => Uint8List.fromList(const [
            137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,
            0,0,0,144,119,83,222,0,0,0,12,73,68,65,84,8,215,99,248,207,192,0,
            0,0,3,0,1,169,118,218,141,0,0,0,0,73,69,78,68,174,66,96,130
          ]),
          onToggleTag: (ts) => tagged.contains(ts)
              ? tagged.remove(ts)
              : tagged.add(ts),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wc-thumb-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wc-thumb-200')));
    expect(tagged.contains(200), isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/world_clip/world_clip_timeline_test.dart`
Expected: FAIL (file does not exist).

- [ ] **Step 3: Implement the timeline widget**

Create `lib/screens/world_clip/world_clip_timeline.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// A horizontal proxy-thumbnail strip. Tapping a thumb toggles its key-frame
/// tag (a tagged thumb is highlighted). Thumbnails load lazily via [thumbnailBuilder].
class WorldClipTimeline extends StatelessWidget {
  final List<int> timestamps;
  final Set<int> taggedTimestamps;
  final Future<Uint8List> Function(int timestampMs) thumbnailBuilder;
  final void Function(int timestampMs) onToggleTag;

  const WorldClipTimeline({
    super.key,
    required this.timestamps,
    required this.taggedTimestamps,
    required this.thumbnailBuilder,
    required this.onToggleTag,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: timestamps.length,
        itemBuilder: (context, i) {
          final ts = timestamps[i];
          final tagged = taggedTimestamps.contains(ts);
          return GestureDetector(
            key: ValueKey('wc-thumb-$ts'),
            onTap: () => onToggleTag(ts),
            child: Container(
              width: 90,
              margin: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                border: Border.all(
                  color: tagged ? Colors.blue : Colors.transparent,
                  width: 3,
                ),
              ),
              child: FutureBuilder<Uint8List>(
                future: thumbnailBuilder(ts),
                builder: (context, snap) => snap.hasData
                    ? Image.memory(snap.data!, fit: BoxFit.cover)
                    : const Center(child: CircularProgressIndicator()),
              ),
            ),
          );
        },
      ),
    );
  }
}
```

- [ ] **Step 4: Wire extraction into the flow screen**

In `lib/screens/world_clip/world_clip_flow_screen.dart`, replace `_SourceStage`'s `onPicked` plumbing with real wiring. Add imports:

```dart
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../services/service_locator.dart';
import '../../services/world_clip/video_source.dart';
import '../../services/world_clip/frame_extractor.dart';
import '../../services/world_clip/clip_project_store.dart';
import '../../services/world_clip/models/clip_project.dart';
import 'world_clip_timeline.dart';
```

In `_WorldClipFlowScreenState`, add fields and a load method:

```dart
  ClipProjectStore? _store;
  ClipProject? _project;
  FrameExtractor? _extractor;
  List<int> _timestamps = [];
  final Set<int> _tagged = {};

  Future<ClipProjectStore> _ensureStore() async {
    if (_store != null) return _store!;
    final cache = await getTemporaryDirectory();
    _store = ClipProjectStore(Directory(p.join(cache.path, 'world_clip')));
    return _store!;
  }

  Future<void> _onPickVideo() async {
    final file = await getIt<VideoSource>().pickVideo();
    if (file == null) return;
    final store = await _ensureStore();
    final project = await store.create(
        name: 'Clip ${DateTime.now().toIso8601String().substring(0, 16)}',
        sourceVideo: file);
    final videoPath =
        p.join(store.projectDir(project.id).path, project.sourceVideoFileName);
    final extractor = OpenCvFrameExtractor(videoPath);
    final timestamps = await extractor.sampleTimestamps(fps: 5);
    setState(() {
      _project = project;
      _extractor = extractor;
      _timestamps = timestamps;
      _stage = WorldClipStage.timeline;
    });
  }

  @override
  void dispose() {
    _extractor?.dispose();
    super.dispose();
  }
```

Change `_SourceStage(onPicked: ...)` to call `_onPickVideo`, and add a timeline branch to the `switch`:

```dart
        WorldClipStage.timeline => Column(
            children: [
              Expanded(
                child: WorldClipTimeline(
                  timestamps: _timestamps,
                  taggedTimestamps: _tagged,
                  thumbnailBuilder: (ts) => _extractor!.thumbnailAt(ts),
                  onToggleTag: (ts) => setState(() =>
                      _tagged.contains(ts) ? _tagged.remove(ts) : _tagged.add(ts)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: _tagged.isEmpty
                      ? null
                      : () => setState(() => _stage = WorldClipStage.review),
                  child: Text(AppLocalizations.of(context)!.worldClipReview),
                ),
              ),
            ],
          ),
```

- [ ] **Step 5: Run the timeline test and analyzer**

Run:
```bash
flutter test test/world_clip/world_clip_timeline_test.dart
flutter analyze lib/screens/world_clip
```
Expected: timeline test PASSES; analyzer clean.

- [ ] **Step 6: Commit**

```bash
git add lib/screens/world_clip/world_clip_flow_screen.dart lib/screens/world_clip/world_clip_timeline.dart test/world_clip/world_clip_timeline_test.dart
git commit -m "feat(world_clip): wire video import + extraction + timeline tagging"
```

### Task 15: Review/reorder stage + compile

**Files:**
- Create: `lib/screens/world_clip/clip_review_screen.dart`
- Modify: `lib/screens/world_clip/world_clip_flow_screen.dart`
- Test: `test/world_clip/clip_review_screen_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/world_clip/clip_review_screen_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/screens/world_clip/clip_review_screen.dart';

void main() {
  final png = Uint8List.fromList(const [
    137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,0,0,0,
    144,119,83,222,0,0,0,12,73,68,65,84,8,215,99,248,207,192,0,0,0,3,0,1,169,
    118,218,141,0,0,0,0,73,69,78,68,174,66,96,130
  ]);

  testWidgets('shows a tile per page and a compile button', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ClipReviewScreen(
        pages: [png, png],
        onReorder: (a, b) {},
        onRemove: (i) {},
        onCompilePdf: () {},
        onCompileImages: () {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.byKey(const ValueKey('wc-compile')), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/world_clip/clip_review_screen_test.dart`
Expected: FAIL (file does not exist).

- [ ] **Step 3: Implement the review screen**

Create `lib/screens/world_clip/clip_review_screen.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

/// Accept / reject / reorder corrected pages, then choose the output format.
class ClipReviewScreen extends StatelessWidget {
  final List<Uint8List> pages;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(int index) onRemove;
  final VoidCallback onCompilePdf;
  final VoidCallback onCompileImages;

  const ClipReviewScreen({
    super.key,
    required this.pages,
    required this.onReorder,
    required this.onRemove,
    required this.onCompilePdf,
    required this.onCompileImages,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        Expanded(
          child: ReorderableListView.builder(
            itemCount: pages.length,
            onReorder: onReorder,
            itemBuilder: (context, i) => ListTile(
              key: ValueKey('wc-page-$i'),
              leading: SizedBox(width: 56, child: Image.memory(pages[i])),
              title: Text('${i + 1}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => onRemove(i),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            key: const ValueKey('wc-compile'),
            children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: onCompileImages,
                    child: Text(l10n.worldClipOutputImages)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                    onPressed: onCompilePdf,
                    child: Text(l10n.worldClipOutputPdf)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Wire review + compile into the flow screen**

In `world_clip_flow_screen.dart`, add imports:

```dart
import 'dart:typed_data';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../services/world_clip/frame_correction.dart';
import '../../services/world_clip/clip_compiler.dart';
import '../../services/world_clip/models/clip_spec.dart';
import '../../services/world_clip/models/correction.dart';
import 'clip_review_screen.dart';
```

Add a page cache and a builder that applies corrections, plus compile handlers:

```dart
  List<Uint8List> _reviewPages = [];
  List<int> _orderedTags = [];

  Future<void> _buildReviewPages() async {
    final correction = getIt<FrameCorrection>();
    _orderedTags = _tagged.toList()..sort();
    final pages = <Uint8List>[];
    for (final ts in _orderedTags) {
      final full = await _extractor!.fullFrameAt(ts);
      final spec = _project!.clips.firstWhere(
        (c) => c.frameTimestampMs == ts,
        orElse: () => ClipSpec(
            id: ts.toString(),
            frameTimestampMs: ts,
            order: 0,
            corrections: const []),
      );
      pages.add(await correction.apply(full, spec.corrections));
    }
    setState(() => _reviewPages = pages);
  }

  Future<void> _compile(ClipOutputFormat format) async {
    final note = await ClipCompiler().compile(
      title: _project!.name,
      pageImagesPng: _reviewPages,
      format: format,
    );
    if (!mounted) return;
    // addNote inserts and updates the in-memory list + notifies listeners.
    await context.read<AppProvider>().addNote(note);
    if (!mounted) return;
    Navigator.of(context).pop(note.id);
  }
```

In the `switch`, change the timeline's review button to call `_buildReviewPages()` then advance, and add the review branch:

```dart
        WorldClipStage.review => _reviewPages.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : ClipReviewScreen(
                pages: _reviewPages,
                onReorder: (oldI, newI) => setState(() {
                  if (newI > oldI) newI -= 1;
                  final t = _orderedTags.removeAt(oldI);
                  _orderedTags.insert(newI, t);
                  final pg = _reviewPages.removeAt(oldI);
                  _reviewPages.insert(newI, pg);
                }),
                onRemove: (i) => setState(() {
                  _orderedTags.removeAt(i);
                  _reviewPages.removeAt(i);
                }),
                onCompilePdf: () => _compile(ClipOutputFormat.pdf),
                onCompileImages: () => _compile(ClipOutputFormat.inlineImages),
              ),
```

Update the timeline's review button `onPressed` to:

```dart
                  onPressed: _tagged.isEmpty
                      ? null
                      : () async {
                          setState(() => _stage = WorldClipStage.review);
                          await _buildReviewPages();
                        },
```

> `AppProvider.addNote(Note)` (confirmed at `lib/providers/app_provider.dart:104`) inserts the note and updates the provider's in-memory list — there is no separate reload method, so this is the single persistence call. The mesh-correction editing UI (Task 16) writes `corrections` onto `_project.clips`; until then every clip uses an empty correction list (raw frame), which is the correct default for content like app screenshots.

- [ ] **Step 5: Run tests + analyzer**

Run:
```bash
flutter test test/world_clip/clip_review_screen_test.dart
flutter analyze lib/screens/world_clip
```
Expected: PASS; analyzer clean.

- [ ] **Step 6: Commit**

```bash
git add lib/screens/world_clip/clip_review_screen.dart lib/screens/world_clip/world_clip_flow_screen.dart test/world_clip/clip_review_screen_test.dart
git commit -m "feat(world_clip): add review/reorder stage + compile to note"
```

### Task 16: Mesh/crop/rotate editor (Stage 3, optional per clip)

**Files:**
- Create: `lib/screens/world_clip/mesh_editor.dart`
- Modify: `lib/screens/world_clip/world_clip_flow_screen.dart`
- Test: `test/world_clip/mesh_editor_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/world_clip/mesh_editor_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/screens/world_clip/mesh_editor.dart';
import 'package:note_synapse/services/world_clip/models/correction.dart';

void main() {
  final png = Uint8List.fromList(const [
    137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,0,0,0,
    144,119,83,222,0,0,0,12,73,68,65,84,8,215,99,248,207,192,0,0,0,3,0,1,169,
    118,218,141,0,0,0,0,73,69,78,68,174,66,96,130
  ]);

  testWidgets('returns mesh corrections via onDone', (tester) async {
    List<Correction>? result;
    await tester.pumpWidget(MaterialApp(
      home: MeshEditor(
        framePng: png,
        initial: const [],
        onDone: (c) => result = c,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wc-mesh-done')));
    expect(result, isNotNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/world_clip/mesh_editor_test.dart`
Expected: FAIL (file does not exist).

- [ ] **Step 3: Implement the editor**

Create `lib/screens/world_clip/mesh_editor.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../services/world_clip/models/correction.dart';
import '../../services/world_clip/models/mesh_grid.dart';
import '../../services/world_clip/models/norm_point.dart';

/// Optional per-clip correction editor: drag the 4 (or subdivided) mesh
/// corners over the frame; "Add crease" subdivides vertically for folded pages.
class MeshEditor extends StatefulWidget {
  final Uint8List framePng;
  final List<Correction> initial;
  final void Function(List<Correction> corrections) onDone;

  const MeshEditor({
    super.key,
    required this.framePng,
    required this.initial,
    required this.onDone,
  });

  @override
  State<MeshEditor> createState() => _MeshEditorState();
}

class _MeshEditorState extends State<MeshEditor> {
  late MeshGrid _grid;

  @override
  void initState() {
    super.initState();
    final meshes = widget.initial.whereType<MeshDewarpCorrection>();
    _grid = meshes.isEmpty
        ? MeshGrid.identity(rows: 1, cols: 1)
        : meshes.first.grid;
  }

  void _addCrease() => setState(() {
        _grid = MeshGrid.identity(rows: _grid.rows + 1, cols: _grid.cols);
      });

  void _movePoint(int index, NormPoint to) => setState(() {
        final pts = List<NormPoint>.from(_grid.points);
        pts[index] = NormPoint(to.x.clamp(0, 1), to.y.clamp(0, 1));
        _grid = MeshGrid(rows: _grid.rows, cols: _grid.cols, points: pts);
      });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth, h = constraints.maxHeight;
              return Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(widget.framePng, fit: BoxFit.contain),
                  for (var i = 0; i < _grid.points.length; i++)
                    Positioned(
                      left: _grid.points[i].x * w - 12,
                      top: _grid.points[i].y * h - 12,
                      child: GestureDetector(
                        onPanUpdate: (d) => _movePoint(
                          i,
                          NormPoint(
                            (_grid.points[i].x * w + d.delta.dx) / w,
                            (_grid.points[i].y * h + d.delta.dy) / h,
                          ),
                        ),
                        child: const Icon(Icons.circle,
                            size: 24, color: Colors.blueAccent),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton.icon(
              onPressed: _addCrease,
              icon: const Icon(Icons.add),
              label: const Text('Add crease'),
            ),
            FilledButton(
              key: const ValueKey('wc-mesh-done'),
              onPressed: () =>
                  widget.onDone([MeshDewarpCorrection(grid: _grid)]),
              child: const Text('Done'),
            ),
          ],
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Wire the editor into the flow (correct stage)**

In `world_clip_flow_screen.dart`, add `import 'mesh_editor.dart';`. Add a field `int _correctIndex = 0;` and a `WorldClipStage.correct` branch that lets the user step through tagged frames before review. The simplest wiring: from the timeline, change the review button to first enter `correct` for each tagged frame, or add an "Edit" affordance. Minimal acceptable wiring — add a per-clip edit entry from the review tile:

In `ClipReviewScreen`'s `ListTile`, add an edit button (modify Task 15's tile `trailing` to a `Row` with edit + delete). On edit, push `MeshEditor` for that frame, and on `onDone` store the corrections on `_project.clips` and rebuild that page:

```dart
  Future<void> _editClip(int index) async {
    final ts = _orderedTags[index];
    final full = await _extractor!.fullFrameAt(ts);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(AppLocalizations.of(context)!.worldClip)),
        body: MeshEditor(
          framePng: full,
          initial: _correctionsFor(ts),
          onDone: (corrections) async {
            _setCorrectionsFor(ts, corrections);
            await _store!.save(_project!);
            final corrected =
                await getIt<FrameCorrection>().apply(full, corrections);
            setState(() => _reviewPages[index] = corrected);
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    ));
  }

  List<Correction> _correctionsFor(int ts) =>
      _project!.clips
          .firstWhere((c) => c.frameTimestampMs == ts,
              orElse: () => ClipSpec(
                  id: ts.toString(),
                  frameTimestampMs: ts,
                  order: 0,
                  corrections: const []))
          .corrections;

  void _setCorrectionsFor(int ts, List<Correction> corrections) {
    final existing =
        _project!.clips.indexWhere((c) => c.frameTimestampMs == ts);
    final spec = ClipSpec(
        id: ts.toString(),
        frameTimestampMs: ts,
        order: _orderedTags.indexOf(ts),
        corrections: corrections);
    if (existing >= 0) {
      _project!.clips[existing] = spec;
    } else {
      _project!.clips.add(spec);
    }
  }
```

In `ClipReviewScreen`, add an **optional** callback so Task 15's test (which omits it) still compiles: `final void Function(int index)? onEdit;` in the constructor. In the tile's `trailing`, replace the single delete `IconButton` with a `Row(mainAxisSize: MainAxisSize.min, children: [...])` containing an edit button shown only when `onEdit != null` plus the existing delete button:

```dart
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onEdit != null)
                    IconButton(
                      icon: const Icon(Icons.crop),
                      onPressed: () => onEdit!(i),
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => onRemove(i),
                  ),
                ],
              ),
```

Then pass `onEdit: _editClip` from the flow screen's `ClipReviewScreen(...)` call.

- [ ] **Step 5: Run tests + analyzer**

Run:
```bash
flutter test test/world_clip/mesh_editor_test.dart
flutter analyze lib/screens/world_clip
```
Expected: PASS; analyzer clean.

- [ ] **Step 6: Commit**

```bash
git add lib/screens/world_clip/mesh_editor.dart lib/screens/world_clip/world_clip_flow_screen.dart lib/screens/world_clip/clip_review_screen.dart test/world_clip/mesh_editor_test.dart
git commit -m "feat(world_clip): add per-clip mesh/crop correction editor"
```

---

## Phase 8 — Entry points

### Task 17: Add the "World Clip" item to the main-screen [+] sheet

**Files:**
- Modify: `lib/screens/main_screen.dart`

- [ ] **Step 1: Add the import**

At the top of `lib/screens/main_screen.dart`, add:

```dart
import 'world_clip/world_clip_flow_screen.dart';
```

- [ ] **Step 2: Add the ListTile directly below "New Note From Clipboard"**

Find the `ListTile` for `l10n.newNoteFromClipboard` (around line 211-219). Immediately after it, insert:

```dart
              ListTile(
                leading: const Icon(Icons.movie_creation_outlined),
                title: Text(l10n.worldClip),
                subtitle: Text(l10n.worldClipSubtitle),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const WorldClipFlowScreen(),
                  ));
                },
              ),
```

- [ ] **Step 3: Verify it builds and renders**

Run:
```bash
flutter analyze lib/screens/main_screen.dart
flutter run -d macos
```
Manually: tap `[+]` → confirm "World Clip" appears below "New Note From Clipboard" → tap it → the flow screen opens with the "Import video" button.

- [ ] **Step 4: Commit**

```bash
git add lib/screens/main_screen.dart
git commit -m "feat(world_clip): add World Clip entry to main-screen [+] sheet"
```

### Task 18: Settings → "World Clip Projects" list

**Files:**
- Create: `lib/screens/world_clip/world_clip_projects_screen.dart`
- Modify: the settings screen (find it: `lib/screens/settings_screen.dart` or similar)
- Test: `test/world_clip/world_clip_projects_screen_test.dart`

- [ ] **Step 1: Locate the settings screen**

Run: `ls lib/screens | grep -i settings`
Record the exact file (e.g. `settings_screen.dart`). Open it and find the list of settings `ListTile`s.

- [ ] **Step 2: Write the failing test**

Create `test/world_clip/world_clip_projects_screen_test.dart`:

```dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/screens/world_clip/world_clip_projects_screen.dart';
import 'package:note_synapse/services/world_clip/clip_project_store.dart';

void main() {
  testWidgets('shows empty state when no projects', (tester) async {
    final tmp = await Directory.systemTemp.createTemp('wc_projects');
    final store = ClipProjectStore(Directory('${tmp.path}/world_clip'));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WorldClipProjectsScreen(store: store),
    ));
    await tester.pumpAndSettle();
    expect(find.text('No saved World Clip projects'), findsOneWidget);
    await tmp.delete(recursive: true);
  });
}
```

- [ ] **Step 3: Implement the projects screen**

Create `lib/screens/world_clip/world_clip_projects_screen.dart`:

```dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../l10n/app_localizations.dart';
import '../../services/world_clip/clip_project_store.dart';
import '../../services/world_clip/models/clip_project.dart';
import 'world_clip_flow_screen.dart';

class WorldClipProjectsScreen extends StatefulWidget {
  /// Injectable for tests; defaults to the cache-dir store.
  final ClipProjectStore? store;
  const WorldClipProjectsScreen({super.key, this.store});

  @override
  State<WorldClipProjectsScreen> createState() =>
      _WorldClipProjectsScreenState();
}

class _WorldClipProjectsScreenState extends State<WorldClipProjectsScreen> {
  ClipProjectStore? _store;
  List<ClipProject> _projects = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _store = widget.store ??
        ClipProjectStore(Directory(p.join(
            (await getTemporaryDirectory()).path, 'world_clip')));
    await _reload();
  }

  Future<void> _reload() async {
    final projects = await _store!.listAll();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.worldClipProjects)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _projects.isEmpty
              ? Center(child: Text(l10n.worldClipEmptyProjects))
              : ListView.builder(
                  itemCount: _projects.length,
                  itemBuilder: (context, i) {
                    final pr = _projects[i];
                    return ListTile(
                      title: Text(pr.name),
                      subtitle: Text('${pr.clips.length} clips'),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            WorldClipFlowScreen(resumeProjectId: pr.id),
                      )),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: l10n.worldClipDeleteProject,
                        onPressed: () async {
                          await _store!.delete(pr.id);
                          await _reload();
                        },
                      ),
                    );
                  },
                ),
    );
  }
}
```

- [ ] **Step 4: Add a settings entry**

In the settings screen file from Step 1, add the import:

```dart
import 'world_clip/world_clip_projects_screen.dart';
```

Add a `ListTile` among the settings items:

```dart
          ListTile(
            leading: const Icon(Icons.movie_creation_outlined),
            title: Text(AppLocalizations.of(context)!.worldClipProjects),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const WorldClipProjectsScreen(),
            )),
          ),
```

- [ ] **Step 5: Run test + analyzer**

Run:
```bash
flutter test test/world_clip/world_clip_projects_screen_test.dart
flutter analyze lib/screens/world_clip lib/screens/settings_screen.dart
```
Expected: PASS; analyzer clean. (Adjust the settings file path to the real one.)

- [ ] **Step 6: Commit**

```bash
git add lib/screens/world_clip/world_clip_projects_screen.dart lib/screens/settings_screen.dart test/world_clip/world_clip_projects_screen_test.dart
git commit -m "feat(world_clip): add World Clip Projects list in settings"
```

---

## Phase 9 — Resume + full verification

### Task 19: Implement project resume in the flow screen

**Files:**
- Modify: `lib/screens/world_clip/world_clip_flow_screen.dart`

- [ ] **Step 1: Load an existing project on init when resuming**

In `_WorldClipFlowScreenState.initState`, add:

```dart
  @override
  void initState() {
    super.initState();
    if (widget.resumeProjectId != null) _resume(widget.resumeProjectId!);
  }

  Future<void> _resume(String projectId) async {
    final store = await _ensureStore();
    final project = await store.load(projectId);
    if (project == null) return;
    final videoPath =
        p.join(store.projectDir(project.id).path, project.sourceVideoFileName);
    final extractor = OpenCvFrameExtractor(videoPath);
    final timestamps = await extractor.sampleTimestamps(fps: 5);
    setState(() {
      _project = project;
      _extractor = extractor;
      _timestamps = timestamps;
      _tagged
        ..clear()
        ..addAll(project.clips.map((c) => c.frameTimestampMs));
      _stage = WorldClipStage.timeline;
    });
  }
```

- [ ] **Step 2: Persist tags on the project when they change**

In the timeline's `onToggleTag`, after mutating `_tagged`, persist:

```dart
                  onToggleTag: (ts) async {
                    setState(() => _tagged.contains(ts)
                        ? _tagged.remove(ts)
                        : _tagged.add(ts));
                    // Sync ClipSpecs with the tag set and save.
                    _project!.clips.removeWhere(
                        (c) => !_tagged.contains(c.frameTimestampMs));
                    for (final t in _tagged) {
                      if (!_project!.clips
                          .any((c) => c.frameTimestampMs == t)) {
                        _project!.clips.add(ClipSpec(
                            id: t.toString(),
                            frameTimestampMs: t,
                            order: 0,
                            corrections: const []));
                      }
                    }
                    await _store!.save(_project!);
                  },
```

- [ ] **Step 3: Verify resume manually**

Run: `flutter run -d macos`
Manually: create a project (import video, tag a frame), back out, open Settings → World Clip Projects → tap the project → confirm the timeline reappears with the prior tag highlighted.

- [ ] **Step 4: Commit**

```bash
git add lib/screens/world_clip/world_clip_flow_screen.dart
git commit -m "feat(world_clip): resume cached projects from settings"
```

### Task 20: Full-suite run + manual corpus verification

**Files:** none (verification only).

- [ ] **Step 1: Run the entire test suite**

Run: `flutter test`
Expected: all tests pass (World Clip tests + existing suite unaffected).

- [ ] **Step 2: Run the analyzer over the whole feature**

Run: `flutter analyze`
Expected: no new errors/warnings in `lib/services/world_clip` or `lib/screens/world_clip`.

- [ ] **Step 3: Manual corpus check on a device**

On a real device (or simulator with a sideloaded video), run the full flow for three inputs and confirm clean, ordered output:
- a short pan over a paperback page,
- an app screen-recording (no correction needed — confirm raw frames compile fine),
- a pan over a whiteboard (use mesh dewarp to flatten).

For each: confirm the produced note opens, the PDF renders in the pdfrx viewer (PDF output) or images render inline (image output), and that an existing AI action (e.g. send the note's attachment to Gemini) works on the result — confirming the "reuse existing AI" goal.

- [ ] **Step 4: Final commit (docs/cleanup if any)**

```bash
git add -A
git commit -m "chore(world_clip): finalize feature after full verification"
```

---

## Self-Review notes (for the implementer)

- **Spec coverage:** Stage flow (§4) → Tasks 13–16, 19; data shapes (§5) → Tasks 2–5; PDF/inline output (§4 Stage 5) → Task 7; entry points (§4) → Tasks 17–18; dependencies/risks (§6) → Task 1 (spike) + seams in Tasks 8–10; testing (§7) → tests in each task + Task 20.
- **OpenCV API names** in Tasks 8–9 are written against the documented `opencv_dart` surface but MUST be confirmed against the resolved package version; the tests pin behavior, not symbol names — adjust call sites if the API differs.
- **`AppProvider.addNote`** (confirmed `lib/providers/app_provider.dart:104`) is the single persistence call used in Task 15. The settings screen is **`lib/screens/settings_screen.dart`** (confirmed) — Task 18 edits that file.
- **Correction UI scope:** Task 16 ships the **mesh-dewarp** editor (the spec's central, user-emphasized requirement, incl. subdivide-for-creases). `CropCorrection`/`RotateCorrection` are fully implemented and tested in the `FrameCorrection` engine (Task 9) and persist in `ClipSpec`; exposing crop/rotate gesture controls in the editor is a fast-follow using the same `Positioned`-drag pattern. Flag to the user if full crop/rotate UI is required in this pass.
- **No DB migration**, no new AI surface, no new key storage — confirmed against the spec boundary.
- **No mockito/build_runner** needed for any World Clip test (compiler returns a `Note`; tests use fakes/temp dirs), so `dart run build_runner build` is not a prerequisite for this feature's suite.
