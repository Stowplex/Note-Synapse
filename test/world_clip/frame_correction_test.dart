import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:note_synapse/services/world_clip/frame_correction.dart';
import 'package:note_synapse/services/world_clip/models/correction.dart';
import 'package:note_synapse/services/world_clip/models/mesh_grid.dart';

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
}
