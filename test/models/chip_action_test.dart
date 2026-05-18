import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/chip_action.dart';

void main() {
  group('ChipAction', () {
    test('stores label and prompt', () {
      const c = ChipAction(label: 'explain transformer', prompt: 'You are a tutor...');
      expect(c.label, 'explain transformer');
      expect(c.prompt, 'You are a tutor...');
    });

    test('equality is by value (label + prompt)', () {
      const a = ChipAction(label: 'L', prompt: 'P');
      const b = ChipAction(label: 'L', prompt: 'P');
      const c = ChipAction(label: 'L', prompt: 'P-different');
      const d = ChipAction(label: 'L-different', prompt: 'P');
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
    });

    test('hashCode matches for equal instances', () {
      const a = ChipAction(label: 'L', prompt: 'P');
      const b = ChipAction(label: 'L', prompt: 'P');
      expect(a.hashCode, b.hashCode);
    });

    test('toString does not leak the full prompt content', () {
      const c = ChipAction(label: 'L', prompt: 'a very secret persona prompt');
      // toString reports label + prompt length, not prompt text.
      final s = c.toString();
      expect(s, contains('L'));
      expect(s, contains('28c')); // length of 'a very secret persona prompt'
      expect(s, isNot(contains('persona')));
    });
  });
}
