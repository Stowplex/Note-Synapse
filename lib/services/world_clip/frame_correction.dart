import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'models/correction.dart';
import 'models/mesh_grid.dart';

/// Applies an ordered list of [Correction]s to a PNG frame, returning a PNG.
abstract class FrameCorrection {
  Future<Uint8List> apply(Uint8List sourcePng, List<Correction> corrections);
}

class OpenCvFrameCorrection implements FrameCorrection {
  @override
  Future<Uint8List> apply(
      Uint8List sourcePng, List<Correction> corrections) async {
    var mat = cv.imdecode(sourcePng, cv.IMREAD_COLOR);
    for (final c in corrections) {
      final next = switch (c) {
        CropCorrection() => _crop(mat, c),
        RotateCorrection() => _rotate(mat, c),
        MeshDewarpCorrection() => _meshDewarp(mat, c.grid),
      };
      if (!identical(next, mat)) mat.dispose();
      mat = next;
    }
    final (_, png) = cv.imencode('.png', mat);
    mat.dispose();
    return png;
  }

  cv.Mat _crop(cv.Mat src, CropCorrection c) {
    return src.region(_safeRect(
      (c.x * src.cols).round(),
      (c.y * src.rows).round(),
      (c.width * src.cols).round(),
      (c.height * src.rows).round(),
      src.cols,
      src.rows,
    )).clone();
  }

  /// Builds a Rect guaranteed to sit fully inside a [maxW]x[maxH] Mat with
  /// width/height >= 1. OpenCV's region() asserts the rect is in bounds, so
  /// normalized corrections (which can round or extend past the edge) must be
  /// clamped before use.
  static cv.Rect _safeRect(int x, int y, int w, int h, int maxW, int maxH) {
    final x0 = x.clamp(0, maxW - 1);
    final y0 = y.clamp(0, maxH - 1);
    final ww = w.clamp(1, maxW - x0);
    final hh = h.clamp(1, maxH - y0);
    return cv.Rect(x0, y0, ww, hh);
  }

  cv.Mat _rotate(cv.Mat src, RotateCorrection c) {
    final center = cv.Point2f(src.cols / 2, src.rows / 2);
    final m = cv.getRotationMatrix2D(center, -c.degrees, 1.0);
    final out = cv.warpAffine(src, m, (src.cols, src.rows));
    m.dispose();
    return out;
  }

  /// Per-cell perspective warp: each grid cell's quad is mapped to its
  /// destination rectangle and composited into the output. A 1x1 grid is a
  /// single homography (classic keystone); subdivided grids bend at creases.
  cv.Mat _meshDewarp(cv.Mat src, MeshGrid grid) {
    final w = src.cols, h = src.rows;
    final out = cv.Mat.zeros(h, w, src.type);
    int idx(int r, int c) => r * (grid.cols + 1) + c;
    for (var r = 0; r < grid.rows; r++) {
      for (var c = 0; c < grid.cols; c++) {
        final tl = grid.points[idx(r, c)];
        final tr = grid.points[idx(r, c + 1)];
        final br = grid.points[idx(r + 1, c + 1)];
        final bl = grid.points[idx(r + 1, c)];
        final srcPts = cv.VecPoint2f.fromList([
          cv.Point2f(tl.x * w, tl.y * h),
          cv.Point2f(tr.x * w, tr.y * h),
          cv.Point2f(br.x * w, br.y * h),
          cv.Point2f(bl.x * w, bl.y * h),
        ]);
        // Integer cell edges, shared by the destination quad and the copy
        // region so the rect always lands inside `out`/`warped` (the last
        // edge rounds to exactly w/h, avoiding an out-of-bounds region()).
        final ix0 = (c / grid.cols * w).round(), ix1 = ((c + 1) / grid.cols * w).round();
        final iy0 = (r / grid.rows * h).round(), iy1 = ((r + 1) / grid.rows * h).round();
        final dstPts = cv.VecPoint2f.fromList([
          cv.Point2f(ix0.toDouble(), iy0.toDouble()),
          cv.Point2f(ix1.toDouble(), iy0.toDouble()),
          cv.Point2f(ix1.toDouble(), iy1.toDouble()),
          cv.Point2f(ix0.toDouble(), iy1.toDouble()),
        ]);
        final m = cv.getPerspectiveTransform2f(srcPts, dstPts);
        final warped = cv.warpPerspective(src, m, (w, h));
        // Copy the destination cell region from `warped` into `out`.
        final cellRect = _safeRect(ix0, iy0, ix1 - ix0, iy1 - iy0, w, h);
        final cellSrc = warped.region(cellRect);
        final cellDst = out.region(cellRect);
        cellSrc.copyTo(cellDst);
        m.dispose();
        warped.dispose();
        cellSrc.dispose();
        cellDst.dispose();
        srcPts.dispose();
        dstPts.dispose();
      }
    }
    return out;
  }
}
