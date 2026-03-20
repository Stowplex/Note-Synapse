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

    test('injects toolSchemaBlock into system message', () {
      final messages = [
        PromptMessage(role: PromptRole.system, content: 'You are helpful.'),
        PromptMessage(role: PromptRole.user, content: 'Hello'),
      ];
      final result = LocalMnnModel.formatChatML(messages, toolSchemaBlock: 'TOOLS_HERE');
      expect(result, contains('You are helpful.\n\nTOOLS_HERE'));
      // Ensure it's inside the system block, before im_end
      final systemBlock = result.split('<|im_end|>').first;
      expect(systemBlock, contains('TOOLS_HERE'));
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

  group('LocalMnnModel tool call parsing', () {
    test('parses valid JSON tool call from response', () {
      final response = 'Let me search for that.\n{"name": "call_tool", "arguments": {"service_name": "mcp", "tool_name": "search", "params": {"query": "test"}}}';
      final result = LocalMnnModel.parseToolCalls(response);
      expect(result.functionCalls, isNotNull);
      expect(result.functionCalls!.length, 1);
      expect(result.functionCalls![0]['name'], 'call_tool');
      expect(result.functionCalls![0]['args']['tool_name'], 'search');
      expect(result.text, 'Let me search for that.');
    });

    test('handles malformed JSON with json_repair', () {
      // Missing closing quote on "test
      final response = '{"name": "call_tool", "arguments": {"service_name": "mcp", "tool_name": "search", "params": {"query": "test}}}';
      final result = LocalMnnModel.parseToolCalls(response);
      // json_repair should fix the missing quote
      expect(result.functionCalls, isNotNull);
    });

    test('returns plain text when no tool call found', () {
      final response = 'This is just a regular response with no tool calls.';
      final result = LocalMnnModel.parseToolCalls(response);
      expect(result.functionCalls, isNull);
      expect(result.text, response);
    });

    test('parses tool call with braces inside string values', () {
      final response = '{"name": "call_tool", "arguments": {"service_name": "mcp", "tool_name": "run", "params": {"code": "if (x) { print(\\"}\\"); }"}}}';
      final result = LocalMnnModel.parseToolCalls(response);
      expect(result.functionCalls, isNotNull);
      expect(result.functionCalls![0]['args']['tool_name'], 'run');
    });

    test('parses tool call followed by trailing text', () {
      final response = '{"name": "call_tool", "arguments": {"service_name": "mcp", "tool_name": "search", "params": {"q": "test"}}} I will now search.';
      final result = LocalMnnModel.parseToolCalls(response);
      expect(result.functionCalls, isNotNull);
      expect(result.functionCalls![0]['args']['tool_name'], 'search');
    });

    test('falls back to plain text when arguments is not a map', () {
      final response = '{"name": "call_tool", "arguments": "invalid"}';
      final result = LocalMnnModel.parseToolCalls(response);
      expect(result.functionCalls, isNull);
      expect(result.text, response);
    });

    test('builds tool schema block for system prompt', () {
      final tools = [
        {
          'name': 'call_tool',
          'description': 'Call a tool',
          'parameters': {'type': 'object', 'properties': {}}
        }
      ];
      final block = LocalMnnModel.buildToolSchemaBlock(tools);
      expect(block, contains('call_tool'));
      expect(block, contains('"name": "call_tool"'));
    });
  });

  group('LocalMnnModel image handling', () {
    test('inserts img tag for image attachment path', () {
      final result = LocalMnnModel.insertImageTags(
        'Describe this image',
        ['/tmp/resized_photo.jpg'],
      );
      expect(result, 'Describe this image\n<img>/tmp/resized_photo.jpg</img>');
    });

    test('inserts multiple img tags for multiple images', () {
      final result = LocalMnnModel.insertImageTags(
        'Compare these',
        ['/tmp/img1.jpg', '/tmp/img2.jpg'],
      );
      expect(result, contains('<img>/tmp/img1.jpg</img>'));
      expect(result, contains('<img>/tmp/img2.jpg</img>'));
    });

    test('returns original text when no images', () {
      final result = LocalMnnModel.insertImageTags('Hello', []);
      expect(result, 'Hello');
    });

    test('estimates image tokens from dimensions', () {
      // 768x512 image: ceil(768/28) * ceil(512/28) = 28 * 19 = 532 tokens
      expect(LocalMnnModel.estimateImageTokens(768, 512), 532);
      // 1024x768 → resized to 768x576: ceil(768/28) * ceil(576/28) = 28 * 21 = 588
      expect(LocalMnnModel.estimateImageTokens(1024, 768), 588);
      // 200x100 → no resize: ceil(200/28) * ceil(100/28) = 8 * 4 = 32
      expect(LocalMnnModel.estimateImageTokens(200, 100), 32);
    });
  });
}
