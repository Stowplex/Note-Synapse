import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gpt_markdown/custom_widgets/selectable_adapter.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../utils/synapse_temp_utils.dart';
import 'interactive_checkbox_component.dart';

/// A wrapper widget that provides interactive checkboxes using gpt_markdown
/// with a custom checkbox component that handles state updates.
class InteractiveCheckboxMarkdown extends StatefulWidget {
  final String originalContent;
  final Function(String)? onContentChanged;
  final TextStyle? style;
  final TextDirection textDirection;
  final Function(String, String)? onLinkTap;
  final int? maxLines;
  final TextOverflow? overflow;

  const InteractiveCheckboxMarkdown({
    super.key,
    required this.originalContent,
    this.onContentChanged,
    this.style,
    this.textDirection = TextDirection.ltr,
    this.onLinkTap,
    this.maxLines,
    this.overflow,
  });

  @override
  State<InteractiveCheckboxMarkdown> createState() =>
      _InteractiveCheckboxMarkdownState();
}

class _InteractiveCheckboxMarkdownState
    extends State<InteractiveCheckboxMarkdown> {
  late String _currentContent;

  @override
  void initState() {
    super.initState();
    _currentContent = widget.originalContent;
  }

  @override
  void didUpdateWidget(InteractiveCheckboxMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.originalContent != widget.originalContent) {
      _currentContent = widget.originalContent;
    }
  }

  void _handleCheckboxToggle(String checkboxLine, String checkboxText, bool newValue) {
    // Find the checkbox line in the content and update it
    // checkboxLine contains the original matched line (trimmed), checkboxText is the text after [x] or [ ]
    final lines = _currentContent.split('\n');
    
    // Match checkboxes with pattern: [ ] or [x] optionally prefixed with - 
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmedLine = line.trim();
      
      // Try to match the checkbox line by comparing the trimmed versions
      // The checkboxLine passed from the component is already trimmed
      if (trimmedLine == checkboxLine) {
        // This is the exact line - update it
        final checkboxMatch = RegExp(r'^(\s*)(?:-\s+)?\[([ x])\]\s+(.+)$').firstMatch(line);
        if (checkboxMatch != null) {
          final indent = checkboxMatch.group(1) ?? '';
          final textAfterCheckbox = checkboxMatch.group(3) ?? '';
          final hasDashPrefix = trimmedLine.startsWith('-');
          final dashPrefix = hasDashPrefix ? '- ' : '';
          final newCheckbox = newValue ? 'x' : ' ';
          lines[i] = '${indent}$dashPrefix[$newCheckbox] ${textAfterCheckbox}';
          
          _currentContent = lines.join('\n');
          widget.onContentChanged?.call(_currentContent);
          setState(() {});
          break;
        }
      } else {
        // Try to match by the text content after the checkbox
        // This handles cases where there might be slight differences in whitespace
        final checkboxMatch = RegExp(r'^(\s*)(?:-\s+)?\[([ x])\]\s+(.+)$').firstMatch(line);
        if (checkboxMatch != null) {
          final textAfterCheckbox = checkboxMatch.group(3) ?? '';
          // Match by checking if the text portions match
          // Compare the raw text (without markdown processing)
          if (textAfterCheckbox.trim() == checkboxText.trim() ||
              (textAfterCheckbox.trim().isNotEmpty && 
               checkboxText.trim().isNotEmpty &&
               textAfterCheckbox.contains(checkboxText.trim()))) {
            // Update the checkbox state
            final indent = checkboxMatch.group(1) ?? '';
            final hasDashPrefix = trimmedLine.startsWith('-');
            final dashPrefix = hasDashPrefix ? '- ' : '';
            final newCheckbox = newValue ? 'x' : ' ';
            lines[i] = '${indent}$dashPrefix[$newCheckbox] ${textAfterCheckbox}';
            
            _currentContent = lines.join('\n');
            widget.onContentChanged?.call(_currentContent);
            setState(() {});
            break;
          }
        }
      }
    }
  }

  /// Custom latex builder that wraps individual math formulas in horizontal scroll views
  /// This handles long formulas by allowing horizontal scrolling
  Widget _customLatexBuilder(
    BuildContext context,
    String tex,
    TextStyle textStyle,
    bool inline,
  ) {
    final mathWidget = SelectableAdapter(
      selectedText: tex,
      child: Math.tex(
        tex,
        textStyle: textStyle,
        mathStyle: inline ? MathStyle.text : MathStyle.display,
        textScaleFactor: 1,
        settings: const TexParserSettings(strict: Strict.ignore),
        options: MathOptions(
          sizeUnderTextStyle: MathSize.large,
          color: widget.style?.color ?? Theme.of(context).colorScheme.onSurface,
          fontSize: widget.style?.fontSize ??
              Theme.of(context).textTheme.bodyMedium?.fontSize,
          mathFontOptions: FontOptions(
            fontFamily: "Main",
            fontWeight: widget.style?.fontWeight ?? FontWeight.normal,
            fontShape: FontStyle.normal,
          ),
          textFontOptions: FontOptions(
            fontFamily: "Main",
            fontWeight: widget.style?.fontWeight ?? FontWeight.normal,
            fontShape: FontStyle.normal,
          ),
          style: inline ? MathStyle.text : MathStyle.display,
        ),
        onErrorFallback: (err) {
          return Text(
            tex,
            textDirection: widget.textDirection,
            style: textStyle.copyWith(
              color: (!kDebugMode)
                  ? null
                  : Theme.of(context).colorScheme.error,
            ),
          );
        },
      ),
    );

    // Wrap the math widget in a horizontal scrollable container
    // This allows long formulas to scroll without affecting the rest of the content
    // Use LayoutBuilder to ensure proper constraints are provided to the child
    // This prevents layout errors when selection containers try to access widget sizes
    // The key is providing finite vertical constraints even when the parent has infinite height
    return LayoutBuilder(
      builder: (context, constraints) {
        // Provide a finite maxHeight to prevent layout issues with transforms in selection containers
        // Use a large but finite value if constraints are unbounded
        final maxHeight = constraints.maxHeight.isFinite &&
                constraints.maxHeight > 0
            ? constraints.maxHeight
            : 10000.0; // Large finite value as fallback

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.hardEdge,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: maxHeight,
            ),
            child: mathWidget,
          ),
        );
      },
    );
  }

  /// Custom image builder that handles data URLs and synapsetemp:/// URIs.
  ///
  /// - synapsetemp:/// URIs load files from the app's cache directory
  /// - data: URIs are decoded and rendered from memory
  /// - all other URIs fall back to network loading
  Widget _customImageBuilder(
    BuildContext context,
    String url, {
    double? width,
    double? height,
  }) {
    if (SynapseTempUtils.isSynapseTempUri(url)) {
      return FutureBuilder<SynapseTempFile>(
        future: SynapseTempUtils.loadFile(url),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _buildLoadingPlaceholder(width, height);
          }

          if (snapshot.hasError || !snapshot.hasData) {
            if (snapshot.hasError && kDebugMode) {
              debugPrint('SynapseTemp image load error: ${snapshot.error}');
            }
            return _buildPlaceholder(width, height, 'Unable to load temporary image');
          }

          final tempFile = snapshot.data!;
          final mime = tempFile.mimeType.toLowerCase();

          if (mime == 'image/svg+xml') {
            // Render SVG using InAppWebView for better compatibility and edge case handling
            try {
              final svgContent = utf8.decode(tempFile.bytes);
              return _buildSvgWebView(svgContent, width, height);
            } catch (e) {
              if (kDebugMode) {
                debugPrint('Error decoding SVG content: $e');
              }
              return _buildPlaceholder(width, height, 'Failed to decode SVG');
            }
          }

          if (mime.startsWith('image/')) {
            return SizedBox(
              width: width,
              height: height,
              child: Image.memory(
                tempFile.bytes,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return _buildPlaceholder(width, height, 'Failed to render image');
                },
              ),
            );
          }

          return _buildPlaceholder(width, height, 'Unsupported image type: ${tempFile.mimeType}');
        },
      );
    }

    if (url.startsWith('data:')) {
      try {
        final uri = Uri.parse(url);
        final dataString = uri.toString();

        final commaIndex = dataString.indexOf(',');
        if (commaIndex == -1) {
          return _buildPlaceholder(width, height, 'Invalid data URL format');
        }

        final header = dataString.substring(5, commaIndex); // Skip 'data:'
        final data = dataString.substring(commaIndex + 1);

        String mimetype = 'text/plain';
        bool isBase64 = false;

        if (header.isNotEmpty) {
          final parts = header.split(';');
          if (parts.isNotEmpty && parts[0].isNotEmpty) {
            mimetype = parts[0];
          }
          isBase64 = parts.any((p) => p.toLowerCase() == 'base64');
        }

        if (mimetype.toLowerCase() == 'image/svg+xml') {
          // Render SVG using InAppWebView for better compatibility and edge case handling
          try {
            final svgContent = isBase64 ? utf8.decode(base64.decode(data)) : Uri.decodeComponent(data);
            return _buildSvgWebView(svgContent, width, height);
          } catch (e) {
            if (kDebugMode) {
              debugPrint('Error decoding SVG from data URL: $e');
            }
            return _buildPlaceholder(width, height, 'Failed to decode SVG');
          }
        }

        if (mimetype.startsWith('image/')) {
          if (!isBase64) {
            return _buildPlaceholder(width, height, 'Only base64 encoded images are supported');
          }

          final bytes = base64.decode(data);
          return SizedBox(
            width: width,
            height: height,
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return _buildPlaceholder(width, height, 'Failed to render image');
              },
            ),
          );
        }

        return _buildPlaceholder(width, height, 'Unsupported image type: $mimetype');
      } catch (e) {
        return _buildPlaceholder(width, height, 'Error loading image: $e');
      }
    }

    return SizedBox(
      width: width,
      height: height,
      child: Image(
        image: NetworkImage(url),
        loadingBuilder: (
          BuildContext context,
          Widget child,
          ImageChunkEvent? loadingProgress,
        ) {
          if (loadingProgress == null) {
            return child;
          }
          return Center(
            child: CircularProgressIndicator(
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded /
                      loadingProgress.expectedTotalBytes!
                  : null,
            ),
          );
        },
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          return const Icon(Icons.broken_image, size: 48);
        },
      ),
    );
  }

  /// Builds a placeholder widget for unsupported or error cases.
  Widget _buildPlaceholder(double? width, double? height, String message) {
    return SizedBox(
      width: width,
      height: height ?? 100,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceVariant,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingPlaceholder(double? width, double? height) {
    return SizedBox(
      width: width,
      height: height ?? 100,
      child: const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  /// Creates an HTML wrapper for SVG content to render in WebView.
  /// This ensures proper scaling and responsive behavior with pan and zoom support.
  String _createSvgHtmlWrapper(String svgContent) {
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes">
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    html, body {
      width: 100%;
      height: 100%;
      overflow: hidden;
    }
    body {
      display: flex;
      align-items: center;
      justify-content: center;
    }
    #svg-container {
      width: 100%;
      height: 100%;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    svg {
      max-width: 100%;
      max-height: 100%;
      width: auto;
      height: auto;
      display: block;
    }
  </style>
  <script src="synapse://svg.pan-zoom.min.js"></script>
</head>
<body>
  <div id="svg-container">
    $svgContent
  </div>
  <script>
    // Initialize svg-pan-zoom after the DOM is loaded
    document.addEventListener('DOMContentLoaded', function() {
      const svgElement = document.querySelector('svg');
      if (svgElement && typeof svgPanZoom !== 'undefined') {
        svgPanZoom(svgElement, {
          zoomEnabled: true,
          controlIconsEnabled: false,
          fit: true,
          center: true,
          minZoom: 0.1,
          maxZoom: 10,
          zoomScaleSensitivity: 0.3,
          dblClickZoomEnabled: true,
          mouseWheelZoomEnabled: true,
          preventMouseEventsDefault: true,
        });
      }
    });
  </script>
</body>
</html>
''';
  }

  /// Builds an InAppWebView widget to render SVG content with pan and zoom support.
  Widget _buildSvgWebView(String svgContent, double? width, double? height) {
    final htmlContent = _createSvgHtmlWrapper(svgContent);
    
    // Determine the height for the WebView
    // If height is not provided, calculate based on width with a reasonable aspect ratio
    final webViewHeight = height ?? (width != null ? width * 0.75 : 300.0);
    
    return SizedBox(
      width: width,
      height: webViewHeight,
      child: InAppWebView(
        initialData: InAppWebViewInitialData(
          data: htmlContent,
          mimeType: 'text/html',
          encoding: 'utf8',
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          supportZoom: true,
          transparentBackground: true,
          disableContextMenu: false,
          horizontalScrollBarEnabled: false,
          verticalScrollBarEnabled: false,
          resourceCustomSchemes: ['synapse'],
          useHybridComposition: true,
        ),
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<VerticalDragGestureRecognizer>(
            () => VerticalDragGestureRecognizer(),
          ),
          Factory<HorizontalDragGestureRecognizer>(
            () => HorizontalDragGestureRecognizer(),
          ),
          Factory<ScaleGestureRecognizer>(
            () => ScaleGestureRecognizer(),
          ),
          Factory<TapGestureRecognizer>(
            () => TapGestureRecognizer(),
          ),
          Factory<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(),
          ),
        },
        onLoadResourceWithCustomScheme: (controller, request) async {
          if (request.url.scheme.toLowerCase() == 'synapse') {
            final data = await rootBundle.loadString("assets/scripts/${request.url.host}");
            return CustomSchemeResponse(
              contentType: 'application/javascript',
              data: Uint8List.fromList(utf8.encode(data)),
            );
          }
          return null;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Create custom components list with our safe HTag and optional interactive checkbox component
    final components = [
      CodeBlockMd(),
      LatexMathMultiLine(),
      NewLines(),
      BlockQuote(),
      TableMd(),
      SafeHTag(), // Use our safe version instead of HTag
      UnOrderedList(),
      OrderedList(),
      RadioButtonMd(),
      if (widget.onContentChanged != null)
        InteractiveCheckboxMd(
          onToggle: (line, text, value) => _handleCheckboxToggle(line, text, value),
        )
      else
        CheckBoxMd(), // Use regular checkbox if not interactive
      HrLine(),
      IndentMd(),
    ];

    return GptMarkdown(
      _currentContent,
      style: widget.style,
      textDirection: widget.textDirection,
      onLinkTap: widget.onLinkTap,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      latexBuilder: _customLatexBuilder,
      imageBuilder: _customImageBuilder,
      components: components,
    );
  }
}

