import 'dart:math' as math;
import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'models/correction.dart';
import 'models/mesh_grid.dart';

/// Applies an ordered list of [Correction]s to a source frame, returning the
/// corrected image bytes. When [maxWidth] is set and the result is wider it is
/// downscaled (bounds memory). When [jpegQuality] is set the output is JPEG at
/// that quality (1–100) instead of PNG — video frames are photographic with no
/// alpha, so JPEG is far smaller; otherwise PNG (lossless) is returned.
abstract class FrameCorrection {
  Future<Uint8List> apply(Uint8List sourcePng, List<Correction> corrections,
      {int? maxWidth, int? jpegQuality});
}

class OpenCvFrameCorrection implements FrameCorrection {
  @override
  Future<Uint8List> apply(Uint8List sourcePng, List<Correction> corrections,
      {int? maxWidth, int? jpegQuality}) async {
    var mat = cv.imdecode(sourcePng, cv.IMREAD_COLOR);
    try {
      if (mat.isEmpty) {
        // Undecodable input (corrupt / unsupported codec) — don't feed an
        // empty Mat into the ops below.
        throw StateError('Could not decode source image');
      }
      for (final c in corrections) {
        final next = switch (c) {
          CropCorrection() => _crop(mat, c),
          RotateCorrection() => _rotate(mat, c),
          MeshDewarpCorrection() => _meshDewarp(mat, c.grid),
          ColorAdjustCorrection() => _colorAdjust(mat, c),
        };
        if (!identical(next, mat)) mat.dispose();
        mat = next;
      }
      // Cap output resolution (cheap OpenCV resize on the decoded Mat — avoids
      // holding/encoding full-res pages, the source of the many-image OOM).
      if (maxWidth != null && mat.cols > maxWidth) {
        final scaled = cv.resize(
            mat, (maxWidth, (mat.rows * maxWidth / mat.cols).round()),
            interpolation: cv.INTER_AREA);
        mat.dispose();
        mat = scaled;
      }
      if (jpegQuality != null) {
        final params =
            cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, jpegQuality]);
        try {
          final (_, jpg) = cv.imencode('.jpg', mat, params: params);
          return jpg;
        } finally {
          params.dispose();
        }
      }
      final (_, png) = cv.imencode('.png', mat);
      return png;
    } finally {
      // Guarantees the accumulator is freed even if a correction throws
      // (OpenCV Mats are not GC-managed); callers handle the rethrow.
      mat.dispose();
    }
  }

  cv.Mat _crop(cv.Mat src, CropCorrection c) {
    final view = src.region(_safeRect(
      (c.x * src.cols).round(),
      (c.y * src.rows).round(),
      (c.width * src.cols).round(),
      (c.height * src.rows).round(),
      src.cols,
      src.rows,
    ));
    final out = view.clone();
    view.dispose(); // region() returns a header view that must be freed.
    return out;
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

  /// Applies the contrast/saturation/temperature affine color transform via
  /// cv.transform with a 3x4 matrix (the implicit 4th input component is 1,
  /// so the last column is the additive offset). The shared RGB matrix from
  /// the model is reordered here for OpenCV's BGR channel layout; results are
  /// saturate-cast back to 8-bit by OpenCV.
  cv.Mat _colorAdjust(cv.Mat src, ColorAdjustCorrection c) {
    if (c.isNeutral) return src;
    final rgb = c.rgbMatrix(); // row-major 3x4 over (R, G, B, 1)
    // BGR reorder: output row i takes RGB row (2-i); input col j maps to RGB
    // col (2-j); the offset column stays in place.
    final bgr = List<double>.filled(12, 0);
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        bgr[i * 4 + j] = rgb[(2 - i) * 4 + (2 - j)];
      }
      bgr[i * 4 + 3] = rgb[(2 - i) * 4 + 3];
    }
    final m = cv.Mat.fromList(3, 4, cv.MatType.CV_32FC1, bgr);
    try {
      return cv.transform(src, m);
    } finally {
      m.dispose();
    }
  }

  cv.Mat _rotate(cv.Mat src, RotateCorrection c) {
    final w = src.cols, h = src.rows;
    final center = cv.Point2f(w / 2, h / 2);
    final m = cv.getRotationMatrix2D(center, -c.degrees, 1.0);
    // Expand the output canvas to fit the rotated content so a 90°/arbitrary
    // rotation doesn't clip the corners (the default dsize would crop).
    final rad = c.degrees * math.pi / 180.0;
    final cosA = math.cos(rad).abs(), sinA = math.sin(rad).abs();
    final newW = (w * cosA + h * sinA).round().clamp(1, 1 << 30);
    final newH = (w * sinA + h * cosA).round().clamp(1, 1 << 30);
    m.setNum(0, 2, m.atNum(0, 2) + (newW - w) / 2);
    m.setNum(1, 2, m.atNum(1, 2) + (newH - h) / 2);
    final out = cv.warpAffine(src, m, (newW, newH));
    m.dispose();
    return out;
  }

  /// Per-cell perspective warp: each grid cell's quad is mapped to its
  /// destination rectangle and composited into the output. A 1x1 grid is a
  /// single homography (classic keystone); subdivided grids bend at creases.
  cv.Mat _meshDewarp(cv.Mat src, MeshGrid grid) {
    final w = src.cols, h = src.rows;
    final out = cv.Mat.zeros(h, w, src.type);
    // Copies [rect] from [from] into the same region of `out`, disposing the
    // region views. Used for both the warped cell and the degenerate fallback.
    void copyRegion(cv.Mat from, cv.Rect rect) {
      final s = from.region(rect);
      final d = out.region(rect);
      try {
        s.copyTo(d);
      } finally {
        s.dispose();
        d.dispose();
      }
    }

    for (var r = 0; r < grid.rows; r++) {
      for (var c = 0; c < grid.cols; c++) {
        // Integer cell edges, shared by the destination quad and the copy
        // region so the rect always lands inside `out`/`warped` (the last
        // edge rounds to exactly w/h, avoiding an out-of-bounds region()).
        final ix0 = (c / grid.cols * w).round(), ix1 = ((c + 1) / grid.cols * w).round();
        final iy0 = (r / grid.rows * h).round(), iy1 = ((r + 1) / grid.rows * h).round();
        // Skip cells that round to zero extent (cols/rows finer than the
        // pixel grid) — a zero-area destination quad is a degenerate transform.
        if (ix1 <= ix0 || iy1 <= iy0) continue;

        final tl = grid.at(r, c), tr = grid.at(r, c + 1);
        final br = grid.at(r + 1, c + 1), bl = grid.at(r + 1, c);
        final srcPts = cv.VecPoint2f.fromList([
          cv.Point2f(tl.x * w, tl.y * h),
          cv.Point2f(tr.x * w, tr.y * h),
          cv.Point2f(br.x * w, br.y * h),
          cv.Point2f(bl.x * w, bl.y * h),
        ]);
        final dstPts = cv.VecPoint2f.fromList([
          cv.Point2f(ix0.toDouble(), iy0.toDouble()),
          cv.Point2f(ix1.toDouble(), iy0.toDouble()),
          cv.Point2f(ix1.toDouble(), iy1.toDouble()),
          cv.Point2f(ix0.toDouble(), iy1.toDouble()),
        ]);
        final cellRect = _safeRect(ix0, iy0, ix1 - ix0, iy1 - iy0, w, h);
        cv.Mat? m, warped;
        try {
          m = cv.getPerspectiveTransform2f(srcPts, dstPts);
          warped = cv.warpPerspective(src, m, (w, h));
          copyRegion(warped, cellRect);
        } catch (_) {
          // Degenerate cell transform (e.g. coincident corners). Fall back to
          // the original pixels for this cell so the page is never silently
          // blanked — a bad mesh degrades to ~identity, not black.
          try {
            copyRegion(src, cellRect);
          } catch (_) {/* last resort: leave the cell as-is */}
        } finally {
          m?.dispose();
          warped?.dispose();
          srcPts.dispose();
          dstPts.dispose();
        }
      }
    }
    return out;
  }
}
