import 'dart:io';
import 'package:flutter/services.dart';

/// Decodes a source video into proxy thumbnails, full-res frames, and
/// per-frame features. The seam lets the decode backend be swapped.
abstract class FrameExtractor {
  /// Frame timestamps (ms) sampled at [fps], ascending.
  Future<List<int>> sampleTimestamps({int fps = 5});

  /// Downsampled PNG thumbnail at [timestampMs] for the timeline.
  Future<Uint8List> thumbnailAt(int timestampMs, {int maxWidth = 240});

  /// Full-resolution PNG frame at [timestampMs].
  Future<Uint8List> fullFrameAt(int timestampMs);

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

  @override
  void dispose() {}
}

/// A [FrameExtractor] backed by a fixed list of image files (the "Import
/// Pictures" path). The "timestamp" of each frame is simply its index, so the
/// review pipeline (which keys pages by frame id) works unchanged.
class PictureFrameExtractor implements FrameExtractor {
  final List<String> imagePaths;
  PictureFrameExtractor(this.imagePaths);

  @override
  Future<List<int>> sampleTimestamps({int fps = 5}) async =>
      [for (var i = 0; i < imagePaths.length; i++) i];

  @override
  Future<Uint8List> thumbnailAt(int index, {int maxWidth = 240}) =>
      fullFrameAt(index);

  @override
  Future<Uint8List> fullFrameAt(int index) {
    if (index < 0 || index >= imagePaths.length) {
      throw StateError('No image at index $index');
    }
    return File(imagePaths[index]).readAsBytes();
  }

  @override
  void dispose() {}
}
