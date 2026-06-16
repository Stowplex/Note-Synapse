import 'norm_point.dart';

/// A control-point grid over a frame in normalized coords, row-major.
/// `rows`/`cols` are CELL counts; there are (rows+1)*(cols+1) points.
class MeshGrid {
  final int rows;
  final int cols;
  final List<NormPoint> points;

  const MeshGrid({required this.rows, required this.cols, required this.points});

  /// The control point at grid cell-corner (row [r], column [c]), 0..rows /
  /// 0..cols. Centralizes the row-major stride so the (cols+1) invariant lives
  /// next to the data.
  NormPoint at(int r, int c) => points[r * (cols + 1) + c];

  factory MeshGrid.identity({required int rows, required int cols}) {
    final pts = <NormPoint>[];
    for (var r = 0; r <= rows; r++) {
      for (var c = 0; c <= cols; c++) {
        pts.add(NormPoint(c / cols, r / rows));
      }
    }
    return MeshGrid(rows: rows, cols: cols, points: pts);
  }

  Map<String, dynamic> toJson() => {
        'rows': rows,
        'cols': cols,
        'points': points.map((p) => p.toJson()).toList(),
      };

  factory MeshGrid.fromJson(Map<String, dynamic> j) => MeshGrid(
        rows: j['rows'] as int,
        cols: j['cols'] as int,
        points: (j['points'] as List)
            .map((e) => NormPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
