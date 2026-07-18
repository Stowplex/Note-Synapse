import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_provider.dart';
import '../../services/service_locator.dart';
import '../../services/world_clip/video_source.dart';
import '../../services/world_clip/screen_capture_service.dart';
import '../../services/world_clip/frame_extractor.dart';
import '../../services/world_clip/frame_selector.dart';
import '../../services/world_clip/keyframe_detector.dart';
import '../../services/world_clip/edge_detector.dart';
import '../../services/world_clip/frame_correction.dart';
import '../../services/world_clip/clip_project_store.dart';
import '../../services/world_clip/clip_compiler.dart';
import '../../services/world_clip/models/clip_project.dart';
import '../../services/world_clip/models/clip_spec.dart';
import '../../services/world_clip/models/correction.dart';
import '../../services/world_clip/models/mesh_grid.dart';
import 'world_clip_timeline.dart';
import 'clip_review_screen.dart';
import 'correction_editor.dart';
import 'frame_memo_cache.dart';
import 'picture_sequence_screen.dart';
import 'progress_scrim.dart';

/// Stages of the capture flow. Per-clip correction (mesh editor) is reached as
/// a pushed route from the review stage rather than a top-level stage.
enum WorldClipStage { source, timeline, review }

/// Nearest tagged key-frame strictly before [current], or the last one when
/// nothing is selected; null when there is none to go to. Top-level so the
/// timeline stage's prev/next navigation is unit-testable without driving
/// device-only frame extraction.
int? previousKeyframe(Set<int> tagged, int? current) {
  int? best;
  for (final t in tagged) {
    if (current != null && t >= current) continue;
    if (best == null || t > best) best = t;
  }
  return best;
}

/// Nearest tagged key-frame strictly after [current], or the first one when
/// nothing is selected; null when there is none to go to.
int? nextKeyframe(Set<int> tagged, int? current) {
  int? best;
  for (final t in tagged) {
    if (current != null && t <= current) continue;
    if (best == null || t < best) best = t;
  }
  return best;
}

class WorldClipFlowScreen extends StatefulWidget {
  /// When non-null, resume an existing cached project by id.
  final String? resumeProjectId;
  const WorldClipFlowScreen({super.key, this.resumeProjectId});

  @override
  State<WorldClipFlowScreen> createState() => _WorldClipFlowScreenState();
}

class _WorldClipFlowScreenState extends State<WorldClipFlowScreen> {
  WorldClipStage _stage = WorldClipStage.source;

  ClipProjectStore? _store;
  ClipProject? _project;
  FrameExtractor? _extractor;
  List<int> _timestamps = [];
  final Set<int> _tagged = {};
  int? _selectedTs; // current scrub position in the timeline stage
  bool _detecting = false;
  String _detectLabel = '';
  bool _cloning = false; // batch clone-edits in progress (review stage)
  String _cloneLabel = ''; // progress label for the clone overlay
  bool _compiling = false; // building the note (PDF/inline) in progress
  bool _capturing = false; // screen recording in progress (source stage)
  // Shared timeline-thumbnail cache: warmed in the background and reused by the
  // strip, the scrub highlight, and (crucially) auto key-frame detection so the
  // detector scores already-decoded thumbnails instead of re-extracting frames.
  // Bounded so a long video can't accumulate every decoded thumbnail (OOM).
  static const int _thumbCacheCap = 150;
  final _thumbCache = FrameMemoCache(_thumbCacheCap);

  Future<Uint8List> _thumb(int ts) =>
      _thumbCache.getOrAdd(ts, () => _extractor!.thumbnailAt(ts));

  /// Eagerly decodes the first window of timeline thumbnails in the background
  /// so the strip and scrubbing are responsive on entry. Bounded by the cache
  /// cap — warming more than fits would just thrash eviction. The rest load
  /// lazily as the strip scrolls / detection samples them.
  Future<void> _prewarmThumbnails() async {
    final warm = _timestamps.take(_thumbCacheCap).toList();
    for (final ts in warm) {
      if (!mounted || _stage != WorldClipStage.timeline || _extractor == null) {
        return;
      }
      try {
        await _thumb(ts);
      } catch (_) {
        // Skip frames that fail to decode; detection/strip tolerate gaps.
      }
    }
  }

  List<Uint8List> _reviewPages = [];
  List<int> _orderedTags = [];

  @override
  void initState() {
    super.initState();
    if (widget.resumeProjectId != null) _resume(widget.resumeProjectId!);
  }

  @override
  void dispose() {
    _extractor?.dispose();
    super.dispose();
  }

  Future<ClipProjectStore> _ensureStore() async {
    if (_store != null) return _store!;
    final cache = await getTemporaryDirectory();
    _store = ClipProjectStore(Directory(p.join(cache.path, 'world_clip')));
    return _store!;
  }

  Future<void> _onPickVideo() async {
    final file = await getIt<VideoSource>().pickVideo();
    if (file == null) return;
    await _startVideoProject(file);
  }

  /// "Screen Capture": records the device screen (the user switches to the app
  /// they want to film, then stops via the in-app button or the notification),
  /// then routes the recording into the same video pipeline as a gallery
  /// import. Shows the recording overlay while the capture is live.
  Future<void> _onScreenCapture() async {
    final svc = getIt<ScreenCaptureService>();
    setState(() => _capturing = true);
    File? file;
    try {
      file = await svc.record();
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
    if (file == null) return; // cancelled / denied / failed
    await _startVideoProject(file);
  }

  Future<void> _stopScreenCapture() =>
      getIt<ScreenCaptureService>().stop();

  /// Copies [file] into a fresh project, samples its frames, and opens the
  /// timeline stage. Shared by gallery import and screen capture.
  Future<void> _startVideoProject(File file) async {
    final store = await _ensureStore();
    final project = await store.create(
        name: 'Clip ${DateTime.now().toIso8601String().substring(0, 16)}',
        sourceVideo: file);
    final videoPath =
        p.join(store.projectDir(project.id).path, project.sourceVideoFileName);
    final extractor = PlatformFrameExtractor(videoPath);
    final timestamps = await extractor.sampleTimestamps(fps: 5);
    if (!mounted) return;
    setState(() {
      _project = project;
      _extractor = extractor;
      _timestamps = timestamps;
      _selectedTs = timestamps.isEmpty ? null : timestamps.first;
      _stage = WorldClipStage.timeline;
    });
    _prewarmThumbnails();
  }

  /// "Import Pictures": multi-pick images and go straight to the review /
  /// keystone-correction stage (no video timeline / key-frame step). RAW
  /// captures (DNG twins of the JPEGs on Pixel/ProRAW) are indistinguishable
  /// in the OS picker and undecodable downstream, so they are dropped here
  /// with a notice instead of failing later in the pipeline.
  Future<void> _onPickImages() async {
    final picked = await getIt<VideoSource>().pickImages();
    final files = [for (final f in picked) if (!isRawImagePath(f.path)) f];
    final skippedRaw = picked.length - files.length;
    if (skippedRaw > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!
              .worldClipSkippedRawImages(skippedRaw))));
    }
    if (files.isEmpty || !mounted) return;
    await _importPictureFiles(files);
  }

  /// "Picture Sequence": in-app camera capture of a still-photo sequence
  /// (optionally anti-glare-fused per page — see [PictureSequenceScreen]).
  /// Feeds the resulting files through the exact same picture-import pipeline
  /// as [_onPickImages] — the two differ only in how the images were acquired.
  Future<void> _onPictureSequence() async {
    final files = await Navigator.of(context).push<List<File>?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PictureSequenceScreen(),
      ),
    );
    if (files == null || files.isEmpty || !mounted) return;
    // The captured pages live in a temp dir PictureSequenceScreen created and
    // handed off (rather than cleaning up itself, since deleting them before
    // the import's copy finishes would race it) — reclaim it once they're
    // safely copied into the project.
    await _importPictureFiles(files, cleanupDir: files.first.parent);
  }

  /// Copies [files] into a fresh picture project and opens the review stage —
  /// the single import pipeline shared by "Import pictures" and "Picture
  /// sequence" (they differ only in how the images were acquired). Deletes
  /// [cleanupDir] (best-effort) once the copy succeeded.
  Future<void> _importPictureFiles(List<File> files,
      {Directory? cleanupDir}) async {
    final name = AppLocalizations.of(context)!.worldClipPicturesProjectName(
        DateTime.now().toIso8601String().substring(0, 16));
    final store = await _ensureStore();
    final ClipProject project;
    try {
      project = await store.createFromImages(name: name, images: files);
    } catch (e) {
      // The source files are unreachable to the user either way — reclaim
      // them rather than stranding them in the temp dir until OS cleanup.
      await _deleteQuietly(cleanupDir);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                AppLocalizations.of(context)!.worldClipImportFailed('$e'))));
      }
      return;
    }
    await _deleteQuietly(cleanupDir);
    if (!mounted) return;
    await _enterPictureReview(store, project);
  }

  static Future<void> _deleteQuietly(Directory? dir) async {
    if (dir == null) return;
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Sets up a picture project's frame source and opens the review stage,
  /// skipping the timeline. Shared by fresh import and resume.
  Future<void> _enterPictureReview(
      ClipProjectStore store, ClipProject project) async {
    final indices = project.clips.map((c) => c.frameTimestampMs).toList()
      ..sort();
    setState(() {
      _project = project;
      _extractor = PictureFrameExtractor(store.imagePaths(project));
      _timestamps = indices;
      _tagged
        ..clear()
        ..addAll(indices);
      _selectedTs = indices.isEmpty ? null : indices.first;
      _stage = WorldClipStage.review;
      _reviewPages = [];
    });
    await _buildReviewPages();
  }

  Future<void> _resume(String projectId) async {
    final store = await _ensureStore();
    final project = await store.load(projectId);
    if (project == null) return;
    if (project.isPictureProject) {
      if (!mounted) return;
      await _enterPictureReview(store, project);
      return;
    }
    final videoPath =
        p.join(store.projectDir(project.id).path, project.sourceVideoFileName);
    final extractor = PlatformFrameExtractor(videoPath);
    final timestamps = await extractor.sampleTimestamps(fps: 5);
    if (!mounted) return;
    setState(() {
      _project = project;
      _extractor = extractor;
      // Auto-detection's fast-scroll refinement can persist tags BETWEEN the
      // fps-5 samples — merge them back in so every restored tag has a thumb
      // in the strip (same merge _autoDetectKeyframes does in-session).
      _timestamps = {
        ...timestamps,
        ...project.clips.map((c) => c.frameTimestampMs),
      }.toList()
        ..sort();
      _tagged
        ..clear()
        ..addAll(project.clips.map((c) => c.frameTimestampMs));
      _selectedTs = _timestamps.isEmpty ? null : _timestamps.first;
      _stage = WorldClipStage.timeline;
    });
    _prewarmThumbnails();
  }

  /// Toggles the key-frame tag for the currently-selected scrub frame and
  /// persists (the explicit "Set/Remove key-frame" button).
  Future<void> _toggleSelectedKeyframe() async {
    final ts = _selectedTs;
    if (ts == null) return;
    await _onToggleTag(ts);
  }

  /// Auto-suggests key frames via [KeyframeDetector]: every sampled thumbnail
  /// (reused from the cache, not re-decoded) is scored for sharpness,
  /// inter-frame motion, and 2D viewport shift; the clip is then classified —
  /// a scrolling/panning capture is walked by cumulative coverage (no dropped
  /// lines, bounded overlap) while a page-flip capture keeps the original
  /// stable-hold segmentation — and near-identical pages are pruned.
  Future<void> _autoDetectKeyframes() async {
    if (_extractor == null || _timestamps.isEmpty) return;
    final sampled = List<int>.from(_timestamps);
    setState(() {
      _detecting = true;
      _detectLabel =
          AppLocalizations.of(context)!.worldClipAnalyzing(0, sampled.length);
    });
    KeyframeDetectionResult? result;
    try {
      final detector = KeyframeDetector(
        thumbAt: _thumb,
        shouldAbort: () => !mounted,
        onProgress: (done, total) {
          if (mounted) {
            setState(() => _detectLabel =
                AppLocalizations.of(context)!.worldClipAnalyzing(done, total));
          }
        },
      );
      result = await detector.detect(sampled);
    } catch (_) {
      result = null; // decode hiccup mid-detection — abort gracefully
    }
    if (!mounted) return; // user left mid-detection — don't mutate/persist
    if (result == null) {
      setState(() => _detecting = false);
      return;
    }
    final picks = result.timestamps;
    for (final ts in picks) {
      _tagged.add(ts);
      _project!.ensureClip(ts);
    }
    await _store!.save(_project!);
    if (!mounted) return;
    setState(() {
      _detecting = false;
      // Fast-scroll refinement can suggest frames BETWEEN the original
      // samples — merge them into the strip so their tags are visible.
      _timestamps = {..._timestamps, ...picks}.toList()..sort();
      if (picks.isNotEmpty) _selectedTs = picks.first;
    });
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      // Edge state: no clear pages found and no manual tags yet.
      final message = picks.isEmpty && _tagged.isEmpty
          ? l10n.worldClipNoClearPages
          : result.mode == CaptureMode.scroll
              ? l10n.worldClipSuggestedKeyFramesScrolling(picks.length)
              : l10n.worldClipSuggestedKeyFrames(picks.length);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Tagged timestamps in display order. By default this is video (timestamp)
  /// order — so auto-detected and manually-added frames interleave correctly;
  /// only once the user has drag-reordered ([ClipProject.manualOrder]) does the
  /// persisted [ClipSpec.order] take over (ties still broken by timestamp).
  List<int> _orderedTagsFromClips() =>
      _project!.orderedClips().map((c) => c.frameTimestampMs).toList();

  /// Rewrites every ClipSpec.order to match the current `_orderedTags` and
  /// persists, so review-stage reorder/remove are durable.
  Future<void> _persistOrder() async {
    for (var i = 0; i < _orderedTags.length; i++) {
      _project!.clipForTimestamp(_orderedTags[i])?.order = i;
    }
    await _store!.save(_project!);
  }

  Future<void> _onToggleTag(int ts) async {
    setState(() =>
        _tagged.contains(ts) ? _tagged.remove(ts) : _tagged.add(ts));
    // Sync ClipSpecs with the tag set: drop untagged, ensure tagged exist.
    _project!.clips
        .removeWhere((c) => !_tagged.contains(c.frameTimestampMs));
    for (final t in _tagged) {
      _project!.ensureClip(t);
    }
    await _store!.save(_project!);
  }

  List<Correction> _correctionsFor(int ts) =>
      _project!.clipForTimestamp(ts)?.corrections ?? const [];

  void _setCorrectionsFor(int ts, List<Correction> corrections) =>
      _project!.ensureClip(ts).corrections = corrections;

  /// Decodes the full frame at [ts] and applies its corrections, capped to the
  /// shared page-width. Falls back to the uncorrected frame if a correction
  /// throws, so a bad edit never strands the review on a spinner.
  Future<Uint8List> _renderCorrectedPage(int ts) async {
    final full = await _extractor!.fullFrameAt(ts);
    try {
      return await getIt<FrameCorrection>().apply(
        full,
        _correctionsFor(ts),
        maxWidth: kWorldClipMaxPageWidth,
        jpegQuality: kWorldClipJpegQuality,
      );
    } catch (_) {
      return full;
    }
  }

  Future<void> _buildReviewPages() async {
    _orderedTags = _orderedTagsFromClips();
    final pages = [for (final ts in _orderedTags) await _renderCorrectedPage(ts)];
    if (!mounted) return;
    setState(() => _reviewPages = pages);
  }

  Future<void> _editClip(int index) async {
    final ts = _orderedTags[index];
    final full = await _extractor!.fullFrameAt(ts);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      // fullscreenDialog disables the iOS swipe-back-to-pop gesture, which
      // otherwise collides with dragging the keystone corner handles near the
      // screen edge.
      fullscreenDialog: true,
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(AppLocalizations.of(context)!.worldClip)),
        body: CorrectionEditor(
          framePng: full,
          initial: _correctionsFor(ts),
          onDone: (corrections) async {
            _setCorrectionsFor(ts, corrections);
            await _store!.save(_project!);
            final corrected = await getIt<FrameCorrection>().apply(
              full,
              corrections,
              maxWidth: kWorldClipMaxPageWidth,
              jpegQuality: kWorldClipJpegQuality,
            );
            if (!mounted) return;
            // Re-resolve by timestamp: the page may have moved or been removed
            // while the editor was open, so the captured index can be stale.
            final current = _orderedTags.indexOf(ts);
            if (current >= 0) {
              setState(() => _reviewPages[current] = corrected);
            }
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    ));
  }

  /// Batch-applies [sourceIndex]'s corrections (rotation + crop / keystone) to
  /// every page in [targetIndices], re-rendering each affected review page and
  /// persisting. Cloned corrections are deep-copied so the pages stay
  /// independently editable afterwards.
  Future<void> _cloneEdits(int sourceIndex, Set<int> targetIndices) async {
    if (sourceIndex < 0 || sourceIndex >= _orderedTags.length) return;
    final sourceCorrections = _correctionsFor(_orderedTags[sourceIndex]);
    final targets = targetIndices
        .where((i) => i >= 0 && i < _orderedTags.length && i != sourceIndex)
        .toList();
    if (targets.isEmpty) return;

    setState(() {
      _cloning = true;
      _cloneLabel = '';
    });
    try {
      for (final i in targets) {
        final ts = _orderedTags[i];
        // Deep-copy via JSON so each clip owns its corrections.
        _setCorrectionsFor(ts, [
          for (final c in sourceCorrections) Correction.fromJson(c.toJson())
        ]);
        final corrected = await _renderCorrectedPage(ts);
        final current = _orderedTags.indexOf(ts);
        if (current >= 0) _reviewPages[current] = corrected;
      }
      await _store!.save(_project!);
    } finally {
      if (mounted) setState(() => _cloning = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(AppLocalizations.of(context)!
                .worldClipClonedEdits(targets.length))),
      );
    }
  }

  /// Batch "clone edit actions": copies [sourceIndex]'s rotation and color
  /// adjustments, but re-runs document auto-detection on each target's own
  /// (rotated) frame instead of pasting the source's literal keystone quad —
  /// pages framed slightly differently each get their own fitted crop.
  Future<void> _cloneEditActions(int sourceIndex, Set<int> targetIndices) async {
    if (sourceIndex < 0 || sourceIndex >= _orderedTags.length) return;
    final source = _correctionsFor(_orderedTags[sourceIndex]);
    final rotation = source
        .whereType<RotateCorrection>()
        .fold<double>(0, (sum, r) => sum + r.degrees);
    final colors = source.whereType<ColorAdjustCorrection>().toList();
    final targets = targetIndices
        .where((i) => i >= 0 && i < _orderedTags.length && i != sourceIndex)
        .toList();
    if (targets.isEmpty) return;

    setState(() {
      _cloning = true;
      _cloneLabel = '';
    });
    final engine = getIt<FrameCorrection>();
    try {
      for (var n = 0; n < targets.length; n++) {
        setState(() => _cloneLabel = AppLocalizations.of(context)!
            .worldClipAutoDetecting(n + 1, targets.length));
        // Yield a frame so the progress overlay repaints before the
        // synchronous OpenCV detection blocks the UI isolate.
        await Future<void>.delayed(Duration.zero);
        final ts = _orderedTags[targets[n]];
        final full = await _extractor!.fullFrameAt(ts);
        // Detect on the rotated frame, exactly like "Auto edges" in the
        // editor does after the same rotation.
        final base = rotation % 360 == 0
            ? full
            : await engine.apply(full, [RotateCorrection(degrees: rotation)]);
        final grid = detectDocumentQuad(base);
        _setCorrectionsFor(ts, [
          if (rotation % 360 != 0) RotateCorrection(degrees: rotation),
          MeshDewarpCorrection(
              grid: grid ?? MeshGrid.identity(rows: 1, cols: 1)),
          // Deep-copy so each clip owns its color adjustments.
          for (final c in colors)
            Correction.fromJson(c.toJson()),
        ]);
        final corrected = await _renderCorrectedPage(ts);
        if (!mounted) return;
        final current = _orderedTags.indexOf(ts);
        if (current >= 0) setState(() => _reviewPages[current] = corrected);
      }
      await _store!.save(_project!);
    } finally {
      if (mounted) setState(() => _cloning = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(AppLocalizations.of(context)!
                .worldClipAutoEdited(targets.length))),
      );
    }
  }

  Future<void> _compile(ClipOutputFormat format) async {
    if (_compiling) return; // guard against double-tap
    setState(() => _compiling = true);
    try {
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
    } finally {
      if (mounted) setState(() => _compiling = false);
    }
  }

  Widget _buildTimelineStage(AppLocalizations l10n) {
    final selectedTagged =
        _selectedTs != null && _tagged.contains(_selectedTs);
    final prevKey = previousKeyframe(_tagged, _selectedTs);
    final nextKey = nextKeyframe(_tagged, _selectedTs);
    return Stack(
      children: [
        Column(
          children: [
            // Large preview of the scrub position (video-editor layout).
            Expanded(
              child: Container(
                color: Colors.black,
                width: double.infinity,
                child: _selectedTs == null
                    ? Center(
                        child: Text(l10n.worldClipNoFrames,
                            style: const TextStyle(color: Colors.white70)))
                    : _LargePreview(
                        timestampMs: _selectedTs!,
                        builder: (ts) =>
                            _extractor!.thumbnailAt(ts, maxWidth: 720),
                      ),
              ),
            ),
            // Key-frame navigation + tagging + auto-detect controls.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton.outlined(
                    key: const ValueKey('wc-prev-key'),
                    tooltip: l10n.worldClipPreviousKeyFrame,
                    onPressed: prevKey == null
                        ? null
                        : () => setState(() => _selectedTs = prevKey),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _selectedTs == null
                          ? null
                          : _toggleSelectedKeyframe,
                      icon: Icon(selectedTagged ? Icons.key_off : Icons.key),
                      label: Text(selectedTagged
                          ? l10n.worldClipRemoveKeyFrame
                          : l10n.worldClipSetKeyFrame),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    key: const ValueKey('wc-next-key'),
                    tooltip: l10n.worldClipNextKeyFrame,
                    onPressed: nextKey == null
                        ? null
                        : () => setState(() => _selectedTs = nextKey),
                    icon: const Icon(Icons.chevron_right),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _detecting ? null : _autoDetectKeyframes,
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(l10n.worldClipAutoButton),
                  ),
                ],
              ),
            ),
            WorldClipTimeline(
              timestamps: _timestamps,
              taggedTimestamps: _tagged,
              selectedTimestamp: _selectedTs,
              thumbnailBuilder: _thumb,
              onSelect: (ts) => setState(() => _selectedTs = ts),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _tagged.isEmpty
                      ? null
                      : () async {
                          setState(() => _stage = WorldClipStage.review);
                          await _buildReviewPages();
                        },
                  child: Text('${l10n.worldClipReview} (${_tagged.length})'),
                ),
              ),
            ),
          ],
        ),
        if (_detecting) ProgressScrim(label: _detectLabel),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final stageBody = switch (_stage) {
      WorldClipStage.source => _SourceStage(
          onPickVideo: _onPickVideo,
          onPickImages: _onPickImages,
          onPictureSequence: _onPictureSequence,
          onScreenCapture: _onScreenCapture,
          screenCaptureSupported: getIt<ScreenCaptureService>().isSupported,
        ),
      WorldClipStage.timeline => _buildTimelineStage(l10n),
        WorldClipStage.review => _reviewPages.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                children: [
                  ClipReviewScreen(
                pages: _reviewPages,
                onReorder: (oldI, newI) {
                  setState(() {
                    if (newI > oldI) newI -= 1;
                    final t = _orderedTags.removeAt(oldI);
                    _orderedTags.insert(newI, t);
                    final pg = _reviewPages.removeAt(oldI);
                    _reviewPages.insert(newI, pg);
                    // Switch to manual ordering; from now on the dragged order
                    // is honored instead of timestamp order.
                    _project!.manualOrder = true;
                  });
                  _persistOrder();
                },
                onRemove: (i) {
                  final ts = _orderedTags[i];
                  setState(() {
                    _orderedTags.removeAt(i);
                    _reviewPages.removeAt(i);
                    _tagged.remove(ts);
                    _project!.clips
                        .removeWhere((c) => c.frameTimestampMs == ts);
                    // Removing the last page would otherwise strand the review
                    // stage on its loading spinner. Picture projects have no
                    // timeline, so step back to the source picker; video
                    // projects step back to the timeline to re-tag.
                    if (_reviewPages.isEmpty) {
                      _stage = _project!.isPictureProject
                          ? WorldClipStage.source
                          : WorldClipStage.timeline;
                    }
                  });
                  _persistOrder();
                },
                onEdit: _editClip,
                onCloneEdits: _cloneEdits,
                onCloneEditActions: _cloneEditActions,
                onCompilePdf: () => _compile(ClipOutputFormat.pdf),
                onCompileImages: () => _compile(ClipOutputFormat.inlineImages),
              ),
                  if (_cloning) ProgressScrim(label: _cloneLabel),
                  if (_compiling) ProgressScrim(label: l10n.worldClipCompile),
                ],
              ),
    };
    return Scaffold(
      appBar: AppBar(title: Text(l10n.worldClip)),
      body: Stack(
        children: [
          stageBody,
          if (_capturing) _recordingOverlay(l10n),
        ],
      ),
    );
  }

  /// Full-screen overlay shown while a screen recording is live: the recording
  /// indicator, instructions to switch to the target app, and a Stop button
  /// (the foreground-service notification offers the same Stop action).
  Widget _recordingOverlay(AppLocalizations l10n) {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xCC000000),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.fiber_manual_record,
                    color: Colors.redAccent, size: 48),
                const SizedBox(height: 16),
                Text(l10n.worldClipScreenCaptureRecording,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(l10n.worldClipScreenCaptureHint,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const ValueKey('wc-capture-stop'),
                  onPressed: _stopScreenCapture,
                  icon: const Icon(Icons.stop),
                  label: Text(l10n.worldClipScreenCaptureStop),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Large scrub preview that memoizes the decoded frame per timestamp so
/// re-selecting a frame doesn't re-decode it.
class _LargePreview extends StatefulWidget {
  final int timestampMs;
  final Future<Uint8List> Function(int timestampMs) builder;
  const _LargePreview({required this.timestampMs, required this.builder});

  @override
  State<_LargePreview> createState() => _LargePreviewState();
}

class _LargePreviewState extends State<_LargePreview> {
  // Bound memory — preview frames are larger (720px) than strip thumbnails.
  final _cache = FrameMemoCache(24);
  final TransformationController _zoom = TransformationController();

  Future<Uint8List> _frameFor(int ts) =>
      _cache.getOrAdd(ts, () => widget.builder(ts));

  @override
  void didUpdateWidget(_LargePreview old) {
    super.didUpdateWidget(old);
    // Reset zoom/pan when scrubbing to a different frame.
    if (old.timestampMs != widget.timestampMs) {
      _zoom.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _frameFor(widget.timestampMs),
      builder: (context, snap) => snap.hasData
          // Pinch/double-tap-pan to inspect sharpness at full detail.
          ? InteractiveViewer(
              transformationController: _zoom,
              minScale: 1,
              maxScale: 8,
              child: Center(child: Image.memory(snap.data!, fit: BoxFit.contain)),
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}

class _SourceStage extends StatelessWidget {
  final VoidCallback onPickVideo;
  final VoidCallback onPickImages;
  final VoidCallback onPictureSequence;
  final VoidCallback onScreenCapture;
  final bool screenCaptureSupported;
  const _SourceStage({
    required this.onPickVideo,
    required this.onPickImages,
    required this.onPictureSequence,
    required this.onScreenCapture,
    required this.screenCaptureSupported,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton.icon(
            icon: const Icon(Icons.video_library),
            label: Text(l10n.worldClipImportVideo),
            onPressed: onPickVideo,
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            icon: const Icon(Icons.photo_library),
            label: Text(l10n.worldClipImportPictures),
            onPressed: onPickImages,
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            key: const ValueKey('wc-picture-sequence'),
            icon: const Icon(Icons.burst_mode),
            label: Text(l10n.worldClipPictureSequence),
            onPressed: onPictureSequence,
          ),
          if (screenCaptureSupported) ...[
            const SizedBox(height: 16),
            ElevatedButton.icon(
              key: const ValueKey('wc-screen-capture'),
              icon: const Icon(Icons.fiber_manual_record),
              label: Text(l10n.worldClipScreenCapture),
              onPressed: onScreenCapture,
            ),
          ],
        ],
      ),
    );
  }
}
