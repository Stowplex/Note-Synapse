import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'orb_matching.dart';

/// Phase-correlation response below which a shift estimate is untrusted.
/// Empirically (see `phase_correlate_probe_test.dart`): a real scroll match
/// responds ~0.5-0.9; unrelated content responds ~0.
const double kMinPhaseResponse = 0.1;

/// Inter-frame diff at or below which two frames are treated as identical
/// (shift = 0 with full confidence, skipping estimation entirely). Also the
/// analyzer's notion of "settled".
const double kIdenticalDiff = 0.015;

/// Fractions of the frame height cropped off the top/bottom before shift
/// estimation, so fixed screen chrome (status bar, app bar, nav bar) can't
/// anchor the correlation to a zero shift. The measured translation of the
/// remaining content is unaffected by the crop.
const double kShiftCropTop = 0.10;
const double kShiftCropBottom = 0.08;

/// One frame's measurements from [StreamingFrameAnalyzer]. Shifts are in
/// PIXELS at the analyzed (thumbnail) scale — the caller normalizes them to
/// screen fractions once the usable content height is known (after static
/// chrome rows have been measured across the whole clip).
class AnalyzedFrame {
  final int timestampMs;
  final double sharpness;
  final double diffFromPrev;

  /// Viewport motion since the previous fed frame: positive dyPx = scrolled
  /// down, positive dxPx = panned right (content moved the opposite way).
  final double dxPx;
  final double dyPx;

  /// True when (dxPx, dyPx) is trusted; false = the pair was untrackable.
  final bool shiftKnown;

  /// Analyzed frame dimensions (thumbnail scale).
  final int width;
  final int height;

  const AnalyzedFrame({
    required this.timestampMs,
    required this.sharpness,
    required this.diffFromPrev,
    required this.dxPx,
    required this.dyPx,
    required this.shiftKnown,
    required this.width,
    required this.height,
  });
}

/// A pairwise viewport-shift estimate (pixels, viewport convention as in
/// [AnalyzedFrame]).
class ShiftEstimate {
  final double dxPx;
  final double dyPx;
  final bool known;
  const ShiftEstimate(this.dxPx, this.dyPx, this.known);
  static const unknown = ShiftEstimate(0, 0, false);
}

/// Rows of fixed, never-changing screen chrome measured across a clip.
class StaticChrome {
  final int topRows;
  final int bottomRows;
  const StaticChrome(this.topRows, this.bottomRows);
}

/// Streaming per-frame analyzer: feed decoded PNG frames in order via [add];
/// each call returns that frame's [AnalyzedFrame] (sharpness, diff, and the
/// 2D viewport shift from the previous frame). Also accumulates per-row
/// change statistics so [staticChrome] can report fixed chrome rows at the
/// end. Holds the previous frame as a decoded gray Mat (each frame is
/// decoded exactly once). Call [dispose] when done.
class StreamingFrameAnalyzer {
  cv.Mat? _prevGray;
  Float64List? _rowChange;
  int _pairs = 0;

  /// Feeds the next frame. Frames must be same-sized (thumbnails of one
  /// video); a size mismatch yields an unknown shift for that pair.
  AnalyzedFrame add(int timestampMs, Uint8List png) {
    final mat = cv.imdecode(png, cv.IMREAD_COLOR);
    final cv.Mat gray;
    try {
      // A corrupt PNG decodes to an empty Mat and cvtColor throws — dispose
      // the decode either way rather than leaking it to the caller's catch.
      gray = cv.cvtColor(mat, cv.COLOR_BGR2GRAY);
    } finally {
      mat.dispose();
    }

    final sharpness = _varianceOfLaplacian(gray);
    var diff = 1.0;
    var shift = ShiftEstimate.unknown;
    final prev = _prevGray;
    if (prev != null && prev.cols == gray.cols && prev.rows == gray.rows) {
      diff = _accumulateDiff(prev, gray);
      if (diff <= kIdenticalDiff) {
        shift = const ShiftEstimate(0, 0, true);
      } else {
        shift = estimateShift(prev, gray);
      }
    }
    _prevGray?.dispose();
    _prevGray = gray;
    return AnalyzedFrame(
      timestampMs: timestampMs,
      sharpness: sharpness,
      diffFromPrev: diff,
      dxPx: shift.dxPx,
      dyPx: shift.dyPx,
      shiftKnown: shift.known,
      width: gray.cols,
      height: gray.rows,
    );
  }

  /// Mean |diff| (0..1) between the full frames, while also accumulating the
  /// per-row change profile used by [staticChrome].
  double _accumulateDiff(cv.Mat prev, cv.Mat gray) {
    final delta = cv.absDiff(prev, gray);
    final mean = cv.mean(delta).val1 / 255.0;
    final w = delta.cols, h = delta.rows;
    final rows = _rowChange ??= Float64List(h);
    if (rows.length == h) {
      final data = delta.data;
      for (var r = 0; r < h; r++) {
        var sum = 0;
        final base = r * w;
        for (var c = 0; c < w; c++) {
          sum += data[base + c];
        }
        rows[r] += sum / w;
      }
      _pairs++;
    }
    delta.dispose();
    return mean;
  }

  /// Contiguous top/bottom rows whose content never changed across the clip
  /// — fixed chrome (status bar, reader app bar, nav bar). A row is static
  /// when its average change is under 15% of the median row's. Returns zero
  /// rows for clips with no real motion (nothing to distinguish).
  StaticChrome staticChrome() {
    final rows = _rowChange;
    if (rows == null || _pairs == 0) return const StaticChrome(0, 0);
    final sorted = List<double>.from(rows)..sort();
    final median = sorted[sorted.length ~/ 2] / _pairs;
    if (median < 0.5) return const StaticChrome(0, 0); // effectively static clip
    final threshold = median * 0.15;
    var top = 0;
    while (top < rows.length && rows[top] / _pairs < threshold) {
      top++;
    }
    var bottom = 0;
    while (bottom < rows.length - top &&
        rows[rows.length - 1 - bottom] / _pairs < threshold) {
      bottom++;
    }
    return StaticChrome(top, bottom);
  }

  void dispose() {
    _prevGray?.dispose();
    _prevGray = null;
  }
}

/// Analyzes a standalone (prev, current) PNG pair — used by the bisection
/// pass to score frames fetched between the original samples. Equivalent to
/// feeding exactly these two frames to a fresh [StreamingFrameAnalyzer].
AnalyzedFrame analyzePair({
  required int timestampMs,
  required Uint8List prevPng,
  required Uint8List png,
}) {
  final analyzer = StreamingFrameAnalyzer();
  try {
    analyzer.add(timestampMs, prevPng);
    return analyzer.add(timestampMs, png);
  } finally {
    analyzer.dispose();
  }
}

/// Mean abs-diff (0..1) of the overlap region above which a candidate shift
/// is rejected by [_verifyShift]. A correct shift overlays near-identical
/// content (small residual from compression / slight perspective); an
/// aliased or wrong shift overlays unrelated content (~0.2+).
const double kMaxVerifyDiff = 0.12;

/// Estimates the viewport shift between two same-sized GRAY frames: phase
/// correlation first (fast, exact for screen content), ORB translation as a
/// fallback for handheld footage where rotation/perspective/lighting break
/// the correlation. Both run on the chrome-cropped region, and every
/// candidate is VERIFIED by overlaying the frames at the claimed offset —
/// phase correlation is circular, so a scroll beyond ~half the frame aliases
/// to a small bogus shift with a plausible response; only verification can
/// tell the difference. Convention: positive dyPx = viewport scrolled DOWN
/// (content moved up); positive dxPx = viewport panned right.
ShiftEstimate estimateShift(cv.Mat prevGray, cv.Mat gray) {
  final h = gray.rows;
  final top = (h * kShiftCropTop).round();
  final bottom = (h * (1 - kShiftCropBottom)).round();
  if (bottom - top < 32) return ShiftEstimate.unknown;
  final roi = cv.Rect(0, top, gray.cols, bottom - top);
  final prevRoi = prevGray.region(roi);
  final currRoi = gray.region(roi);
  final prev = prevRoi.clone();
  final curr = currRoi.clone();
  prevRoi.dispose();
  currRoi.dispose();
  try {
    var shift = _phaseShift(prev, curr);
    if (shift.known && _verifyShift(prev, curr, shift.dxPx, shift.dyPx)) {
      return shift;
    }
    shift = _orbTranslation(prev, curr);
    if (shift.known && _verifyShift(prev, curr, shift.dxPx, shift.dyPx)) {
      return shift;
    }
    return ShiftEstimate.unknown;
  } finally {
    prev.dispose();
    curr.dispose();
  }
}

/// Overlays [prev] and [curr] displaced by the candidate viewport shift and
/// accepts only if the overlapping content actually matches. Requires a
/// meaningful overlap (>= 32px each axis) so a shift claiming to share
/// almost nothing can't "verify" on a sliver.
bool _verifyShift(cv.Mat prev, cv.Mat curr, double dxPx, double dyPx) {
  final ix = dxPx.round(), iy = dyPx.round();
  final w = curr.cols, h = curr.rows;
  final ow = w - ix.abs(), oh = h - iy.abs();
  if (ow < 32 || oh < 32) return false;
  // Viewport moved (ix, iy) → the content prev shows at (x, y) sits in curr
  // at (x - ix, y - iy).
  final pRect = cv.Rect(ix > 0 ? ix : 0, iy > 0 ? iy : 0, ow, oh);
  final cRect = cv.Rect(ix > 0 ? 0 : -ix, iy > 0 ? 0 : -iy, ow, oh);
  final rp = prev.region(pRect);
  final rc = curr.region(cRect);
  final delta = cv.absDiff(rp, rc);
  final diff = cv.mean(delta).val1 / 255.0;
  rp.dispose();
  rc.dispose();
  delta.dispose();
  return diff <= kMaxVerifyDiff;
}

/// Phase-correlation candidate on already-cropped gray mats. The result is
/// a CANDIDATE only — the correlation is circular, so the caller must verify
/// it against the actual pixels ([_verifyShift]).
ShiftEstimate _phaseShift(cv.Mat prev, cv.Mat curr) {
  cv.Mat? prevF, currF;
  try {
    prevF = prev.convertTo(cv.MatType.CV_32FC1);
    currF = curr.convertTo(cv.MatType.CV_32FC1);
    final (shift, response) = cv.phaseCorrelate(prevF, currF);
    if (response < kMinPhaseResponse) return ShiftEstimate.unknown;
    // phaseCorrelate reports where curr's content sits relative to prev
    // (content moved up = negative y); viewport motion is the negation.
    return ShiftEstimate(-shift.x, -shift.y, true);
  } catch (_) {
    return ShiftEstimate.unknown;
  } finally {
    prevF?.dispose();
    currF?.dispose();
  }
}

/// ORB fallback: matches keypoints between the frames and takes the
/// consensus (median) displacement as a pure translation. Accepts only when
/// a solid majority of the Lowe-filtered matches agree with the median —
/// rotation-heavy or content-replaced pairs fail that consensus and stay
/// unknown.
ShiftEstimate _orbTranslation(cv.Mat prevGray, cv.Mat gray) {
  // orbGoodMatches degrades to null on any native failure (e.g. features2d
  // missing from the native build) rather than sinking the whole analysis.
  final matches =
      orbGoodMatches(prevGray, gray, nFeatures: 500, minKeypoints: 30);
  if (matches == null) return ShiftEstimate.unknown;
  try {
    final kpA = matches.queryKeypoints, kpB = matches.trainKeypoints;
    final dxs = <double>[], dys = <double>[];
    for (final m in matches.good) {
      // Content motion from prev->curr; viewport motion is the negation.
      dxs.add(-(kpB[m.trainIdx].x - kpA[m.queryIdx].x));
      dys.add(-(kpB[m.trainIdx].y - kpA[m.queryIdx].y));
    }
    if (dxs.length < 15) return ShiftEstimate.unknown;
    final mx = _median(dxs), my = _median(dys);
    var consensus = 0;
    for (var i = 0; i < dxs.length; i++) {
      if ((dxs[i] - mx).abs() <= 4 && (dys[i] - my).abs() <= 4) consensus++;
    }
    if (consensus / dxs.length < 0.5) return ShiftEstimate.unknown;
    return ShiftEstimate(mx, my, true);
  } catch (_) {
    return ShiftEstimate.unknown;
  } finally {
    matches.dispose();
  }
}

double _median(List<double> xs) {
  final s = List<double>.from(xs)..sort();
  return s[s.length ~/ 2];
}

double _varianceOfLaplacian(cv.Mat gray) {
  final lap = cv.laplacian(gray, cv.MatType.CV_64F);
  final (_, stddev) = cv.meanStdDev(lap);
  lap.dispose();
  return stddev.val1 * stddev.val1;
}
