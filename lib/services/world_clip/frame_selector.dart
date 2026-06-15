/// Per-frame metrics used to suggest key frames.
class FrameFeature {
  final int timestampMs;

  /// Variance-of-Laplacian; higher = sharper.
  final double sharpness;

  /// Normalized difference (0..1) from the *previous sampled* frame; this is
  /// the inter-frame motion signal — high during a page turn / camera move,
  /// near-zero while holding steady on a page.
  final double diffFromPrev;

  const FrameFeature({
    required this.timestampMs,
    required this.sharpness,
    required this.diffFromPrev,
  });
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
    final motions = [for (var i = 1; i < n; i++) frames[i].diffFromPrev]..sort();
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
      if (segmentLength >= minStableFrames && best.sharpness >= sharpnessFloor) {
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
