import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/frame_selector.dart';

/// Builds a 5fps frame list from per-frame rows of
/// (sharpness, diff, dy, confidence); dx stays 0 (vertical scroll).
List<FrameFeature> _frames(
  List<(double sharp, double diff, double dy, double conf)> rows,
) => [
  for (var i = 0; i < rows.length; i++)
    FrameFeature(
      timestampMs: i * 200,
      sharpness: rows[i].$1,
      diffFromPrev: rows[i].$2,
      dy: rows[i].$3,
      shiftConfidence: rows[i].$4,
    ),
];

(double, double, double, double) _hold({double sharp = 100}) =>
    (sharp, 0.005, 0.0, 1.0);
(double, double, double, double) _scroll(double dy, {double sharp = 80}) =>
    (sharp, 0.15, dy, 0.9);
(double, double, double, double) _jump() => (60.0, 0.5, 0.0, 0.0);

/// Continuity invariant: walking the confident shift chain, the net
/// displacement between consecutive picks never reaches a full screen (no
/// dropped lines), except across chain breaks (where both sides are picked).
void _assertContinuity(List<FrameFeature> frames, List<int> picks) {
  final pickSet = picks.toSet();
  var net = 0.0;
  var chainBroken = false;
  for (final f in frames) {
    if (f.shiftKnown) {
      net += f.dy;
    } else if (f.diffFromPrev > 0.02) {
      chainBroken = true; // break — the selector picks both sides instead
      net = 0;
    }
    if (pickSet.contains(f.timestampMs)) {
      if (!chainBroken) {
        expect(net.abs(), lessThan(1.0),
            reason: 'gap of ${net.abs()} screens before pick ${f.timestampMs}');
      }
      net = 0;
      chainBroken = false;
    }
  }
}

void main() {
  const selector = ScrollFrameSelector();

  test('monotonic stop-and-go scroll: full coverage, bounded overlap', () {
    // Scroll 0.25/frame for 3 frames, hold 2, repeat — a typical read-scroll.
    final rows = <(double, double, double, double)>[_hold()];
    for (var burst = 0; burst < 6; burst++) {
      rows.addAll([_scroll(0.25), _scroll(0.25), _scroll(0.25)]);
      rows.addAll([_hold(), _hold()]);
    }
    final frames = _frames(rows);
    final picks = selector.suggest(frames);
    _assertContinuity(frames, picks);
    // 6 bursts × 0.75 screens = 4.5 screens of travel → ~6-7 picks, far from
    // one-per-pause (which the old hold-segmentation would produce = 7 holds)
    // but critically also NOT dropping any content.
    expect(picks.first, 0);
    expect(picks.length, inInclusiveRange(5, 8));
  });

  test('small stop-and-go scrolls no longer yield one page per pause', () {
    // 12 pauses, each preceded by only 0.2 screens of scroll — the old
    // selector tags every pause (12 near-duplicates). Coverage-based picking
    // needs ~0.75 travel per pick → ~3-4 picks.
    final rows = <(double, double, double, double)>[_hold()];
    for (var p = 0; p < 12; p++) {
      rows.add(_scroll(0.2));
      rows.addAll([_hold(), _hold()]);
    }
    final frames = _frames(rows);
    final picks = selector.suggest(frames);
    _assertContinuity(frames, picks);
    expect(picks.length, inInclusiveRange(3, 5));
  });

  test('continuous never-settled scroll still picks within the hard bound',
      () {
    final rows = [
      _hold(),
      for (var i = 0; i < 30; i++) _scroll(0.15),
    ];
    final frames = _frames(rows);
    final picks = selector.suggest(frames);
    _assertContinuity(frames, picks);
    // 4.5 screens of travel / ~0.75-0.92 per pick.
    expect(picks.length, inInclusiveRange(5, 8));
  });

  test('scroll down, back up, and down again does not duplicate picks', () {
    final rows = <(double, double, double, double)>[
      _hold(),
      // Down 0.5, back up 0.5 (re-reading), down 0.5 — net 0.5 screens.
      _scroll(0.25), _scroll(0.25),
      _scroll(-0.25), _scroll(-0.25),
      _scroll(0.25), _scroll(0.25),
      _hold(),
    ];
    final frames = _frames(rows);
    final picks = selector.suggest(frames);
    // Net travel is only 0.5 screens: the initial frame plus at most a tail
    // pick — never a pick per direction change.
    expect(picks.length, lessThanOrEqualTo(2));
  });

  test('a chapter jump (chain break) keeps both sides of the break', () {
    final rows = <(double, double, double, double)>[
      _hold(),
      _scroll(0.3), _scroll(0.3), // 0.6 screens into chapter 1
      _jump(), // content replaced — untrackable
      _hold(), _scroll(0.3), _hold(),
    ];
    final frames = _frames(rows);
    final picks = selector.suggest(frames);
    // Bottom of chapter 1 (frame 2, ts 400 — 0.6 > minBreakCoverage) and top
    // of chapter 2 (frame 3, ts 600) must both survive.
    expect(picks, contains(400));
    expect(picks, contains(600));
  });

  test('trailing content below the last pick is kept (tail pick)', () {
    final rows = <(double, double, double, double)>[
      _hold(),
      for (var i = 0; i < 5; i++) _scroll(0.16), // 0.8 → triggers a pick
      _hold(),
      _scroll(0.2), _scroll(0.2), // 0.4 trailing screens
      _hold(),
    ];
    final frames = _frames(rows);
    final picks = selector.suggest(frames);
    _assertContinuity(frames, picks);
    // The final hold (last frame) carries 0.4 screens of unseen content.
    expect(picks.last, frames.last.timestampMs);
  });

  test('prefers a settled frame inside the target window', () {
    final rows = <(double, double, double, double)>[
      _hold(),
      for (var i = 0; i < 5; i++) _scroll(0.16), // reaches 0.8 while moving
      _hold(sharp: 120), // settles at 0.8 — this is the pick we want
      _scroll(0.16),
      _hold(),
    ];
    final frames = _frames(rows);
    final picks = selector.suggest(frames);
    expect(picks, contains(6 * 200)); // the settled frame at coverage 0.8
  });

  test('empty and single-frame inputs', () {
    expect(selector.suggest(const []), isEmpty);
    expect(
      selector.suggest(_frames([_hold()])),
      [0],
    );
  });

  group('detectCaptureMode', () {
    test('scrolling clip classifies as scroll', () {
      final rows = <(double, double, double, double)>[
        _hold(),
        for (var i = 0; i < 12; i++) _scroll(0.15),
        _hold(),
      ];
      expect(detectCaptureMode(_frames(rows)), CaptureMode.scroll);
    });

    test('page-flip clip (holds + untrackable spikes) stays pageFlip', () {
      final rows = <(double, double, double, double)>[
        for (var page = 0; page < 6; page++) ...[
          _jump(),
          _hold(),
          _hold(),
        ],
      ];
      expect(detectCaptureMode(_frames(rows)), CaptureMode.pageFlip);
    });

    test('static clip stays pageFlip', () {
      final rows = [for (var i = 0; i < 10; i++) _hold()];
      expect(detectCaptureMode(_frames(rows)), CaptureMode.pageFlip);
    });

    test('2D pan (bulletin board) classifies as scroll via dx', () {
      final frames = [
        for (var i = 0; i < 14; i++)
          FrameFeature(
            timestampMs: i * 200,
            sharpness: 80,
            diffFromPrev: i == 0 ? 0.005 : 0.15,
            dx: i == 0 ? 0 : 0.15 * math.cos(i / 4),
            dy: i == 0 ? 0 : 0.10,
            shiftConfidence: i == 0 ? 1.0 : 0.9,
          ),
      ];
      expect(detectCaptureMode(frames), CaptureMode.scroll);
    });
  });
}
