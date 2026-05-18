import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/conversation_title_directive.dart';

void main() {
  group('ConversationTitleDirective', () {
    test('parses leading directive and strips it from content', () {
      final result = ConversationTitleDirective.parseLeading('''
```conversation-title
forge-mes-cnc
```

**FORGE** compares MES and CNC cases.''');

      expect(result.hadDirective, isTrue);
      expect(result.title, 'forge-mes-cnc');
      expect(result.content, '**FORGE** compares MES and CNC cases.');
    });

    test('normalizes malformed directive slug', () {
      final result = ConversationTitleDirective.parseLeading('''
```conversation-title
FORGE / MES & CNC comparison!!!!
```
Answer.''');

      expect(result.title, 'forge-mes-cnc-comparison');
      expect(result.content, 'Answer.');
    });

    test('ignores non-leading directive blocks', () {
      final result = ConversationTitleDirective.parseLeading('''Answer first.

```conversation-title
late-title
```''');

      expect(result.hadDirective, isFalse);
      expect(result.title, isNull);
      expect(result.content, contains('late-title'));
    });

    test('fallback slug is lowercase kebab-case from response text', () {
      expect(
        ConversationTitleDirective.fallbackSlugFromResponse(
          'Entropy tradeoffs in distributed systems are subtle.',
        ),
        'entropy-tradeoffs-in-distributed-systems-are',
      );
    });
  });
}
