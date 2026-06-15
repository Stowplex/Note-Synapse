import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/clip_project_store.dart';
import 'package:note_synapse/services/world_clip/models/clip_spec.dart';

void main() {
  late Directory tmp;
  late ClipProjectStore store;
  late File fakeVideo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('world_clip_test');
    store = ClipProjectStore(Directory('${tmp.path}/world_clip'));
    fakeVideo = File('${tmp.path}/in.mp4')..writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('create copies the source video and persists project.json', () async {
    final p = await store.create(name: 'Book', sourceVideo: fakeVideo);
    final dir = store.projectDir(p.id);
    expect(File('${dir.path}/${p.sourceVideoFileName}').existsSync(), isTrue);
    expect(File('${dir.path}/project.json').existsSync(), isTrue);
    expect(p.name, 'Book');
  });

  test('save then load returns equal data', () async {
    final p = await store.create(name: 'Book', sourceVideo: fakeVideo);
    p.clips.add(ClipSpec(
        id: 'c1', frameTimestampMs: 500, order: 0, corrections: const []));
    await store.save(p);
    final loaded = await store.load(p.id);
    expect(loaded!.clips.single.frameTimestampMs, 500);
  });

  test('listAll returns created projects newest-first', () async {
    final a = await store.create(name: 'A', sourceVideo: fakeVideo);
    final b = await store.create(name: 'B', sourceVideo: fakeVideo);
    final all = await store.listAll();
    expect(all.map((p) => p.id), containsAll([a.id, b.id]));
  });

  test('delete removes the project dir', () async {
    final p = await store.create(name: 'X', sourceVideo: fakeVideo);
    await store.delete(p.id);
    expect(store.projectDir(p.id).existsSync(), isFalse);
    expect(await store.load(p.id), isNull);
  });

  test('listAll tolerates a missing base dir', () async {
    final fresh = ClipProjectStore(Directory('${tmp.path}/never_created'));
    expect(await fresh.listAll(), isEmpty);
  });
}
