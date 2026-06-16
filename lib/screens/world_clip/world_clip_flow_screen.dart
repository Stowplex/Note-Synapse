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
import '../../services/world_clip/frame_extractor.dart';
import '../../services/world_clip/frame_selector.dart';
import '../../services/world_clip/frame_correction.dart';
import '../../services/world_clip/clip_project_store.dart';
import '../../services/world_clip/clip_compiler.dart';
import '../../services/world_clip/models/clip_project.dart';
import '../../services/world_clip/models/clip_spec.dart';
import '../../services/world_clip/models/correction.dart';
import 'world_clip_timeline.dart';
import 'clip_review_screen.dart';
import 'correction_editor.dart';

/// Stages of the capture flow. Per-clip correction (mesh editor) is reached as
/// a pushed route from the review stage rather than a top-level stage.
enum WorldClipStage { source, timeline, review }

class WorldClipFlowScreen extends StatefulWidget {
  /// When non-null, resume an existing cached project by id.
  final String? resumeProjectId;
  const WorldClipFlowScreen({super.key, this.resumeProjectId});

  @override
  State<WorldClipFlowScreen> createState() => _WorldClipFlowScreenState();
}

class _WorldClipFlowScreenState extends State<WorldClipFlowScreen> {
  // Cap corrected-page resolution so the in-memory review pages (and the PDF /
  // inline-image / isolate-copy payloads built from them) stay bounded — this
  // is the root mitigation for OOM on clips with many pages.
  static const int _maxPageWidth = 1600;

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
  bool _compiling = false; // building the note (PDF/inline) in progress
  // Shared timeline-thumbnail cache: warmed in the background and reused by the
  // strip, the scrub highlight, and (crucially) auto key-frame detection so the
  // detector scores already-decoded thumbnails instead of re-extracting frames.
  final Map<int, Future<Uint8List>> _thumbCache = {};
  // Bound resident thumbnail memory (each ~10-20KB). LRU-evict the oldest so a
  // long video can't accumulate every decoded thumbnail (would OOM).
  static const int _thumbCacheCap = 150;

  Future<Uint8List> _thumb(int ts) {
    final f = _thumbCache[ts] ??= _extractor!.thumbnailAt(ts);
    if (_thumbCache.length > _thumbCacheCap && _thumbCache.keys.first != ts) {
      _thumbCache.remove(_thumbCache.keys.first);
    }
    return f;
  }

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

  Future<void> _resume(String projectId) async {
    final store = await _ensureStore();
    final project = await store.load(projectId);
    if (project == null) return;
    final videoPath =
        p.join(store.projectDir(project.id).path, project.sourceVideoFileName);
    final extractor = PlatformFrameExtractor(videoPath);
    final timestamps = await extractor.sampleTimestamps(fps: 5);
    if (!mounted) return;
    setState(() {
      _project = project;
      _extractor = extractor;
      _timestamps = timestamps;
      _tagged
        ..clear()
        ..addAll(project.clips.map((c) => c.frameTimestampMs));
      _selectedTs = timestamps.isEmpty ? null : timestamps.first;
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

  /// Auto-suggests key frames: scores every sampled thumbnail (reused from the
  /// cache, not re-decoded) for sharpness + inter-frame motion, then segments
  /// the clip into stable holds and tags the sharpest frame of each held page.
  /// Progress overlay. Uses the full timeline sampling so brief page holds are
  /// not missed.
  Future<void> _autoDetectKeyframes() async {
    if (_extractor == null || _timestamps.isEmpty) return;
    final sampled = List<int>.from(_timestamps);
    setState(() {
      _detecting = true;
      _detectLabel = 'Analyzing 0/${sampled.length}';
    });
    final features = <FrameFeature>[];
    Uint8List? prevPng;
    try {
      for (var i = 0; i < sampled.length; i++) {
        final png = await _thumb(sampled[i]);
        features.add(computeFrameFeature(
            timestampMs: sampled[i], framePng: png, prevFramePng: prevPng));
        prevPng = png;
        if (!mounted) return;
        setState(() => _detectLabel = 'Analyzing ${i + 1}/${sampled.length}');
      }
    } catch (_) {
      // Feature extraction failed (e.g. decode hiccup) — abort gracefully.
      if (mounted) setState(() => _detecting = false);
      return;
    }
    // Defaults segment the clip into stable page-holds with an adaptive motion
    // threshold, so this self-tunes to a steady e-reader or a handheld book.
    const selector = FrameSelector();
    if (!mounted) return; // user left mid-detection — don't mutate/persist
    final picks = selector.suggest(features);
    for (final ts in picks) {
      if (_clipFor(ts) == null) {
        _tagged.add(ts);
        _project!.clips.add(ClipSpec(
            id: ts.toString(),
            frameTimestampMs: ts,
            order: _project!.clips.length,
            corrections: const []));
      }
    }
    await _store!.save(_project!);
    if (!mounted) return;
    setState(() {
      _detecting = false;
      if (picks.isNotEmpty) _selectedTs = picks.first;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Suggested ${picks.length} key frame(s)')),
      );
    }
  }

  /// The ClipSpec for [ts], or null when the frame isn't tagged.
  ClipSpec? _clipFor(int ts) {
    final i = _project!.clips.indexWhere((c) => c.frameTimestampMs == ts);
    return i < 0 ? null : _project!.clips[i];
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
      _clipFor(_orderedTags[i])?.order = i;
    }
    await _store!.save(_project!);
  }

  Future<void> _onToggleTag(int ts) async {
    setState(() =>
        _tagged.contains(ts) ? _tagged.remove(ts) : _tagged.add(ts));
    // Sync ClipSpecs with the tag set: drop untagged, append new tags.
    _project!.clips
        .removeWhere((c) => !_tagged.contains(c.frameTimestampMs));
    for (final t in _tagged) {
      if (_clipFor(t) == null) {
        _project!.clips.add(ClipSpec(
            id: t.toString(),
            frameTimestampMs: t,
            order: _project!.clips.length,
            corrections: const []));
      }
    }
    await _store!.save(_project!);
  }

  Future<void> _buildReviewPages() async {
    final correction = getIt<FrameCorrection>();
    _orderedTags = _orderedTagsFromClips();
    final pages = <Uint8List>[];
    for (final ts in _orderedTags) {
      final full = await _extractor!.fullFrameAt(ts);
      try {
        pages.add(await correction.apply(full, _correctionsFor(ts),
            maxWidth: _maxPageWidth));
      } catch (_) {
        // A bad correction must not strand the whole review on a spinner —
        // fall back to the uncorrected frame so the page still shows.
        pages.add(full);
      }
    }
    if (!mounted) return;
    setState(() => _reviewPages = pages);
  }

  List<Correction> _correctionsFor(int ts) =>
      _clipFor(ts)?.corrections ?? const [];

  void _setCorrectionsFor(int ts, List<Correction> corrections) {
    final existing = _project!.clips.indexWhere((c) => c.frameTimestampMs == ts);
    final spec = ClipSpec(
        id: ts.toString(),
        frameTimestampMs: ts,
        order: existing >= 0 ? _project!.clips[existing].order : _orderedTags.indexOf(ts),
        corrections: corrections);
    if (existing >= 0) {
      _project!.clips[existing] = spec;
    } else {
      _project!.clips.add(spec);
    }
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
            final corrected =
                await getIt<FrameCorrection>()
                    .apply(full, corrections, maxWidth: _maxPageWidth);
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

    setState(() => _cloning = true);
    final correction = getIt<FrameCorrection>();
    try {
      for (final i in targets) {
        final ts = _orderedTags[i];
        // Deep-copy via JSON so each clip owns its corrections.
        final cloned = [
          for (final c in sourceCorrections)
            Correction.fromJson(c.toJson())
        ];
        _setCorrectionsFor(ts, cloned);
        final full = await _extractor!.fullFrameAt(ts);
        final corrected =
            await correction.apply(full, cloned, maxWidth: _maxPageWidth);
        final current = _orderedTags.indexOf(ts);
        if (current >= 0) _reviewPages[current] = corrected;
      }
      await _store!.save(_project!);
    } finally {
      if (mounted) setState(() => _cloning = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cloned edits to ${targets.length} page(s)')),
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
                    ? const Center(child: Text('No frames',
                        style: TextStyle(color: Colors.white70)))
                    : _LargePreview(
                        timestampMs: _selectedTs!,
                        builder: (ts) =>
                            _extractor!.thumbnailAt(ts, maxWidth: 720),
                      ),
              ),
            ),
            // Key-frame + auto-detect controls.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _selectedTs == null
                          ? null
                          : _toggleSelectedKeyframe,
                      icon: Icon(selectedTagged ? Icons.key_off : Icons.key),
                      label: Text(selectedTagged
                          ? 'Remove key frame'
                          : 'Set key frame'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _detecting ? null : _autoDetectKeyframes,
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('Auto'),
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
        if (_detecting)
          Positioned.fill(
            child: ColoredBox(
              color: const Color(0x99000000),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(_detectLabel,
                        style: const TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.worldClip)),
      body: switch (_stage) {
        WorldClipStage.source => _SourceStage(onPicked: _onPickVideo),
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
                    // stage on its loading spinner — step back to the timeline.
                    if (_reviewPages.isEmpty) {
                      _stage = WorldClipStage.timeline;
                    }
                  });
                  _persistOrder();
                },
                onEdit: _editClip,
                onCloneEdits: _cloneEdits,
                onCompilePdf: () => _compile(ClipOutputFormat.pdf),
                onCompileImages: () => _compile(ClipOutputFormat.inlineImages),
              ),
                  if (_cloning)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Color(0x99000000),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                  if (_compiling)
                    Positioned.fill(
                      child: ColoredBox(
                        color: const Color(0x99000000),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 12),
                              Text(
                                AppLocalizations.of(context)!.worldClipCompile,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      },
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
  final Map<int, Future<Uint8List>> _cache = {};
  static const _cap = 24; // bound memory on long videos (full-size previews)

  final TransformationController _zoom = TransformationController();

  Future<Uint8List> _frameFor(int ts) {
    final f = _cache[ts] ??= widget.builder(ts);
    if (_cache.length > _cap && _cache.keys.first != ts) {
      _cache.remove(_cache.keys.first);
    }
    return f;
  }

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
