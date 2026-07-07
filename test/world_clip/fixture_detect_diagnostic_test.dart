// Diagnostic harness: drop real photos into test/world_clip/fixtures/ (or a
// top-level tmp_test/ folder) and run
//   flutter test test/world_clip/fixture_detect_diagnostic_test.dart
// For every image it prints each candidate quad (strategy, area fraction,
// border edge support, composite score) and the winner, and writes a
// `<name>_overlay.png` next to the source so detection can be eyeballed.
// Skips when no images are present.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:note_synapse/services/world_clip/edge_detector.dart';

void main() {
  final images = <File>[
    for (final dir in [Directory('test/world_clip/fixtures'), Directory('tmp_test')])
      if (dir.existsSync())
        for (final f in dir.listSync().whereType<File>())
          if (const {'.jpg', '.jpeg', '.png'}
                  .contains(p.extension(f.path).toLowerCase()) &&
              !p.basenameWithoutExtension(f.path).endsWith('_overlay') &&
              !p.basenameWithoutExtension(f.path).endsWith('_detect') &&
              !p.basenameWithoutExtension(f.path).contains('_mask'))
            f,
  ];

  if (images.isEmpty) {
    test('diagnose (skipped)', () {
      markTestSkipped('no fixture images in test/world_clip/fixtures '
          'or tmp_test');
    });
    return;
  }

  for (final file in images) {
    final name = p.basenameWithoutExtension(file.path);
    test('diagnose $name', () {
      final bytes = file.readAsBytesSync();
      final diag = DetectDiagnostics();
      final grid = detectDocumentQuad(bytes, diagnostics: diag);

      // ignore: avoid_print
      print('[$name] candidates:');
      for (final c in diag.candidates) {
        // ignore: avoid_print
        print('  $c');
      }
      // ignore: avoid_print
      print('[$name] chosen=${diag.chosen} quad=${grid?.points.map((pt) =>
          "(${pt.x.toStringAsFixed(3)},${pt.y.toStringAsFixed(3)})").toList()}');

      // Write each strategy's closed mask for visual inspection.
      for (final entry in diag.maskPngs.entries) {
        File(p.join(p.dirname(file.path), '${name}_mask_${entry.key}.png'))
            .writeAsBytesSync(entry.value);
      }

      // Draw the detected quad on a small copy so the snap can be eyeballed.
      if (grid != null) {
        final src = cv.imdecode(bytes, cv.IMREAD_COLOR);
        const outWidth = 700;
        final small = src.cols > outWidth
            ? cv.resize(src, (outWidth, (src.rows * outWidth / src.cols).round()),
                interpolation: cv.INTER_AREA)
            : src.clone();
        src.dispose();
        final w = small.cols, h = small.rows;
        final pts = grid.points
            .map((pt) => cv.Point((pt.x * w).round(), (pt.y * h).round()))
            .toList();
        // MeshGrid order is TL,TR,BL,BR; draw the closed outline TL→TR→BR→BL.
        final poly = [pts[0], pts[1], pts[3], pts[2]];
        for (var i = 0; i < 4; i++) {
          cv.line(small, poly[i], poly[(i + 1) % 4], cv.Scalar(0, 0, 255),
              thickness: 3);
        }
        for (final pt in poly) {
          cv.circle(small, pt, 8, cv.Scalar(0, 255, 0), thickness: -1);
        }
        final (_, overlayPng) = cv.imencode('.png', small);
        File(p.join(p.dirname(file.path), '${name}_overlay.png'))
            .writeAsBytesSync(overlayPng);
        small.dispose();
      }
      expect(grid, isNotNull);
    });
  }
}
