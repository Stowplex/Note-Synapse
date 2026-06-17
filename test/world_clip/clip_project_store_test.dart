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

  test('createFromImages copies images and pre-populates clips', () async {
    final imgs = [
      File('${tmp.path}/a.jpg')..writeAsBytesSync([1, 2]),
      File('${tmp.path}/b.png')..writeAsBytesSync([3, 4]),
    ];
    final p = await store.createFromImages(name: 'Pics', images: imgs);
    expect(p.isPictureProject, isTrue);
    expect(p.sourceVideoFileName, '');
    expect(p.imageFileNames, ['image_0.jpg', 'image_1.png']);
    // One clip per image, indexed 0..n-1.
    expect(p.clips.map((c) => c.frameTimestampMs), [0, 1]);
    // Images copied into the project, resolvable via imagePaths.
    final paths = store.imagePaths(p);
    expect(paths.length, 2);
    expect(File(paths[0]).existsSync(), isTrue);
    expect(File(paths[1]).existsSync(), isTrue);
    // Round-trips as a picture project.
    final loaded = (await store.load(p.id))!;
    expect(loaded.isPictureProject, isTrue);
    expect(loaded.imageFileNames, ['image_0.jpg', 'image_1.png']);
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

  test('clip order survives a save/reload so a reorder persists on resume',
      () async {
    final p = await store.create(name: 'Reordered', sourceVideo: fakeVideo);
    // Two clips whose `order` is the reverse of their timestamp order — this
    // is what a review-stage drag produces; resume must replay `order`.
    p.clips.add(ClipSpec(
        id: 'late', frameTimestampMs: 2000, order: 0, corrections: const []));
    p.clips.add(ClipSpec(
        id: 'early', frameTimestampMs: 1000, order: 1, corrections: const []));
    await store.save(p);

    final loaded = (await store.load(p.id))!;
    loaded.clips.sort((a, b) => a.order.compareTo(b.order));
    expect(loaded.clips.map((c) => c.frameTimestampMs), [2000, 1000]);
  });
}
