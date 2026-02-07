import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'logger_service.dart';

/// Service responsible for rendering Latex math formulas to images (PNG)
/// so they can be embedded in PDF exports.
class MathRendererService {
  MathRendererService._();

  /// Renders a Latex string to a PNG image.
  ///
  /// This requires a [BuildContext] to insert the [Math] widget into the tree
  /// to perform layout and painting. The widget is inserted offscreen.
  static Future<Uint8List?> renderMathToImage(
    String tex,
    BuildContext context, {
    bool isInline = false,
    TextStyle? style,
    Color? color,
    double scale = 2.0, // Higher scale for better print quality (PDF)
  }) async {
    try {
      final completer = Completer<Uint8List?>();
      final globalKey = GlobalKey();

      // We need to determine the text style to use.
      // If none provided, we use a default based on the context.
      final theme = Theme.of(context);
      final TextStyle effectiveStyle =
          style ??
          theme.textTheme.bodyMedium ??
          const TextStyle(fontSize: 14, color: Colors.black);

      final effectiveColor = color ?? effectiveStyle.color ?? Colors.black;

      // Construct the Math widget
      final mathWidget = Math.tex(
        tex,
        mathStyle: isInline ? MathStyle.text : MathStyle.display,
        textStyle: effectiveStyle.copyWith(
          fontSize:
              (effectiveStyle.fontSize ?? 14) * scale, // Scale up font size
          color: effectiveColor,
        ),
        options: MathOptions(
          sizeUnderTextStyle: MathSize.large,
          color: effectiveColor,
          fontSize: (effectiveStyle.fontSize ?? 14) * scale,
          mathFontOptions: const FontOptions(
            fontFamily: "Main",
            fontWeight: FontWeight.normal,
            fontShape: FontStyle.normal,
          ),
          textFontOptions: const FontOptions(
            fontFamily: "Main",
            fontWeight: FontWeight.normal,
            fontShape: FontStyle.normal,
          ),
          style: isInline ? MathStyle.text : MathStyle.display,
        ),
        onErrorFallback: (err) {
          LoggerService.warning('Math rendering error for "$tex": $err');
          return Text(tex, style: effectiveStyle.copyWith(color: Colors.red));
        },
      );

      // Wrap in RepaintBoundary to capture as image
      final widgetToRender = RepaintBoundary(
        key: globalKey,
        child: Container(color: Colors.transparent, child: mathWidget),
      );

      // Insert into Overlay
      final overlayState = Overlay.of(context);

      // Position it offscreen
      final overlayEntry = OverlayEntry(
        builder: (context) => Positioned(
          left: -10000,
          top: -10000, // Explicitly offscreen
          child: Material(color: Colors.transparent, child: widgetToRender),
        ),
      );

      try {
        overlayState.insert(overlayEntry);

        // Wait for next frame to ensure layout is done
        await Future.delayed(const Duration(milliseconds: 50));
        // Wait for one more frame just in case
        await Future.delayed(Duration.zero);

        // Capture image
        final boundary =
            globalKey.currentContext?.findRenderObject()
                as RenderRepaintBoundary?;

        if (boundary == null) {
          LoggerService.warning(
            'Failed to find RepaintBoundary for math rendering',
          );
          completer.complete(null);
        } else {
          // We configured scale via font size, so pixelRatio 1.0 is fine,
          // but we can also use pixelRatio here for extra sharpness if needed.
          // Since we already scaled font, 1.0 is likely enough, but let's use 2.0 for high DPI PDF.
          // Actually, if we scaled font, we might just want to capture at 1.0 relative to that size.
          // Let's use 1.0 here but rely on the font scale.
          final image = await boundary.toImage(pixelRatio: 2.0);
          final byteData = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          completer.complete(byteData?.buffer.asUint8List());
        }
      } catch (e) {
        LoggerService.warning('Error capturing math image: $e');
        completer.complete(null);
      } finally {
        overlayEntry.remove();
      }

      return completer.future;
    } catch (e, stackTrace) {
      LoggerService.error(
        'Main error in renderMathToImage: $e',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }
}
