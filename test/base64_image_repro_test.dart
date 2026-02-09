import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';

void main() {
  testWidgets('InteractiveCheckboxMarkdown renders complex base64 image correctly', (
    WidgetTester tester,
  ) async {
    // This is a minimal valid base64 png, but with %0A injections mimicking the user's snippet
    // to see if the regex fails to capture it.
    // The "garbage" output essentially means the text itself is rendered instead of an image widget.
    const base64Data =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKwMTQAAAABJRU5ErkJggg==';

    // Simulate what might be happening: percent encoding or newlines
    // Case 1: Standard
    const inputStandard = '![test]($base64Data)';

    // Case 2: With %0A (URL encoded newline)
    const inputEncoded =
        '![test](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKwMTQAAAABJRU5ErkJggg==%0A)';

    // Case 3: With actual newlines (some md parsers break on this)
    const inputNewline =
        '![test](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKwMTQAAAABJRU5ErkJggg==\n)';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveCheckboxMarkdown(
            originalContent: '$inputStandard\n\n$inputEncoded\n\n$inputNewline',
          ),
        ),
      ),
    );

    // Allow futures to settle
    await tester.pumpAndSettle();

    // If "garbage" spills out, we expect to find the text "data:image..." in the finder.
    // If it renders as an image, the text should NOT be visible.

    expect(
      find.textContaining('data:image/png;base64'),
      findsNothing,
      reason: 'Base64 string incorrectly rendered as text',
    );

    // Also verify we have images
    expect(find.byType(Image), findsWidgets);
  });
}
