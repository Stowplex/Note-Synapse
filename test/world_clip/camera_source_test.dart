import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/camera_source.dart';

const back = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);
const front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);

void main() {
  group('CameraPictureSource (Picture Sequence still capture)', () {
    // The still-capture path records no audio: `enableAudio: false` means the
    // OS mic-permission prompt never appears for World Clip captures.
    test('controller is constructed audio-free (no mic prompt)', () {
      final src = CameraPictureSource();
      final controller = src.buildController(back);
      expect(controller.enableAudio, isFalse);
    });

    test(
        'prefers the back camera even when the platform lists the front one '
        'first (this photographs documents)', () async {
      final src = CameraPictureSource(
        camerasProvider: () async => [front, back],
      );
      final built = await src.selectAndBuild();
      expect(built.description, back);
      expect(built.enableAudio, isFalse);
    });

    test('falls back to the first camera when there is no back camera',
        () async {
      final src = CameraPictureSource(camerasProvider: () async => [front]);
      final built = await src.selectAndBuild();
      expect(built.description, front);
    });

    test('the controller the source captures from is audio-free', () async {
      final src = CameraPictureSource(camerasProvider: () async => [back]);
      await src.selectAndBuild();
      expect(src.controller.enableAudio, isFalse);
    });

    // Backing out of the screen while availableCameras() is still in flight
    // used to leave the freshly-built controller holding the device camera
    // (dispose() ran before the controller existed) — initialize() must tear
    // it down itself when it finds the source was disposed mid-flight.
    test('dispose during camera enumeration tears down the built controller',
        () async {
      final cameras = Completer<List<CameraDescription>>();
      final src = CameraPictureSource(camerasProvider: () => cameras.future);
      final init = src.initialize();
      await src.dispose();
      cameras.complete([back]);
      await init;
      expect(src.isDisposed, isTrue);
    });
  });
}
