import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/video_source.dart';

void main() {
  test('FakeVideoSource yields its configured path', () async {
    final src = FakeVideoSource('/tmp/x.mp4');
    expect((await src.pickVideo())?.path, '/tmp/x.mp4');
  });

  test('FakeVideoSource yields null when configured empty', () async {
    expect(await FakeVideoSource(null).pickVideo(), isNull);
  });

  test('FakeVideoSource yields its configured picture paths', () async {
    final src = FakeVideoSource(null, imagePaths: ['/a.jpg', '/b.jpg']);
    expect((await src.pickImages()).map((f) => f.path), ['/a.jpg', '/b.jpg']);
  });

  test('FakeVideoSource yields no pictures by default', () async {
    expect(await FakeVideoSource(null).pickImages(), isEmpty);
  });
}
