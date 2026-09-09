import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/tools/note_tools.dart';
import 'package:note_synapse/services/tools/tool_outcome.dart';
import 'package:note_synapse/services/tools/tool_param_validator.dart';

void main() {
  final modifyNotesSchema = ModifyNotesTool().inputSchema;
  final modifyNoteSchema = ModifyNoteTool().inputSchema;

  group('ToolParamValidator — trace-replay violations', () {
    test('flags integer modification (trace payload: modification: 4)', () {
      final violations = ToolParamValidator.validate({
        'modifications': [
          {'note_id': 'cc1cf667', 'modification': 4},
        ],
      }, modifyNotesSchema);

      expect(violations, hasLength(1));
      expect(violations.single.path, 'modifications[0].modification');
      expect(violations.single.expected, 'object');
      expect(violations.single.actual, contains('int (4)'));
    });

    test('flags string modification (trace payload: "Infinity")', () {
      final violations = ToolParamValidator.validate({
        'modifications': [
          {'note_id': 'cc1cf667', 'modification': 'Infinity'},
        ],
      }, modifyNotesSchema);

      expect(violations, hasLength(1));
      expect(violations.single.path, 'modifications[0].modification');
      expect(violations.single.actual, contains('string'));
    });

    test('flags explicit null content (trace payload: {"content": null})', () {
      final violations = ToolParamValidator.validate({
        'note_id': 'cc1cf667',
        'modification': {'content': null, 'tags': null},
      }, modifyNoteSchema);

      expect(violations, hasLength(2));
      expect(
        violations.map((v) => v.path),
        containsAll(['modification.content', 'modification.tags']),
      );
      expect(violations.first.actual, contains('null'));
    });

    test('flags missing required keys (trace: note_id nested inside '
        'modification)', () {
      final violations = ToolParamValidator.validate({
        'modification': {
          'note_id': 'cc1cf667',
          'content': {'action': 'replace', 'text': 'x'},
        },
      }, modifyNoteSchema);

      expect(violations.map((v) => v.path), contains('note_id'));
      expect(
        violations.firstWhere((v) => v.path == 'note_id').actual,
        'missing',
      );
    });

    test('flags enum miss on content.action', () {
      final violations = ToolParamValidator.validate({
        'note_id': 'n1',
        'modification': {
          'content': {'action': 'overwrite', 'text': 'x'},
        },
      }, modifyNoteSchema);

      expect(violations, hasLength(1));
      expect(violations.single.path, 'modification.content.action');
      expect(violations.single.expected, contains('append'));
    });
  });

  group('ToolParamValidator — fail-open leniency', () {
    test('valid modify_notes payload passes', () {
      final violations = ToolParamValidator.validate({
        'modifications': [
          {
            'note_id': 'n1',
            'modification': {
              'content': {'action': 'append', 'text': 'hello'},
            },
          },
        ],
      }, modifyNotesSchema);
      expect(violations, isEmpty);
    });

    test('bare array for link passes (runtime accepts both shapes)', () {
      final violations = ToolParamValidator.validate({
        'note_id': 'n1',
        'modification': {
          'link': [
            {'relation': 'related', 'target': 'n2'},
          ],
        },
      }, modifyNoteSchema);
      expect(violations, isEmpty);
    });

    test('extra unknown keys pass', () {
      final violations = ToolParamValidator.validate({
        'note_id': 'n1',
        'modification': {
          'content': {'action': 'append', 'text': 'x'},
        },
        'unexpected_extra': 42,
      }, modifyNoteSchema);
      expect(violations, isEmpty);
    });

    test('scalar-to-scalar mismatch passes ("5" where integer declared)', () {
      final violations = ToolParamValidator.validate(
        {'count': '5'},
        {
          'type': 'object',
          'properties': {
            'count': {'type': 'integer'},
          },
        },
      );
      expect(violations, isEmpty);
    });

    test('unknown schema keywords and type arrays pass', () {
      final violations = ToolParamValidator.validate(
        {
          'value': 4,
          'union': 4,
        },
        {
          'type': 'object',
          'properties': {
            'value': {r'$ref': '#/defs/thing'},
            'union': {
              'type': ['object', 'array'],
            },
          },
        },
      );
      expect(violations, isEmpty);
    });

    test('null, empty, or missing schema passes anything', () {
      expect(ToolParamValidator.validate({'x': 4}, null), isEmpty);
      expect(ToolParamValidator.validate({'x': 4}, {}), isEmpty);
      expect(
        ToolParamValidator.validate({'x': 4}, {'type': 'object'}),
        isEmpty,
      );
    });

    test('container where scalar declared is flagged', () {
      final violations = ToolParamValidator.validate(
        {
          'name': {'first': 'a'},
        },
        {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
          },
        },
      );
      expect(violations, hasLength(1));
      expect(violations.single.expected, 'string');
    });
  });

  group('ToolParamValidator.validateAndNormalize — coercion and lifting', () {
    test('coerces a double-encoded modification.content JSON string', () {
      final result = ToolParamValidator.validateAndNormalize(
        toolName: 'modify_note',
        params: {
          'note_id': 'cc1cf667',
          'modification': {
            'content':
                '{"action": "replace_text", "old_text": "| |", '
                '"new_text": "| [x] |"}',
          },
        },
        inputSchema: modifyNoteSchema,
      );

      expect(result.failure, isNull);
      final content =
          (result.params['modification'] as Map)['content'] as Map;
      expect(content['action'], 'replace_text');
      expect(content['new_text'], '| [x] |');
    });

    test('coerces the verbatim mangled trace payload (double-encoded object '
        'with a trailing "}},note_id:" tail) via repairJson', () {
      const mangled =
          '{\n  "action": "replace_text",\n  "old_text": '
          '"|        | 小猪皮皮的游乐园之梦 |   1    |",\n  "new_text": '
          '"| [x]      | 小猪皮皮的游乐园之梦 |   1    |",\n  "section": '
          '"## 2026-08-03"\n}},note_id:';
      final result = ToolParamValidator.validateAndNormalize(
        toolName: 'modify_note',
        params: {
          'note_id': 'cc1cf667',
          'modification': {'content': mangled},
        },
        inputSchema: modifyNoteSchema,
      );

      expect(result.failure, isNull, reason: result.failure?.message);
      final content =
          (result.params['modification'] as Map)['content'] as Map;
      expect(content['action'], 'replace_text');
      expect(content['old_text'], contains('小猪皮皮的游乐园之梦'));
      expect(content['section'], '## 2026-08-03');
    });

    test('lifts misplaced content keys from the modification level '
        '(verbatim trace attempt 2 shape)', () {
      final result = ToolParamValidator.validateAndNormalize(
        toolName: 'modify_note',
        params: {
          'note_id': 'cc1cf667',
          'modification': {
            'NOTE_ID': 'cc1cf667',
            'content': '|        | 小猪皮皮的游乐园之梦 |   1    |',
            'action': 'replace_text',
            'old_text': '|        | 小猪皮皮的游乐园之梦 |   1    |',
            'new_text': '| [x]      | 小猪皮皮的游乐园之梦 |   1    |',
          },
        },
        inputSchema: modifyNoteSchema,
      );

      expect(result.failure, isNull, reason: result.failure?.message);
      final modification = result.params['modification'] as Map;
      final content = modification['content'] as Map;
      expect(content['action'], 'replace_text');
      expect(content['old_text'], contains('小猪皮皮'));
      // The lifted keys are gone from the modification level; the stray
      // string content was superseded by the replace_text keys.
      expect(modification.containsKey('old_text'), isFalse);
      expect(content.containsKey('text'), isFalse);
    });

    test('a stray string content becomes text when only an action is '
        'misplaced', () {
      final result = ToolParamValidator.validateAndNormalize(
        toolName: 'modify_note',
        params: {
          'note_id': 'n1',
          'modification': {'content': 'hello world', 'action': 'append'},
        },
        inputSchema: modifyNoteSchema,
      );

      expect(result.failure, isNull, reason: result.failure?.message);
      final content =
          (result.params['modification'] as Map)['content'] as Map;
      expect(content['action'], 'append');
      expect(content['text'], 'hello world');
    });

    test('lifting does not fire when content is already a valid object', () {
      final result = ToolParamValidator.validateAndNormalize(
        toolName: 'modify_note',
        params: {
          'note_id': 'n1',
          'modification': {
            'content': {'action': 'append', 'text': 'x'},
            'section': '## Should stay put? No — section IS a content key',
          },
        },
        inputSchema: modifyNoteSchema,
      );
      // content is a Map, so nothing is lifted or altered.
      expect(result.failure, isNull);
      final modification = result.params['modification'] as Map;
      expect((modification['content'] as Map)['text'], 'x');
      expect(modification.containsKey('section'), isTrue);
    });

    test('non-JSON strings for object properties are still rejected', () {
      final result = ToolParamValidator.validateAndNormalize(
        toolName: 'modify_notes',
        params: {
          'modifications': [
            {'note_id': 'n1', 'modification': 'Infinity'},
          ],
        },
        inputSchema: modifyNotesSchema,
      );
      expect(result.failure, isNotNull);
      expect(result.failure!.code, ToolOutcome.codeInvalidArgument);
      // Original params returned untouched on failure.
      expect(
        ((result.params['modifications'] as List).single
            as Map)['modification'],
        'Infinity',
      );
    });

    test('coerces a JSON-encoded array string for an array property', () {
      final result = ToolParamValidator.validateAndNormalize(
        toolName: 'modify_notes',
        params: {
          'modifications':
              '[{"note_id": "n1", "modification": '
              '{"content": {"action": "append", "text": "x"}}}]',
        },
        inputSchema: modifyNotesSchema,
      );
      expect(result.failure, isNull, reason: result.failure?.message);
      expect(result.params['modifications'], isA<List>());
    });

    test('normalization never mutates the caller\'s params', () {
      final original = {
        'note_id': 'n1',
        'modification': {
          'content': '{"action": "append", "text": "x"}',
        },
      };
      ToolParamValidator.validateAndNormalize(
        toolName: 'modify_note',
        params: original,
        inputSchema: modifyNoteSchema,
      );
      expect(
        (original['modification'] as Map)['content'],
        isA<String>(),
        reason: 'input map must stay untouched',
      );
    });
  });

  group('ToolParamValidator.validationFailure', () {
    test('produces a parseable invalid_argument envelope with path, hint, '
        'and no raw cast text', () {
      final failure = ToolParamValidator.validationFailure(
        toolName: 'modify_notes',
        params: {
          'modifications': [
            {'note_id': 'n1', 'modification': 4},
          ],
        },
        inputSchema: modifyNotesSchema,
      );

      expect(failure, isNotNull);
      expect(failure!.code, ToolOutcome.codeInvalidArgument);
      expect(failure.retryable, isFalse);
      expect(failure.message, contains('modify_notes'));
      expect(failure.message, contains('modifications[0].modification'));
      expect(failure.message, contains('expected object'));
      expect(failure.message, isNot(contains('is not a subtype')));

      final serialized = failure.serialize();
      final roundTripped = ToolOutcome.tryParseFailure(serialized);
      expect(roundTripped, isNotNull);
      expect(roundTripped!.code, ToolOutcome.codeInvalidArgument);
    });

    test('returns null for valid params', () {
      final failure = ToolParamValidator.validationFailure(
        toolName: 'modify_note',
        params: {
          'note_id': 'n1',
          'modification': {
            'content': {'action': 'append', 'text': 'x'},
          },
        },
        inputSchema: modifyNoteSchema,
      );
      expect(failure, isNull);
    });

    test('includes example when the schema declares one', () {
      final failure = ToolParamValidator.validationFailure(
        toolName: 'demo',
        params: {'config': 3},
        inputSchema: {
          'type': 'object',
          'properties': {
            'config': {'type': 'object'},
          },
          'examples': [
            {
              'config': {'key': 'value'},
            },
          ],
        },
      );
      expect(failure, isNotNull);
      expect(failure!.message, contains('Example: {"config":{"key":"value"}}'));
    });
  });

  group('ToolOutcome normalization', () {
    test('native error map becomes typed failure with code', () {
      final outcome = ToolOutcome.fromNativeResult('modify_note', {
        'error': 'User denied the note modification.',
        'code': 'user_denied',
      });
      expect(outcome.success, isFalse);
      expect(outcome.isUserDenied, isTrue);
    });

    test('native error map without code defaults to tool_error', () {
      final outcome = ToolOutcome.fromNativeResult('x', {'error': 'boom'});
      expect(outcome.success, isFalse);
      expect(outcome.code, ToolOutcome.codeToolError);
    });

    test('native success map is JSON-encoded, not Dart Map.toString()', () {
      final outcome = ToolOutcome.fromNativeResult('x', {
        'status': 'success',
        'modified_count': 2,
      });
      expect(outcome.success, isTrue);
      expect(outcome.message, '{"status":"success","modified_count":2}');
    });

    test('native string result passes through raw', () {
      final outcome = ToolOutcome.fromNativeResult('x', '# Skill: foo\nbody');
      expect(outcome.success, isTrue);
      expect(outcome.message, '# Skill: foo\nbody');
    });

    test('AI tool success:false becomes a failure', () {
      final outcome = ToolOutcome.fromAiToolResult(
        'log_reading_session',
        '{"success": false, "message": "CSRF token expired"}',
      );
      expect(outcome.success, isFalse);
      expect(outcome.code, ToolOutcome.codeToolError);
      expect(outcome.message, contains('CSRF token expired'));
    });

    test('AI tool success:true stays success', () {
      final outcome = ToolOutcome.fromAiToolResult(
        'log_reading_session',
        '{"success": true, "message": "Logged"}',
      );
      expect(outcome.success, isTrue);
    });

    test('tryParseFailure ignores ordinary text mentioning errors', () {
      expect(ToolOutcome.tryParseFailure('Result contains error text'), isNull);
      expect(ToolOutcome.tryParseFailure('{"error": "just a string"}'), isNull);
      expect(ToolOutcome.tryParseFailure('{"success": true}'), isNull);
    });

    test('tryParseFailure ignores error-shaped tool payloads lacking the '
        'harness sentinel (e.g. an API proxy returning an upstream error '
        'body as its successful result)', () {
      expect(
        ToolOutcome.tryParseFailure(
          '{"error": {"code": "404", "message": "user not found"}}',
        ),
        isNull,
      );
    });

    test('serialized failure round-trips code, retryable, and data', () {
      const failure = ToolOutcome.failure(
        code: ToolOutcome.codeTransportError,
        message: 'Connection refused',
        retryable: true,
        data: {'attempt': 1},
      );
      final parsed = ToolOutcome.tryParseFailure(failure.serialize());
      expect(parsed, isNotNull);
      expect(parsed!.code, ToolOutcome.codeTransportError);
      expect(parsed.retryable, isTrue);
      expect(parsed.data, {'attempt': 1});
      expect(parsed.message, 'Connection refused');
    });
  });
}
