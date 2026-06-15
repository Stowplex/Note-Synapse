import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'models/mesh_grid.dart';
import 'models/norm_point.dart';

/// Auto-detects the largest document-like quadrilateral in a frame so the
/// keystone editor can seed its mesh corners. Pure OpenCV `imgproc` (works in
/// opencv_dart 2.x; only `videoio` is unavailable). Returns null when no
/// convincing quad is found.
///
/// Pipeline (robust to real-world photos): downscale → gray → blur → Canny →
/// morphological close (bridge edge gaps) → external contours. For the largest
/// contours it tries, in order: a 4-point convex `approxPolyDP` at several
/// tolerances, the same on the convex hull, then `minAreaRect` as a rotated-
/// rectangle fallback. Coordinates are returned normalized (0..1), so working
/// on a downscaled copy is exact.
MeshGrid? detectDocumentQuad(Uint8List framePng,
    {double minAreaFraction = 0.12}) {
  final src = cv.imdecode(framePng, cv.IMREAD_COLOR);
  final scratch = <cv.Mat>[];
  cv.Mat keep(cv.Mat m) {
    scratch.add(m);
    return m;
  }

  try {
    if (src.cols < 8 || src.rows < 8) return null;

    // Work on a downscaled copy for speed and stable Canny thresholds.
    const workWidth = 1024;
    cv.Mat work = src;
    if (src.cols > workWidth) {
      work = keep(cv.resize(
          src, (workWidth, (src.rows * workWidth / src.cols).round()),
          interpolation: cv.INTER_AREA));
    }
    final w = work.cols, h = work.rows;
    final minArea = w * h * minAreaFraction;

    final gray = keep(cv.cvtColor(work, cv.COLOR_BGR2GRAY));
    final blurred = keep(cv.gaussianBlur(gray, (5, 5), 0));
    final edges = keep(cv.canny(blurred, 50, 150));
    final kernel =
        keep(cv.getStructuringElement(cv.MORPH_RECT, (7, 7)));
    // Close bridges the small gaps that otherwise leave the page outline open.
    final closed = keep(cv.morphologyEx(edges, cv.MORPH_CLOSE, kernel));

    final (contours, hierarchy) =
        cv.findContours(closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
    try {
      // Sort contour indices by area, largest first.
      final indices = <int>[];
      for (var i = 0; i < contours.length; i++) {
        indices.add(i);
      }
      indices.sort((a, b) =>
          cv.contourArea(contours[b]).compareTo(cv.contourArea(contours[a])));

      for (final i in indices) {
        final contour = contours[i];
        final area = cv.contourArea(contour);
        if (area < minArea) break; // sorted desc — nothing else qualifies

        final quad = _quadFromContour(contour, area);
        if (quad == null) continue;
        final normalized = [
          for (final p in quad) NormPoint(p.$1 / w, p.$2 / h)
        ];
        final ordered = orderQuadCorners(normalized);
        if (_cornersDistinct(ordered)) {
          return MeshGrid(rows: 1, cols: 1, points: ordered);
        }
      }
      return null;
    } finally {
      contours.dispose();
      hierarchy.dispose();
    }
  } finally {
    src.dispose();
    for (final m in scratch) {
      m.dispose();
    }
  }
}

/// Extracts four corner points (in pixel coords) from a contour, trying
/// progressively looser strategies. Returns null if none yields a usable quad.
List<(double, double)>? _quadFromContour(cv.VecPoint contour, double area) {
  final peri = cv.arcLength(contour, true);

  // 1) Direct polygon approximation at a few tolerances.
  for (final eps in const [0.02, 0.03, 0.05, 0.08]) {
    final approx = cv.approxPolyDP(contour, eps * peri, true);
    try {
      if (approx.length == 4 && cv.isContourConvex(approx)) {
        return [for (var j = 0; j < 4; j++) (approx[j].x.toDouble(), approx[j].y.toDouble())];
      }
    } finally {
      approx.dispose();
    }
  }

  // 2) Approximate the convex hull (handles concave noise on the outline).
  final hullMat = cv.convexHull(contour);
  cv.VecPoint? hull;
  try {
    hull = cv.VecPoint.fromMat(hullMat);
    final hullPeri = cv.arcLength(hull, true);
    for (final eps in const [0.02, 0.04, 0.08]) {
      final approx = cv.approxPolyDP(hull, eps * hullPeri, true);
      try {
        if (approx.length == 4) {
          return [for (var j = 0; j < 4; j++) (approx[j].x.toDouble(), approx[j].y.toDouble())];
        }
      } finally {
        approx.dispose();
      }
    }
  } finally {
    hullMat.dispose();
    hull?.dispose();
  }

  // 3) Rotated bounding rectangle — accept if the contour fills most of it
  //    (i.e. the contour really is roughly rectangular, like a page).
  final rr = cv.minAreaRect(contour);
  final boxPts = rr.points;
  try {
    final pts = [
      for (var j = 0; j < boxPts.length; j++)
        (boxPts[j].x.toDouble(), boxPts[j].y.toDouble())
    ];
    if (pts.length == 4 && area / _polygonArea(pts) > 0.6) {
      return pts;
    }
  } finally {
    boxPts.dispose();
  }
  return null;
}

double _polygonArea(List<(double, double)> pts) {
  var sum = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final a = pts[i], b = pts[(i + 1) % pts.length];
    sum += a.$1 * b.$2 - b.$1 * a.$2;
  }
  return sum.abs() / 2;
}

/// True when all four corners are pairwise separated by at least [minGap]
/// (normalized), i.e. the quad hasn't collapsed onto fewer distinct points.
bool _cornersDistinct(List<NormPoint> pts, {double minGap = 0.05}) {
  for (var i = 0; i < pts.length; i++) {
    for (var j = i + 1; j < pts.length; j++) {
      final dx = pts[i].x - pts[j].x, dy = pts[i].y - pts[j].y;
      if (dx * dx + dy * dy < minGap * minGap) return false;
    }
  }
  return true;
}

/// Reorders four corner points into MeshGrid row-major order
/// (top-left, top-right, bottom-left, bottom-right) regardless of the input
/// winding, using the classic sum/diff heuristic.
List<NormPoint> orderQuadCorners(List<NormPoint> pts) {
  assert(pts.length == 4);
  NormPoint pick(double Function(NormPoint) score, {required bool max}) {
    var best = pts.first;
    var bestScore = score(best);
    for (final p in pts.skip(1)) {
      final s = score(p);
      if (max ? s > bestScore : s < bestScore) {
        best = p;
        bestScore = s;
      }
    }
    return best;
  }

  final tl = pick((p) => p.x + p.y, max: false);
  final br = pick((p) => p.x + p.y, max: true);
  final tr = pick((p) => p.x - p.y, max: true);
  final bl = pick((p) => p.x - p.y, max: false);
  return [tl, tr, bl, br];
}
