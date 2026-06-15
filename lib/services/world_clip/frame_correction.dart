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
    final rect = cv.Rect(
      (c.x * src.cols).round(),
      (c.y * src.rows).round(),
      (c.width * src.cols).round(),
      (c.height * src.rows).round(),
    );
    return src.region(rect).clone();
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
        final dx0 = (c / grid.cols * w), dx1 = ((c + 1) / grid.cols * w);
        final dy0 = (r / grid.rows * h), dy1 = ((r + 1) / grid.rows * h);
        final dstPts = cv.VecPoint2f.fromList([
          cv.Point2f(dx0, dy0),
          cv.Point2f(dx1, dy0),
          cv.Point2f(dx1, dy1),
          cv.Point2f(dx0, dy1),
        ]);
        final m = cv.getPerspectiveTransform2f(srcPts, dstPts);
        final warped = cv.warpPerspective(src, m, (w, h));
        // Copy the destination cell region from `warped` into `out`.
        final cellRect = cv.Rect(
            dx0.round(), dy0.round(), (dx1 - dx0).round(), (dy1 - dy0).round());
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
