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
