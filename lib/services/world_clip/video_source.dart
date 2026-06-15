import 'dart:io';
import 'package:image_picker/image_picker.dart';

/// Yields a source video. v1: gallery import. Future: in-app camera intent.
abstract class VideoSource {
  Future<File?> pickVideo();
}

class GalleryVideoSource implements VideoSource {
  final ImagePicker _picker;
  GalleryVideoSource([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  @override
  Future<File?> pickVideo() async {
    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    return picked == null ? null : File(picked.path);
  }
}

/// Test double.
class FakeVideoSource implements VideoSource {
  final String? path;
  FakeVideoSource(this.path);
  @override
  Future<File?> pickVideo() async => path == null ? null : File(path!);
}
