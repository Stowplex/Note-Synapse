import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/frame_selector.dart';
import 'package:note_synapse/services/world_clip/keyframe_detector.dart';

import 'scroll_document_fixture.dart';

const int kViewW = 240, kViewH = 420;

/// Piecewise-linear scroll position: breakpoints (tsMs, y), interpolated for
/// ANY timestamp — so the detector's bisection can fetch between samples
/// exactly like the real extractor decodes intermediate video frames.
double posAt(List<(int, int)> keys, int ts) {
  if (ts <= keys.first.$1) return keys.first.$2.toDouble();
  for (var i = 1; i < keys.length; i++) {
    if (ts <= keys[i].$1) {
      final (t0, y0) = keys[i - 1];
      final (t1, y1) = keys[i];
      if (t1 == t0) return y1.toDouble();
      return y0 + (y1 - y0) * (ts - t0) / (t1 - t0);
    }
  }
  return keys.last.$2.toDouble();
}

List<int> sampleTs(int durationMs) => [
  for (var t = 0; t < durationMs; t += 200) t,
];

void main() {
  test('stop-and-go scroll: full coverage, no dropped lines, no duplicates',
      () async {
    final doc = makeDocument(kViewW, 3000);
    // Hold 600ms, then 8 bursts of +300px over 600ms + 400ms hold each.
    final keys = <(int, int)>[(0, 0), (600, 0)];
    var t = 600, y = 0;
    for (var burst = 0; burst < 8; burst++) {
      t += 600;
      y += 300;
      keys.add((t, y));
      t += 400;
      keys.add((t, y));
    }
    Future<Uint8List> thumbAt(int ts) async =>
        frameAt(doc, posAt(keys, ts).round());

    final detector = KeyframeDetector(thumbAt: thumbAt);
    final result = await detector.detect(sampleTs(t));
    doc.dispose();

    expect(result, isNotNull);
    expect(result!.mode, CaptureMode.scroll);
    final positions = [for (final ts in result.timestamps) posAt(keys, ts)];
    // Continuity: consecutive pages never gap by a full viewport.
    for (var i = 1; i < positions.length; i++) {
      expect(
        (positions[i] - positions[i - 1]).abs(),
        lessThan(kViewH.toDouble()),
        reason: 'dropped lines between pages $i-1 and $i: $positions',
      );
    }
    // Coverage: first page at the top, last page shows the final content.
    expect(positions.first, lessThan(50));
    expect(positions.last, greaterThan(2400 - kViewH.toDouble()));
    // Overlap bounded: far fewer pages than the 9 holds, but enough to cover
    // 2400px of travel (>= ceil(2400/420) = 6).
    expect(result.timestamps.length, inInclusiveRange(6, 10));
  });

  test('fast fling between samples is recovered by bisection', () async {
    final doc = makeDocument(kViewW, 3000);
    // Hold, then 600px in one 200ms sample gap (untrackable at 5fps), hold.
    final keys = <(int, int)>[(0, 0), (600, 0), (800, 600), (1800, 600)];
    var midFetches = 0;
    Future<Uint8List> thumbAt(int ts) async {
      if (ts % 200 != 0) midFetches++;
      return frameAt(doc, posAt(keys, ts).round());
    }

    final detector = KeyframeDetector(thumbAt: thumbAt);
    final result = await detector.detect(sampleTs(1800));
    doc.dispose();

    expect(result, isNotNull);
    expect(midFetches, greaterThan(0), reason: 'bisection never ran');
    final positions = [for (final ts in result!.timestamps) posAt(keys, ts)];
    for (var i = 1; i < positions.length; i++) {
      expect(
        (positions[i] - positions[i - 1]).abs(),
        lessThan(kViewH.toDouble()),
        reason: 'fling dropped lines: $positions',
      );
    }
    expect(positions.last, greaterThan(600 - kViewH.toDouble()));
  });

  test('page-flip clip stays in flip mode with one pick per page', () async {
    final doc = makeDocument(kViewW, 3000);
    // Three "pages" = disjoint document regions with instant jumps.
    final keys = <(int, int)>[
      (0, 0), (999, 0),
      (1000, 1200), (1999, 1200),
      (2000, 2400), (3000, 2400),
    ];
    Future<Uint8List> thumbAt(int ts) async =>
        frameAt(doc, posAt(keys, ts).round());

    final detector = KeyframeDetector(thumbAt: thumbAt);
    final result = await detector.detect(sampleTs(3000));
    doc.dispose();

    expect(result, isNotNull);
    expect(result!.mode, CaptureMode.pageFlip);
    final positions = {
      for (final ts in result.timestamps) (posAt(keys, ts) / 100).round(),
    };
    expect(positions, {0, 12, 24}); // exactly one page per held region
  });

  test('scrolling back to the top does not duplicate the first page',
      () async {
    final doc = makeDocument(kViewW, 3000);
    // Down to 800 with pauses, back up to 0, hold.
    final keys = <(int, int)>[
      (0, 0), (600, 0),
      (1400, 400), (1800, 400),
      (2600, 800), (3200, 800),
      (4000, 0), (4800, 0),
    ];
    Future<Uint8List> thumbAt(int ts) async =>
        frameAt(doc, posAt(keys, ts).round());

    final detector = KeyframeDetector(thumbAt: thumbAt);
    final result = await detector.detect(sampleTs(4800));
    doc.dispose();

    expect(result, isNotNull);
    final topPages = [
      for (final ts in result!.timestamps)
        if (posAt(keys, ts) < 50) ts,
    ];
    expect(topPages.length, 1, reason: 'top page duplicated: $result');
  });

  test('a clip whose every frame fails to decode aborts (null), not an '
      'empty success (which would blame capture technique)', () async {
    final detector = KeyframeDetector(
      thumbAt: (ts) async => throw StateError('no frame at $ts'),
    );
    expect(await detector.detect(sampleTs(1000)), isNull);
  });

  test('abort mid-detection returns null without picks', () async {
    final doc = makeDocument(kViewW, 3000);
    var calls = 0;
    final detector = KeyframeDetector(
      thumbAt: (ts) async => frameAt(doc, 0),
      shouldAbort: () => ++calls > 3,
    );
    final result = await detector.detect(sampleTs(3000));
    doc.dispose();
    expect(result, isNull);
  });
}
