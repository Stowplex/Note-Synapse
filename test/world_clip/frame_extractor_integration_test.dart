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
