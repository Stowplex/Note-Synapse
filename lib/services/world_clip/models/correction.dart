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

/// Color and tone adjustment.
///
/// Two stages, both implemented in the OpenCV render path:
/// 1. An affine transform of RGB values (contrast / saturation / color
///    temperature), exposed by [rgbMatrix].
/// 2. A per-channel tone curve (brightness / highlights / shadows / blacks /
///    whites), exposed as a 256-entry lookup table by [toneLut].
/// Neutral values: contrast 1, saturation 1, everything else 0.
class ColorAdjustCorrection extends Correction {
  /// Multiplier around mid-gray (128); 1 = unchanged.
  final double contrast;

  /// 0 = grayscale, 1 = unchanged, >1 boosted.
  final double saturation;

  /// -1 (cool, more blue) .. 1 (warm, more red); 0 = unchanged.
  final double temperature;

  /// Uniform exposure shift, -1..1; 0 = unchanged.
  final double brightness;

  /// Brightens/darkens the upper tonal range only, -1..1.
  final double highlights;

  /// Lifts/deepens the lower tonal range only, -1..1.
  final double shadows;

  /// Black point: the very darkest tones, tighter range than [shadows].
  final double blacks;

  /// White point: the very brightest tones, tighter range than [highlights].
  final double whites;

  ColorAdjustCorrection({
    this.contrast = 1,
    this.saturation = 1,
    this.temperature = 0,
    this.brightness = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.blacks = 0,
    this.whites = 0,
  });

  bool get isAffineNeutral =>
      contrast == 1 && saturation == 1 && temperature == 0;

  bool get isToneNeutral =>
      brightness == 0 &&
      highlights == 0 &&
      shadows == 0 &&
      blacks == 0 &&
      whites == 0;

  bool get isNeutral => isAffineNeutral && isToneNeutral;

  /// Strength of the temperature slider at full deflection: ±30% red/blue.
  static const double _tempGain = 0.3;

  /// Max tone shift (in 0-255 levels) at full slider deflection.
  static const double _toneRange = 64;

  /// The tone curve as a 256-entry lookup table (applied per channel after
  /// the affine stage). Each slider adds a weighted offset: brightness is
  /// uniform, shadows/highlights taper quadratically into the low/high end,
  /// blacks/whites taper cubically so they move only the extremes.
  List<int> toneLut() {
    return List<int>.generate(256, (v) {
      final x = v / 255.0;
      final out = v +
          brightness * _toneRange +
          shadows * _toneRange * (1 - x) * (1 - x) +
          highlights * _toneRange * x * x +
          blacks * _toneRange * (1 - x) * (1 - x) * (1 - x) +
          whites * _toneRange * x * x * x;
      return out.round().clamp(0, 255);
    });
  }

  /// The affine color transform as a row-major 3x4 matrix over RGB in the
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
        'brightness': brightness,
        'highlights': highlights,
        'shadows': shadows,
        'blacks': blacks,
        'whites': whites,
      };

  factory ColorAdjustCorrection.fromJson(Map<String, dynamic> j) =>
      ColorAdjustCorrection(
        contrast: (j['contrast'] as num?)?.toDouble() ?? 1,
        saturation: (j['saturation'] as num?)?.toDouble() ?? 1,
        temperature: (j['temperature'] as num?)?.toDouble() ?? 0,
        brightness: (j['brightness'] as num?)?.toDouble() ?? 0,
        highlights: (j['highlights'] as num?)?.toDouble() ?? 0,
        shadows: (j['shadows'] as num?)?.toDouble() ?? 0,
        blacks: (j['blacks'] as num?)?.toDouble() ?? 0,
        whites: (j['whites'] as num?)?.toDouble() ?? 0,
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
