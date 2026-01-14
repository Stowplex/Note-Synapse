import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/custom_widgets/custom_divider.dart';

// Constants
const String kBlockEditDragData = 'block_edit_drag';

// Typedefs
typedef BlockEditRequestedCallback =
    void Function(String blockContent, int occurrenceIndex);

typedef BlockOccurrenceCallback = int Function(String blockContent);

/// A wrapper widget that makes markdown blocks draggable drop targets for editing
class DragTargetBlockWrapper extends StatefulWidget {
  final Widget child;
  final String blockContent;
  final int occurrenceIndex;
  final BlockEditRequestedCallback? onBlockEditRequested;

  const DragTargetBlockWrapper({
    super.key,
    required this.child,
    required this.blockContent,
    required this.occurrenceIndex,
    this.onBlockEditRequested,
  });

  @override
  State<DragTargetBlockWrapper> createState() => _DragTargetBlockWrapperState();
}

class _DragTargetBlockWrapperState extends State<DragTargetBlockWrapper> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    // If no callback is set, don't wrap with DragTarget
    if (widget.onBlockEditRequested == null) {
      return widget.child;
    }

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) {
        debugPrint('DragTarget: onWillAcceptWithDetails data=${details.data}');
        if (details.data == kBlockEditDragData) {
          setState(() => _isHovering = true);
          return true;
        }
        return false;
      },
      onLeave: (_) {
        debugPrint('DragTarget: onLeave');
        setState(() => _isHovering = false);
      },
      onAcceptWithDetails: (details) {
        debugPrint('DragTarget: onAcceptWithDetails data=${details.data}');
        setState(() => _isHovering = false);
        if (details.data == kBlockEditDragData) {
          widget.onBlockEditRequested?.call(
            widget.blockContent,
            widget.occurrenceIndex,
          );
        }
      },
      builder: (context, candidateData, rejectedData) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          foregroundDecoration: BoxDecoration(
            border: _isHovering
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  )
                : Border.all(color: Colors.transparent, width: 2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: widget.child,
        );
      },
    );
  }
}

/// Safe heading component that handles null cases gracefully and supports drag-to-edit
class DragTargetSafeHTag extends BlockMd {
  final BlockEditRequestedCallback? onBlockEditRequested;
  final BlockOccurrenceCallback? getOccurrence;

  DragTargetSafeHTag({this.onBlockEditRequested, this.getOccurrence});

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

    Widget contentWidget;

    if (match == null) {
      contentWidget = config.getRich(TextSpan(text: text, style: config.style));
    } else {
      var hashGroup = match.namedGroup('hash');
      var dataGroup = match.namedGroup('data');
      if (hashGroup == null || dataGroup == null) {
        contentWidget = config.getRich(
          TextSpan(text: text, style: config.style),
        );
      } else {
        var hashLength = hashGroup.length;
        if (hashLength < 1 || hashLength > 6) {
          contentWidget = config.getRich(
            TextSpan(text: text, style: config.style),
          );
        } else {
          var conf = config.copyWith(
            style: [
              theme.h1,
              theme.h2,
              theme.h3,
              theme.h4,
              theme.h5,
              theme.h6,
            ][hashLength - 1],
          );
          contentWidget = config.getRich(
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
    }

    if (onBlockEditRequested != null && getOccurrence != null) {
      final occurrence = getOccurrence!(text);
      return DragTargetBlockWrapper(
        blockContent: text,
        occurrenceIndex: occurrence,
        onBlockEditRequested: onBlockEditRequested,
        child: contentWidget,
      );
    }

    return contentWidget;
  }
}

/// SafeHTag for backward compatibility if needed, but we'll use DragTargetSafeHTag
class SafeHTag extends DragTargetSafeHTag {
  SafeHTag() : super();
}

/// Custom checkbox component that extends BlockMd and provides interactive behavior
class InteractiveCheckboxMd extends BlockMd {
  final void Function(String checkboxLine, String checkboxText, bool newValue)
  onToggle;

  // Optional drag support for checkbox lines (less common but possible)
  final BlockEditRequestedCallback? onBlockEditRequested;
  final BlockOccurrenceCallback? getOccurrence;

  InteractiveCheckboxMd({
    required this.onToggle,
    this.onBlockEditRequested,
    this.getOccurrence,
  });

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

    Widget child = InteractiveCustomCb(
      value: checkboxState,
      textDirection: config.textDirection,
      onChanged: (newValue) {
        onToggle(originalLine, checkboxText, newValue);
      },
      child: MdWidget(context, checkboxText, false, config: config),
    );

    if (onBlockEditRequested != null && getOccurrence != null) {
      final occurrence = getOccurrence!(text);
      return DragTargetBlockWrapper(
        blockContent: text,
        occurrenceIndex: occurrence,
        onBlockEditRequested: onBlockEditRequested,
        child: child,
      );
    }

    return child;
  }
}

/// Custom checkbox widget with interactive behavior
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
                child: SelectionContainer.disabled(
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
          ),
          Flexible(child: child),
        ],
      ),
    );
  }
}

/// Table component with drag-to-edit support
class DragTargetTableMd extends TableMd {
  final BlockEditRequestedCallback? onBlockEditRequested;
  final BlockOccurrenceCallback? getOccurrence;

  DragTargetTableMd({this.onBlockEditRequested, this.getOccurrence});

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final child = super.build(context, text, config);

    if (onBlockEditRequested != null && getOccurrence != null) {
      final occurrence = getOccurrence!(text);
      return DragTargetBlockWrapper(
        blockContent: text,
        occurrenceIndex: occurrence,
        onBlockEditRequested: onBlockEditRequested,
        child: child,
      );
    }
    return child;
  }
}

/// BlockQuote component with drag-to-edit support
/// Note: BlockQuote extends InlineMd, so we override span() not build()
class DragTargetBlockQuoteMd extends BlockQuote {
  final BlockEditRequestedCallback? onBlockEditRequested;
  final BlockOccurrenceCallback? getOccurrence;

  DragTargetBlockQuoteMd({this.onBlockEditRequested, this.getOccurrence});

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final childSpan = super.span(context, text, config);

    if (onBlockEditRequested != null && getOccurrence != null) {
      final occurrence = getOccurrence!(text);
      // Wrap the entire span in a WidgetSpan with DragTargetBlockWrapper
      return TextSpan(
        children: [
          WidgetSpan(
            child: DragTargetBlockWrapper(
              blockContent: text,
              occurrenceIndex: occurrence,
              onBlockEditRequested: onBlockEditRequested,
              child: Text.rich(childSpan as TextSpan),
            ),
          ),
        ],
      );
    }
    return childSpan;
  }
}

/// OrderedList component with drag-to-edit support
class DragTargetOrderedListMd extends OrderedList {
  final BlockEditRequestedCallback? onBlockEditRequested;
  final BlockOccurrenceCallback? getOccurrence;

  DragTargetOrderedListMd({this.onBlockEditRequested, this.getOccurrence});

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final child = super.build(context, text, config);

    if (onBlockEditRequested != null && getOccurrence != null) {
      final occurrence = getOccurrence!(text);
      return DragTargetBlockWrapper(
        blockContent: text,
        occurrenceIndex: occurrence,
        onBlockEditRequested: onBlockEditRequested,
        child: child,
      );
    }
    return child;
  }
}

/// UnorderedList component with drag-to-edit support
class DragTargetUnorderedListMd extends UnOrderedList {
  final BlockEditRequestedCallback? onBlockEditRequested;
  final BlockOccurrenceCallback? getOccurrence;

  DragTargetUnorderedListMd({this.onBlockEditRequested, this.getOccurrence});

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final child = super.build(context, text, config);

    if (onBlockEditRequested != null && getOccurrence != null) {
      final occurrence = getOccurrence!(text);
      return DragTargetBlockWrapper(
        blockContent: text,
        occurrenceIndex: occurrence,
        onBlockEditRequested: onBlockEditRequested,
        child: child,
      );
    }
    return child;
  }
}

/// LatexMathMultiLine component with drag-to-edit support
class DragTargetLatexMd extends LatexMathMultiLine {
  final BlockEditRequestedCallback? onBlockEditRequested;
  final BlockOccurrenceCallback? getOccurrence;

  DragTargetLatexMd({this.onBlockEditRequested, this.getOccurrence});

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final child = super.build(context, text, config);

    if (onBlockEditRequested != null && getOccurrence != null) {
      final occurrence = getOccurrence!(text);
      return DragTargetBlockWrapper(
        blockContent: text,
        occurrenceIndex: occurrence,
        onBlockEditRequested: onBlockEditRequested,
        child: child,
      );
    }
    return child;
  }
}

/// IndentMd component with drag-to-edit support (for indented regular text)
class DragTargetIndentMd extends IndentMd {
  final BlockEditRequestedCallback? onBlockEditRequested;
  final BlockOccurrenceCallback? getOccurrence;

  DragTargetIndentMd({this.onBlockEditRequested, this.getOccurrence});

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final child = super.build(context, text, config);

    if (onBlockEditRequested != null && getOccurrence != null) {
      final occurrence = getOccurrence!(text);
      return DragTargetBlockWrapper(
        blockContent: text,
        occurrenceIndex: occurrence,
        onBlockEditRequested: onBlockEditRequested,
        child: child,
      );
    }
    return child;
  }
}
