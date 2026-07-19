import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'orb_matching.dart';

/// Raised when [fuseAntiGlare] can't decode any usable image at all (an empty
/// list, or the reference shot is corrupt). A bad *non-reference* shot is
/// instead silently dropped from the fusion — see [fuseAntiGlare].
class GlareFusionException implements Exception {
  GlareFusionException(this.message);
  final String message;
  @override
  String toString() => 'GlareFusionException: $message';
}

/// ORB features required in each of the reference/candidate frame before an
/// alignment is even attempted — below this a homography would be fit from
/// too few correspondences to trust.
const int kMinFeatures = 40;

/// Lowe's-ratio-filtered correspondences required before attempting RANSAC.
const int kMinGoodMatches = 15;

/// Fraction of the good matches that RANSAC must accept as inliers to the
/// fitted homography — below this, the "good" matches disagreed too much
/// about the transform to trust it (a sign the two shots don't actually
/// share enough real page content, or the matches are dominated by
/// coincidental texture rather than the page itself).
const double kMinInlierFraction = 0.35;

/// Below this fraction of the reference frame actually covered by the
/// warped candidate, the alignment is rejected — a low fraction means the
/// fitted transform maps most of the candidate outside the reference's
/// bounds, which a small, RANSAC-accepted inlier set can still produce if
/// those inliers happen to cluster in one corner.
const double kMinAlignedCoverage = 0.5;

/// Combines [shots] — photos of the same page taken from meaningfully
/// different camera POSITIONS around it (see `AntiGlareStep` — a specular
/// highlight tracks the viewing angle, which moving the camera changes far
/// more than tilting it in place does, and this also naturally varies scale
/// a little as the camera moves closer/further) — into one image with
/// glare, shadows, and any other minority-shots occluder (e.g. a hand
/// pressing the page flat that's been repositioned between shots) removed.
///
/// [shots.first] is the reference frame (the centered shot). Each other shot
/// is aligned onto it by ORB feature matching + a RANSAC-fitted homography
/// (see `_alignToReference`) — general-purpose feature matching, not
/// document-boundary detection, so it isn't thrown off by scale changes
/// (the user standing closer/further between shots) or by background
/// clutter (surrounding texture just gives ORB more to match against; a
/// non-planar background that doesn't obey the page's homography gets
/// filtered out as RANSAC outliers on its own). At each pixel, the output
/// copies the WHOLE pixel (all channels together) from whichever aligned
/// sample is the MEDOID there — the sample with the smallest total color
/// distance to the others, i.e. the one the majority agrees on. Anything a
/// minority of shots disagrees about at that spot — a highlight, a shadow,
/// a hand — loses the vote to whatever the other shots actually show
/// underneath. (With exactly 2 valid samples there's no majority to find;
/// see `_selectMedoid`.)
///
/// A shot that fails to decode or fails to align with confidence is dropped
/// rather than corrupting the result. If fewer than 2 shots end up usable,
/// [shots.first] is returned unchanged (no fusion to do). Throws
/// [GlareFusionException] only when [shots] is empty or the reference frame
/// itself can't be decoded.
Uint8List fuseAntiGlare(
  List<Uint8List> shots, {
  int maxWidth = 1600,
  int jpegQuality = 92,
}) {
  if (shots.isEmpty) {
    throw GlareFusionException('fuseAntiGlare requires at least one shot');
  }
  if (shots.length == 1) return shots.first;

  final scratch = <cv.Mat>[];
  cv.Mat keep(cv.Mat m) {
    scratch.add(m);
    return m;
  }

  try {
    final decodedRef = keep(cv.imdecode(shots.first, cv.IMREAD_COLOR));
    if (decodedRef.isEmpty) {
      throw GlareFusionException('Could not decode the reference shot');
    }
    final reference = _downscale(decodedRef, maxWidth, keep);
    final referenceMask = keep(
      cv.Mat.fromScalar(
        reference.rows,
        reference.cols,
        cv.MatType.CV_8UC1,
        cv.Scalar.all(255),
      ),
    );

    final images = <cv.Mat>[reference];
    final masks = <cv.Mat>[referenceMask];

    for (final bytes in shots.skip(1)) {
      final decoded = keep(cv.imdecode(bytes, cv.IMREAD_COLOR));
      if (decoded.isEmpty) continue; // corrupt shot — drop, don't fail the page
      final candidate = _downscale(decoded, maxWidth, keep);
      final aligned = _alignToReference(reference, candidate, keep: keep);
      if (aligned != null) {
        images.add(aligned.$1);
        masks.add(aligned.$2);
      }
    }

    if (images.length < 2) return shots.first; // nothing aligned — nothing to fuse

    final fused = keep(_selectMedoid(images, masks));
    final params = cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, jpegQuality]);
    try {
      final (_, jpg) = cv.imencode('.jpg', fused, params: params);
      return jpg;
    } finally {
      params.dispose();
    }
  } finally {
    for (final m in scratch) {
      m.dispose();
    }
  }
}

cv.Mat _downscale(cv.Mat src, int maxWidth, cv.Mat Function(cv.Mat) keep) {
  if (src.cols <= maxWidth) return src;
  return keep(
    cv.resize(
      src,
      (maxWidth, (src.rows * maxWidth / src.cols).round()),
      interpolation: cv.INTER_AREA,
    ),
  );
}

/// Aligns [candidate] onto [reference]'s pixel grid via ORB keypoint
/// matching + a RANSAC-fitted homography, then warps [candidate] through it.
/// Returns the warped candidate plus a same-shape validity mask (255 where
/// the warp actually covers real candidate pixels, 0 in the border the
/// transform leaves uncovered) — both already added to [keep]. Returns null
/// (rather than throwing) on too few features/matches, too low a RANSAC
/// inlier fraction ([kMinInlierFraction]), too little coverage
/// ([kMinAlignedCoverage]), or any native-side exception — one bad shot
/// never sinks the whole page.
(cv.Mat, cv.Mat)? _alignToReference(
  cv.Mat reference,
  cv.Mat candidate, {
  required cv.Mat Function(cv.Mat) keep,
}) {
  OrbMatches? matches;
  cv.VecPoint2f? srcPts;
  cv.VecPoint2f? dstPts;
  try {
    final refGray = keep(cv.cvtColor(reference, cv.COLOR_BGR2GRAY));
    final candGray = keep(cv.cvtColor(candidate, cv.COLOR_BGR2GRAY));

    matches = orbGoodMatches(
      candGray,
      refGray,
      nFeatures: 2000,
      minKeypoints: kMinFeatures,
    );
    if (matches == null) return null;
    final good = matches.good;
    if (good.length < kMinGoodMatches) return null;

    final candKp = matches.queryKeypoints;
    final refKp = matches.trainKeypoints;
    srcPts = cv.VecPoint2f.fromList([
      for (final m in good)
        cv.Point2f(candKp[m.queryIdx].x, candKp[m.queryIdx].y),
    ]);
    dstPts = cv.VecPoint2f.fromList([
      for (final m in good) cv.Point2f(refKp[m.trainIdx].x, refKp[m.trainIdx].y),
    ]);
    // findHomography takes Mats, not point vectors directly.
    final srcMat = keep(cv.Mat.fromVec(srcPts));
    final dstMat = keep(cv.Mat.fromVec(dstPts));
    final inlierMask = keep(cv.Mat.empty());
    final h = keep(
      cv.findHomography(
        srcMat,
        dstMat,
        method: cv.RANSAC,
        ransacReprojThreshold: 5.0,
        mask: inlierMask,
      ),
    );
    if (h.isEmpty) return null;
    if (_validFraction(inlierMask) < kMinInlierFraction) return null;

    final dsize = (reference.cols, reference.rows);
    final warped = keep(cv.warpPerspective(candidate, h, dsize));
    final fullMask = keep(
      cv.Mat.fromScalar(
        candidate.rows,
        candidate.cols,
        cv.MatType.CV_8UC1,
        cv.Scalar.all(255),
      ),
    );
    final warpedMask = keep(cv.warpPerspective(fullMask, h, dsize));
    if (_validFraction(warpedMask) < kMinAlignedCoverage) return null;
    return (warped, warpedMask);
  } catch (_) {
    return null;
  } finally {
    matches?.dispose();
    srcPts?.dispose();
    dstPts?.dispose();
  }
}

/// Fraction of [mask]'s bytes that are valid (>= 128 for an 8-bit mask; a
/// RANSAC inlier mask is 0/1 per point, which the same threshold treats as
/// 1 = valid).
double _validFraction(cv.Mat mask) {
  final data = mask.data;
  if (data.isEmpty) return 0;
  var valid = 0;
  for (final v in data) {
    if (v >= 1) valid++;
  }
  return valid / data.length;
}

/// BGR luma weights matching [OpenCvFrameCorrection]'s tone/saturation math
/// in `frame_correction.dart`, reused here so "brightness" means the same
/// thing across this codebase's image pipeline.
double _luma(int b, int g, int r) => 0.114 * b + 0.587 * g + 0.299 * r;

/// At each pixel, copies the WHOLE pixel (every channel together) from
/// whichever of [images] is the MEDOID there — the valid sample with the
/// smallest total squared color distance to every other valid sample,
/// skipping entries whose [masks] byte at that pixel is invalid (< 128 —
/// the unwarped border of an aligned shot). [images.first]/[masks.first] is
/// the reference and its mask is all-255, so every pixel always has at
/// least one sample.
///
/// This is a general-purpose "vote out the minority" rule: with 3+ valid
/// samples, whichever one disagrees with the rest — a glare highlight, a
/// shadow, a hand pressing the page flat that's moved between shots — sits
/// far from the others in color space and loses, regardless of whether the
/// anomaly is brighter, darker, or just a different color. With exactly 2
/// valid samples there's no majority to find (both are equidistant from
/// each other), so this falls back to the lower-luma one — biased toward
/// suppressing glare specifically, the single most common 2-sample case
/// (anti-glare's other candidate failed to align).
///
/// Selecting a whole source pixel — rather than voting each channel
/// independently — matters because alignment is never pixel-perfect: at a
/// content edge, a 1px misalignment can put one image's dark side and
/// another's light side at the same output pixel, and per-channel voting
/// would mix them into a color that exists in NEITHER source (a visible
/// colored fringe/ghost along every edge). Copying one sample's full pixel
/// can't produce a color that wasn't actually photographed.
cv.Mat _selectMedoid(List<cv.Mat> images, List<cv.Mat> masks) {
  final w = images.first.cols, h = images.first.rows;
  final channels = images.first.channels;
  final out = cv.Mat.zeros(h, w, images.first.type);
  final outData = out.data;
  final imgData = [for (final m in images) m.data];
  final maskData = [for (final m in masks) m.data];
  final n = images.length;
  final validSamples = List<int>.filled(n, 0);
  final pixelCount = w * h;
  for (var pix = 0; pix < pixelCount; pix++) {
    final base = pix * channels;
    var count = 0;
    for (var k = 0; k < n; k++) {
      if (maskData[k][pix] >= 128) validSamples[count++] = k;
    }

    late final Uint8List chosen;
    if (count <= 1) {
      chosen = imgData[count == 1 ? validSamples[0] : 0];
    } else if (count == 2) {
      final a = imgData[validSamples[0]], b = imgData[validSamples[1]];
      final lumaA = _luma(a[base], a[base + 1], a[base + 2]);
      final lumaB = _luma(b[base], b[base + 1], b[base + 2]);
      chosen = lumaA <= lumaB ? a : b;
    } else {
      var bestCost = double.infinity;
      var bestData = imgData[validSamples[0]];
      for (var i = 0; i < count; i++) {
        final di = imgData[validSamples[i]];
        final bi = di[base], gi = di[base + 1], ri = di[base + 2];
        var cost = 0.0;
        for (var j = 0; j < count; j++) {
          if (j == i) continue;
          final dj = imgData[validSamples[j]];
          final db = bi - dj[base], dg = gi - dj[base + 1], dr = ri - dj[base + 2];
          cost += (db * db + dg * dg + dr * dr).toDouble();
        }
        if (cost < bestCost) {
          bestCost = cost;
          bestData = di;
        }
      }
      chosen = bestData;
    }
    for (var c = 0; c < channels; c++) {
      outData[base + c] = chosen[base + c];
    }
  }
  return out;
}
