import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/world_clip/frame_correction.dart';

void main() {
  test('FrameCorrection resolves after registration', () async {
    await resetForTesting();
    registerWorldClipServices();
    expect(getIt<FrameCorrection>(), isA<OpenCvFrameCorrection>());
  });
}
