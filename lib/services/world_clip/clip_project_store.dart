import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'models/clip_project.dart';
import 'models/clip_spec.dart';

/// Persists [ClipProject]s as JSON + cached frames under a cache base dir.
/// The base dir is injected so tests can use a temp directory.
class ClipProjectStore {
  final Directory baseDir;
  ClipProjectStore(this.baseDir);

  Directory projectDir(String id) => Directory(p.join(baseDir.path, id));
  File _projectFile(String id) => File(p.join(projectDir(id).path, 'project.json'));
  Directory proxyDir(String id) => Directory(p.join(projectDir(id).path, 'proxy'));
  Directory clipsDir(String id) => Directory(p.join(projectDir(id).path, 'clips'));

  Future<ClipProject> create({
    required String name,
    required File sourceVideo,
  }) async {
    final id = const Uuid().v4();
    final dir = projectDir(id);
    await dir.create(recursive: true);
    await proxyDir(id).create(recursive: true);
    await clipsDir(id).create(recursive: true);

    final ext = p.extension(sourceVideo.path);
    final videoName = 'source$ext';
    await sourceVideo.copy(p.join(dir.path, videoName));

    final project = ClipProject(
      id: id,
      name: name,
      createdAt: DateTime.now(),
      sourceVideoFileName: videoName,
      clips: [],
    );
    await save(project);
    return project;
  }

  /// Creates a picture-import project: copies each picked image into the
  /// project's clips dir and pre-populates one [ClipSpec] per image (its
  /// frameTimestampMs / order is just its index). No source video.
  Future<ClipProject> createFromImages({
    required String name,
    required List<File> images,
  }) async {
    // A picture project is identified by a non-empty imageFileNames list; an
    // empty import would be misclassified as a video project on resume.
    if (images.isEmpty) {
      throw ArgumentError('createFromImages requires at least one image');
    }
    final id = const Uuid().v4();
    await projectDir(id).create(recursive: true);
    await proxyDir(id).create(recursive: true);
    await clipsDir(id).create(recursive: true);

    final imageFileNames = <String>[];
    final clips = <ClipSpec>[];
    for (var i = 0; i < images.length; i++) {
      final ext = p.extension(images[i].path);
      final fileName = 'image_$i$ext';
      await images[i].copy(p.join(clipsDir(id).path, fileName));
      imageFileNames.add(fileName);
      clips.add(ClipSpec(
          id: '$i', frameTimestampMs: i, order: i, corrections: []));
    }

    final project = ClipProject(
      id: id,
      name: name,
      createdAt: DateTime.now(),
      sourceVideoFileName: '',
      imageFileNames: imageFileNames,
      clips: clips,
    );
    await save(project);
    return project;
  }

  /// Absolute paths to a picture project's copied images, indexed by frame.
  List<String> imagePaths(ClipProject project) => [
        for (final name in project.imageFileNames)
          p.join(clipsDir(project.id).path, name)
      ];

  Future<void> save(ClipProject project) async {
    await projectDir(project.id).create(recursive: true);
    await _projectFile(project.id)
        .writeAsString(jsonEncode(project.toJson()));
  }

  Future<ClipProject?> load(String id) async {
    final f = _projectFile(id);
    if (!await f.exists()) return null;
    return ClipProject.fromJson(
        jsonDecode(await f.readAsString()) as Map<String, dynamic>);
  }

  Future<List<ClipProject>> listAll() async {
    if (!await baseDir.exists()) return [];
    final projects = <ClipProject>[];
    await for (final entity in baseDir.list()) {
      if (entity is Directory) {
        final loaded = await load(p.basename(entity.path));
        if (loaded != null) projects.add(loaded);
      }
    }
    projects.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return projects;
  }

  Future<void> delete(String id) async {
    final dir = projectDir(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
