import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';

void main() {
  test('CustomATagMd regex catastrophic backtracking benchmark', () {
    final atag = CustomATagMd();
    final regex = atag.exp;

    // Pathological case 1: [text]( followed by many open parens
    final buffer = StringBuffer('[text](');
    for (var i = 0; i < 2000; i++) {
      buffer.write('(a');
    }
    // No closing paren for the main link, so it must backtrack
    final input1 = buffer.toString();

    final stopwatch = Stopwatch()..start();
    regex.firstMatch(input1);
    stopwatch.stop();
    print('Input 1 (nested parens) took ${stopwatch.elapsedMilliseconds}ms');
    expect(stopwatch.elapsedMilliseconds, lessThan(500));

    // Pathological case 2: [text]( followed by long text with repeated "group-like" sequences
    final buffer2 = StringBuffer('[text](');
    for (var i = 0; i < 5000; i++) {
      buffer2.write('part ');
    }
    final input2 = buffer2.toString();

    stopwatch.reset();
    stopwatch.start();
    regex.firstMatch(input2);
    stopwatch.stop();
    print('Input 2 (long strings) took ${stopwatch.elapsedMilliseconds}ms');
    expect(stopwatch.elapsedMilliseconds, lessThan(500));

    // Pathological case 3: Nested parens that ALMOST match
    final buffer3 = StringBuffer('[text](');
    for (var i = 0; i < 2000; i++) {
      buffer3.write('(a)');
    }
    // Missing final )
    final input3 = buffer3.toString();
    stopwatch.reset();
    stopwatch.start();
    regex.firstMatch(input3);
    stopwatch.stop();
    print('Input 3 (repeated groups) took ${stopwatch.elapsedMilliseconds}ms');
    expect(stopwatch.elapsedMilliseconds, lessThan(500));
  });
}
