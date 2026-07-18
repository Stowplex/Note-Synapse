import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// A camera-built controller plus the description it was built from. Lets tests
/// assert the audio-free invariant without touching the platform.
@immutable
class BuiltCamera {
  const BuiltCamera(this.description, this.enableAudio);
  final CameraDescription description;
  final bool enableAudio;
}

/// In-app camera capture of a still-photo sequence ("Picture Sequence" mode):
/// one `takePicture()` call per shot. Audio is irrelevant for stills, but
/// `enableAudio: false` is kept anyway so this path never triggers an OS
/// mic-permission prompt.
///
/// The camera enumeration is injectable so the audio-free invariant can be
/// tested without a device.
class CameraPictureSource {
  CameraPictureSource({
    Future<List<CameraDescription>> Function()? camerasProvider,
  }) : _camerasProvider = camerasProvider ?? availableCameras;

  final Future<List<CameraDescription>> Function() _camerasProvider;
  CameraController? _controller;
  bool _disposed = false;

  /// True after [dispose] until the next [initialize]. The screen checks this
  /// after awaiting [initialize] so a camera opened mid-teardown is never
  /// treated as live.
  bool get isDisposed => _disposed;

  /// Constructs the controller for [description] — audio-free, no platform call
  /// until [CameraController.initialize] is invoked. The seam tests assert on.
  @visibleForTesting
  CameraController buildController(CameraDescription description) =>
      CameraController(description, ResolutionPreset.high, enableAudio: false);

  /// Picks the back camera when there is one (this photographs documents;
  /// enumeration order is platform-defined and may list the selfie camera
  /// first) and builds its (audio-free) controller, without initializing the
  /// platform. Returns what was built for assertions.
  @visibleForTesting
  Future<BuiltCamera> selectAndBuild() async {
    final cams = await _camerasProvider();
    final description = cams.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cams.first,
    );
    final controller = buildController(description);
    _controller = controller;
    return BuiltCamera(description, controller.enableAudio);
  }

  /// Opens the camera. Re-callable after [dispose] (the app-lifecycle path:
  /// the camera must be released while backgrounded and reopened on resume).
  /// If [dispose] lands while the enumeration is still in flight, the built
  /// controller is torn down here instead of being left holding the camera —
  /// callers must check [isDisposed] before using [controller].
  Future<void> initialize() async {
    _disposed = false;
    await selectAndBuild();
    if (_disposed) {
      await _controller?.dispose();
      _controller = null;
      return;
    }
    await _controller!.initialize();
    if (_disposed) {
      // Disposed while the platform open was in flight.
      await _controller?.dispose();
      _controller = null;
    }
  }

  CameraController get controller => _controller!;

  /// Snaps one still photo and returns it as a [File]. Callers take as many
  /// shots as the sequence/anti-glare flow needs; this class holds no
  /// per-shot state of its own.
  Future<File> takePicture() async {
    final file = await _controller!.takePicture();
    return File(file.path);
  }

  /// Sets the flash mode on the live controller. Applies to every capture
  /// from here on (the controller itself remembers it) until changed again —
  /// callers don't need to re-set it per shot.
  Future<void> setFlashMode(FlashMode mode) => _controller!.setFlashMode(mode);

  Future<void> dispose() async {
    _disposed = true;
    final controller = _controller;
    _controller = null;
    await controller?.dispose();
  }
}
