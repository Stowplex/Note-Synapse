import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/think_tag_utils.dart';

void main() {
  group('stripThinkTags', () {
    test('returns unchanged content when no think tags present', () {
      const input = '[{"name": "task1"}]';
      final result = stripThinkTags(input);
      expect(result.cleanedContent, input);
      expect(result.thinkContent, isNull);
    });

    test('strips single think block before JSON', () {
      const input = '''<think>reasoning here</think>
[{"name": "task1"}]''';
      final result = stripThinkTags(input);
      expect(result.cleanedContent.trim(), '[{"name": "task1"}]');
      expect(result.thinkContent, 'reasoning here');
    });

    test('strips think block after JSON', () {
      const input = '''[{"name": "task1"}]
<think>post-reasoning</think>''';
      final result = stripThinkTags(input);
      expect(result.cleanedContent.trim(), '[{"name": "task1"}]');
      expect(result.thinkContent, 'post-reasoning');
    });

    test('handles multiple think blocks', () {
      const input = '<think>first</think>text<think>second</think>more';
      final result = stripThinkTags(input);
      expect(result.cleanedContent, 'textmore');
      expect(result.thinkContent, 'first\n\nsecond');
    });

    test('handles multiline think content with JSON inside', () {
      // Based on user's real example - JSON appears both inside and outside think
      const input = '''<think>用户要求我创作一篇短篇侦探小说...
[{"name": "wrong_json"}]
</think>

我将按照您的要求创作...

[{"name": "correct_json"}]''';
      final result = stripThinkTags(input);
      // The JSON outside think tag should be preserved
      expect(result.cleanedContent, contains('correct_json'));
      expect(result.cleanedContent, isNot(contains('wrong_json')));
      expect(result.thinkContent, contains('用户要求我创作'));
    });

    test('handles case-insensitive tags', () {
      const input = '<THINK>reasoning</THINK>[1]';
      final result = stripThinkTags(input);
      expect(result.cleanedContent.trim(), '[1]');
      expect(result.thinkContent, 'reasoning');
    });

    test('handles empty think tags', () {
      const input = '<think></think>content';
      final result = stripThinkTags(input);
      expect(result.cleanedContent, 'content');
      expect(result.thinkContent, isNull); // Empty content ignored
    });

    test('handles whitespace-only think content', () {
      const input = '<think>   </think>content';
      final result = stripThinkTags(input);
      expect(result.cleanedContent, 'content');
      expect(result.thinkContent, isNull); // Whitespace-only ignored
    });
  });

  group('extractJsonFromResponse', () {
    test('extracts JSON from code block', () {
      const input = '''Some text
```json
{"tool": "search", "args": {}}
```
More text''';
      final result = extractJsonFromResponse(input);
      expect(result, '{"tool": "search", "args": {}}');
    });

    test('extracts JSON array when expectArray is true', () {
      const input = 'Text [{"name": "task1"}] more text';
      final result = extractJsonFromResponse(input, expectArray: true);
      expect(result, '[{"name": "task1"}]');
    });

    test('extracts JSON object by default', () {
      const input = 'Text {"tool": "test"} more text';
      final result = extractJsonFromResponse(input);
      expect(result, '{"tool": "test"}');
    });

    test('strips think tags before extraction', () {
      const input = '<think>reasoning</think>{"tool": "test"}';
      final result = extractJsonFromResponse(input);
      expect(result, '{"tool": "test"}');
    });

    test('handles nested JSON objects', () {
      const input = '{"tool": "test", "args": {"query": "hello"}}';
      final result = extractJsonFromResponse(input);
      expect(result, input);
    });

    test('handles strings with braces inside', () {
      const input = '{"answer": "Use { and } carefully"}';
      final result = extractJsonFromResponse(input);
      expect(result, input);
    });

    test('returns null for no JSON', () {
      const input = 'Just plain text without any JSON';
      final result = extractJsonFromResponse(input);
      expect(result, isNull);
    });
  });

  group('formatThinkForHistory', () {
    test('wraps content in think tags', () {
      const content = 'My reasoning';
      final result = formatThinkForHistory(content);
      expect(result, '<think>My reasoning</think>');
    });
  });
}
