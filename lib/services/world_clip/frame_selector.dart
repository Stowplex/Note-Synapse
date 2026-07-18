/// [FrameFeature.shiftConfidence] at or above this means the frame's
/// (dx, dy) viewport shift is trusted; below it the shift is unknown (the
/// content was replaced too abruptly to track — a page flip, a chapter jump,
/// or motion too fast for the estimator).
const double kShiftKnown = 0.5;

/// Per-frame metrics used to suggest key frames.
class FrameFeature {
  final int timestampMs;

  /// Variance-of-Laplacian; higher = sharper.
  final double sharpness;

  /// Normalized difference (0..1) from the *previous sampled* frame; this is
  /// the inter-frame motion signal — high during a page turn / camera move,
  /// near-zero while holding steady on a page.
  final double diffFromPrev;

  /// Viewport translation since the previous sampled frame, in fractions of
  /// the usable frame width/height (1.0 = one full screen). Positive dy =
  /// the viewport moved DOWN the content (a downward scroll); positive dx =
  /// the viewport panned right. Only meaningful when [shiftConfidence] >=
  /// [kShiftKnown].
  final double dx;
  final double dy;

  /// Confidence of (dx, dy) — see [kShiftKnown]. Defaults to 0 (unknown) so
  /// pre-existing flip-mode callers that never estimate shifts are unaffected.
  final double shiftConfidence;

  const FrameFeature({
    required this.timestampMs,
    required this.sharpness,
    required this.diffFromPrev,
    this.dx = 0,
    this.dy = 0,
    this.shiftConfidence = 0,
  });

  bool get shiftKnown => shiftConfidence >= kShiftKnown;
}

/// Suggests key-frame timestamps for a video that pans/flips across pages.
///
/// Model: the clip is a sequence of *stable holds* (the camera resting on a
/// page) separated by *transitions* (a page turn or camera move). We want one
/// keyframe per held page — the sharpest, fully-settled frame.
///
/// Algorithm (shot-segmentation + sharpest-per-segment, a standard robust
/// technique): walk the frames splitting them into stable segments wherever the
/// inter-frame motion ([FrameFeature.diffFromPrev]) spikes above an *adaptive*
/// threshold (a multiple of the median motion, so it self-tunes to how steady
/// the camera is). Each segment held for at least [minStableFrames] samples
/// yields its sharpest frame as a keyframe. Transition frames form tiny,
/// high-motion segments and are dropped. Suggestions seed the timeline — the
/// user adds/removes freely on top.
class FrameSelector {
  /// Absolute floor for the motion threshold, so a rock-steady camera (tiny
  /// median motion) doesn't treat every micro-jitter as a page change.
  final double minMotion;

  /// Motion threshold = max(minMotion, median-motion × motionFactor). A page
  /// turn is an outlier well above the steady-state jitter.
  final double motionFactor;

  /// A stable segment must span at least this many samples to count as a
  /// deliberate page (filters momentary stops mid-flip).
  final int minStableFrames;

  /// Segments whose sharpest frame is below this are dropped (e.g. a blank or
  /// fully-blurred hold). Kept low — segmentation already excludes motion blur.
  final double sharpnessFloor;

  /// Minimum spacing between accepted keyframes.
  final int minGapMs;

  const FrameSelector({
    this.minMotion = 0.04,
    this.motionFactor = 2.5,
    this.minStableFrames = 2,
    this.sharpnessFloor = 0,
    this.minGapMs = 400,
  });

  List<int> suggest(List<FrameFeature> frames) {
    final n = frames.length;
    if (n == 0) return [];
    if (n == 1) return [frames.first.timestampMs];

    // Adaptive motion threshold from the steady-state (median) motion.
    final motions = [for (var i = 1; i < n; i++) frames[i].diffFromPrev]
      ..sort();
    final median = motions[motions.length ~/ 2];
    final threshold = _max(minMotion, median * motionFactor);

    final picked = <int>[];
    var i = 0;
    while (i < n) {
      // Extend a stable segment while the next frame's motion stays low.
      var j = i;
      var bestIdx = i;
      while (j + 1 < n && frames[j + 1].diffFromPrev <= threshold) {
        j++;
        if (frames[j].sharpness > frames[bestIdx].sharpness) bestIdx = j;
      }
      final segmentLength = j - i + 1;
      final best = frames[bestIdx];
      if (segmentLength >= minStableFrames &&
          best.sharpness >= sharpnessFloor) {
        if (picked.isEmpty || best.timestampMs - picked.last >= minGapMs) {
          picked.add(best.timestampMs);
        }
      }
      i = j + 1;
    }
    return picked;
  }

  static double _max(double a, double b) => a > b ? a : b;
}

/// How a clip presents its content, which decides the selection strategy.
enum CaptureMode {
  /// Discrete pages: stable holds separated by abrupt content replacement
  /// (page turns). Handled by [FrameSelector]'s hold segmentation.
  pageFlip,

  /// Continuous translation: a scrolling screen recording or a camera panning
  /// over a large surface. Handled by [ScrollFrameSelector]'s coverage walk.
  scroll,
}

/// Classifies a clip as scrolling/panning vs page-flipping.
///
/// Scroll/pan capture is *trackable* motion: most moving frames carry a
/// confident (dx, dy) and their magnitudes sum to well over a screen of
/// travel. Page flips are *untrackable* motion: content is replaced abruptly,
/// so moving frames mostly have unknown shifts and confident travel stays
/// small. Both signals are required — a handheld page-flip clip with some
/// incidental camera drift has travel but a low tracked fraction, and a
/// static clip has neither.
CaptureMode detectCaptureMode(
  List<FrameFeature> frames, {
  double minTravelScreens = 1.2,
  double minTrackedFraction = 0.7,
  double displacedFloor = 0.02,
  double movingDiffFloor = 0.08,
}) {
  var travel = 0.0;
  var displaced = 0;
  var untrackedMoving = 0;
  for (var i = 1; i < frames.length; i++) {
    final f = frames[i];
    final mag = f.dx.abs() > f.dy.abs() ? f.dx.abs() : f.dy.abs();
    if (f.shiftKnown && mag > displacedFloor) {
      travel += mag;
      displaced++;
    } else if (!f.shiftKnown && f.diffFromPrev > movingDiffFloor) {
      untrackedMoving++;
    }
  }
  final moving = displaced + untrackedMoving;
  if (moving == 0) return CaptureMode.pageFlip;
  if (travel >= minTravelScreens &&
      displaced / moving >= minTrackedFraction) {
    return CaptureMode.scroll;
  }
  return CaptureMode.pageFlip;
}

/// Suggests key frames for a scroll/pan capture by walking the *cumulative
/// viewport displacement* rather than segmenting stable holds.
///
/// Every frame's position is chained from the per-frame (dx, dy) shifts, in
/// screen units. A key frame is picked when the net displacement since the
/// last pick reaches [targetCoverage] of a screen (leaving deliberate overlap
/// for continuity), preferring a *settled* frame (no instantaneous motion —
/// crisp for camera captures); if the user scrolls straight through the
/// target zone, the pick is forced before displacement can exceed
/// [hardCoverage] — the invariant that guarantees no content line is ever
/// dropped between consecutive picks. Where the shift chain breaks (a
/// chapter jump / content replacement the estimator couldn't track), both
/// sides of the break are picked so neither document's edge is lost.
/// Direction reversals cancel out in the net displacement, so scrolling back
/// and forth over the same region doesn't spray duplicate picks.
class ScrollFrameSelector {
  /// Net displacement (fraction of a screen, either axis) at which we *start
  /// wanting* the next key frame — i.e. ~25% intended overlap.
  final double targetCoverage;

  /// Net displacement we must never exceed between picks. Kept below 1.0 so
  /// even estimator noise can't open a gap in the captured content.
  final double hardCoverage;

  /// Instantaneous [FrameFeature.diffFromPrev] at or below which a frame
  /// counts as settled (held still — preferred as a pick).
  final double settledDiff;

  /// Trailing displacement since the last pick that still warrants a final
  /// pick at the end of the clip (don't lose the bottom of the document).
  final double minTailCoverage;

  /// Minimum new displacement for the extra pick on the *near* side of a
  /// chain break (the far side is always picked — it starts new content).
  final double minBreakCoverage;

  const ScrollFrameSelector({
    this.targetCoverage = 0.75,
    this.hardCoverage = 0.92,
    this.settledDiff = 0.02,
    this.minTailCoverage = 0.10,
    this.minBreakCoverage = 0.08,
  });

  List<int> suggest(List<FrameFeature> frames) {
    final n = frames.length;
    if (n == 0) return [];
    final picks = <int>[frames.first.timestampMs];

    // netAt[k]: position of frame k relative to the last pick, in screen
    // units; filled lazily as the walk advances and rebased on each pick, so
    // a reprocessed frame is never re-accumulated.
    var lastPick = 0;
    // Candidate window: frame indices whose coverage sits in [target, hard]
    // relative to the CURRENT lastPick.
    final window = <int>[];
    final netAt = List<_Vec?>.filled(n, null);
    netAt[0] = const _Vec(0, 0);

    double coverageOf(int idx) {
      final v = netAt[idx]!;
      final ax = v.x.abs(), ay = v.y.abs();
      return ax > ay ? ax : ay;
    }

    void rebase(int newPick) {
      final base = netAt[newPick]!;
      for (var k = newPick; k < n; k++) {
        final v = netAt[k];
        if (v != null) netAt[k] = _Vec(v.x - base.x, v.y - base.y);
      }
      lastPick = newPick;
      window.clear();
    }

    bool settled(int idx) => frames[idx].diffFromPrev <= settledDiff;

    /// Best frame of the candidate window: settled beats unsettled, then
    /// sharper beats blurrier.
    int bestOfWindow() {
      var best = window.first;
      for (final idx in window.skip(1)) {
        final s = settled(idx), bs = settled(best);
        if (s != bs) {
          if (s) best = idx;
          continue;
        }
        if (frames[idx].sharpness > frames[best].sharpness) best = idx;
      }
      return best;
    }

    var i = 1;
    while (i < n) {
      final f = frames[i];
      if (netAt[i] == null) {
        final prev = netAt[i - 1]!;
        if (f.shiftKnown) {
          netAt[i] = _Vec(prev.x + f.dx, prev.y + f.dy);
        } else if (f.diffFromPrev <= settledDiff) {
          // Unknown shift but visually static — treat as no motion.
          netAt[i] = prev;
        } else {
          // Chain break: content was replaced (or moved untrackably fast).
          // Keep the last frame of the old content if it added anything...
          if (i - 1 != lastPick && coverageOf(i - 1) >= minBreakCoverage) {
            picks.add(frames[i - 1].timestampMs);
          }
          // ...and always restart on the first frame of the new content.
          picks.add(f.timestampMs);
          netAt[i] = const _Vec(0, 0);
          lastPick = i;
          window.clear();
          i++;
          continue;
        }
      }

      final cov = coverageOf(i);
      if (cov >= hardCoverage) {
        // Must pick now. Prefer a good frame from the [target, hard] window;
        // if the coverage jumped straight past hard in one step, fall back to
        // the previous frame — unless that IS the last pick (a single step
        // beyond hard), in which case frame i itself is the best we can do.
        final pick = window.isNotEmpty
            ? bestOfWindow()
            : (i - 1 != lastPick ? i - 1 : i);
        picks.add(frames[pick].timestampMs);
        rebase(pick);
        // Frames after the pick re-run against the new baseline.
        i = pick + 1;
        continue;
      }
      if (cov >= targetCoverage) {
        if (settled(i)) {
          picks.add(f.timestampMs);
          rebase(i);
        } else {
          window.add(i);
        }
      }
      i++;
    }

    // Tail: keep the end of the document if meaningful content trails the
    // last pick. Prefer the last settled frame; fall back to the final frame.
    if (lastPick < n - 1 && coverageOf(n - 1) >= minTailCoverage) {
      var tail = n - 1;
      for (var k = n - 1; k > lastPick; k--) {
        if (netAt[k] == null) break;
        if (settled(k) && coverageOf(k) >= minTailCoverage) {
          tail = k;
          break;
        }
      }
      picks.add(frames[tail].timestampMs);
    }
    return picks;
  }
}

class _Vec {
  final double x, y;
  const _Vec(this.x, this.y);
}
