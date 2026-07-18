import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'frame_analyzer.dart';
import 'frame_selector.dart';

/// Two picked pages whose 64×64 mean abs-diff (0..1) is below this are the
/// same content — the blurrier one is dropped. Conservative: genuinely
/// adjacent scroll pages (even with 25% overlap) differ far more than this.
const double kDuplicatePageDiff = 0.03;

/// Result of [KeyframeDetector.detect].
class KeyframeDetectionResult {
  /// Suggested key-frame timestamps, ascending. May include timestamps
  /// BETWEEN the original samples (added by bisection of fast scrolls).
  final List<int> timestamps;
  final CaptureMode mode;
  const KeyframeDetectionResult(this.timestamps, this.mode);
}

/// End-to-end auto key-frame detection over a clip's sampled thumbnails:
///
/// 1. Streams every sampled frame through [StreamingFrameAnalyzer]
///    (sharpness, inter-frame diff, 2D viewport shift, static-chrome rows).
/// 2. Bisects untracked high-motion pairs by fetching intermediate frames —
///    a fast fling can move more than the estimator's range between samples;
///    subdividing recovers the shift chain (and thereby the no-dropped-lines
///    guarantee). A pair that stays untracked at full depth is a real
///    content jump and is left as a chain break.
/// 3. Normalizes pixel shifts by the *usable* frame size (fixed chrome rows
///    excluded) and classifies the clip: scrolling/panning capture →
///    [ScrollFrameSelector] (coverage walk); page-flip capture → the
///    original [FrameSelector] (hold segmentation), unchanged.
/// 4. Prunes duplicate pages globally: any pick near-identical to an
///    already-kept pick (e.g. re-reading a section, or repeated holds on one
///    page) keeps only the sharper of the two.
class KeyframeDetector {
  /// Returns the (cached) timeline thumbnail PNG at a timestamp. Must accept
  /// arbitrary timestamps, not just the sampled ones (bisection).
  final Future<Uint8List> Function(int timestampMs) thumbAt;

  final void Function(int done, int total)? onProgress;

  /// Polled between frames; returning true abandons detection (returns null).
  final bool Function()? shouldAbort;

  /// Upper bound on extra frames fetched by the bisection pass.
  final int maxBisectionFetches;

  /// Don't subdivide a pair closer than this (≈ the decoder's meaningful
  /// frame spacing).
  final int minBisectionGapMs;

  KeyframeDetector({
    required this.thumbAt,
    this.onProgress,
    this.shouldAbort,
    this.maxBisectionFetches = 40,
    this.minBisectionGapMs = 40,
  });

  int _fetches = 0;

  Future<KeyframeDetectionResult?> detect(List<int> sampledTs) async {
    if (sampledTs.isEmpty) {
      return const KeyframeDetectionResult([], CaptureMode.pageFlip);
    }
    _fetches = 0;

    // Pass 1: stream analysis. A frame that fails to decode is skipped; the
    // next frame's shift then simply spans the gap.
    final analyzer = StreamingFrameAnalyzer();
    final frames = <AnalyzedFrame>[];
    StaticChrome chrome;
    try {
      for (var i = 0; i < sampledTs.length; i++) {
        if (shouldAbort?.call() ?? false) return null;
        try {
          final png = await thumbAt(sampledTs[i]);
          frames.add(analyzer.add(sampledTs[i], png));
        } catch (_) {
          // Decode hiccup — tolerate the gap.
        }
        onProgress?.call(i + 1, sampledTs.length);
      }
      chrome = analyzer.staticChrome();
    } finally {
      analyzer.dispose();
    }
    if (frames.isEmpty) {
      // Every sampled frame failed to decode — the source is missing or
      // corrupt, not "no pages found". Abort (null) so the caller doesn't
      // present capture-technique advice for an extraction failure.
      return null;
    }

    // Pass 2: bisect untracked high-motion pairs.
    final refined = <AnalyzedFrame>[frames.first];
    for (var i = 1; i < frames.length; i++) {
      if (shouldAbort?.call() ?? false) return null;
      final f = frames[i];
      if (!f.shiftKnown && f.diffFromPrev > kIdenticalDiff) {
        final chain = await _refine(refined.last.timestampMs, f.timestampMs, 3);
        if (chain != null) {
          refined.addAll(chain);
          continue;
        }
      }
      refined.add(f);
    }

    // Normalize pixel shifts to fractions of the USABLE frame (chrome
    // excluded): one screen of new content = usableH pixels.
    final w = refined.first.width, h = refined.first.height;
    final usableH = _clampMin(h - chrome.topRows - chrome.bottomRows, h ~/ 2);
    final usableW = _clampMin(w, 1);
    final features = [
      for (final f in refined)
        FrameFeature(
          timestampMs: f.timestampMs,
          sharpness: f.sharpness,
          diffFromPrev: f.diffFromPrev,
          dx: f.dxPx / usableW,
          dy: f.dyPx / usableH,
          shiftConfidence: f.shiftKnown ? 1.0 : 0.0,
        ),
    ];

    final mode = detectCaptureMode(features);
    final picks = mode == CaptureMode.scroll
        ? const ScrollFrameSelector().suggest(features)
        : const FrameSelector().suggest(features);

    final sharpnessAt = {for (final f in refined) f.timestampMs: f.sharpness};
    final deduped = await _pruneDuplicates(picks, sharpnessAt);
    if (deduped == null) return null; // aborted
    return KeyframeDetectionResult(deduped..sort(), mode);
  }

  static int _clampMin(int v, int floor) => v < floor ? floor : v;

  /// Recovers a confident shift chain across (tsA, tsB] by fetching the
  /// midpoint and recursing into whichever half stays untracked. Returns the
  /// intermediate frames (each with a shift relative to its predecessor,
  /// ending with tsB), or null if any sub-pair stays untracked — a genuine
  /// content jump, kept as a chain break.
  Future<List<AnalyzedFrame>?> _refine(int tsA, int tsB, int depth) async {
    if (depth <= 0 ||
        tsB - tsA < 2 * minBisectionGapMs ||
        _fetches >= maxBisectionFetches) {
      return null;
    }
    final mid = (tsA + tsB) ~/ 2;
    AnalyzedFrame midFrame, endFrame;
    try {
      final pngA = await thumbAt(tsA);
      final pngMid = await thumbAt(mid);
      final pngB = await thumbAt(tsB);
      _fetches++;
      midFrame = analyzePair(timestampMs: mid, prevPng: pngA, png: pngMid);
      endFrame = analyzePair(timestampMs: tsB, prevPng: pngMid, png: pngB);
    } catch (_) {
      return null;
    }
    final left = midFrame.shiftKnown
        ? <AnalyzedFrame>[midFrame]
        : await _refine(tsA, mid, depth - 1);
    if (left == null) return null;
    final right = endFrame.shiftKnown
        ? <AnalyzedFrame>[endFrame]
        : await _refine(mid, tsB, depth - 1);
    if (right == null) return null;
    return [...left, ...right];
  }

  /// Global duplicate-page pruning: each pick is compared (64×64 gray diff)
  /// against every already-kept pick; on a near-identical match the sharper
  /// of the two survives. Catches both flip-mode duplicate holds and
  /// scroll-mode re-reads of an earlier section.
  Future<List<int>?> _pruneDuplicates(
    List<int> picks,
    Map<int, double> sharpnessAt,
  ) async {
    if (picks.length < 2) return List.of(picks);
    final kept = <int>[];
    final mats = <int, cv.Mat>{};
    try {
      for (final ts in picks) {
        if (shouldAbort?.call() ?? false) return null;
        cv.Mat? candidate;
        try {
          candidate = _tinyGray(await thumbAt(ts));
        } catch (_) {
          kept.add(ts); // can't compare — keep rather than silently drop
          continue;
        }
        int? duplicateOf;
        for (final k in kept) {
          final other = mats[k];
          if (other == null) continue;
          final delta = cv.absDiff(candidate, other);
          final diff = cv.mean(delta).val1 / 255.0;
          delta.dispose();
          if (diff < kDuplicatePageDiff) {
            duplicateOf = k;
            break;
          }
        }
        if (duplicateOf == null) {
          kept.add(ts);
          mats[ts] = candidate;
        } else if ((sharpnessAt[ts] ?? 0) > (sharpnessAt[duplicateOf] ?? 0)) {
          // Same page, sharper take — replace the earlier pick.
          kept[kept.indexOf(duplicateOf)] = ts;
          mats.remove(duplicateOf)?.dispose();
          mats[ts] = candidate;
        } else {
          candidate.dispose();
        }
      }
      return kept;
    } finally {
      for (final m in mats.values) {
        m.dispose();
      }
    }
  }

  static cv.Mat _tinyGray(Uint8List png) {
    final mat = cv.imdecode(png, cv.IMREAD_COLOR);
    final cv.Mat gray;
    try {
      // A corrupt frame decodes to an empty Mat and cvtColor throws — the
      // caller catches and keeps the pick, but the decode must not leak.
      gray = cv.cvtColor(mat, cv.COLOR_BGR2GRAY);
    } finally {
      mat.dispose();
    }
    try {
      return cv.resize(gray, (64, 64));
    } finally {
      gray.dispose();
    }
  }
}
