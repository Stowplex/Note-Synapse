import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/xml_response_parser.dart';

void main() {
  group('parseXmlAgentResponse', () {
    group('Valid tool actions', () {
      test('parses tool action correctly', () {
        const response = '''
<MyThought>I need to search for relevant notes.</MyThought>
<Action type="tool">
<ToolName>search_notes</ToolName>
<Content>{"query": "machine learning"}</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.hasError, isFalse);
        expect(result.thought, equals('I need to search for relevant notes.'));
        expect(result.actionType, equals('tool'));
        expect(result.toolName, equals('search_notes'));
        expect(result.parsedContent, isA<Map<String, dynamic>>());
        expect(result.parsedContent['query'], equals('machine learning'));
      });

      test('parses tool action with nested JSON args', () {
        const response = '''
<MyThought>Complex query needed.</MyThought>
<Action type="tool">
<ToolName>advanced_search</ToolName>
<Content>{"query": "test", "options": {"limit": 10, "fuzzy": true}}</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.parsedContent['options']['limit'], equals(10));
      });

      test('strips code fences from JSON Content', () {
        const response = '''
<MyThought>Searching notes.</MyThought>
<Action type="tool">
<ToolName>search_notes</ToolName>
<Content>
```json
{"query": "test"}
```
</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.parsedContent['query'], equals('test'));
      });

      test('uses jsonRepair for malformed JSON in Content', () {
        const response = '''
<MyThought>Searching.</MyThought>
<Action type="tool">
<ToolName>search_notes</ToolName>
<Content>{"query": "test",}</Content>
</Action>
''';
        // Trailing comma is invalid JSON but should be repaired
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.parsedContent['query'], equals('test'));
      });
    });

    group('Valid answer actions', () {
      test('parses answer action correctly', () {
        const response = '''
<MyThought>I have all the information needed.</MyThought>
<Action type="answer">
<Content>
# Analysis Report

## Summary
The data shows positive trends.

## Details
1. First finding
2. Second finding
</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.actionType, equals('answer'));
        expect(result.content, contains('# Analysis Report'));
        expect(result.content, contains('positive trends'));
        expect(result.parsedContent, isNull); // No JSON parsing for answer
      });

      test('handles markdown with code blocks in answer', () {
        const response = r'''
<MyThought>Providing code example.</MyThought>
<Action type="answer">
<Content>
Here's the code:

```python
def hello():
    return "world"
```

And some JavaScript:

```javascript
const x = 42;
```
</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.content, contains('def hello'));
        expect(result.content, contains('const x = 42'));
      });
    });

    group('Valid think actions', () {
      test('parses think action correctly', () {
        const response = '''
<MyThought>Need to analyze existing data.</MyThought>
<Action type="think">
<Content>Looking at the execution history, I notice several patterns...</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.actionType, equals('think'));
        expect(result.content, contains('several patterns'));
      });

      test('think action allows empty content', () {
        const response = '''
<MyThought>Just thinking out loud.</MyThought>
<Action type="think">
</Action>
''';
        final result = parseXmlAgentResponse(response);

        // think allows missing Content
        expect(result.isValid, isTrue);
        expect(result.actionType, equals('think'));
      });
    });

    group('Valid spawn_subtasks actions', () {
      test('parses spawn_subtasks action correctly', () {
        const response = '''
<MyThought>This is complex, need to decompose.</MyThought>
<Action type="spawn_subtasks">
<Content>[{"description": "Research topic A", "tools": ["search"]}, {"description": "Research topic B", "tools": ["search"]}]</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.actionType, equals('spawn_subtasks'));
        expect(result.parsedContent, isA<List>());
        expect(result.parsedContent.length, equals(2));
        expect(
          result.parsedContent[0]['description'],
          equals('Research topic A'),
        );
      });

      test('handles multiline JSON array in spawn_subtasks', () {
        const response = '''
<MyThought>Decomposing task.</MyThought>
<Action type="spawn_subtasks">
<Content>
[
  {
    "description": "First subtask",
    "tools": ["tool1", "tool2"]
  },
  {
    "description": "Second subtask",
    "tools": []
  }
]
</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.parsedContent.length, equals(2));
      });
    });

    group('Thought extraction', () {
      test('extracts thought content', () {
        const response = '''
<MyThought>This is my reasoning process.</MyThought>
<Action type="answer">
<Content>Done.</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.thought, equals('This is my reasoning process.'));
      });

      test('handles missing thought element', () {
        const response = '''
<Action type="answer">
<Content>Just the answer.</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.thought, isNull);
      });

      test('handles multiline thought', () {
        const response = '''
<MyThought>
First I considered option A.
Then I realized option B is better.
Finally, I decided on option C.
</MyThought>
<Action type="answer">
<Content>C</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.thought, contains('option A'));
        expect(result.thought, contains('option B'));
        expect(result.thought, contains('option C'));
      });
    });

    group('Error cases - Missing Action', () {
      test('returns error for missing Action element', () {
        const response = '''
<MyThought>I'm thinking...</MyThought>
This is just some text without an action.
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('Missing <Action'));
      });

      test('returns error for only thought element', () {
        const response = '<MyThought>Just a thought</MyThought>';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('Missing <Action'));
      });
    });

    group('Error cases - Invalid type', () {
      test('returns error for invalid action type', () {
        const response = '''
<Action type="invalid_type">
<Content>something</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('Invalid action type'));
        expect(result.parseError, contains('invalid_type'));
      });

      test('returns error for empty type attribute', () {
        const response = '''
<Action type="">
<Content>something</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
      });
    });

    group('Error cases - Tool action', () {
      test('returns error for tool action without ToolName', () {
        const response = '''
<Action type="tool">
<Content>{"query": "test"}</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('<ToolName>'));
      });

      test('returns error for empty ToolName', () {
        const response = '''
<Action type="tool">
<ToolName></ToolName>
<Content>{"query": "test"}</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('empty'));
      });

      test('returns error when tool Content is not a JSON object', () {
        const response = '''
<Action type="tool">
<ToolName>search</ToolName>
<Content>["array", "not", "object"]</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('JSON object'));
      });

      test('returns error for completely invalid JSON in tool', () {
        const response = '''
<Action type="tool">
<ToolName>search</ToolName>
<Content>this is not json at all</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        // Error could be from JSON parsing or schema validation
        expect(
          result.parseError!.contains('JSON') ||
              result.parseError!.contains('object'),
          isTrue,
        );
      });
    });

    group('Error cases - spawn_subtasks', () {
      test('returns error when spawn_subtasks Content is not a JSON array', () {
        const response = '''
<Action type="spawn_subtasks">
<Content>{"description": "single object"}</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('JSON array'));
      });

      test('returns error when subtask is missing description field', () {
        const response = '''
<Action type="spawn_subtasks">
<Content>[{"tools": ["search"]}, {"description": "valid"}]</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('description'));
        expect(result.parseError, contains('index 0'));
      });

      test('returns error when subtask description is empty', () {
        const response = '''
<Action type="spawn_subtasks">
<Content>[{"description": "", "tools": []}]</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('empty'));
      });

      test('returns error when subtask is not an object', () {
        const response = '''
<Action type="spawn_subtasks">
<Content>["just", "strings"]</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('not a JSON object'));
      });
    });

    group('Error cases - Missing Content', () {
      test('returns error for tool without Content', () {
        const response = '''
<Action type="tool">
<ToolName>search</ToolName>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('Missing <Content>'));
      });

      test('returns error for answer without Content', () {
        const response = '''
<Action type="answer">
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('Missing <Content>'));
      });

      test('returns error for empty Content in tool', () {
        const response = '''
<Action type="tool">
<ToolName>search</ToolName>
<Content></Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('Empty'));
      });
    });

    group('Robustness', () {
      test('handles whitespace variations', () {
        const response = '''
<MyThought>   Spaced thought   </MyThought>
<Action   type = "answer"  >
  <Content>  Spaced content  </Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.thought, equals('Spaced thought'));
        expect(result.content, equals('Spaced content'));
      });

      test('handles think tags interleaved with XML', () {
        const response = '''
<think>Internal reasoning here</think>
<MyThought>Visible thought</MyThought>
<Action type="answer">
<Content>The answer</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.thought, equals('Visible thought'));
        expect(result.content, equals('The answer'));
      });

      test('handles single quotes in type attribute', () {
        const response = '''
<Action type='answer'>
<Content>Works with single quotes</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.actionType, equals('answer'));
      });

      test('handles case-insensitive element names', () {
        const response = '''
<MYTHOUGHT>uppercase thought</MYTHOUGHT>
<ACTION TYPE="answer">
<CONTENT>uppercase content</CONTENT>
</ACTION>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.thought, equals('uppercase thought'));
      });

      test('handles extra text before/after XML', () {
        const response = '''
Here's my response:

<MyThought>The thought</MyThought>
<Action type="answer">
<Content>The content</Content>
</Action>

Some trailing text.
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.thought, equals('The thought'));
      });

      test('handles special characters in content', () {
        const response = '''
<MyThought>Handling special chars</MyThought>
<Action type="answer">
<Content>
Formula: E = mc²
URL: https://example.com?foo=bar&baz=1
Symbols: < > & " '
</Content>
</Action>
''';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.content, contains('mc²'));
        expect(result.content, contains('foo=bar&baz=1'));
      });
    });

    group('Edge cases', () {
      test('handles very short valid response', () {
        const response = '<Action type="answer"><Content>x</Content></Action>';
        final result = parseXmlAgentResponse(response);

        expect(result.isValid, isTrue);
        expect(result.content, equals('x'));
      });

      test('handles empty string input', () {
        final result = parseXmlAgentResponse('');

        expect(result.hasError, isTrue);
        expect(result.parseError, contains('Missing <Action'));
      });

      test('handles input with only whitespace', () {
        final result = parseXmlAgentResponse('   \n\t  \n   ');

        expect(result.hasError, isTrue);
      });
    });
  });
}
