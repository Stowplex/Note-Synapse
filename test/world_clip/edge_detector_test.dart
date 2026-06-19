import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:note_synapse/services/world_clip/edge_detector.dart';
import 'package:note_synapse/services/world_clip/models/norm_point.dart';

Uint8List _solidPng(int w, int h) {
  final mat = cv.Mat.create(rows: h, cols: w, type: cv.MatType.CV_8UC3);
  final (_, png) = cv.imencode('.png', mat);
  mat.dispose();
  return png;
}

void main() {
  group('orderQuadCorners', () {
    test('sorts arbitrary winding into TL, TR, BL, BR', () {
      // Supplied in a scrambled order.
      final ordered = orderQuadCorners(const [
        NormPoint(0.9, 0.9), // BR
        NormPoint(0.1, 0.1), // TL
        NormPoint(0.9, 0.1), // TR
        NormPoint(0.1, 0.9), // BL
      ]);
      expect(ordered[0], const NormPoint(0.1, 0.1)); // TL
      expect(ordered[1], const NormPoint(0.9, 0.1)); // TR
      expect(ordered[2], const NormPoint(0.1, 0.9)); // BL
      expect(ordered[3], const NormPoint(0.9, 0.9)); // BR
    });
  });

  group('detectDocumentQuad', () {
    test('falls back to the full frame when no inner document is found', () {
      // A featureless frame has no distinct bright blob → snap to the edges.
      final grid = detectDocumentQuad(_solidPng(80, 60));
      expect(grid, isNotNull);
      expect(grid!.points.length, 4);
      expect(grid.points.first, const NormPoint(0, 0)); // full-frame TL
      expect(grid.points.last, const NormPoint(1, 1)); // full-frame BR
    });

    test('returns null only when the frame cannot be decoded / is tiny', () {
      expect(detectDocumentQuad(_solidPng(1, 1)), isNull);
    });

    test('detects a bright rectangular page on a dark background', () {
      // Dark canvas with a large white "page" inset from the edges.
      final mat = cv.Mat.create(rows: 400, cols: 300, type: cv.MatType.CV_8UC3);
      cv.rectangle(mat, cv.Rect(40, 60, 220, 280), cv.Scalar.all(255),
          thickness: -1); // filled
      final (_, png) = cv.imencode('.png', mat);
      mat.dispose();

      final grid = detectDocumentQuad(png);
      expect(grid, isNotNull);
      expect(grid!.points.length, 4);
      // Top-left corner near the rectangle's normalized origin (40/300, 60/400).
      final tl = grid.points.first;
      expect(tl.x, closeTo(40 / 300, 0.08));
      expect(tl.y, closeTo(60 / 400, 0.08));
    });

    test('detects a light page inset by dark margins (screenshot-like)', () {
      // Bright page filling most of the frame with a dark margin, plus dark
      // "text" rectangles inside that the close step should fill over.
      final mat = cv.Mat.create(rows: 600, cols: 400, type: cv.MatType.CV_8UC3);
      cv.rectangle(mat, cv.Rect(20, 30, 360, 540), cv.Scalar.all(235),
          thickness: -1); // page
      cv.rectangle(mat, cv.Rect(60, 90, 280, 20), cv.Scalar.all(30),
          thickness: -1); // a line of text
      cv.rectangle(mat, cv.Rect(60, 200, 250, 20), cv.Scalar.all(30),
          thickness: -1);
      final (_, png) = cv.imencode('.png', mat);
      mat.dispose();

      final grid = detectDocumentQuad(png);
      expect(grid, isNotNull);
      // Detected page should be inset from the frame (not the full-frame
      // fallback), i.e. top-left x ≈ 20/400, not 0.
      expect(grid!.points.first.x, closeTo(20 / 400, 0.1));
      expect(grid.points.first.x, greaterThan(0.01));
    });
  });
}
