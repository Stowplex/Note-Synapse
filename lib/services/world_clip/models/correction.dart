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
      case 'colorAdjust':
        return ColorAdjustCorrection.fromJson(json);
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

/// Contrast / saturation / color-temperature adjustment.
///
/// All three compose into a single affine transform of RGB values, exposed by
/// [rgbMatrix] and shared by the OpenCV render path and the Flutter
/// `ColorFilter.matrix` live preview so both produce the same pixels.
/// Neutral values: contrast 1, saturation 1, temperature 0.
class ColorAdjustCorrection extends Correction {
  /// Multiplier around mid-gray (128); 1 = unchanged.
  final double contrast;

  /// 0 = grayscale, 1 = unchanged, >1 boosted.
  final double saturation;

  /// -1 (cool, more blue) .. 1 (warm, more red); 0 = unchanged.
  final double temperature;

  ColorAdjustCorrection({
    this.contrast = 1,
    this.saturation = 1,
    this.temperature = 0,
  });

  bool get isNeutral => contrast == 1 && saturation == 1 && temperature == 0;

  /// Strength of the temperature slider at full deflection: ±30% red/blue.
  static const double _tempGain = 0.3;

  /// The combined color transform as a row-major 3x4 matrix over RGB in the
  /// 0-255 domain: out = M[0..2] * (R, G, B) + M[3].
  /// Composition order: temperature → saturation → contrast.
  List<double> rgbMatrix() {
    // Temperature: diagonal red/blue gains.
    final rGain = 1 + _tempGain * temperature;
    final bGain = 1 - _tempGain * temperature;
    // Saturation: blend between Rec.709 luma and identity.
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final s = saturation;
    // Rows of (contrast * saturation) applied to the temperature gains.
    final m = List<double>.filled(12, 0);
    final diag = [rGain, 1.0, bGain];
    for (var row = 0; row < 3; row++) {
      final lum = [lr, lg, lb];
      for (var col = 0; col < 3; col++) {
        final sat = lum[col] * (1 - s) + (row == col ? s : 0);
        m[row * 4 + col] = contrast * sat * diag[col];
      }
      // Contrast pivots around mid-gray.
      m[row * 4 + 3] = 128 * (1 - contrast);
    }
    return m;
  }

  @override
  Map<String, dynamic> toJson() => {
        'tool': 'colorAdjust',
        'contrast': contrast,
        'saturation': saturation,
        'temperature': temperature,
      };

  factory ColorAdjustCorrection.fromJson(Map<String, dynamic> j) =>
      ColorAdjustCorrection(
        contrast: (j['contrast'] as num?)?.toDouble() ?? 1,
        saturation: (j['saturation'] as num?)?.toDouble() ?? 1,
        temperature: (j['temperature'] as num?)?.toDouble() ?? 0,
      );
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
