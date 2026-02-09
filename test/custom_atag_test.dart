import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';

void main() {
  test('CustomATagMd regex should be non-greedy', () {
    final atag = CustomATagMd();
    final regex = atag.exp;

    const input = '[1] [hello](www.google.com)';
    final match = regex.firstMatch(input);

    expect(match, isNotNull);
    // Should match '[hello](www.google.com)' not '[1] [hello](www.google.com)'
    expect(match!.group(0), equals('[hello](www.google.com)'));
  });

  test('CustomATagMd regex matches standard link', () {
    final atag = CustomATagMd();
    final regex = atag.exp;
    const input = '[text](link)';
    final match = regex.firstMatch(input);
    expect(match!.group(0), equals('[text](link)'));
  });
}
