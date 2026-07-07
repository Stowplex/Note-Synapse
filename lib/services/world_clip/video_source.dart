import 'dart:io';
import 'package:image_picker/image_picker.dart';

/// Camera RAW file extensions. RAW captures (e.g. Pixel / ProRAW DNGs) show up
/// in the OS photo picker next to their JPEG twins and are nearly impossible
/// to tell apart there — and OpenCV can't decode them — so picked RAW files
/// are dropped before entering a project.
const Set<String> kRawImageExtensions = {
  '.dng', '.raw', '.arw', '.srf', '.sr2', '.cr2', '.cr3', '.crw', '.nef',
  '.nrw', '.orf', '.rw2', '.raf', '.srw', '.pef', '.x3f', '.3fr', '.erf',
  '.kdc', '.mrw', '.rwl',
};

/// True when [path] has a camera RAW extension (case-insensitive).
bool isRawImagePath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  return kRawImageExtensions.contains(path.substring(dot).toLowerCase());
}

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
