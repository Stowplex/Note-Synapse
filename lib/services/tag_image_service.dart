import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/utils/file_utils.dart';
import 'package:path_provider/path_provider.dart';

class TagImageService {
  final DatabaseService _db;

  /// tagName -> imagePath
  Map<String, String> _tagNameToImage = {};

  /// tagId -> tagName (for reverse lookup)
  Map<String, String> _tagIdToName = {};

  /// Revision counter — widgets listen to this for rebuilds.
  final ValueNotifier<int> revision = ValueNotifier(0);

  /// Cached application documents directory path (set during loadAll).
  String? _appDocsPath;
  String? get appDocsPath => _appDocsPath;

  /// Built-in image names (without path prefix).
  /// Update this list when adding new built-in images to assets/tag_images/.
  static const List<String> builtinImages = [
    // Placeholder - will be populated when user provides actual images
  ];

  TagImageService(this._db);

  /// Load all tag-image mappings from DB. Call once at startup.
  Future<void> loadAll() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _appDocsPath = dir.path;
    } catch (_) {
      // path_provider unavailable (e.g. in unit tests)
    }

    final tagImages = await _db.getAllTagImages(); // tagId -> imagePath
    final allTags = await _db.getAllTags();

    _tagIdToName = {for (final tag in allTags) tag.id: tag.name};

    _tagNameToImage = {};
    for (final entry in tagImages.entries) {
      final tagName = _tagIdToName[entry.key];
      if (tagName != null) {
        _tagNameToImage[tagName] = entry.value;
      }
    }
  }

  /// Get the image path for a single tag (by name). Returns null if none.
  String? getImagePathForTag(String tagName) {
    return _tagNameToImage[tagName];
  }

  /// Get up to 2 image paths for a list of tag names.
  /// Filters to tags that have images, sorts alphabetically, returns first 2.
  List<String> getImagePathsForTags(List<String> tagNames) {
    final withImages =
        tagNames.where((name) => _tagNameToImage.containsKey(name)).toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return withImages.take(2).map((name) => _tagNameToImage[name]!).toList();
  }

  /// Set or update the image for a tag. Refreshes cache.
  Future<void> setTagImage(String tagId, String imagePath) async {
    await _db.setTagImage(tagId, imagePath);
    await loadAll();
    revision.value++;
  }

  /// Remove the image for a tag. Deletes user image file if not built-in.
  Future<void> removeTagImage(String tagId) async {
    // Check if it's a user image before removing from DB
    final currentPath = await _db.getTagImage(tagId);
    await _db.removeTagImage(tagId);

    // Delete user image file from disk
    if (currentPath != null && !currentPath.startsWith('builtin:')) {
      try {
        final storageDir = await FileUtils.getPrivateStorageDirectory();
        final baseDir = storageDir.parent;
        final file = File('${baseDir.path}/$currentPath');
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // File deletion is best-effort
      }
    }

    await loadAll();
    revision.value++;
  }

  /// Check if an imagePath refers to a built-in image.
  static bool isBuiltin(String imagePath) {
    return imagePath.startsWith('builtin:');
  }

  /// Get the asset path for a built-in image name.
  static String builtinAssetPath(String name) {
    return 'assets/tag_images/$name.png';
  }

  /// Extract the built-in name from a builtin: path.
  static String builtinName(String imagePath) {
    return imagePath.replaceFirst('builtin:', '');
  }
}
