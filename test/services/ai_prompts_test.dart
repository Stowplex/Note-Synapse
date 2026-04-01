import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/prompts/ai_prompts.dart';
import 'package:note_synapse/services/prompts/system_prompt_builder.dart';

void main() {
  test(
    'math formula guidelines use explicit hierarchy and ban dollar math',
    () {
      final guidelines = AIPrompts.mathFormulaGuidelines;

      expect(guidelines, contains('Math Output Contract:'));
      expect(guidelines, contains('Required format:'));
      expect(guidelines, contains('Forbidden format:'));
      expect(guidelines, contains(r'Do not use $...$ for inline math'));
      expect(guidelines, contains(r'Do not use $$...$$ for display math'));
      expect(guidelines, contains(r'write \( x_i \) instead'));
      expect(guidelines, contains(r'write \[ a_i = a_{i-1} \] instead'));
    },
  );

  test('system prompt builder preserves multi-line guideline hierarchy', () {
    final prompt = SystemPromptBuilder.build(
      taskContext: 'Test context.',
      guidelines: [AIPrompts.mathFormulaGuidelines],
      now: DateTime(2026, 3, 22),
    );

    expect(prompt.content, contains('Guidelines:\nMath Output Contract:'));
    expect(
      prompt.content,
      isNot(contains('Guidelines:\n- Math Output Contract:')),
    );
    expect(
      prompt.content,
      contains('Required format:\n1. Inline math: use only'),
    );
  });
}
