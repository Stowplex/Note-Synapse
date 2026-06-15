import 'package:flutter/services.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'frame_selector.dart';

/// Decodes a source video into proxy thumbnails, full-res frames, and
/// per-frame features. The seam lets the decode backend be swapped.
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

/// Extracts frames via a platform method channel backed by Android's
/// `MediaMetadataRetriever` and iOS's `AVAssetImageGenerator`.
///
/// opencv_dart 2.2.x dropped its FFmpeg backend, so its `VideoCapture` cannot
/// decode video files (the Task-1 spike's documented risk #1). Video *decode*
/// therefore runs natively; OpenCV's `imgproc` (which still works) is reused
/// only for the sharpness/scene-change feature math on already-decoded frames.
class PlatformFrameExtractor implements FrameExtractor {
  static const MethodChannel _defaultChannel =
      MethodChannel('note_synapse/video_frames');

  final String videoPath;
  final MethodChannel _channel;
  int? _durationMs;

  PlatformFrameExtractor(this.videoPath, {MethodChannel? channel})
      : _channel = channel ?? _defaultChannel;

  Future<int> _duration() async =>
      _durationMs ??=
          (await _channel.invokeMethod<int>('getDuration', {'path': videoPath})) ??
              0;

  @override
  Future<List<int>> sampleTimestamps({int fps = 5}) async {
    final durationMs = await _duration();
    final step = (1000 / fps).round();
    final out = <int>[];
    for (var t = 0; t < durationMs; t += step) {
      out.add(t);
    }
    return out;
  }

  /// Fetches one frame as PNG bytes. [maxWidth] == 0 means full resolution.
  Future<Uint8List> _frame(int timestampMs, int maxWidth) async {
    final bytes = await _channel.invokeMethod<Uint8List>('extractFrame', {
      'path': videoPath,
      'timeMs': timestampMs,
      'maxWidth': maxWidth,
    });
    if (bytes == null || bytes.isEmpty) {
      throw StateError('No frame at ${timestampMs}ms');
    }
    return bytes;
  }

  @override
  Future<Uint8List> thumbnailAt(int timestampMs, {int maxWidth = 240}) =>
      _frame(timestampMs, maxWidth);

  @override
  Future<Uint8List> fullFrameAt(int timestampMs) => _frame(timestampMs, 0);

  /// Width used when decoding frames purely for feature scoring. Smaller than
  /// full-res keeps auto key-frame detection responsive; the sharpness/diff
  /// thresholds in [FrameSelector] are relative, so the downscale is fine.
  static const int _featureWidth = 480;

  @override
  Future<FrameFeature> featureAt(int timestampMs,
      {int? previousTimestampMs}) async {
    final bytes = await _frame(timestampMs, _featureWidth);
    final prevBytes = previousTimestampMs == null
        ? null
        : await _frame(previousTimestampMs, _featureWidth);
    return computeFrameFeature(
        timestampMs: timestampMs, framePng: bytes, prevFramePng: prevBytes);
  }

  @override
  void dispose() {}
}

/// Computes the sharpness (variance-of-Laplacian) and scene-change (diff from
/// the previous frame) features from already-decoded PNG bytes. Kept separate
/// from [FrameExtractor] so auto key-frame detection can score the *cached
/// timeline thumbnails* directly (no extra video decode). Uses OpenCV
/// `imgproc` only, which works in opencv_dart 2.x.
FrameFeature computeFrameFeature({
  required int timestampMs,
  required Uint8List framePng,
  Uint8List? prevFramePng,
}) {
  final mats = <cv.Mat>[];
  cv.Mat track(cv.Mat m) {
    mats.add(m);
    return m;
  }

  try {
    final mat = track(cv.imdecode(framePng, cv.IMREAD_COLOR));
    final gray = track(cv.cvtColor(mat, cv.COLOR_BGR2GRAY));
    final lap = track(cv.laplacian(gray, cv.MatType.CV_64F));
    final (_, stddev) = cv.meanStdDev(lap);
    final variance = stddev.val1 * stddev.val1;

    double diff = 1.0;
    if (prevFramePng != null) {
      final prev = track(cv.imdecode(prevFramePng, cv.IMREAD_COLOR));
      final prevGray = track(cv.cvtColor(prev, cv.COLOR_BGR2GRAY));
      final small = track(cv.resize(gray, (64, 64)));
      final prevSmall = track(cv.resize(prevGray, (64, 64)));
      final delta = track(cv.absDiff(small, prevSmall));
      diff = cv.mean(delta).val1 / 255.0;
    }
    return FrameFeature(
        timestampMs: timestampMs, sharpness: variance, diffFromPrev: diff);
  } finally {
    for (final m in mats) {
      m.dispose();
    }
  }
}
