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

  ClipProject project(List<ClipSpec> clips, {bool manualOrder = false}) =>
      ClipProject(
        id: 'p',
        name: 'n',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        sourceVideoFileName: 's.mp4',
        clips: clips,
        manualOrder: manualOrder,
      );

  test('orderedClips defaults to video (timestamp) order, ignoring insert order',
      () {
    // Inserted auto-first (low order) then manual (high order), but the manual
    // frame is EARLIER in the video — it must come first by default.
    final p = project([
      ClipSpec(id: 'auto', frameTimestampMs: 2000, order: 0, corrections: const []),
      ClipSpec(id: 'manual', frameTimestampMs: 1000, order: 1, corrections: const []),
    ]);
    expect(p.orderedClips().map((c) => c.frameTimestampMs), [1000, 2000]);
  });

  test('orderedClips honors ClipSpec.order once manualOrder is set', () {
    final p = project([
      ClipSpec(id: 'a', frameTimestampMs: 1000, order: 1, corrections: const []),
      ClipSpec(id: 'b', frameTimestampMs: 2000, order: 0, corrections: const []),
    ], manualOrder: true);
    expect(p.orderedClips().map((c) => c.frameTimestampMs), [2000, 1000]);
  });

  test('manualOrder round-trips through json', () {
    final p = project(const [], manualOrder: true);
    expect(ClipProject.fromJson(p.toJson()).manualOrder, isTrue);
    // Defaults to false when absent (backward compatibility).
    final legacy = {
      'id': 'x', 'name': 'n', 'createdAt': 0, 'sourceVideo': 's.mp4',
      'clips': <dynamic>[],
    };
    expect(ClipProject.fromJson(legacy).manualOrder, isFalse);
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
