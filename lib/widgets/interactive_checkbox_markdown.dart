import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/custom_widgets/selectable_adapter.dart';
import 'package:flutter/foundation.dart';
import 'interactive_checkbox_component.dart';

/// A wrapper widget that provides interactive checkboxes using gpt_markdown
/// with a custom checkbox component that handles state updates.
class InteractiveCheckboxMarkdown extends StatefulWidget {
  final String originalContent;
  final Function(String) onContentChanged;
  final TextStyle? style;
  final TextDirection textDirection;
  final Function(String, String)? onLinkTap;
  final int? maxLines;
  final TextOverflow? overflow;

  const InteractiveCheckboxMarkdown({
    super.key,
    required this.originalContent,
    required this.onContentChanged,
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
          widget.onContentChanged(_currentContent);
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
            widget.onContentChanged(_currentContent);
            setState(() {});
            break;
          }
        }
      }
    }
  }

  /// Custom latex builder that wraps individual math formulas in horizontal scroll views
  /// This preserves the math formula fixes from ConstrainedGptMarkdown
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

  @override
  Widget build(BuildContext context) {
    // Create custom components list with our interactive checkbox component
    final components = [
      CodeBlockMd(),
      LatexMathMultiLine(),
      NewLines(),
      BlockQuote(),
      TableMd(),
      HTag(),
      UnOrderedList(),
      OrderedList(),
      RadioButtonMd(),
      InteractiveCheckboxMd(
        onToggle: (line, text, value) => _handleCheckboxToggle(line, text, value),
      ),
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
      components: components,
    );
  }
}

