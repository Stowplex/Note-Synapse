import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';

void main() {
  testWidgets(
    'renders inline strong markdown when no link handler is present',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: InteractiveCheckboxMarkdown(
              originalContent: 'In the context of the **FORGE** benchmark.',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('**FORGE**'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is RichText && _hasBoldText(widget.text, 'FORGE'),
        ),
        findsAtLeastNWidgets(1),
      );
    },
  );
}

bool _hasBoldText(InlineSpan span, String text) {
  if (span is TextSpan) {
    if ((span.text?.contains(text) ?? false) &&
        span.style?.fontWeight == FontWeight.bold) {
      return true;
    }
    return span.children?.any((child) => _hasBoldText(child, text)) ?? false;
  }
  return false;
}
