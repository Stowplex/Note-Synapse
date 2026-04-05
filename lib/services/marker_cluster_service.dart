import 'dart:math';

import 'package:flutter/rendering.dart';

import '../models/in_note_marker.dart';

enum MarkerPlacementMode { auto, single, split }

class MarkerClusterService {
  const MarkerClusterService._();

  static List<NormalizedRect> buildPlacementRects(
    List<NormalizedRect> rawRects, {
    MarkerPlacementMode mode = MarkerPlacementMode.auto,
  }) {
    final sanitized = rawRects.where(_isUsableRect).toList();
    if (sanitized.isEmpty) {
      return const [];
    }

    final clusters = _clusterRects(sanitized);
    if (clusters.isEmpty) {
      return const [];
    }

    if (mode == MarkerPlacementMode.single) {
      return [_mergeCluster(sanitized)];
    }

    return clusters.map(_mergeCluster).toList();
  }

  static bool shouldOfferSplitOverride(List<NormalizedRect> rawRects) {
    final sanitized = rawRects.where(_isUsableRect).toList();
    if (sanitized.length < 2) {
      return false;
    }
    return _clusterRects(sanitized).length > 1;
  }

  static bool _isUsableRect(NormalizedRect rect) {
    return rect.w > 0 && rect.h > 0;
  }

  static List<List<NormalizedRect>> _clusterRects(List<NormalizedRect> rects) {
    final visited = List<bool>.filled(rects.length, false);
    final clusters = <List<NormalizedRect>>[];

    for (var i = 0; i < rects.length; i++) {
      if (visited[i]) continue;
      final queue = <int>[i];
      visited[i] = true;
      final cluster = <NormalizedRect>[];

      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        final currentRect = rects[current];
        cluster.add(currentRect);

        for (var j = 0; j < rects.length; j++) {
          if (visited[j]) continue;
          if (_shouldMerge(currentRect, rects[j])) {
            visited[j] = true;
            queue.add(j);
          }
        }
      }

      clusters.add(cluster);
    }

    clusters.sort((a, b) {
      final aRect = _mergeCluster(a);
      final bRect = _mergeCluster(b);
      final yCompare = aRect.y.compareTo(bRect.y);
      if (yCompare != 0) return yCompare;
      return aRect.x.compareTo(bRect.x);
    });
    return clusters;
  }

  static bool _shouldMerge(NormalizedRect a, NormalizedRect b) {
    if (_rectsTouchOrOverlap(a, b)) {
      return true;
    }
    if (_looksLikeUnderlineContinuation(a, b)) {
      return true;
    }
    if (_looksLikeStackedUnderline(a, b)) {
      return true;
    }
    return false;
  }

  static bool _rectsTouchOrOverlap(NormalizedRect a, NormalizedRect b) {
    final rectA = Rect.fromLTWH(a.x, a.y, a.w, a.h).inflate(0.012);
    final rectB = Rect.fromLTWH(b.x, b.y, b.w, b.h).inflate(0.012);
    return rectA.overlaps(rectB) ||
        rectA.contains(rectB.topLeft) ||
        rectA.contains(rectB.bottomRight) ||
        rectB.contains(rectA.topLeft) ||
        rectB.contains(rectA.bottomRight);
  }

  static bool _looksLikeUnderlineContinuation(
    NormalizedRect a,
    NormalizedRect b,
  ) {
    if (!_isUnderlineLike(a) || !_isUnderlineLike(b)) {
      return false;
    }

    final avgHeight = (a.h + b.h) / 2;
    final centerDeltaY = _centerY(a) - _centerY(b);
    if (centerDeltaY.abs() > max(0.02, avgHeight * 2.8)) {
      return false;
    }

    final horizontalGap = _horizontalGap(a, b);
    final allowedGap = max(0.04, avgHeight * 12);
    if (horizontalGap > allowedGap) {
      return false;
    }

    return true;
  }

  static bool _looksLikeStackedUnderline(NormalizedRect a, NormalizedRect b) {
    if (!_isUnderlineLike(a) || !_isUnderlineLike(b)) {
      return false;
    }

    final verticalGap = _verticalGap(a, b);
    if (verticalGap > 0.07) {
      return false;
    }

    final horizontalOverlap = _overlapLength(a.x, a.x + a.w, b.x, b.x + b.w);
    final minWidth = min(a.w, b.w);
    if (minWidth <= 0) {
      return false;
    }

    return horizontalOverlap / minWidth >= 0.45;
  }

  static bool _isUnderlineLike(NormalizedRect rect) {
    return rect.w > rect.h * 3.5;
  }

  static double _centerY(NormalizedRect rect) => rect.y + rect.h / 2;

  static double _horizontalGap(NormalizedRect a, NormalizedRect b) {
    if (_overlapLength(a.x, a.x + a.w, b.x, b.x + b.w) > 0) {
      return 0;
    }
    if (a.x + a.w < b.x) {
      return b.x - (a.x + a.w);
    }
    return a.x - (b.x + b.w);
  }

  static double _verticalGap(NormalizedRect a, NormalizedRect b) {
    if (_overlapLength(a.y, a.y + a.h, b.y, b.y + b.h) > 0) {
      return 0;
    }
    if (a.y + a.h < b.y) {
      return b.y - (a.y + a.h);
    }
    return a.y - (b.y + b.h);
  }

  static double _overlapLength(
    double startA,
    double endA,
    double startB,
    double endB,
  ) {
    return max(0, min(endA, endB) - max(startA, startB));
  }

  static NormalizedRect _mergeCluster(List<NormalizedRect> rects) {
    var left = rects.first.x;
    var top = rects.first.y;
    var right = rects.first.x + rects.first.w;
    var bottom = rects.first.y + rects.first.h;

    for (final rect in rects.skip(1)) {
      left = min(left, rect.x);
      top = min(top, rect.y);
      right = max(right, rect.x + rect.w);
      bottom = max(bottom, rect.y + rect.h);
    }

    return NormalizedRect(x: left, y: top, w: right - left, h: bottom - top);
  }
}
