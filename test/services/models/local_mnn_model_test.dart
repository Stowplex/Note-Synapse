import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/models/local_mnn_model.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';

void main() {
  group('LocalMnnModel prompt formatting', () {
    test('formats system + user messages to ChatML', () {
      final messages = [
        PromptMessage(role: PromptRole.system, content: 'You are helpful.'),
        PromptMessage(role: PromptRole.user, content: 'Hello'),
      ];
      final result = LocalMnnModel.formatChatML(messages);
      expect(result, contains('<|im_start|>system'));
      expect(result, contains('You are helpful.'));
      expect(result, contains('<|im_end|>'));
      expect(result, contains('<|im_start|>user'));
      expect(result, contains('Hello'));
      expect(result, endsWith('<|im_start|>assistant\n'));
    });

    test('formats multi-turn conversation', () {
      final messages = [
        PromptMessage(role: PromptRole.system, content: 'System prompt'),
        PromptMessage(role: PromptRole.user, content: 'First question'),
        PromptMessage(role: PromptRole.assistant, content: 'First answer'),
        PromptMessage(role: PromptRole.user, content: 'Follow up'),
      ];
      final result = LocalMnnModel.formatChatML(messages);
      expect(result, contains('<|im_start|>assistant\nFirst answer\n<|im_end|>'));
      expect(result, contains('Follow up'));
    });

    test('handles empty system message', () {
      final messages = [
        PromptMessage(role: PromptRole.user, content: 'Hello'),
      ];
      final result = LocalMnnModel.formatChatML(messages);
      expect(result, contains('<|im_start|>user'));
      expect(result, isNot(contains('<|im_start|>system')));
    });
  });
}
