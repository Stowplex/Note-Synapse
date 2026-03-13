import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';

void main() {
  group('applyCheckboxToggle', () {
    // Regression: "牙刷" is a substring of "牙膏牙刷".
    // Before the fix, the contains() fallback would toggle the wrong item.
    test('does not match a checkbox whose text contains the target as substring',
        () {
      const content = '- [x] 毛巾\n'
          '- [x] 杯子\n'
          '- [x] 被子\n'
          '- [x] 牙膏牙刷\n'
          '- [x] 餐具和碗\n'
          '- [ ] 牙刷\n'
          '- [x] 吹风机\n'
          '- [x] 筷子和碗';

      // Simulates InteractiveCheckboxMd calling toggle for "牙刷".
      // checkboxLine as delivered by the markdown component (no "- " prefix).
      final result = applyCheckboxToggle(content, '[ ] 牙刷', '牙刷', true);

      final lines = result.split('\n');
      // "牙膏牙刷" must stay checked — it must NOT have been toggled.
      expect(lines[3], '- [x] 牙膏牙刷');
      // "牙刷" must now be checked.
      expect(lines[5], '- [x] 牙刷');
    });

    test('checks an unchecked item by exact label match', () {
      const content = '- [ ] 买牛奶\n- [x] 买面包';
      final result = applyCheckboxToggle(content, '[ ] 买牛奶', '买牛奶', true);
      expect(result, '- [x] 买牛奶\n- [x] 买面包');
    });

    test('unchecks a checked item by exact label match', () {
      const content = '- [x] 买牛奶\n- [x] 买面包';
      final result = applyCheckboxToggle(content, '[x] 买面包', '买面包', false);
      expect(result, '- [x] 买牛奶\n- [ ] 买面包');
    });

    test('handles checkboxLine that still includes the "- " prefix', () {
      const content = '- [ ] 牙刷\n- [x] 牙膏牙刷';
      // If the caller happens to include the list marker, it should still work.
      final result = applyCheckboxToggle(content, '- [ ] 牙刷', '牙刷', true);
      final lines = result.split('\n');
      expect(lines[0], '- [x] 牙刷');
      expect(lines[1], '- [x] 牙膏牙刷');
    });

    test('returns content unchanged when no matching item found', () {
      const content = '- [ ] 买牛奶';
      final result = applyCheckboxToggle(content, '[ ] 买面包', '买面包', true);
      expect(result, content);
    });

    test(
        'correctly toggles the last item when it shares characters with an earlier item',
        () {
      const content = '- [x] 餐具和碗\n- [x] 筷子和碗';
      final result = applyCheckboxToggle(content, '[x] 筷子和碗', '筷子和碗', false);
      final lines = result.split('\n');
      expect(lines[0], '- [x] 餐具和碗');
      expect(lines[1], '- [ ] 筷子和碗');
    });

    group('duplicate list items', () {
      // Without occurrenceIndex, both calls would toggle the first line.
      test('toggles the first of two identical items (occurrenceIndex 0)', () {
        const content = '- [ ] item\n- [ ] item';
        final result = applyCheckboxToggle(
          content,
          '[ ] item',
          'item',
          true,
          occurrenceIndex: 0,
        );
        expect(result, '- [x] item\n- [ ] item');
      });

      test('toggles the second of two identical items (occurrenceIndex 1)', () {
        const content = '- [ ] item\n- [ ] item';
        final result = applyCheckboxToggle(
          content,
          '[ ] item',
          'item',
          true,
          occurrenceIndex: 1,
        );
        expect(result, '- [ ] item\n- [x] item');
      });

      test('toggles the third of three identical items (occurrenceIndex 2)', () {
        const content = '- [x] item\n- [x] item\n- [ ] item';
        final result = applyCheckboxToggle(
          content,
          '[ ] item',
          'item',
          true,
          occurrenceIndex: 2,
        );
        expect(result, '- [x] item\n- [x] item\n- [x] item');
      });

      test('unchecks the first of two identical checked items', () {
        const content = '- [x] item\n- [x] item';
        final result = applyCheckboxToggle(
          content,
          '[x] item',
          'item',
          false,
          occurrenceIndex: 0,
        );
        expect(result, '- [ ] item\n- [x] item');
      });
    });
  });
}
