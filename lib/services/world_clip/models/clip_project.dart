import 'clip_spec.dart';

/// A cached World Clip editing session. Durable output is the committed note;
/// this lives in the OS cache dir and may be flushed.
class ClipProject {
  final String id;
  String name;
  final DateTime createdAt;
  final String sourceVideoFileName; // relative to the project dir; '' for pictures
  final List<ClipSpec> clips;

  /// For picture-import projects: the copied image filenames (relative to the
  /// project's clips dir), indexed by [ClipSpec.frameTimestampMs]. Empty for
  /// video projects.
  final List<String> imageFileNames;

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
    this.imageFileNames = const [],
    this.manualOrder = false,
  });

  /// True when this project was built from imported pictures rather than a
  /// video (so it has no frame extractor / timeline).
  bool get isPictureProject => imageFileNames.isNotEmpty;

  /// The clip for [ts], or null if that frame isn't tagged.
  ClipSpec? clipForTimestamp(int ts) {
    for (final c in clips) {
      if (c.frameTimestampMs == ts) return c;
    }
    return null;
  }

  /// Returns the clip for [ts], creating an empty one (appended) if needed.
  ClipSpec ensureClip(int ts) =>
      clipForTimestamp(ts) ??
      (clips..add(ClipSpec(
        id: ts.toString(),
        frameTimestampMs: ts,
        order: clips.length,
        corrections: [],
      ))).last;

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
        'imageFileNames': imageFileNames,
        'manualOrder': manualOrder,
        'clips': clips.map((c) => c.toJson()).toList(),
      };

  factory ClipProject.fromJson(Map<String, dynamic> j) => ClipProject(
        id: j['id'] as String,
        name: j['name'] as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(j['createdAt'] as int),
        sourceVideoFileName: j['sourceVideo'] as String,
        imageFileNames:
            (j['imageFileNames'] as List?)?.cast<String>() ?? const [],
        manualOrder: j['manualOrder'] as bool? ?? false,
        clips: (j['clips'] as List)
            .map((e) => ClipSpec.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
