import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_svg/flutter_svg.dart';
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
            return SizedBox(
              width: width,
              height: height,
              child: SvgPicture.memory(
                tempFile.bytes,
                fit: BoxFit.contain,
                placeholderBuilder: (context) => _buildLoadingPlaceholder(width, height),
              ),
            );
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
          final svgData = isBase64 ? utf8.decode(base64.decode(data)) : Uri.decodeComponent(data);
          return SizedBox(
            width: width,
            height: height,
            child: SvgPicture.string(
              svgData,
              fit: BoxFit.contain,
              placeholderBuilder: (context) => _buildLoadingPlaceholder(width, height),
            ),
          );
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

