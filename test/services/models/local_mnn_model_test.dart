import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/models/local_mnn_model.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';

void main() {
  group('LocalMnnModel buildChatMessages', () {
    test('maps system, user, assistant roles correctly', () {
      final messages = [
        PromptMessage(role: PromptRole.system, content: 'You are helpful.'),
        PromptMessage(role: PromptRole.user, content: 'Hello'),
        PromptMessage(role: PromptRole.assistant, content: 'Hi there'),
        PromptMessage(role: PromptRole.user, content: 'Follow up'),
      ];
      final result = LocalMnnModel.buildChatMessages(messages);
      expect(result.length, 4);
      expect(result[0], {'role': 'system', 'content': 'You are helpful.'});
      expect(result[1], {'role': 'user', 'content': 'Hello'});
      expect(result[2], {'role': 'assistant', 'content': 'Hi there'});
      expect(result[3], {'role': 'user', 'content': 'Follow up'});
    });

    test('maps tool role to user with prefix', () {
      final messages = [
        PromptMessage(role: PromptRole.tool, content: '{"result": "ok"}'),
      ];
      final result = LocalMnnModel.buildChatMessages(messages);
      expect(result.length, 1);
      expect(result[0]['role'], 'user');
      expect(result[0]['content'], 'Tool result: {"result": "ok"}');
    });

    test('merges toolSchemaBlock into system message', () {
      final messages = [
        PromptMessage(role: PromptRole.system, content: 'You are helpful.'),
        PromptMessage(role: PromptRole.user, content: 'Hello'),
      ];
      final result = LocalMnnModel.buildChatMessages(
        messages,
        toolSchemaBlock: 'TOOLS_HERE',
      );
      expect(result[0]['role'], 'system');
      expect(result[0]['content'], contains('You are helpful.'));
      expect(result[0]['content'], contains('TOOLS_HERE'));
    });

    test(
      'injects system message for toolSchemaBlock when no system present',
      () {
        final messages = [
          PromptMessage(role: PromptRole.user, content: 'Hello'),
        ];
        final result = LocalMnnModel.buildChatMessages(
          messages,
          toolSchemaBlock: 'TOOLS_HERE',
        );
        expect(result.length, 2);
        expect(result[0], {'role': 'system', 'content': 'TOOLS_HERE'});
        expect(result[1], {'role': 'user', 'content': 'Hello'});
      },
    );

    test('preserves message order for multi-turn conversation', () {
      final messages = [
        PromptMessage(role: PromptRole.system, content: 'System prompt'),
        PromptMessage(role: PromptRole.user, content: 'First question'),
        PromptMessage(role: PromptRole.assistant, content: 'First answer'),
        PromptMessage(role: PromptRole.user, content: 'Second question'),
      ];
      final result = LocalMnnModel.buildChatMessages(messages);
      expect(result.length, 4);
      expect(result[0]['role'], 'system');
      expect(result[1]['role'], 'user');
      expect(result[1]['content'], 'First question');
      expect(result[2]['role'], 'assistant');
      expect(result[2]['content'], 'First answer');
      expect(result[3]['role'], 'user');
      expect(result[3]['content'], 'Second question');
    });
  });

  group('LocalMnnModel formatPrompt (legacy)', () {
    test('formats system + user messages', () {
      final messages = [
        PromptMessage(role: PromptRole.system, content: 'You are helpful.'),
        PromptMessage(role: PromptRole.user, content: 'Hello'),
      ];
      final result = LocalMnnModel.formatPrompt(messages);
      expect(result, contains('You are helpful.'));
      expect(result, endsWith('Hello'));
      // No ChatML tags — MNN applies its own template
      expect(result, isNot(contains('<|im_start|>')));
      expect(result, isNot(contains('<|im_end|>')));
    });

    test('includes assistant turns', () {
      final messages = [
        PromptMessage(role: PromptRole.system, content: 'System prompt'),
        PromptMessage(role: PromptRole.user, content: 'First question'),
        PromptMessage(role: PromptRole.assistant, content: 'First answer'),
        PromptMessage(role: PromptRole.user, content: 'Follow up'),
      ];
      final result = LocalMnnModel.formatPrompt(messages);
      expect(result, contains('First question'));
      expect(result, contains('Assistant: First answer'));
      expect(result, endsWith('Follow up'));
    });

    test('injects toolSchemaBlock into prompt', () {
      final messages = [
        PromptMessage(role: PromptRole.system, content: 'You are helpful.'),
        PromptMessage(role: PromptRole.user, content: 'Hello'),
      ];
      final result = LocalMnnModel.formatPrompt(
        messages,
        toolSchemaBlock: 'TOOLS_HERE',
      );
      expect(result, contains('You are helpful.'));
      expect(result, contains('TOOLS_HERE'));
      expect(result, endsWith('Hello'));
    });

    test('handles user-only message', () {
      final messages = [PromptMessage(role: PromptRole.user, content: 'Hello')];
      final result = LocalMnnModel.formatPrompt(messages);
      expect(result, 'Hello');
    });
  });

  group('LocalMnnModel buildPromptTranscript', () {
    test('flattens multi-turn conversation into labeled transcript', () {
      final messages = [
        PromptMessage(role: PromptRole.system, content: 'You are helpful.'),
        PromptMessage(role: PromptRole.user, content: 'What is in this image?'),
        PromptMessage(
          role: PromptRole.assistant,
          content: 'It looks like a cat.',
        ),
        PromptMessage(
          role: PromptRole.user,
          content: 'What color is it?\n<img>/tmp/cat.jpg<hw>512,512</hw></img>',
        ),
      ];

      final result = LocalMnnModel.buildPromptTranscript(messages);

      expect(result, contains('System instructions:\nYou are helpful.'));
      expect(result, contains('User:\nWhat is in this image?'));
      expect(result, contains('Assistant:\nIt looks like a cat.'));
      expect(
        result,
        contains(
          'User:\nWhat color is it?\n<img>/tmp/cat.jpg<hw>512,512</hw></img>',
        ),
      );
    });

    test('prepends tool schema when no system message exists', () {
      final messages = [
        PromptMessage(role: PromptRole.user, content: 'Search for this'),
      ];

      final result = LocalMnnModel.buildPromptTranscript(
        messages,
        toolSchemaBlock: 'TOOLS_HERE',
      );

      expect(result, startsWith('System instructions:\nTOOLS_HERE'));
      expect(result, contains('User:\nSearch for this'));
    });

    test('renders tool results as their own transcript section', () {
      final messages = [
        PromptMessage(role: PromptRole.user, content: 'Do the thing'),
        PromptMessage(role: PromptRole.tool, content: '{"status":"ok"}'),
      ];

      final result = LocalMnnModel.buildPromptTranscript(messages);

      expect(result, contains('Tool result:\n{"status":"ok"}'));
    });
  });

  group('LocalMnnModel tool call parsing', () {
    test('parses valid JSON tool call from response', () {
      final response =
          'Let me search for that.\n{"name": "call_tool", "arguments": {"service_name": "mcp", "tool_name": "search", "params": {"query": "test"}}}';
      final result = LocalMnnModel.parseToolCalls(response);
      expect(result.functionCalls, isNotNull);
      expect(result.functionCalls!.length, 1);
      expect(result.functionCalls![0]['name'], 'call_tool');
      expect(result.functionCalls![0]['args']['tool_name'], 'search');
      expect(result.text, 'Let me search for that.');
    });

    test('handles malformed JSON with json_repair', () {
      final response =
          '{"name": "call_tool", "arguments": {"service_name": "test", "tool_name": "foo", "params": {"key": "value}}}';
      final result = LocalMnnModel.parseToolCalls(response);
      // json_repair should fix the missing quote
      expect(result.functionCalls, isNotNull);
    });

    test('returns plain text when no tool call found', () {
      final response = 'This is just a plain text response with no JSON.';
      final result = LocalMnnModel.parseToolCalls(response);
      expect(result.text, response);
      expect(result.functionCalls, isNull);
    });

    test('parses tool call with braces inside string values', () {
      final response =
          '{"name": "call_tool", "arguments": {"service_name": "test", "tool_name": "foo", "params": {"code": "if (x) { return y; }"}}}';
      final result = LocalMnnModel.parseToolCalls(response);
      expect(result.functionCalls, isNotNull);
      expect(
        result.functionCalls![0]['args']['params']['code'],
        'if (x) { return y; }',
      );
    });

    test('parses tool call followed by trailing text', () {
      final response =
          '{"name": "call_tool", "arguments": {"service_name": "test", "tool_name": "bar", "params": {}}}\nDone.';
      final result = LocalMnnModel.parseToolCalls(response);
      expect(result.functionCalls, isNotNull);
      expect(result.functionCalls![0]['args']['tool_name'], 'bar');
    });

    test('falls back to plain text when arguments is not a map', () {
      final response = '{"name": "call_tool", "arguments": "invalid"}';
      final result = LocalMnnModel.parseToolCalls(response);
      expect(result.text, response);
      expect(result.functionCalls, isNull);
    });

    test('builds tool schema block for system prompt', () {
      final tools = [
        {
          'name': 'search',
          'description': 'Search the web',
          'parameters': {'query': 'string'},
        },
      ];
      final result = LocalMnnModel.buildToolSchemaBlock(tools);
      expect(result, contains('call_tool'));
      expect(result, contains('search'));
      expect(result, contains('Search the web'));
    });
  });

  group('LocalMnnModel image handling', () {
    test('inserts img tag for image attachment path', () {
      final result = LocalMnnModel.insertImageTags('Describe this', [
        '/tmp/img.jpg',
      ]);
      expect(result, contains('<img>/tmp/img.jpg</img>'));
      expect(result, startsWith('Describe this'));
    });

    test('inserts multiple img tags for multiple images', () {
      final result = LocalMnnModel.insertImageTags('Two images', [
        '/tmp/a.jpg',
        '/tmp/b.png',
      ]);
      expect(result, contains('<img>/tmp/a.jpg</img>'));
      expect(result, contains('<img>/tmp/b.png</img>'));
    });

    test('returns original text when no images', () {
      final result = LocalMnnModel.insertImageTags('No images', []);
      expect(result, 'No images');
    });

    test('estimates image tokens from dimensions', () {
      // 768x512 image (under 784px limit): ceil(768/28) * ceil(512/28) = 28 * 19 = 532 tokens
      expect(LocalMnnModel.estimateImageTokens(768, 512), 532);
      // 2000x1000 → resized to 784x392: ceil(784/28) * ceil(392/28) = 28 * 14 = 392
      expect(LocalMnnModel.estimateImageTokens(2000, 1000), 392);
      // 200x100 → no resize: ceil(200/28) * ceil(100/28) = 8 * 4 = 32
      expect(LocalMnnModel.estimateImageTokens(200, 100), 32);
    });
  });
}
