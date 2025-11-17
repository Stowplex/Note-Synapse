import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'logger_service.dart';
import 'user_app_service.dart';

/// Shared service responsible for rendering SVG strings to PNG bytes.
class SvgRendererService {
  SvgRendererService._();

  /// Renders the provided [svgContent] to PNG bytes using a headless WebView.
  ///
  /// The [canvasWidth] and [canvasHeight] parameters control the render surface.
  /// By default we render at 4K resolution for high quality exports. Callers
  /// can override these values (e.g. 500x500) to cap the output for inline
  /// attachments.
  static Future<Uint8List?> renderSvgToPng(
    String svgContent, {
    int canvasWidth = 3840,
    int canvasHeight = 2160,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      if (kIsWeb || !UserAppService.isWebViewSupported()) {
        LoggerService.debug(
          'SVG rendering via WebView not supported on this platform',
        );
        return null;
      }

      final completer = Completer<Uint8List?>();
      final width = canvasWidth.clamp(1, 7680);
      final height = canvasHeight.clamp(1, 4320);

      final htmlContent = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body {
      margin: 0;
      padding: 0;
      background: white;
      overflow: hidden;
    }
    #svgContainer {
      width: ${width}px;
      height: ${height}px;
      position: absolute;
      top: 0;
      left: 0;
    }
    #canvas {
      display: none;
    }
  </style>
</head>
<body>
  <div id="svgContainer">
    $svgContent
  </div>
  <canvas id="canvas" width="$width" height="$height"></canvas>
  <script>
    (function() {
      const originalConsoleLog = console.log;
      const originalConsoleError = console.error;
      const originalConsoleWarn = console.warn;
      
      function serialize(args) {
        return args.map((arg) => {
          if (typeof arg === 'string') return arg;
          try {
            return JSON.stringify(arg, null, 2);
          } catch (_) {
            return String(arg);
          }
        }).join('\\n');
      }

      console.log = (...args) => originalConsoleLog(serialize(args));
      console.error = (...args) => originalConsoleError(serialize(args));
      console.warn = (...args) => originalConsoleWarn(serialize(args));
      
      function renderSvg() {
        const container = document.getElementById('svgContainer');
        const canvas = document.getElementById('canvas');
        const ctx = canvas.getContext('2d');
        
        const svgElement = container.querySelector('svg');
        if (!svgElement) {
          console.error('SVG element not found in container');
          if (window.flutter_inappwebview?.callHandler) {
            window.flutter_inappwebview.callHandler('svgRendered', null);
          }
          return;
        }
        
        const img = new Image();
        img.onload = function() {
          try {
            ctx.fillStyle = 'white';
            ctx.fillRect(0, 0, canvas.width, canvas.height);
            
            const imgWidth = img.naturalWidth || img.width || canvas.width;
            const imgHeight = img.naturalHeight || img.height || canvas.height;
            if (imgWidth <= 0 || imgHeight <= 0) {
              console.error('Invalid image dimensions:', { imgWidth, imgHeight });
              if (window.flutter_inappwebview?.callHandler) {
                window.flutter_inappwebview.callHandler('svgRendered', null);
              }
              return;
            }
            
            const svgAspect = imgWidth / imgHeight;
            const canvasAspect = canvas.width / canvas.height;
            let drawWidth, drawHeight, drawX, drawY;
            
            if (svgAspect > canvasAspect) {
              drawWidth = canvas.width;
              drawHeight = canvas.width / svgAspect;
              drawX = 0;
              drawY = (canvas.height - drawHeight) / 2;
            } else {
              drawHeight = canvas.height;
              drawWidth = canvas.height * svgAspect;
              drawX = (canvas.width - drawWidth) / 2;
              drawY = 0;
            }
            
            ctx.drawImage(img, drawX, drawY, drawWidth, drawHeight);
            let dataUrl;
            try {
              dataUrl = canvas.toDataURL('image/png');
            } catch (error) {
              console.error('Error converting canvas to data URL:', error);
              if (window.flutter_inappwebview?.callHandler) {
                window.flutter_inappwebview.callHandler('svgRendered', null);
              }
              return;
            }
            
            console.log('SVG rendered successfully');
            if (window.flutter_inappwebview?.callHandler) {
              try {
                window.flutter_inappwebview.callHandler('svgRendered', dataUrl);
              } catch (error) {
                console.error('Error calling handler:', error);
                setTimeout(function() {
                  window.flutter_inappwebview?.callHandler?.('svgRendered', null);
                }, 100);
              }
            }
          } catch (error) {
            console.error('Error rendering SVG to canvas:', error);
            window.flutter_inappwebview?.callHandler?.('svgRendered', null);
          }
        };
        
        img.onerror = function(error) {
          console.error('Error loading SVG image:', error);
          window.flutter_inappwebview?.callHandler?.('svgRendered', null);
        };
        
        try {
          const svgString = new XMLSerializer().serializeToString(svgElement);
          const svgDataUrl = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svgString);
          img.src = svgDataUrl;
        } catch (error) {
          console.error('Error creating SVG data URL:', error);
          window.flutter_inappwebview?.callHandler?.('svgRendered', null);
        }
      }
      
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', () => setTimeout(renderSvg, 100));
      } else {
        setTimeout(renderSvg, 100);
      }
    })();
  </script>
</body>
</html>
''';

      HeadlessInAppWebView? headlessWebView;
      headlessWebView = HeadlessInAppWebView(
        initialData: InAppWebViewInitialData(
          data: htmlContent,
          mimeType: 'text/html',
          encoding: 'utf8',
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          allowFileAccess: false,
          allowContentAccess: false,
          allowFileAccessFromFileURLs: false,
        ),
        onWebViewCreated: (controller) {
          controller.addJavaScriptHandler(
            handlerName: 'svgRendered',
            callback: (args) {
              if (completer.isCompleted) {
                return;
              }

              try {
                final dataUrl = args.isNotEmpty ? args[0] as String? : null;
                if (dataUrl == null || dataUrl.isEmpty) {
                  LoggerService.debug('SVG rendering returned null or empty data URL');
                  completer.complete(null);
                  return;
                }

                final base64Data = dataUrl.split(',').last;
                final imageBytes = base64Decode(base64Data);
                LoggerService.debug(
                  'SVG successfully rendered to PNG: ${imageBytes.length} bytes',
                );
                completer.complete(Uint8List.fromList(imageBytes));
              } catch (e, stackTrace) {
                LoggerService.warning(
                  'Failed to decode SVG rendered PNG: $e',
                  error: e,
                  stackTrace: stackTrace,
                );
                completer.complete(null);
              }
            },
          );
        },
        onConsoleMessage: (controller, consoleMessage) {
          LoggerService.debug('[SVG Render] ${consoleMessage.message}');
        },
        onLoadStop: (controller, url) async {
          LoggerService.debug('SVG rendering page loaded, waiting for render...');
          await Future.delayed(const Duration(milliseconds: 500));

          if (!completer.isCompleted) {
            await Future.delayed(const Duration(milliseconds: 2000));
            if (!completer.isCompleted) {
              LoggerService.warning('SVG rendering timeout - handler not called');
              completer.complete(null);
            }
          }
        },
        onLoadError: (controller, url, code, message) {
          if (completer.isCompleted) {
            return;
          }
          LoggerService.warning(
            'Failed to load SVG rendering page: $message ($code)',
          );
          completer.complete(null);
        },
      );

      await headlessWebView.run();

      try {
        final result = await completer.future.timeout(
          timeout,
          onTimeout: () {
            LoggerService.warning('SVG rendering timeout');
            return null;
          },
        );
        return result;
      } finally {
        try {
          if (headlessWebView.isRunning()) {
            await headlessWebView.dispose();
          }
        } catch (e) {
          LoggerService.warning('Error disposing headless webview: $e');
        }
      }
    } catch (e, stackTrace) {
      LoggerService.warning(
        'Failed to render SVG to PNG: $e',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }
}

