import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/think_tag_utils.dart';

void main() {
  group('isAgentAction', () {
    test('returns true for answer action', () {
      final json = {'answer': 'This is the answer'};
      expect(isAgentAction(json), isTrue);
    });

    test('returns true for tool action', () {
      final json = {
        'tool': 'search',
        'args': {'query': 'test'},
      };
      expect(isAgentAction(json), isTrue);
    });

    test('returns true for think action', () {
      final json = {'think': 'I need to think'};
      expect(isAgentAction(json), isTrue);
    });

    test('returns true for spawn_subtasks action', () {
      final json = {
        'spawn_subtasks': [
          {'description': 'subtask 1'},
        ],
      };
      expect(isAgentAction(json), isTrue);
    });

    test('returns false for generic data object', () {
      final json = {'data': 'some value', 'id': 123};
      expect(isAgentAction(json), isFalse);
    });

    test('returns false for empty object', () {
      final json = <String, dynamic>{};
      expect(isAgentAction(json), isFalse);
    });

    test(
      'returns false for object with keys resembling actions but not exact',
      () {
        // e.g. "answers" implies a list of answers, not the "answer" action
        final json = {
          'answers': ['a', 'b'],
        };
        expect(isAgentAction(json), isFalse);
      },
    );
  });

  group('extractJsonFromResponse - repro cases', () {
    test('extracts answer from raw JSON with embedded code blocks', () {
      // Repro from user: LLM returns JSON with markdown answer containing code blocks
      // NOTE: Using raw JSON (not wrapped in ```json) because nested fences conflict
      const response = r'''
My thought: I have all the necessary information.

{
  "answer": "# Comprehensive Analysis\n\n## Token Management\n\n```typescript\nexport const DEFAULT_TOKEN_LIMIT = 1_048_576;\n```\n\n## Conclusion\n\nThe system implements efficient token management."
}
''';

      final json = extractJsonFromResponse(response);
      expect(json, isNotNull);
      expect(json, contains('"answer"'));
      // Should contain the code block content
      expect(json, contains('DEFAULT_TOKEN_LIMIT'));
    });

    test('handles raw JSON answer with nested Python code blocks', () {
      // Edge case: JSON containing markdown with nested code fences
      // NOTE: Using raw JSON (not wrapped in ```json) because nested fences conflict
      const response = r'''
{
  "answer": "# Code Example\n\n```python\ndef hello():\n    return result\n```\n\nThe above shows a basic function."
}
''';

      final json = extractJsonFromResponse(response);
      expect(json, isNotNull);
      expect(json, contains('"answer"'));
      expect(json, contains('def hello'));
    });

    test('handles JSON with multiple nested code blocks in answer', () {
      const response = r'''
My thought: Research complete.

{
  "answer": "## Architecture Overview\n\n### Server Code\n```javascript\nconst server = express();\nserver.listen(3000);\n```\n\n### Client Code\n```typescript\nimport { Client } from './client';\nconst c = new Client();\n```\n\nBoth components work together."
}
''';

      final json = extractJsonFromResponse(response);
      expect(json, isNotNull);
      expect(json, contains('"answer"'));
    });

    test('correctly extracts answer value (not full JSON wrapper)', () {
      // This tests that extractJsonFromResponse gives us parseable JSON
      // and the consumer can extract just the answer value
      const response = r'''
```json
{
  "answer": "The final result is ready."
}
```
''';

      final json = extractJsonFromResponse(response);
      expect(json, isNotNull);

      // Simulate what agent_service does after extraction
      // It uses jsonDecode (or repairJson) then accesses ['answer']
      // Here we just verify the structure is recognized
      expect(json, contains('"answer"'));
      expect(json, contains('The final result is ready'));
    });

    test('handles very long answer with special characters', () {
      // Real-world case: answer contains URLs, special chars, newlines
      const response = r'''
{
  "answer": "# Report\n\nSee [documentation](https://example.com/doc?foo=bar&baz=1).\n\n> [!NOTE]\n> Important info here.\n\nFormula: \\( E = mc^2 \\)"
}
''';

      final json = extractJsonFromResponse(response);
      expect(json, isNotNull);
      expect(json, contains('"answer"'));
      expect(json, contains('example.com'));
    });
  });
}
