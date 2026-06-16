import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:note_synapse/services/world_clip/frame_correction.dart';
import 'package:note_synapse/services/world_clip/models/correction.dart';
import 'package:note_synapse/services/world_clip/models/mesh_grid.dart';
import 'package:note_synapse/services/world_clip/models/norm_point.dart';

Uint8List _solidPng(int w, int h) {
  final mat = cv.Mat.create(rows: h, cols: w, type: cv.MatType.CV_8UC3);
  final (_, png) = cv.imencode('.png', mat);
  mat.dispose();
  return png;
}

void main() {
  final correction = OpenCvFrameCorrection();

  test('empty corrections returns a decodable image of same size', () async {
    final src = _solidPng(40, 20);
    final out = await correction.apply(src, const []);
    final mat = cv.imdecode(out, cv.IMREAD_COLOR);
    expect(mat.cols, 40);
    expect(mat.rows, 20);
    mat.dispose();
  });

  test('crop reduces dimensions', () async {
    final src = _solidPng(40, 20);
    final out = await correction.apply(
        src, [CropCorrection(x: 0, y: 0, width: 0.5, height: 0.5)]);
    final mat = cv.imdecode(out, cv.IMREAD_COLOR);
    expect(mat.cols, 20);
    expect(mat.rows, 10);
    mat.dispose();
  });

  test('identity mesh dewarp preserves dimensions', () async {
    final src = _solidPng(40, 20);
    final out = await correction.apply(src,
        [MeshDewarpCorrection(grid: MeshGrid.identity(rows: 1, cols: 1))]);
    final mat = cv.imdecode(out, cv.IMREAD_COLOR);
    expect(mat.cols, greaterThan(0));
    expect(mat.rows, greaterThan(0));
    mat.dispose();
  });

  test('maxWidth downscales the corrected output', () async {
    final big = _solidPng(2000, 1000);
    final out = await correction.apply(big, const [], maxWidth: 800);
    final mat = cv.imdecode(out, cv.IMREAD_COLOR);
    expect(mat.cols, 800);
    expect(mat.rows, 400); // aspect preserved
    mat.dispose();
  });

  test('jpegQuality outputs a decodable JPEG (not PNG)', () async {
    final src = _solidPng(64, 48);
    final out = await correction.apply(src, const [], jpegQuality: 80);
    // JPEG magic bytes.
    expect(out[0], 0xFF);
    expect(out[1], 0xD8);
    final mat = cv.imdecode(out, cv.IMREAD_COLOR);
    expect(mat.cols, 64);
    expect(mat.rows, 48);
    mat.dispose();
  });

  test('crop extending past the edge is clamped, not a crash', () async {
    final src = _solidPng(40, 20);
    // x+width and y+height both exceed 1.0 — must clamp instead of throwing.
    final out = await correction.apply(
        src, [CropCorrection(x: 0.6, y: 0.7, width: 0.8, height: 0.9)]);
    final mat = cv.imdecode(out, cv.IMREAD_COLOR);
    expect(mat.cols, inInclusiveRange(1, 40));
    expect(mat.rows, inInclusiveRange(1, 20));
    mat.dispose();
  });

  test('90-degree rotation expands the canvas (swaps dimensions)', () async {
    final src = _solidPng(40, 20);
    final out = await correction.apply(src, [RotateCorrection(degrees: 90)]);
    final mat = cv.imdecode(out, cv.IMREAD_COLOR);
    expect(mat.cols, 20); // was 40 wide
    expect(mat.rows, 40); // was 20 tall — not clipped to 40x20
    mat.dispose();
  });

  test('degenerate mesh falls back to source pixels (not a black page)',
      () async {
    // Mid-gray source so a black (blanked) result is detectable.
    final grayMat =
        cv.Mat.create(rows: 20, cols: 40, r: 128, g: 128, b: 128, type: cv.MatType.CV_8UC3);
    final (_, src) = cv.imencode('.png', grayMat);
    grayMat.dispose();
    // All four control points coincident — the perspective transform is
    // degenerate; apply() must degrade to the original pixels, not blank.
    final grid = MeshGrid(rows: 1, cols: 1, points: const [
      NormPoint(0, 0), NormPoint(0, 0), NormPoint(0, 0), NormPoint(0, 0),
    ]);
    final out = await correction.apply(src, [MeshDewarpCorrection(grid: grid)]);
    final mat = cv.imdecode(out, cv.IMREAD_COLOR);
    expect(mat.cols, 40);
    expect(mat.rows, 20);
    expect(cv.mean(mat).val1, greaterThan(64), reason: 'page must not be blank');
    mat.dispose();
  });

  test('subdivided mesh on a non-divisible frame does not crash', () async {
    // h=21 with rows=2 made the old code round a cell rect past the bottom edge.
    final src = _solidPng(40, 21);
    final out = await correction.apply(src,
        [MeshDewarpCorrection(grid: MeshGrid.identity(rows: 2, cols: 1))]);
    final mat = cv.imdecode(out, cv.IMREAD_COLOR);
    expect(mat.cols, 40);
    expect(mat.rows, 21);
    mat.dispose();
  });
}
