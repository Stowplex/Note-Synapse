import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/models/clip_spec.dart';
import 'package:note_synapse/services/world_clip/models/clip_project.dart';
import 'package:note_synapse/services/world_clip/models/correction.dart';

void main() {
  test('ClipSpec round-trips with corrections', () {
    final spec = ClipSpec(
      id: 'c1',
      frameTimestampMs: 12340,
      order: 0,
      corrections: [RotateCorrection(degrees: 90)],
    );
    final back = ClipSpec.fromJson(spec.toJson());
    expect(back.id, 'c1');
    expect(back.frameTimestampMs, 12340);
    expect(back.corrections.single, isA<RotateCorrection>());
  });

  test('ClipProject round-trips with clips', () {
    final project = ClipProject(
      id: 'p1',
      name: 'Whiteboard',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      sourceVideoFileName: 'source.mp4',
      clips: [
        ClipSpec(id: 'c1', frameTimestampMs: 0, order: 0, corrections: const []),
      ],
    );
    final back = ClipProject.fromJson(project.toJson());
    expect(back.name, 'Whiteboard');
    expect(back.sourceVideoFileName, 'source.mp4');
    expect(back.clips.single.id, 'c1');
    expect(back.createdAt.millisecondsSinceEpoch, 1000);
  });
}
