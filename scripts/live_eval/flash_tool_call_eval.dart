// Live eval: replays the log-book-readings failure scenario against real
// Gemini Flash-class models and checks that the model now produces a
// structurally valid `modify_notes`/`modify_note` call (directly or through
// call_tool) that passes the app's validator.
//
// This measures the thing unit tests cannot: actual model behavior against
// the app's real declarations and catalog text. Run out-of-CI:
//
//   GEMINI_API_KEY=... dart run scripts/live_eval/flash_tool_call_eval.dart \
//       [model-id ...]
//
// Defaults to gemini-3-flash-preview and gemini-3.1-flash-lite.
//
// Exit code 0: every model produced a valid modify call. Non-zero: at least
// one model produced arguments the validator rejected (details printed).
import 'dart:convert';
import 'dart:io';

import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/mcp_tool_integration_service.dart';
import 'package:note_synapse/services/tools/note_tools.dart';
import 'package:note_synapse/services/tools/tool_param_validator.dart';

const _defaultModels = ['gemini-3-flash-preview', 'gemini-3.1-flash-lite'];

// Table format — the shape from the 2026-08-03 failure trace, where the
// model must flip a Status cell rather than a checkbox.
const _readingRecordContent =
    '## 2026-08-03\n'
    '| Status | Book Title | Count |\n'
    '| :----- | :--------- | ----- |\n'
    '|        | 小猪皮皮的游乐园之梦 |   1    |\n'
    '\n'
    '## 2026-07-31\n'
    '- [ ] 飞吧，小猪璞璞：星际奇遇记 x 3遍\n'
    '- [ ] 小猪璞璞的秘密书包 x 2遍\n';

const _skillText =
    '# Skill: log-book-readings\n\n'
    '1. Check Reading Record (note cc1cf667-d64e-4dda-aaf5-7d1c30432872) '
    'with read_note; look for unchecked items.\n'
    '2. For unchecked items, use log_reading_session to record the '
    'readings.\n'
    '3. When it is done, modify the Reading Record with modify_notes and '
    'check the box for the logged item.';

Map<String, List<McpTool>> _activeTools() {
  final modifyNote = ModifyNoteTool();
  final modifyNotes = ModifyNotesTool();
  final readNote = NoteReadTool();
  return {
    'SkillTools': [
      McpTool(
        name: readNote.name,
        description: readNote.description,
        inputSchema: readNote.inputSchema,
      ),
      McpTool(
        name: 'log_reading_session',
        description:
            'Logs a new book reading entry. Requires title and date.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'book_title': {'type': 'string'},
            'date_read': {'type': 'string'},
            'log_value': {'type': 'integer'},
          },
          'required': ['book_title', 'date_read'],
        },
      ),
      McpTool(
        name: modifyNote.name,
        description: modifyNote.description,
        inputSchema: modifyNote.inputSchema,
      ),
      McpTool(
        name: modifyNotes.name,
        description: modifyNotes.description,
        inputSchema: modifyNotes.inputSchema,
      ),
    ],
  };
}

Future<int> main(List<String> args) async {
  final apiKey = Platform.environment['GEMINI_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('GEMINI_API_KEY is not set; refusing to run live eval.');
    return 2;
  }
  final models = args.isEmpty ? _defaultModels : args;

  final tools = _activeTools();
  final catalog = McpToolIntegrationService.buildMcpSystemPrompt(
    tools,
    maxBudgetTokens: 16000,
  );
  final declarations = <Map<String, dynamic>>[
    ...McpToolIntegrationService.buildPerToolDeclarations(tools),
    McpToolIntegrationService.getCallToolFunctionForGemini(tools),
  ];

  // Mirror the trace: skill + note already read + sessions already logged,
  // model must now check the boxes.
  final contents = [
    {
      'role': 'user',
      'parts': [
        {
          'text':
              'sync book readings to bean stack\n\n'
              'Context already gathered this turn:\n'
              '- Skill instructions:\n$_skillText\n\n'
              '- Reading Record note '
              '(id cc1cf667-d64e-4dda-aaf5-7d1c30432872) content:\n'
              '$_readingRecordContent\n'
              '- Both books were ALREADY logged to Beanstack successfully.\n'
              'Now complete step 3 of the skill: update the note.',
        },
      ],
    },
  ];

  var failures = 0;
  for (final model in models) {
    stdout.writeln('=== $model ===');
    final body = {
      'contents': contents,
      'systemInstruction': {
        'parts': [
          {'text': 'You are Note Synapse. Use tools to act.\n$catalog'},
        ],
      },
      'tools': [
        {'functionDeclarations': declarations},
      ],
      'toolConfig': {
        'functionCallingConfig': {'mode': 'VALIDATED'},
      },
      'generationConfig': {'temperature': 1.0, 'maxOutputTokens': 8192},
    };

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      '$model:generateContent?key=$apiKey',
    );
    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        stderr.writeln('  HTTP ${response.statusCode}: $text');
        failures++;
        continue;
      }
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      final parts =
          ((((decoded['candidates'] as List?)?.first
                          as Map?)?['content']
                      as Map?)?['parts']
                  as List?) ??
          const [];
      final calls = parts
          .whereType<Map>()
          .where((p) => p.containsKey('functionCall'))
          .map((p) => p['functionCall'] as Map)
          .toList();
      if (calls.isEmpty) {
        stderr.writeln('  NO function call produced. Parts: $parts');
        failures++;
        continue;
      }
      for (final call in calls) {
        final name = call['name'] as String? ?? '';
        var toolName = name;
        var params = (call['args'] as Map?)?.cast<String, dynamic>() ?? {};
        if (name == 'call_tool') {
          final parsed = McpToolIntegrationService.parseCallToolArguments(
            params,
          );
          if (parsed == null) {
            stderr.writeln('  UNPARSEABLE call_tool args: $params');
            failures++;
            continue;
          }
          toolName = parsed['tool_name'] as String;
          params = parsed['params'] as Map<String, dynamic>;
        }
        final tool = tools['SkillTools']!
            .where((t) => t.name == toolName)
            .firstOrNull;
        final invalid = ToolParamValidator.validationFailure(
          toolName: toolName,
          params: params,
          inputSchema: tool?.inputSchema,
        );
        if (invalid != null) {
          stderr.writeln('  INVALID $toolName call: ${invalid.message}');
          stderr.writeln('  args: ${jsonEncode(params)}');
          failures++;
        } else {
          stdout.writeln('  OK: $toolName(${jsonEncode(params)})');
        }
      }
    } finally {
      client.close();
    }
  }

  stdout.writeln(
    failures == 0
        ? '\nLive eval PASSED for ${models.join(', ')}'
        : '\nLive eval FAILED with $failures invalid outcome(s)',
  );
  return failures == 0 ? 0 : 1;
}
