import 'clip_spec.dart';

/// A cached World Clip editing session. Durable output is the committed note;
/// this lives in the OS cache dir and may be flushed.
class ClipProject {
  final String id;
  String name;
  final DateTime createdAt;
  final String sourceVideoFileName; // relative to the project dir
  final List<ClipSpec> clips;

  /// Whether the user has manually drag-reordered clips. While false, clips are
  /// presented in video (timestamp) order; once true, the persisted
  /// [ClipSpec.order] takes over.
  bool manualOrder;

  ClipProject({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.sourceVideoFileName,
    required this.clips,
    this.manualOrder = false,
  });

  /// Clips in display order: video (timestamp) order by default, or the
  /// persisted [ClipSpec.order] once the user has drag-reordered
  /// ([manualOrder]). Ties always broken by timestamp.
  List<ClipSpec> orderedClips() {
    final sorted = clips.toList();
    sorted.sort((a, b) {
      if (manualOrder) {
        final byOrder = a.order.compareTo(b.order);
        if (byOrder != 0) return byOrder;
      }
      return a.frameTimestampMs.compareTo(b.frameTimestampMs);
    });
    return sorted;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'sourceVideo': sourceVideoFileName,
        'manualOrder': manualOrder,
        'clips': clips.map((c) => c.toJson()).toList(),
      };

  factory ClipProject.fromJson(Map<String, dynamic> j) => ClipProject(
        id: j['id'] as String,
        name: j['name'] as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(j['createdAt'] as int),
        sourceVideoFileName: j['sourceVideo'] as String,
        manualOrder: j['manualOrder'] as bool? ?? false,
        clips: (j['clips'] as List)
            .map((e) => ClipSpec.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
