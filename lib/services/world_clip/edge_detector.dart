import 'dart:math' as math;
import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'models/mesh_grid.dart';
import 'models/norm_point.dart';

/// A full-frame quad (the four image corners) — used when the document fills
/// the frame (e.g. a screenshot / full-page capture) or no inner doc is found.
MeshGrid fullFrameQuad() => MeshGrid.identity(rows: 1, cols: 1);

/// One scored candidate quad, exposed for the fixture diagnostic harness.
class QuadCandidate {
  final String strategy;
  final List<(double, double)> quadPx; // perimeter order, work-image pixels
  final double areaFraction;
  final double edgeScore; // mean border gradient support (0..255)
  final double score; // composite used for ranking
  final String? rejected; // non-null: why this candidate was discarded
  QuadCandidate({
    required this.strategy,
    required this.quadPx,
    required this.areaFraction,
    required this.edgeScore,
    required this.score,
    this.rejected,
  });

  @override
  String toString() =>
      '$strategy area=${areaFraction.toStringAsFixed(2)} '
      'edge=${edgeScore.toStringAsFixed(1)} score=${score.toStringAsFixed(1)}'
      '${rejected == null ? '' : ' REJECTED($rejected)'}'
      ' quad=${quadPx.map((p) => '(${p.$1.round()},${p.$2.round()})').join()}';
}

/// Collects per-candidate details when passed to [detectDocumentQuad] —
/// used by the fixture diagnostic test to tune detection on real photos.
class DetectDiagnostics {
  final List<QuadCandidate> candidates = []; // includes rejected ones
  final Map<String, Uint8List> maskPngs = {}; // strategy → closed mask
  String chosen = 'fullFrame';
}

/// Auto-detects the document quadrilateral in a frame so the keystone editor
/// can seed its mesh corners. Pure OpenCV `imgproc` (works in opencv_dart 2.x;
/// only `videoio` is unavailable).
///
/// Strategy: several independent segmentations propose candidate quads —
/// 1. *Brightness levels*: Otsu threshold plus stricter cuts above it (a
///    bright page often shares Otsu's bright class with sky / dry ground).
/// 2. *Dark levels*: the inverted split, a deep-dark cut, and the mid-dark
///    band between them (a dark sign on a bright counter in front of an even
///    darker backdrop lives only in the band).
/// 3. *Edge outline*: a low-threshold gradient mask traces the physical page
///    border, which survives even when page and background have similar
///    brightness (e.g. a white book on a white table).
/// 4. *Low saturation*: paper/print is desaturated, so the saturation channel
///    separates a page from colorful surroundings (foliage, wood) that share
///    its brightness.
/// Blob masks additionally pass through an erosion ladder that severs thin
/// bridges to background clutter (quads are re-expanded afterwards), and the
/// top few contours of every variant become candidates — the document is not
/// always the largest blob. Implausible quads are discarded (near-full-frame,
/// mostly frame-boundary, sliver-thin, collapsed); the rest are ranked by
/// border gradient support × blob fill × a mild size preference. With no
/// convincing candidate the full frame is returned so a frame-filling
/// document still snaps to the edges. Returns null only when the frame can't
/// be decoded.
MeshGrid? detectDocumentQuad(Uint8List framePng,
    {double minAreaFraction = 0.10, DetectDiagnostics? diagnostics}) {
  final src = cv.imdecode(framePng, cv.IMREAD_COLOR);
  final scratch = <cv.Mat>[];
  cv.Mat keep(cv.Mat m) {
    scratch.add(m);
    return m;
  }

  try {
    if (src.isEmpty || src.cols < 8 || src.rows < 8) return null;

    // Work at a fixed width — downscale for speed, but also upscale small
    // frames so kernel sizes, sample offsets, and gradient scales are always
    // relative to the same geometry (detection must not change with source
    // resolution).
    const workWidth = 1024;
    cv.Mat work = src;
    if (src.cols != workWidth) {
      work = keep(cv.resize(
          src, (workWidth, (src.rows * workWidth / src.cols).round()),
          interpolation:
              src.cols > workWidth ? cv.INTER_AREA : cv.INTER_LINEAR));
    }
    final w = work.cols, h = work.rows;
    final frameArea = (w * h).toDouble();

    final gray = keep(cv.cvtColor(work, cv.COLOR_BGR2GRAY));
    final blurred = keep(cv.gaussianBlur(gray, (5, 5), 0));
    // Gradient magnitude (|dx|/2 + |dy|/2, 8-bit) used to score how much real
    // edge support each candidate quad's border has.
    final gradX = keep(cv.sobel(blurred, cv.MatType.CV_16S, 1, 0));
    final gradY = keep(cv.sobel(blurred, cv.MatType.CV_16S, 0, 1));
    final absX = keep(cv.convertScaleAbs(gradX));
    final absY = keep(cv.convertScaleAbs(gradY));
    final gradMag = keep(cv.addWeighted(absX, 0.5, absY, 0.5, 0));
    // Grayscale dilation = local max: candidate borders sit a few pixels off
    // the true edge (mask dilation, hull rounding), so score against the
    // strongest gradient within a small window instead of the exact pixel.
    final scoreKernel = keep(cv.getStructuringElement(cv.MORPH_RECT, (7, 7)));
    final gradScore = keep(cv.dilate(gradMag, scoreKernel));

    // Small close: heals pinholes/speckle without bridging the (often thin)
    // dark seam that separates a document from adjacent bright background —
    // a large kernel here merged page + table into one frame-sized blob.
    final closeKernel = keep(cv.getStructuringElement(cv.MORPH_RECT, (5, 5)));
    // Erosion ladder: breaks thin bridges between the document blob and
    // clutter that shares its mask, and — unlike a morphological open, which
    // dilates the cut arms right back on — drops the disconnected clutter
    // entirely. Extracted quads are re-expanded by the erosion radius along
    // their edge normals, so the seeded corners still sit on the document
    // edge. Two strengths, because bridge width varies; each level yields its
    // own candidates and scoring picks. Blob masks only — erosion would erase
    // the edge strategy's thin outline loop.
    final erodeLadder = [
      (keep(cv.getStructuringElement(cv.MORPH_RECT, (9, 9))), 4.0),
      (keep(cv.getStructuringElement(cv.MORPH_RECT, (21, 21))), 10.0),
      (keep(cv.getStructuringElement(cv.MORPH_RECT, (31, 31))), 15.0),
    ];

    final masks = <(String, cv.Mat, bool)>[]; // (name, mask, erodeLadder)

    // Strategies 1+2: Otsu bright / dark blobs, plus stricter bright levels —
    // Otsu's single split often lumps a bright page together with bright
    // surroundings (dry ground, sky); a higher cut can separate them.
    final (otsuThresh, bright) =
        cv.threshold(blurred, 0, 255, cv.THRESH_BINARY | cv.THRESH_OTSU);
    masks.add(('bright', keep(bright), true));
    for (final (label, f) in [('bright2', 1 / 3), ('bright3', 3 / 5)]) {
      final t = otsuThresh + (255 - otsuThresh) * f;
      final (_, m) = cv.threshold(blurred, t, 255, cv.THRESH_BINARY);
      masks.add((label, keep(m), true));
    }
    final (_, dark) =
        cv.threshold(blurred, 0, 255, cv.THRESH_BINARY_INV | cv.THRESH_OTSU);
    masks.add(('dark', keep(dark), true));
    // Mid-dark band: a dark document on a bright surface in front of an even
    // darker backdrop merges with the backdrop in the plain dark mask; the
    // band between the two cuts keeps just the document.
    final (_, deepDark) = cv.threshold(
        blurred, otsuThresh * 0.6, 255, cv.THRESH_BINARY_INV);
    keep(deepDark);
    masks.add(('dark2', deepDark, true));
    final darkBand = keep(cv.subtract(dark, deepDark));
    masks.add(('darkBand', darkBand, true));

    // Strategy 3: page outline from the gradient magnitude. A low threshold
    // keeps even a subtle page-on-bright-table boundary that Otsu lumps into
    // one bright region; dilation bridges small gaps so the outline forms a
    // loop whose external contour is the page.
    final (_, edgeMask) = cv.threshold(gradMag, 10, 255, cv.THRESH_BINARY);
    keep(edgeMask);
    final dilateKernel = keep(cv.getStructuringElement(cv.MORPH_RECT, (3, 3)));
    masks.add(
        ('edge', keep(cv.dilate(edgeMask, dilateKernel, iterations: 2)), false));

    // Strategy 4: paper/print is desaturated — the saturation channel splits a
    // page from colorful surroundings (foliage, wood grain) that match its
    // brightness. Only meaningful for color frames with saturation spread.
    final hsv = keep(cv.cvtColor(work, cv.COLOR_BGR2HSV));
    final hsvChannels = cv.split(hsv);
    try {
      final sat = keep(hsvChannels[1].clone());
      final (_, lowSat) =
          cv.threshold(sat, 0, 255, cv.THRESH_BINARY_INV | cv.THRESH_OTSU);
      masks.add(('lowSat', keep(lowSat), true));
    } finally {
      hsvChannels.dispose();
    }

    final valid = <QuadCandidate>[];
    for (final (name, mask, useLadder) in masks) {
      final closed = keep(cv.morphologyEx(mask, cv.MORPH_CLOSE, closeKernel));
      final variants = <(String, cv.Mat, double)>[
        if (!useLadder) (name, closed, 0.0),
        if (useLadder)
          for (var i = 0; i < erodeLadder.length; i++)
            ('$name/erode$i', keep(cv.erode(closed, erodeLadder[i].$1)),
                erodeLadder[i].$2),
      ];
      for (final (label, variant, expandRadius) in variants) {
        if (diagnostics != null) {
          final (_, maskPng) = cv.imencode('.png', variant);
          diagnostics.maskPngs[label.replaceAll('/', '-')] = maskPng;
        }
        for (final (rawQuad, blobArea)
            in _topBlobQuads(variant, frameArea * minAreaFraction)) {
          final quad = expandRadius == 0
              ? rawQuad
              : _expandQuad(rawQuad, expandRadius, w, h);
          final candidate = _scoreCandidate(
              label, quad, blobArea, gradScore, w, h, frameArea);
          diagnostics?.candidates.add(candidate);
          if (candidate.rejected != null) continue;
          valid.add(candidate);
        }
      }
    }

    // Among candidates close to the best score, prefer the largest: a crisp
    // inset sub-panel (an illustration box on a poster) can out-ridge the
    // full document, but the document is what the user framed.
    QuadCandidate? best;
    if (valid.isNotEmpty) {
      final top =
          valid.reduce((a, b) => a.score >= b.score ? a : b);
      best = top;
      for (final c in valid) {
        if (c.score >= top.score * 0.65 &&
            c.areaFraction > best!.areaFraction) {
          best = c;
        }
      }
    }

    // Minimum mean edge support along the border (0..255 scale). Below this
    // the "document" is a threshold artifact, so fall back to the full frame.
    const minEdgeSupport = 12.0;
    if (best != null && best.edgeScore >= minEdgeSupport) {
      final ordered = orderQuadCorners(
          [for (final p in best.quadPx) NormPoint(p.$1 / w, p.$2 / h)]);
      if (_cornersDistinct(ordered)) {
        diagnostics?.chosen = best.strategy;
        return MeshGrid(rows: 1, cols: 1, points: ordered);
      }
    }
    // No convincing inner document → assume it fills the frame.
    return fullFrameQuad();
  } finally {
    src.dispose();
    for (final m in scratch) {
      m.dispose();
    }
  }
}

/// Validates and scores one candidate quad. Implausible quads come back with
/// [QuadCandidate.rejected] set: near-full-frame (the fallback covers those),
/// sliver-thin, or with collapsed corners.
QuadCandidate _scoreCandidate(String strategy, List<(double, double)> quad,
    double blobArea, cv.Mat gradScore, int w, int h, double frameArea) {
  final quadArea = _polygonArea(quad);
  final areaFraction = quadArea / frameArea;
  final (edgeScore, boundaryFraction) = _borderGradientScore(gradScore, quad);
  // How completely the blob fills its corner quad: a document blob is itself
  // quad-shaped (fill ≈ 1); a blob dragging an arm of merged clutter, or an
  // amorphous texture region, leaves large empty wedges (fill « 1).
  final fill = (blobArea / quadArea).clamp(0.0, 1.0);
  // Larger quads win ties: a document usually dominates the frame, and inset
  // sub-regions (an illustration box on a poster) otherwise score similarly.
  // The quarter power keeps size a tiebreak, not the driver.
  final score = edgeScore * fill * math.pow(areaFraction, 0.25).toDouble();

  String? rejected;
  // Near-full-frame quads carry no information beyond the fallback and tend
  // to win by riding background texture; let the fallback handle them.
  if (areaFraction > 0.93) {
    rejected = 'nearFullFrame';
  } else if (boundaryFraction > 0.4) {
    // Mostly frame boundary, not a document outline ("frame minus a corner"
    // blobs, which run ~50%). A document cut off on ONE side loses ~25% of
    // its border and stays under this.
    rejected = 'frameBound';
  } else if (_aspectRatio(quad) > 5) {
    // Sliver quads (e.g. a treeline band) are never documents.
    rejected = 'sliver';
  } else if (_minInteriorAngleDeg(quad) < 30) {
    rejected = 'degenerateAngle';
  }
  return QuadCandidate(
    strategy: strategy,
    quadPx: quad,
    areaFraction: areaFraction,
    edgeScore: edgeScore,
    score: score,
    rejected: rejected,
  );
}

/// Expands a quad outward by [r] pixels along its edge normals — the exact
/// inverse of eroding a convex blob with a square kernel of radius [r] — and
/// clamps to the frame. Corners move by the sum of their two adjacent edges'
/// outward normals.
List<(double, double)> _expandQuad(
    List<(double, double)> quad, double r, int w, int h) {
  final cx = quad.map((p) => p.$1).reduce((a, b) => a + b) / 4;
  final cy = quad.map((p) => p.$2).reduce((a, b) => a + b) / 4;
  // Outward unit normal of edge i (quad[i] → quad[i+1]).
  final normals = <(double, double)>[];
  for (var i = 0; i < 4; i++) {
    final a = quad[i], b = quad[(i + 1) % 4];
    var nx = b.$2 - a.$2, ny = a.$1 - b.$1;
    final len = math.sqrt(nx * nx + ny * ny);
    if (len == 0) {
      normals.add((0, 0));
      continue;
    }
    nx /= len;
    ny /= len;
    // Orient away from the centroid.
    final mx = (a.$1 + b.$1) / 2 - cx, my = (a.$2 + b.$2) / 2 - cy;
    if (nx * mx + ny * my < 0) {
      nx = -nx;
      ny = -ny;
    }
    normals.add((nx, ny));
  }
  return [
    for (var i = 0; i < 4; i++)
      (
        (quad[i].$1 +
                r * (normals[i].$1 + normals[(i + 3) % 4].$1))
            .clamp(0.0, (w - 1).toDouble()),
        (quad[i].$2 +
                r * (normals[i].$2 + normals[(i + 3) % 4].$2))
            .clamp(0.0, (h - 1).toDouble()),
      )
  ];
}

/// The largest few external contours of [mask] (area >= [minArea]) as corner
/// quads with their blob areas — the document is not always the single
/// largest blob, so several candidates are surfaced per mask.
List<(List<(double, double)>, double)> _topBlobQuads(
    cv.Mat mask, double minArea,
    {int maxBlobs = 3}) {
  final (contours, hierarchy) =
      cv.findContours(mask, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
  try {
    final areas = <(int, double)>[];
    for (var i = 0; i < contours.length; i++) {
      final a = cv.contourArea(contours[i]);
      if (a >= minArea) areas.add((i, a));
    }
    areas.sort((a, b) => b.$2.compareTo(a.$2));
    final result = <(List<(double, double)>, double)>[];
    for (final (i, area) in areas.take(maxBlobs)) {
      final quad = _quadFromContour(contours[i], area);
      if (quad != null) result.add((quad, area));
    }
    return result;
  } finally {
    contours.dispose();
    hierarchy.dispose();
  }
}

/// Long-side / short-side ratio of the quad's bounding geometry, using
/// averaged opposite-edge lengths (robust to mild perspective).
double _aspectRatio(List<(double, double)> quad) {
  double d(int i, int j) {
    final dx = quad[i].$1 - quad[j].$1, dy = quad[i].$2 - quad[j].$2;
    return math.sqrt(dx * dx + dy * dy);
  }

  final a = (d(0, 1) + d(2, 3)) / 2;
  final b = (d(1, 2) + d(3, 0)) / 2;
  if (a == 0 || b == 0) return double.infinity;
  return a > b ? a / b : b / a;
}

/// Smallest interior angle of the quad in degrees (perimeter order).
double _minInteriorAngleDeg(List<(double, double)> quad) {
  var minDeg = 360.0;
  for (var i = 0; i < 4; i++) {
    final p = quad[(i + 3) % 4], q = quad[i], r = quad[(i + 1) % 4];
    final v1 = (p.$1 - q.$1, p.$2 - q.$2);
    final v2 = (r.$1 - q.$1, r.$2 - q.$2);
    final n1 = math.sqrt(v1.$1 * v1.$1 + v1.$2 * v1.$2);
    final n2 = math.sqrt(v2.$1 * v2.$1 + v2.$2 * v2.$2);
    if (n1 == 0 || n2 == 0) return 0;
    final cosA =
        ((v1.$1 * v2.$1 + v1.$2 * v2.$2) / (n1 * n2)).clamp(-1.0, 1.0);
    final deg = math.acos(cosA) * 180 / math.pi;
    if (deg < minDeg) minDeg = deg;
  }
  return minDeg;
}

/// Mean gradient *ridge* contrast sampled along the four edges of [quad]
/// (pixel coords, perimeter order), plus the fraction of samples that lie on
/// the frame boundary.
///
/// Each sample reads the gradient on the border and a few pixels to either
/// side (perpendicular): a real document border is a ridge — strong on the
/// edge, weak on the blank margins beside it — so it keeps its full value,
/// while a quad through uniformly busy texture (foliage, gravel), where the
/// off-edge samples are just as strong, nets out near zero. Frame-boundary
/// samples contribute zero — the frame edge is not evidence of a document
/// border — so a quad hugging the frame scores low, while a document merely
/// cut off on one side keeps the support of its remaining edges.
(double, double) _borderGradientScore(
    cv.Mat gradMag, List<(double, double)> quad) {
  const samplesPerEdge = 24;
  const boundaryMargin = 6;
  // Perpendicular offset for the off-edge samples: outside the 7x7 local-max
  // dilation window around the true edge, inside a typical document margin.
  const offEdge = 10.0;
  double at(double x, double y) => gradMag
      .atNum(y.round().clamp(0, gradMag.rows - 1),
          x.round().clamp(0, gradMag.cols - 1))
      .toDouble();

  var sum = 0.0;
  var n = 0;
  var boundary = 0;
  for (var i = 0; i < quad.length; i++) {
    final a = quad[i], b = quad[(i + 1) % quad.length];
    final ex = b.$1 - a.$1, ey = b.$2 - a.$2;
    final len = math.sqrt(ex * ex + ey * ey);
    // Unit perpendicular of this edge (side doesn't matter — both are used).
    final px = len == 0 ? 0.0 : -ey / len, py = len == 0 ? 0.0 : ex / len;
    for (var s = 0; s < samplesPerEdge; s++) {
      final t = (s + 0.5) / samplesPerEdge;
      final x = a.$1 + ex * t, y = a.$2 + ey * t;
      n++;
      final xi = x.round(), yi = y.round();
      if (xi < boundaryMargin ||
          yi < boundaryMargin ||
          xi >= gradMag.cols - boundaryMargin ||
          yi >= gradMag.rows - boundaryMargin) {
        boundary++;
        continue;
      }
      final onEdge = at(x, y);
      final beside = (at(x + px * offEdge, y + py * offEdge) +
              at(x - px * offEdge, y - py * offEdge)) /
          2;
      sum += math.max(0, onEdge - beside);
    }
  }
  if (n == 0) return (0, 0);
  return (sum / n, boundary / n);
}

/// Extracts four corner points (in pixel coords) from a document blob.
/// Returns null if no usable quad is found.
List<(double, double)>? _quadFromContour(cv.VecPoint contour, double area) {
  // 1) Extreme corners of the convex hull. For a page-shaped blob the four
  //    physical corners are the extremes of (x+y) and (x-y), so this snaps to
  //    the true edges (unlike approxPolyDP, which simplifies corners inward).
  final hullMat = cv.convexHull(contour);
  cv.VecPoint? hull;
  try {
    hull = cv.VecPoint.fromMat(hullMat);
    final n = hull.length;
    if (n >= 4) {
      var tl = hull[0], tr = hull[0], br = hull[0], bl = hull[0];
      var tlS = (tl.x + tl.y).toDouble(), brS = (br.x + br.y).toDouble();
      var trD = (tr.x - tr.y).toDouble(), blD = (bl.x - bl.y).toDouble();
      for (var i = 1; i < n; i++) {
        final p = hull[i];
        final s = (p.x + p.y).toDouble(), d = (p.x - p.y).toDouble();
        if (s < tlS) { tl = p; tlS = s; }
        if (s > brS) { br = p; brS = s; }
        if (d > trD) { tr = p; trD = d; }
        if (d < blD) { bl = p; blD = d; }
      }
      final quad = [
        (tl.x.toDouble(), tl.y.toDouble()),
        (tr.x.toDouble(), tr.y.toDouble()),
        (br.x.toDouble(), br.y.toDouble()),
        (bl.x.toDouble(), bl.y.toDouble()),
      ];
      // Accept only if the corner quad actually encloses the blob (it can be
      // degenerate near 45° rotation, where corners aren't diagonal extremes).
      if (_polygonArea(quad) >= area * 0.85) return quad;
    }
  } finally {
    hullMat.dispose();
    hull?.dispose();
  }

  // 2) Rotated bounding rectangle — tight enclosing quad for rotated pages
  //    where the diagonal-extreme heuristic above doesn't hold.
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
