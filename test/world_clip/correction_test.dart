import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/models/correction.dart';
import 'package:note_synapse/services/world_clip/models/mesh_grid.dart';

void main() {
  test('crop round-trips and tags itself', () {
    final c = CropCorrection(x: 0.1, y: 0.2, width: 0.5, height: 0.6);
    final json = c.toJson();
    expect(json['tool'], 'crop');
    final back = Correction.fromJson(json) as CropCorrection;
    expect(back.width, 0.5);
  });

  test('rotate round-trips', () {
    final back = Correction.fromJson(RotateCorrection(degrees: 90).toJson());
    expect((back as RotateCorrection).degrees, 90);
  });

  test('meshDewarp round-trips', () {
    final c = MeshDewarpCorrection(grid: MeshGrid.identity(rows: 1, cols: 1));
    final back = Correction.fromJson(c.toJson()) as MeshDewarpCorrection;
    expect(back.grid.points.length, 4);
  });

  test('colorAdjust round-trips', () {
    final c = ColorAdjustCorrection(
        contrast: 1.2, saturation: 0.8, temperature: -0.5);
    final back = Correction.fromJson(c.toJson()) as ColorAdjustCorrection;
    expect(back.contrast, 1.2);
    expect(back.saturation, 0.8);
    expect(back.temperature, -0.5);
    expect(back.isNeutral, isFalse);
  });

  test('colorAdjust defaults are neutral', () {
    expect(ColorAdjustCorrection().isNeutral, isTrue);
  });

  test('neutral colorAdjust matrix is identity', () {
    final m = ColorAdjustCorrection().rgbMatrix();
    expect(m, [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]);
  });

  test('zero saturation matrix maps every channel to luma', () {
    final m = ColorAdjustCorrection(saturation: 0).rgbMatrix();
    for (var row = 0; row < 3; row++) {
      expect(m[row * 4 + 0], closeTo(0.2126, 1e-9));
      expect(m[row * 4 + 1], closeTo(0.7152, 1e-9));
      expect(m[row * 4 + 2], closeTo(0.0722, 1e-9));
      expect(m[row * 4 + 3], 0);
    }
  });

  test('unknown tool throws', () {
    expect(() => Correction.fromJson({'tool': 'bogus'}), throwsArgumentError);
  });
}
