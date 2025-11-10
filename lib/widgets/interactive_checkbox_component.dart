import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/custom_widgets/custom_divider.dart';

/// Safe heading component that handles null cases gracefully
/// This is a fixed version of HTag that doesn't crash on null values
class SafeHTag extends BlockMd {
  @override
  String get expString => (r"(?<hash>#{1,6})\ (?<data>[^\n]+?)$");
  
  @override
  Widget build(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var theme = GptMarkdownTheme.of(context);
    var match = exp.firstMatch(text.trim());
    if (match == null) {
      return config.getRich(
        TextSpan(
          text: text,
          style: config.style,
        ),
      );
    }
    var hashGroup = match.namedGroup('hash');
    var dataGroup = match.namedGroup('data');
    if (hashGroup == null || dataGroup == null) {
      return config.getRich(
        TextSpan(
          text: text,
          style: config.style,
        ),
      );
    }
    var hashLength = hashGroup.length;
    if (hashLength < 1 || hashLength > 6) {
      return config.getRich(
        TextSpan(
          text: text,
          style: config.style,
        ),
      );
    }
    var conf = config.copyWith(
      style:
          [
            theme.h1,
            theme.h2,
            theme.h3,
            theme.h4,
            theme.h5,
            theme.h6,
          ][hashLength - 1],
    );
    return config.getRich(
      TextSpan(
        children: [
          ...(MarkdownComponent.generate(
            context,
            dataGroup,
            conf,
            false,
          )),
          if (hashLength == 1) ...[
            const TextSpan(
              text: "\n ",
              style: TextStyle(fontSize: 0, height: 0),
            ),
            WidgetSpan(
              child: CustomDivider(
                height: theme.hrLineThickness,
                color:
                    config.style?.color ??
                    Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Custom checkbox component that extends BlockMd and provides interactive behavior
class InteractiveCheckboxMd extends BlockMd {
  final void Function(String checkboxLine, String checkboxText, bool newValue) onToggle;

  InteractiveCheckboxMd({required this.onToggle});

  @override
  String get expString => (r"\[((?:\x|\ ))\]\ (\S[^\n]*?)$");

  @override
  Widget build(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var match = exp.firstMatch(text.trim());
    final checkboxState = "${match?[1]}" == "x";
    final checkboxText = "${match?[2]}";
    final originalLine = text.trim();
    
    return InteractiveCustomCb(
      value: checkboxState,
      textDirection: config.textDirection,
      onChanged: (newValue) {
        onToggle(originalLine, checkboxText, newValue);
      },
      child: MdWidget(context, checkboxText, false, config: config),
    );
  }
}

/// Custom checkbox widget with interactive behavior
/// Similar to CustomCb but with actual onChanged handler
class InteractiveCustomCb extends StatelessWidget {
  const InteractiveCustomCb({
    super.key,
    this.spacing = 5,
    required this.child,
    this.textDirection = TextDirection.ltr,
    required this.value,
    required this.onChanged,
  });
  
  final Widget child;
  final bool value;
  final double spacing;
  final TextDirection textDirection;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: textDirection,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        textBaseline: TextBaseline.alphabetic,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        children: [
          Text.rich(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  start: spacing,
                  end: spacing,
                ),
                child: Checkbox(
                  value: value,
                  onChanged: (newValue) {
                    if (newValue != null) {
                      onChanged(newValue);
                    }
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ),
          Flexible(child: child),
        ],
      ),
    );
  }
}

