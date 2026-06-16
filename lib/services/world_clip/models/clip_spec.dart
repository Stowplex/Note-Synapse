import 'correction.dart';

/// One selected frame plus the ordered corrections to replay on it.
class ClipSpec {
  final String id;
  final int frameTimestampMs;
  int order;
  List<Correction> corrections;

  ClipSpec({
    required this.id,
    required this.frameTimestampMs,
    required this.order,
    required this.corrections,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'frameTimestampMs': frameTimestampMs,
        'order': order,
        'corrections': corrections.map((c) => c.toJson()).toList(),
      };

  factory ClipSpec.fromJson(Map<String, dynamic> j) => ClipSpec(
        id: j['id'] as String,
        frameTimestampMs: j['frameTimestampMs'] as int,
        order: j['order'] as int,
        corrections: (j['corrections'] as List)
            .map((e) => Correction.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
