import 'mesh_grid.dart';

/// A single reversible edit applied to a clip's source frame.
sealed class Correction {
  Map<String, dynamic> toJson();

  static Correction fromJson(Map<String, dynamic> json) {
    switch (json['tool'] as String) {
      case 'crop':
        return CropCorrection.fromJson(json);
      case 'rotate':
        return RotateCorrection.fromJson(json);
      case 'meshDewarp':
        return MeshDewarpCorrection.fromJson(json);
      default:
        throw ArgumentError('Unknown correction tool: ${json['tool']}');
    }
  }
}

/// Crop to a normalized rect (0..1).
class CropCorrection extends Correction {
  final double x, y, width, height;
  CropCorrection(
      {required this.x,
      required this.y,
      required this.width,
      required this.height});

  @override
  Map<String, dynamic> toJson() =>
      {'tool': 'crop', 'rect': [x, y, width, height]};

  factory CropCorrection.fromJson(Map<String, dynamic> j) {
    final r = (j['rect'] as List).cast<num>();
    return CropCorrection(
        x: r[0].toDouble(),
        y: r[1].toDouble(),
        width: r[2].toDouble(),
        height: r[3].toDouble());
  }
}

/// Rotate by degrees (clockwise).
class RotateCorrection extends Correction {
  final double degrees;
  RotateCorrection({required this.degrees});

  @override
  Map<String, dynamic> toJson() => {'tool': 'rotate', 'degrees': degrees};

  factory RotateCorrection.fromJson(Map<String, dynamic> j) =>
      RotateCorrection(degrees: (j['degrees'] as num).toDouble());
}

/// Perspective/mesh dewarp using a control-point grid.
class MeshDewarpCorrection extends Correction {
  final MeshGrid grid;
  MeshDewarpCorrection({required this.grid});

  @override
  Map<String, dynamic> toJson() =>
      {'tool': 'meshDewarp', 'grid': grid.toJson()};

  factory MeshDewarpCorrection.fromJson(Map<String, dynamic> j) =>
      MeshDewarpCorrection(
          grid: MeshGrid.fromJson(j['grid'] as Map<String, dynamic>));
}
