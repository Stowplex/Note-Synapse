import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:note_synapse/services/world_clip/frame_extractor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/video_frames');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Uint8List png(int w, int h) => Uint8List.fromList(
      img.encodePng(img.Image(width: w, height: h)..clear(img.ColorRgb8(30, 60, 90))));

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('sampleTimestamps derives steps from the native duration', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return call.method == 'getDuration' ? 2000 : null;
    });
    final ex = PlatformFrameExtractor('/x.mp4', channel: channel);
    final ts = await ex.sampleTimestamps(fps: 5); // step 200ms over 2000ms
    expect(ts.first, 0);
    expect(ts.length, 10);
    expect(ts.last, 1800);
  });

  test('fullFrameAt and thumbnailAt return the native frame bytes', () async {
    final bytes = png(8, 6);
    int? lastMaxWidth;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'extractFrame') {
        lastMaxWidth = (call.arguments as Map)['maxWidth'] as int;
        return bytes;
      }
      return null;
    });
    final ex = PlatformFrameExtractor('/x.mp4', channel: channel);
    expect(await ex.fullFrameAt(0), equals(bytes));
    expect(lastMaxWidth, 0); // full frame requests no downscale
    await ex.thumbnailAt(0, maxWidth: 120);
    expect(lastMaxWidth, 120);
  });

  test('featureAt computes sharpness/diff from the decoded frames', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return call.method == 'extractFrame' ? png(32, 32) : null;
    });
    final ex = PlatformFrameExtractor('/x.mp4', channel: channel);
    final f = await ex.featureAt(500, previousTimestampMs: 0);
    expect(f.timestampMs, 500);
    expect(f.sharpness, greaterThanOrEqualTo(0));
    expect(f.diffFromPrev, inInclusiveRange(0.0, 1.0));
  });

  test('throws StateError when the native side returns no frame', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final ex = PlatformFrameExtractor('/x.mp4', channel: channel);
    expect(() => ex.fullFrameAt(0), throwsStateError);
  });
}
