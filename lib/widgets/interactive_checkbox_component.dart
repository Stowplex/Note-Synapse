import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';

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
    var match = this.exp.firstMatch(text.trim());
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

