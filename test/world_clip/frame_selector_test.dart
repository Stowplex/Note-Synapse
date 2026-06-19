import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/frame_selector.dart';

/// Builds a frame list from (sharpness, motion-from-prev) pairs at 5fps.
List<FrameFeature> _frames(List<(double sharp, double motion)> rows) => [
      for (var i = 0; i < rows.length; i++)
        FrameFeature(
            timestampMs: i * 200,
            sharpness: rows[i].$1,
            diffFromPrev: rows[i].$2),
    ];

void main() {
  const selector = FrameSelector(minStableFrames: 2, minGapMs: 0);

  test('one keyframe per stable hold, sharpest frame of each', () {
    // Hold A (frames 0-2), flip (frame 3 high motion), hold B (4-6),
    // flip (7), hold C (8-9). Motion ~0.01 while holding, ~0.3 on flips.
    final frames = _frames([
      (100, 0.0), // A
      (150, 0.01), // A
      (200, 0.01), // A  <- sharpest of A
      (40, 0.30), // flip (blurry)
      (180, 0.30), // B
      (120, 0.01), // B
      (90, 0.01), // B
      (30, 0.30), // flip
      (160, 0.28), // C
      (170, 0.01), // C  <- sharpest of C
    ]);
    final picks = selector.suggest(frames);
    // Three held pages → three keyframes, each the sharpest of its hold.
    expect(picks.length, 3);
    expect(picks[0], 400); // frame 2 (sharpest of A)
    expect(picks[1], 800); // frame 4 (sharpest of B)
    expect(picks[2], 1800); // frame 9 (sharpest of C)
  });

  test('detects many distinct pages held in sequence (regression: was 1)', () {
    // 6 pages, each held 3 frames, separated by a single high-motion frame.
    final rows = <(double, double)>[];
    for (var page = 0; page < 6; page++) {
      rows.add((100.0 + page, 0.4)); // page change (motion spike)
      rows.add((150.0 + page, 0.01)); // hold
      rows.add((150.0 + page, 0.01)); // hold
    }
    final picks = selector.suggest(_frames(rows));
    expect(picks.length, 6);
  });

  test('a perfectly steady camera still splits on content changes', () {
    // Tiny jitter everywhere (median ~0.005); only real page changes spike.
    final frames = _frames([
      (100, 0.0), (120, 0.005), (130, 0.004), // page 1
      (110, 0.12), (140, 0.005), (135, 0.004), // page 2 (clean cut at idx 3)
    ]);
    final picks = selector.suggest(frames);
    expect(picks.length, 2);
  });

  test('returns empty for no frames', () {
    expect(selector.suggest(const []), isEmpty);
  });
}
