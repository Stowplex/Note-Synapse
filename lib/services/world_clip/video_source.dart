import 'dart:io';
import 'package:image_picker/image_picker.dart';

/// Yields source media for World Clip — a single video, or a multi-selection of
/// pictures. v1: gallery import. Future: in-app camera intent.
abstract class VideoSource {
  Future<File?> pickVideo();

  /// Multi-select pictures from the gallery. Empty when the user cancels.
  Future<List<File>> pickImages();
}

class GalleryVideoSource implements VideoSource {
  final ImagePicker _picker;
  GalleryVideoSource([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  @override
  Future<File?> pickVideo() async {
    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    return picked == null ? null : File(picked.path);
  }

  @override
  Future<List<File>> pickImages() async {
    final picked = await _picker.pickMultiImage();
    return [for (final x in picked) File(x.path)];
  }
}

/// Test double.
class FakeVideoSource implements VideoSource {
  final String? path;
  final List<String> imagePaths;
  FakeVideoSource(this.path, {this.imagePaths = const []});
  @override
  Future<File?> pickVideo() async => path == null ? null : File(path!);
  @override
  Future<List<File>> pickImages() async => [for (final p in imagePaths) File(p)];
}
