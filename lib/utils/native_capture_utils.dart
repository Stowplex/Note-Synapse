import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativeCaptureUtils {
  NativeCaptureUtils._();

  static const MethodChannel _channel =
      MethodChannel('note_synapse/native_capture');

  static Future<Uint8List?> captureRegion({
    required double x,
    required double y,
    required double width,
    required double height,
    required double devicePixelRatio,
  }) async {
    if (!Platform.isIOS) {
      return null;
    }

    try {
      final result = await _channel.invokeMethod<Uint8List>(
        'captureRegion',
        <String, double>{
          'x': x,
          'y': y,
          'width': width,
          'height': height,
          'devicePixelRatio': devicePixelRatio,
        },
      );
      return result;
    } on PlatformException catch (error) {
      debugPrint('Native capture failed: $error');
      return null;
    } catch (error) {
      debugPrint('Native capture error: $error');
      return null;
    }
  }
}

