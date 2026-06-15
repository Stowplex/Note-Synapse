/// Per-frame metrics used to suggest key frames.
class FrameFeature {
  final int timestampMs;
  /// Variance-of-Laplacian; higher = sharper.
  final double sharpness;
  /// Normalized difference from the previous frame (0..1); higher = scene change.
  final double diffFromPrev;
  const FrameFeature({
    required this.timestampMs,
    required this.sharpness,
    required this.diffFromPrev,
  });
}

/// Suggests key-frame timestamps. Suggestions are a seed for the timeline —
/// the user adds/deletes freely on top.
class FrameSelector {
  final double sharpnessThreshold;
  final double sceneChangeThreshold;
  final int minGapMs;

  const FrameSelector({
    required this.sharpnessThreshold,
    required this.sceneChangeThreshold,
    required this.minGapMs,
  });

  List<int> suggest(List<FrameFeature> frames) {
    final picked = <int>[];
    int? lastPicked;
    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      if (f.sharpness < sharpnessThreshold) continue;
      final isFirst = lastPicked == null;
      final farEnough = isFirst || (f.timestampMs - lastPicked) >= minGapMs;
      final changed = isFirst || f.diffFromPrev >= sceneChangeThreshold;
      if (farEnough && changed) {
        picked.add(f.timestampMs);
        lastPicked = f.timestampMs;
      }
    }
    return picked;
  }
}
