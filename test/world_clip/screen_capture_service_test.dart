import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/screen_capture_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FakeScreenCaptureService', () {
    test('record stays pending until stop delivers the recorded file',
        () async {
      final svc = FakeScreenCaptureService(resultPath: '/tmp/cap.mp4');
      final future = svc.record();
      var resolved = false;
      // ignore: unawaited_futures
      future.then((_) => resolved = true);
      await Future<void>.delayed(Duration.zero);
      expect(resolved, isFalse, reason: 'record() resolves only on stop');
      expect(svc.recordCalls, 1);

      await svc.stop();
      final file = await future;
      expect(file, isNotNull);
      expect(file!.path, '/tmp/cap.mp4');
      expect(svc.stopCalls, 1);
    });

    test('stop with no result path resolves record() to null', () async {
      final svc = FakeScreenCaptureService(resultPath: null);
      final future = svc.record();
      await svc.stop();
      expect(await future, isNull);
    });
  });

  test('UnsupportedScreenCaptureService is inert and unsupported', () async {
    final svc = UnsupportedScreenCaptureService();
    expect(svc.isSupported, isFalse);
    expect(await svc.record(), isNull);
    await svc.stop(); // must not throw
  });

  group('MethodChannelScreenCaptureService', () {
    const channel = MethodChannel('test/screen_capture');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // Pushes a native → Dart onCaptureComplete onto the channel the service
    // listens on, exactly as MainActivity does when a recording finalizes.
    Future<void> deliverComplete(String? path) => messenger.handlePlatformMessage(
          channel.name,
          channel.codec
              .encodeMethodCall(MethodCall('onCaptureComplete', path)),
          (_) {},
        );

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('record returns null when consent is denied (startCapture false)',
        () async {
      messenger.setMockMethodCallHandler(
          channel, (call) async => call.method == 'startCapture' ? false : null);
      final svc = MethodChannelScreenCaptureService(channel: channel);
      expect(await svc.record(), isNull);
    });

    test('record returns null when startCapture raises a PlatformException',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'BOOM');
      });
      final svc = MethodChannelScreenCaptureService(channel: channel);
      expect(await svc.record(), isNull);
    });

    test('record resolves with the file delivered via onCaptureComplete',
        () async {
      messenger.setMockMethodCallHandler(
          channel, (call) async => call.method == 'startCapture' ? true : null);
      final svc = MethodChannelScreenCaptureService(channel: channel);
      final future = svc.record();
      await pumpEventQueue(); // let startCapture resolve so _pending is armed
      await deliverComplete('/tmp/rec.mp4');
      final file = await future;
      expect(file, isA<File>());
      expect(file!.path, '/tmp/rec.mp4');
    });

    test('onCaptureComplete with a null/empty path resolves record() to null',
        () async {
      messenger.setMockMethodCallHandler(
          channel, (call) async => call.method == 'startCapture' ? true : null);
      final svc = MethodChannelScreenCaptureService(channel: channel);
      final f1 = svc.record();
      await pumpEventQueue();
      await deliverComplete(null);
      expect(await f1, isNull);

      final f2 = svc.record();
      await pumpEventQueue();
      await deliverComplete('');
      expect(await f2, isNull);
    });

    test('a second record() while one is live throws', () async {
      messenger.setMockMethodCallHandler(
          channel, (call) async => call.method == 'startCapture' ? true : null);
      final svc = MethodChannelScreenCaptureService(channel: channel);
      // ignore: unawaited_futures
      svc.record();
      await pumpEventQueue(); // arm _pending before the second call
      expect(() => svc.record(), throwsStateError);
    });

    test('stop invokes stopCapture on the channel', () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return call.method == 'startCapture' ? true : null;
      });
      final svc = MethodChannelScreenCaptureService(channel: channel);
      // ignore: unawaited_futures
      svc.record();
      await Future<void>.delayed(Duration.zero);
      await svc.stop();
      expect(methods, contains('stopCapture'));
    });
  });
}
