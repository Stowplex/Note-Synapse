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
import '../../services/world_clip/frame_correction.dart';
import '../../services/world_clip/clip_project_store.dart';
import '../../services/world_clip/clip_compiler.dart';
import '../../services/world_clip/models/clip_project.dart';
import '../../services/world_clip/models/clip_spec.dart';
import '../../services/world_clip/models/correction.dart';
import 'world_clip_timeline.dart';
import 'clip_review_screen.dart';
import 'mesh_editor.dart';

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
  WorldClipStage _stage = WorldClipStage.source;

  ClipProjectStore? _store;
  ClipProject? _project;
  FrameExtractor? _extractor;
  List<int> _timestamps = [];
  final Set<int> _tagged = {};

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
    final extractor = OpenCvFrameExtractor(videoPath);
    final timestamps = await extractor.sampleTimestamps(fps: 5);
    if (!mounted) return;
    setState(() {
      _project = project;
      _extractor = extractor;
      _timestamps = timestamps;
      _stage = WorldClipStage.timeline;
    });
  }

  Future<void> _resume(String projectId) async {
    final store = await _ensureStore();
    final project = await store.load(projectId);
    if (project == null) return;
    final videoPath =
        p.join(store.projectDir(project.id).path, project.sourceVideoFileName);
    final extractor = OpenCvFrameExtractor(videoPath);
    final timestamps = await extractor.sampleTimestamps(fps: 5);
    if (!mounted) return;
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

  /// The ClipSpec for [ts], or null when the frame isn't tagged.
  ClipSpec? _clipFor(int ts) {
    final i = _project!.clips.indexWhere((c) => c.frameTimestampMs == ts);
    return i < 0 ? null : _project!.clips[i];
  }

  /// Tagged timestamps in the user's chosen order (persisted `ClipSpec.order`,
  /// ties broken by timestamp) so a reorder survives a resume.
  List<int> _orderedTagsFromClips() {
    final clips = _project!.clips.toList()
      ..sort((a, b) {
        final byOrder = a.order.compareTo(b.order);
        return byOrder != 0
            ? byOrder
            : a.frameTimestampMs.compareTo(b.frameTimestampMs);
      });
    return clips.map((c) => c.frameTimestampMs).toList();
  }

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
      pages.add(await correction.apply(full, _correctionsFor(ts)));
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
            if (!mounted) return;
            setState(() => _reviewPages[index] = corrected);
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    ));
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.worldClip)),
      body: switch (_stage) {
        WorldClipStage.source => _SourceStage(onPicked: _onPickVideo),
        WorldClipStage.timeline => Column(
            children: [
              Expanded(
                child: WorldClipTimeline(
                  timestamps: _timestamps,
                  taggedTimestamps: _tagged,
                  thumbnailBuilder: (ts) => _extractor!.thumbnailAt(ts),
                  onToggleTag: _onToggleTag,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: _tagged.isEmpty
                      ? null
                      : () async {
                          setState(() => _stage = WorldClipStage.review);
                          await _buildReviewPages();
                        },
                  child: Text(l10n.worldClipReview),
                ),
              ),
            ],
          ),
        WorldClipStage.review => _reviewPages.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : ClipReviewScreen(
                pages: _reviewPages,
                onReorder: (oldI, newI) {
                  setState(() {
                    if (newI > oldI) newI -= 1;
                    final t = _orderedTags.removeAt(oldI);
                    _orderedTags.insert(newI, t);
                    final pg = _reviewPages.removeAt(oldI);
                    _reviewPages.insert(newI, pg);
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
                  });
                  _persistOrder();
                },
                onEdit: _editClip,
                onCompilePdf: () => _compile(ClipOutputFormat.pdf),
                onCompileImages: () => _compile(ClipOutputFormat.inlineImages),
              ),
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
