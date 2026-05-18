import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/chip_action.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/widgets/chip_aware_ai_message_content.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

ConversationMessage _aiMessage(String content) => ConversationMessage(
  id: 'm1',
  conversationId: 'c1',
  type: MessageType.ai,
  content: content,
  timestamp: DateTime(2026),
);

void main() {
  testWidgets('renders stripped markdown and persisted chips', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ChipAwareAiMessageContent(
          message: _aiMessage('''
Visible answer.

```chips
## Explain more
Explain this in more detail.
```
'''),
          isStreaming: false,
          chipsExpected: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_richTextContaining('Visible answer'), findsAtLeastNWidgets(1));
    expect(find.text('Explain more'), findsOneWidget);
    expect(find.textContaining('```chips'), findsNothing);
  });

  testWidgets('chip tap emits the parsed chip action', (tester) async {
    ChipAction? tapped;
    await tester.pumpWidget(
      _wrap(
        ChipAwareAiMessageContent(
          message: _aiMessage('''
Answer.

```chips
## Continue
Continue from here.
```
'''),
          isStreaming: false,
          chipsExpected: false,
          onChipTap: (chip) => tapped = chip,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue'));

    expect(tapped, isNotNull);
    expect(tapped!.label, 'Continue');
    expect(tapped!.prompt, 'Continue from here.');
  });

  testWidgets('shows chip skeleton while an expected chip message streams', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        ChipAwareAiMessageContent(
          message: _aiMessage('Streaming answer'),
          isStreaming: true,
          chipsExpected: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('chip-skeleton-pill')), findsNWidgets(4));
  });
}

Finder _richTextContaining(String text) {
  return find.byWidgetPredicate(
    (widget) => widget is RichText && _spanContains(widget.text, text),
  );
}

bool _spanContains(InlineSpan span, String text) {
  if (span is TextSpan) {
    return (span.text?.contains(text) ?? false) ||
        (span.children?.any((child) => _spanContains(child, text)) ?? false);
  }
  return false;
}
