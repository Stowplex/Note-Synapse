import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';

void main() {
  test('CustomATagMd regex should be non-greedy', () {
    final atag = CustomATagMd();
    final regex = atag.exp;

    const input = '[1] [the text](link)';
    final match = regex.firstMatch(input);

    expect(match, isNotNull);
    // The match should be just '[the text](link)'
    // Wait, regex is unanchored.
    // [1] matches `\[.*?\]`?
    // [1] is `[` + `1` + `]`.
    // But does it match `\(`? No.
    // So `[1]` fails.
    // Next attempt: `[the text](link)`.
    // Matches.

    expect(match!.group(0), equals('[the text](link)'));
  });

  test('CustomATagMd regex matches standard link', () {
    final atag = CustomATagMd();
    final regex = atag.exp;
    const input = '[text](link)';
    final match = regex.firstMatch(input);
    expect(match!.group(0), equals('[text](link)'));
  });
}
