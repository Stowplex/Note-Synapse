// Diagnostic harness: drop real photos at the fixture paths below and run
//   flutter test test/world_clip/fixture_detect_diagnostic_test.dart
// It prints each pipeline stage (Otsu threshold, contour areas, the chosen
// strategy) and the detected quad, and writes a debug overlay PNG next to the
// fixture so detection can be inspected on real images. Skips when absent.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:note_synapse/services/world_clip/edge_detector.dart';

void main() {
  for (final name in const ['ereader', 'book']) {
    test('diagnose $name', () {
      final file = File('test/world_clip/fixtures/$name.png');
      if (!file.existsSync()) {
        markTestSkipped('no fixture test/world_clip/fixtures/$name.png');
        return;
      }
      final bytes = file.readAsBytesSync();

      // Replicate the pipeline stages for visibility.
      final src = cv.imdecode(bytes, cv.IMREAD_COLOR);
      // ignore: avoid_print
      print('[$name] decoded ${src.cols}x${src.rows}');
      const workWidth = 1024;
      final work = src.cols > workWidth
          ? cv.resize(src, (workWidth, (src.rows * workWidth / src.cols).round()),
              interpolation: cv.INTER_AREA)
          : src;
      final w = work.cols, h = work.rows;
      final gray = cv.cvtColor(work, cv.COLOR_BGR2GRAY);
      final blurred = cv.gaussianBlur(gray, (5, 5), 0);
      final (otsu, binary) =
          cv.threshold(blurred, 0, 255, cv.THRESH_BINARY | cv.THRESH_OTSU);
      final kernel = cv.getStructuringElement(cv.MORPH_RECT, (15, 15));
      final closed = cv.morphologyEx(binary, cv.MORPH_CLOSE, kernel);
      final (contours, hierarchy) =
          cv.findContours(closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
      var bestArea = 0.0;
      for (var i = 0; i < contours.length; i++) {
        final a = cv.contourArea(contours[i]);
        if (a > bestArea) bestArea = a;
      }
      // ignore: avoid_print
      print('[$name] work ${w}x$h otsu=$otsu contours=${contours.length} '
          'largestAreaFrac=${(bestArea / (w * h)).toStringAsFixed(3)}');

      final grid = detectDocumentQuad(bytes);
      // ignore: avoid_print
      print('[$name] detected quad = ${grid?.points.map((p) =>
          "(${p.x.toStringAsFixed(3)},${p.y.toStringAsFixed(3)})").toList()}');

      // Write a debug overlay (binary mask) for visual inspection.
      final (_, maskPng) = cv.imencode('.png', closed);
      File('test/world_clip/fixtures/${name}_mask.png')
          .writeAsBytesSync(maskPng);

      // Draw the detected quad on the work image so the snap can be eyeballed.
      if (grid != null) {
        final pts = grid.points
            .map((p) => cv.Point((p.x * w).round(), (p.y * h).round()))
            .toList();
        // Order TL,TR,BR,BL for a closed outline.
        final poly = [pts[0], pts[1], pts[3], pts[2]];
        for (var i = 0; i < 4; i++) {
          cv.line(work, poly[i], poly[(i + 1) % 4], cv.Scalar(0, 0, 255),
              thickness: 4);
        }
        for (final p in poly) {
          cv.circle(work, p, 10, cv.Scalar(0, 255, 0), thickness: -1);
        }
        final (_, overlayPng) = cv.imencode('.png', work);
        File('test/world_clip/fixtures/${name}_overlay.png')
            .writeAsBytesSync(overlayPng);
      }

      src.dispose();
      if (!identical(work, src)) work.dispose();
      gray.dispose();
      blurred.dispose();
      binary.dispose();
      kernel.dispose();
      closed.dispose();
      contours.dispose();
      hierarchy.dispose();
      expect(grid, isNotNull);
    });
  }
}
