import 'clip_spec.dart';

/// A cached World Clip editing session. Durable output is the committed note;
/// this lives in the OS cache dir and may be flushed.
class ClipProject {
  final String id;
  String name;
  final DateTime createdAt;
  final String sourceVideoFileName; // relative to the project dir
  final List<ClipSpec> clips;

  ClipProject({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.sourceVideoFileName,
    required this.clips,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'sourceVideo': sourceVideoFileName,
        'clips': clips.map((c) => c.toJson()).toList(),
      };

  factory ClipProject.fromJson(Map<String, dynamic> j) => ClipProject(
        id: j['id'] as String,
        name: j['name'] as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(j['createdAt'] as int),
        sourceVideoFileName: j['sourceVideo'] as String,
        clips: (j['clips'] as List)
            .map((e) => ClipSpec.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
