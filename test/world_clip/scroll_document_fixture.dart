import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Deterministic tall "document" texture (blocky pseudo-text), shared by the
/// frame-analyzer and keyframe-detector suites. The texture's density is
/// load-bearing — it's what makes phase correlation and ORB tracking succeed
/// deterministically — so both suites must exercise the estimators against
/// the same synthetic content.
cv.Mat makeDocument(int width, int height, {int seed = 42}) {
  final doc = cv.Mat.zeros(height, width, cv.MatType.CV_8UC1);
  final data = doc.data;
  var s = seed;
  int next() {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    return s;
  }

  for (var i = 0; i < data.length; i++) {
    data[i] = (next() % 100) < 30 ? 20 + next() % 60 : 200 + next() % 55;
  }
  return doc;
}

/// PNG of the viewport at scroll offset [y], with fixed "chrome" bars of
/// [chromeTop]/[chromeBottom] rows drawn flat (they never change).
Uint8List frameAt(
  cv.Mat doc,
  int y, {
  int w = 240,
  int h = 420,
  int chromeTop = 0,
  int chromeBottom = 0,
}) {
  final roi = doc.region(cv.Rect(0, y, w, h));
  final view = roi.clone();
  roi.dispose();
  final data = view.data;
  for (var r = 0; r < chromeTop; r++) {
    for (var c = 0; c < w; c++) {
      data[r * w + c] = 40;
    }
  }
  for (var r = h - chromeBottom; r < h; r++) {
    for (var c = 0; c < w; c++) {
      data[r * w + c] = 40;
    }
  }
  final bgr = cv.cvtColor(view, cv.COLOR_GRAY2BGR);
  view.dispose();
  final (_, png) = cv.imencode('.png', bgr);
  bgr.dispose();
  return png;
}
