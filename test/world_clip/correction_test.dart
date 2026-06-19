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

  test('unknown tool throws', () {
    expect(() => Correction.fromJson({'tool': 'bogus'}), throwsArgumentError);
  });
}
