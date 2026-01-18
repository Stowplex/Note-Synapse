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
}
