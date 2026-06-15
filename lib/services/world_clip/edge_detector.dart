import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'models/mesh_grid.dart';
import 'models/norm_point.dart';

/// Auto-detects the largest document-like quadrilateral in a frame so the
/// keystone editor can seed its mesh corners instead of starting at the image
/// edges. Pure OpenCV `imgproc` (works in opencv_dart 2.x; only `videoio` is
/// unavailable). Returns null when no convincing quad is found.
MeshGrid? detectDocumentQuad(Uint8List framePng,
    {double minAreaFraction = 0.2}) {
  final src = cv.imdecode(framePng, cv.IMREAD_COLOR);
  cv.Mat? gray, blurred, edges;
  try {
    final w = src.cols, h = src.rows;
    if (w < 2 || h < 2) return null;

    gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
    blurred = cv.gaussianBlur(gray, (5, 5), 0);
    edges = cv.canny(blurred, 50, 150);

    final (contours, hierarchy) =
        cv.findContours(edges, cv.RETR_LIST, cv.CHAIN_APPROX_SIMPLE);
    try {
      final minArea = w * h * minAreaFraction;
      double bestArea = 0;
      List<NormPoint>? best;
      for (var i = 0; i < contours.length; i++) {
        final contour = contours[i];
        final peri = cv.arcLength(contour, true);
        final approx = cv.approxPolyDP(contour, 0.02 * peri, true);
        try {
          if (approx.length == 4) {
            final area = cv.contourArea(approx).abs();
            if (area > bestArea && area >= minArea) {
              bestArea = area;
              best = [
                for (var j = 0; j < 4; j++)
                  NormPoint(approx[j].x / w, approx[j].y / h),
              ];
            }
          }
        } finally {
          approx.dispose();
        }
      }
      if (best == null) return null;
      return MeshGrid(rows: 1, cols: 1, points: orderQuadCorners(best));
    } finally {
      contours.dispose();
      hierarchy.dispose();
    }
  } finally {
    src.dispose();
    gray?.dispose();
    blurred?.dispose();
    edges?.dispose();
  }
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
