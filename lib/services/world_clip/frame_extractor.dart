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
    // opencv_dart 2.x: meanStdDev returns (Scalar mean, Scalar stddev).
    final (_, stddev) = cv.meanStdDev(lap);
    final sharpness = stddev.val1;
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
