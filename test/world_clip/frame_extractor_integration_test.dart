import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:note_synapse/services/world_clip/frame_extractor.dart';

/// Writes a small multi-frame video to [path] using OpenCV's VideoWriter.
/// Returns false if the host build has no video-encode backend (FFmpeg), in
/// which case the dependent test is skipped — the on-device check (Task 1) is
/// the authoritative gate for real-device decode.
bool _writeFixture(String path) {
  const w = 64, h = 48, fps = 10.0;
  cv.VideoWriter? writer;
  try {
    writer = cv.VideoWriter.fromFile(path, 'mp4v', fps, (w, h));
    if (!writer.isOpened) return false;
    for (var i = 0; i < 20; i++) {
      // Alternating colors so consecutive frames differ (diffFromPrev > 0).
      final mat = cv.Mat.create(
          rows: h, cols: w, r: (i * 12) % 255, g: 40, b: 200 - i, type: cv.MatType.CV_8UC3);
      writer.write(mat);
      mat.dispose();
    }
    return true;
  } catch (_) {
    return false;
  } finally {
    writer?.release();
  }
}

void main() {
  test('extracts timestamps, frames, thumbnails and features from a video',
      () async {
    final tmp = await Directory.systemTemp.createTemp('wc_extractor');
    final path = '${tmp.path}/sample.mp4';
    try {
      if (!_writeFixture(path) || File(path).lengthSync() == 0) {
        markTestSkipped('host OpenCV lacks a video encode backend');
        return;
      }
      OpenCvFrameExtractor? ex;
      try {
        ex = OpenCvFrameExtractor(path);
      } on StateError {
        markTestSkipped('host OpenCV lacks a video decode backend');
        return;
      }

      final ts = await ex.sampleTimestamps(fps: 5);
      expect(ts, isNotEmpty);
      expect(ts.first, 0);

      final full = await ex.fullFrameAt(ts.first);
      expect(full.length, greaterThan(8)); // a real PNG

      final thumb = await ex.thumbnailAt(ts.first, maxWidth: 32);
      expect(thumb.length, greaterThan(8));

      final feature =
          await ex.featureAt(ts.last, previousTimestampMs: ts.first);
      expect(feature.timestampMs, ts.last);
      expect(feature.sharpness, greaterThanOrEqualTo(0));
      expect(feature.diffFromPrev, inInclusiveRange(0.0, 1.0));

      ex.dispose();
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}
