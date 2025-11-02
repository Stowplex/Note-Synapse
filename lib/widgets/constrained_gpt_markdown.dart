import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/custom_widgets/selectable_adapter.dart';
import 'package:flutter/foundation.dart';

/// A wrapper around GptMarkdown that handles math formula overflow
/// by providing a custom latex builder that wraps individual formulas in scrollable containers.
class ConstrainedGptMarkdown extends StatelessWidget {
  final String content;
  final TextStyle? style;
  final TextDirection? textDirection;
  final void Function(String, String)? onLinkTap;
  final int? maxLines;
  final TextOverflow? overflow;

  const ConstrainedGptMarkdown(
    this.content, {
    super.key,
    this.style,
    this.textDirection,
    this.onLinkTap,
    this.maxLines,
    this.overflow,
  });

  /// Custom latex builder that wraps individual math formulas in horizontal scroll views
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
          color: style?.color ?? Theme.of(context).colorScheme.onSurface,
          fontSize: style?.fontSize ?? Theme.of(context).textTheme.bodyMedium?.fontSize,
          mathFontOptions: FontOptions(
            fontFamily: "Main",
            fontWeight: style?.fontWeight ?? FontWeight.normal,
            fontShape: FontStyle.normal,
          ),
          textFontOptions: FontOptions(
            fontFamily: "Main",
            fontWeight: style?.fontWeight ?? FontWeight.normal,
            fontShape: FontStyle.normal,
          ),
          style: inline ? MathStyle.text : MathStyle.display,
        ),
        onErrorFallback: (err) {
          return Text(
            tex,
            textDirection: textDirection ?? TextDirection.ltr,
            style: textStyle.copyWith(
              color: (!kDebugMode) ? null : Theme.of(context).colorScheme.error,
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
        final maxHeight = constraints.maxHeight.isFinite && constraints.maxHeight > 0
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
    return GptMarkdown(
      content,
      style: style,
      textDirection: textDirection ?? TextDirection.ltr,
      onLinkTap: onLinkTap,
      maxLines: maxLines,
      overflow: overflow,
      latexBuilder: _customLatexBuilder,
    );
  }
}
