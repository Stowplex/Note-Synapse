import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/models/norm_point.dart';
import 'package:note_synapse/services/world_clip/models/mesh_grid.dart';

void main() {
  test('identity grid has (rows+1)*(cols+1) evenly spaced points', () {
    final g = MeshGrid.identity(rows: 2, cols: 1);
    expect(g.points.length, 6); // (2+1)*(1+1)
    expect(g.points.first, const NormPoint(0, 0));
    expect(g.points.last, const NormPoint(1, 1));
  });

  test('round-trips through json', () {
    final g = MeshGrid(rows: 1, cols: 1, points: const [
      NormPoint(0, 0), NormPoint(1, 0), NormPoint(0, 1), NormPoint(0.9, 1),
    ]);
    final back = MeshGrid.fromJson(g.toJson());
    expect(back.rows, 1);
    expect(back.cols, 1);
    expect(back.points.last.x, 0.9);
  });
}
