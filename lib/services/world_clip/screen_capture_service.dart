import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Records the device screen to a video file for World Clip capture.
///
/// On Android this drives the system MediaProjection flow: the OS consent
/// dialog lets the user pick a single app or the whole screen (single-app
/// selection on Android 14+), the recording runs in a foreground service, and
/// it is finalized when the user stops it (the in-app button or the
/// notification action). Platforms without a backend report
/// [isSupported] == false so the source screen can hide the entry point.
abstract class ScreenCaptureService {
  /// Whether screen capture is available on this platform/build.
  bool get isSupported;

  /// Begins recording and resolves with the recorded video file once the user
  /// stops it — or null if they cancelled/denied consent or recording failed.
  /// While the future is pending the recording is live; call [stop] to end it
  /// (the notification's Stop action resolves it too).
  Future<File?> record();

  /// Requests that an in-progress recording stop and finalize. Safe to call
  /// when nothing is recording; the file is delivered via the pending [record].
  Future<void> stop();
}

/// No-op backend for platforms without a screen-capture implementation yet
/// (iOS / desktop / web). Keeps the source-screen logic platform-agnostic.
class UnsupportedScreenCaptureService implements ScreenCaptureService {
  @override
  bool get isSupported => false;
  @override
  Future<File?> record() async => null;
  @override
  Future<void> stop() async {}
}

/// Method-channel backend (Android). Bridges to `note_synapse/screen_capture`:
///  - `startCapture` launches the OS consent + foreground recording and returns
///    true once recording started, false if the user cancelled/denied.
///  - `stopCapture` asks native to finalize the current recording.
///  - native → Dart `onCaptureComplete(path)` delivers the finished file path
///    (null on failure). This covers both the in-app Stop and the notification
///    Stop action, which may fire while the app is backgrounded.
class MethodChannelScreenCaptureService implements ScreenCaptureService {
  static const MethodChannel _defaultChannel =
      MethodChannel('note_synapse/screen_capture');

  final MethodChannel _channel;
  Completer<File?>? _pending;

  MethodChannelScreenCaptureService({MethodChannel? channel})
      : _channel = channel ?? _defaultChannel {
    _channel.setMethodCallHandler(_onCall);
  }

  @override
  bool get isSupported => !kIsWeb && Platform.isAndroid;

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'onCaptureComplete') {
      final path = call.arguments as String?;
      final pending = _pending;
      _pending = null;
      pending?.complete(path == null || path.isEmpty ? null : File(path));
    }
    return null;
  }

  @override
  Future<File?> record() async {
    if (_pending != null) {
      throw StateError('A screen recording is already in progress');
    }
    // Arm _pending BEFORE startCapture: native can finish almost immediately
    // (e.g. setup fails and fires onCaptureComplete(null)) and that callback
    // must find a completer to resolve, or record() would hang forever.
    final completer = _pending = Completer<File?>();
    var started = false;
    try {
      started = await _channel.invokeMethod<bool>('startCapture') ?? false;
    } on PlatformException {
      started = false; // consent failed / native error — treat as cancelled
    }
    // If consent was denied / start failed and no native completion raced in
    // first, disarm and report cancelled. (If a completion already resolved
    // the completer, honour it.)
    if (!started && identical(_pending, completer) && !completer.isCompleted) {
      _pending = null;
      return null;
    }
    return completer.future;
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopCapture');
    } on PlatformException {
      // Native couldn't stop cleanly — unblock record() so the UI recovers.
      final pending = _pending;
      _pending = null;
      pending?.complete(null);
    }
  }
}

/// Test double. By default [record] stays pending until [stop] is called,
/// mirroring the real "record until the user stops" lifecycle. With
/// [autoComplete] it resolves immediately with [resultPath], modelling the
/// notification's Stop action firing without an in-app tap.
class FakeScreenCaptureService implements ScreenCaptureService {
  FakeScreenCaptureService(
      {this.resultPath, this.supported = true, this.autoComplete = false});

  /// Path delivered when the recording stops (null simulates a failed/empty
  /// recording or a denied consent).
  final String? resultPath;
  final bool supported;
  final bool autoComplete;
  int recordCalls = 0;
  int stopCalls = 0;
  Completer<File?>? _pending;

  @override
  bool get isSupported => supported;

  @override
  Future<File?> record() async {
    recordCalls++;
    if (autoComplete) return resultPath == null ? null : File(resultPath!);
    return (_pending = Completer<File?>()).future;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    final pending = _pending;
    _pending = null;
    pending?.complete(resultPath == null ? null : File(resultPath!));
  }
}
