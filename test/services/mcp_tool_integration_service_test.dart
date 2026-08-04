import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/mcp_tool_integration_service.dart';
import 'package:note_synapse/services/models/local_mnn_model.dart';
import 'package:note_synapse/services/models/gemini_model.dart';
import 'package:note_synapse/services/tools/note_tools.dart';

import '../utils/test_prompt_template_setup.dart';

void main() {
  setUpAll(() async {
    await registerTestPromptTemplateService();
  });

  group('McpToolIntegrationService', () {
    group('parseCallToolArguments', () {
      test('parses normal arguments', () {
        final raw = {
          'service_name': 's1',
          'tool_name': 't1',
          'params': {'a': 1},
        };
        final result = McpToolIntegrationService.parseCallToolArguments(raw);
        expect(result, isNotNull);
        expect(result!['service_name'], 's1');
        expect(result['tool_name'], 't1');
        expect(result['params'], {'a': 1});
      });

      test('parses empty params', () {
        final raw = {
          'service_name': 's1',
          'tool_name': 't1',
          'params': <String, dynamic>{},
        };
        final result = McpToolIntegrationService.parseCallToolArguments(raw);
        expect(result, isNotNull);
        expect(result!['service_name'], 's1');
        expect(result['tool_name'], 't1');
        expect(result['params'], isEmpty);
      });

      test('parses params provided as empty object', () {
        // Simulating the structure: {service_name: ..., params: {}}
        final raw = {'service_name': 'System', 'tool_name': 'ls', 'params': {}};
        final result = McpToolIntegrationService.parseCallToolArguments(raw);
        expect(result, isNotNull);
        expect(result!['params'], isEmpty);
      });

      test('parses params from list format (positional fallback)', () {
        final raw = [
          's1',
          't1',
          {'a': 1},
        ];
        final result = McpToolIntegrationService.parseCallToolArguments(raw);
        expect(result, isNotNull);
        expect(result!['service_name'], 's1');
        expect(result['tool_name'], 't1');
        expect(result['params'], {'a': 1});
      });

      test('uses fallback service/tool for direct-call normalization', () {
        final raw = {
          'params': {'noteId': 'skill-1'},
        };
        final result = McpToolIntegrationService.parseCallToolArguments(
          raw,
          fallbackServiceName: 'SkillTools',
          fallbackToolName: 'load_skill',
        );
        expect(result, isNotNull);
        expect(result!['service_name'], 'SkillTools');
        expect(result['tool_name'], 'load_skill');
        expect(result['params'], {'noteId': 'skill-1'});
      });
    });

    group('buildMcpSystemPrompt', () {
      test('uses canonical wrapper fields in compact mode', () {
        final prompt = McpToolIntegrationService.buildMcpSystemPrompt({
          'SkillTools': [
            McpTool(
              name: 'load_skill',
              description: 'Load a skill',
              inputSchema: const {
                'type': 'object',
                'properties': {
                  'noteId': {'type': 'string', 'description': 'Skill note id'},
                },
                'required': ['noteId'],
              },
            ),
          ],
        }, maxBudgetTokens: 16000);

        expect(prompt, contains('service_name'));
        expect(prompt, contains('tool_name'));
        expect(prompt, contains('params'));
        expect(prompt, isNot(contains('service: "example"')));
        expect(prompt, isNot(contains('name: "tool_fn"')));
        expect(prompt, isNot(contains('param: {a: "hello"}')));
      });

      test('preferDirectCalls swaps the intro for chat surfaces while the '
          'default (agent/local) keeps the call_tool-only wording', () {
        final tools = <String, List<McpTool>>{
          'System': [
            McpTool(
              name: 'search_notes',
              description: 'Search',
              inputSchema: const {
                'type': 'object',
                'properties': {
                  'query': {'type': 'string'},
                },
              },
            ),
          ],
        };

        final chatPrompt = McpToolIntegrationService.buildMcpSystemPrompt(
          tools,
          maxBudgetTokens: 16000,
          preferDirectCalls: true,
        );
        expect(chatPrompt, contains('Call tools directly by their declared'));
        expect(chatPrompt, isNot(contains('only through call_tool')));

        // The default — used by agent mode, whose XML protocol depends on
        // call_tool — must keep the original wording byte-for-byte.
        final agentPrompt = McpToolIntegrationService.buildMcpSystemPrompt(
          tools,
          maxBudgetTokens: 16000,
        );
        expect(
          agentPrompt,
          contains(
            'Call external tools only through call_tool with '
            '{service_name, tool_name, params}.',
          ),
        );
        expect(agentPrompt, isNot(contains('directly by their declared')));
      });

      test('renders an Example line for tools declaring schema examples, '
          'and none for tools without', () {
        final prompt = McpToolIntegrationService.buildMcpSystemPrompt({
          'System': [
            McpTool(
              name: 'demo_tool',
              description: 'Demo',
              inputSchema: const {
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
            ),
            McpTool(
              name: 'plain_tool',
              description: 'Plain',
              inputSchema: const {
                'type': 'object',
                'properties': {
                  'q': {'type': 'string'},
                },
              },
            ),
          ],
        }, maxBudgetTokens: 16000);

        expect(
          prompt,
          contains(
            'Example: call_tool({"service_name": "System", '
            '"tool_name": "demo_tool", "params": {"config":{"key":"value"}}})',
          ),
        );
        // Exactly one per-tool Example line — plain_tool must not get one.
        // (The generic wrapper intro has its own unquoted example line.)
        expect('Example: call_tool({"'.allMatches(prompt), hasLength(1));
      });

      test('marks array items explicitly and renders the batch modify_notes '
          'schema to full depth', () {
        final modifyNotes = ModifyNotesTool();
        final prompt = McpToolIntegrationService.buildMcpSystemPrompt({
          'System': [
            McpTool(
              name: modifyNotes.name,
              description: modifyNotes.description,
              inputSchema: modifyNotes.inputSchema,
            ),
          ],
        }, maxBudgetTokens: 16000);

        expect(prompt, contains('Each array item is an object with:'));
        // Depth regression: the batch tool nests one level deeper than
        // modify_note; link.added item fields must still render.
        expect(prompt, contains('relation (string'));
        expect(prompt, contains('target (string'));
        // The replace_text affordance is documented.
        expect(prompt, contains('replace_text'));
        expect(prompt, contains('old_text'));
      });
    });

    group('getCallToolFunctionForGemini', () {
      test('compact description is short and omits tool catalog', () {
        final tools = <String, List<McpTool>>{
          'System': [
            McpTool(
              name: 'search_notes',
              description: 'Search notes',
              inputSchema: {
                'type': 'object',
                'properties': {
                  'query': {'type': 'string', 'description': 'Search query'},
                },
                'required': ['query'],
              },
            ),
          ],
        };

        final compactFn =
            McpToolIntegrationService.getCallToolFunctionForGemini(
          tools,
          compactDescription: true,
        );
        final normalFn =
            McpToolIntegrationService.getCallToolFunctionForGemini(tools);

        final compactDesc = compactFn['description'] as String;
        final normalDesc = normalFn['description'] as String;

        // Compact should be significantly shorter
        expect(compactDesc.length, lessThan(normalDesc.length));
        expect(compactDesc, contains('service_name'));
        expect(compactDesc, contains('tool_name'));
        // Compact should NOT contain tool catalog details
        expect(compactDesc, isNot(contains('search_notes')));
      });
    });
  });

    group('AIModel.buildToolDeclarations polymorphism', () {
      final tools = <String, List<McpTool>>{
        'System': [
          McpTool(
            name: 'search_notes',
            description: 'Search notes',
            inputSchema: {
              'type': 'object',
              'properties': {
                'query': {'type': 'string', 'description': 'Search query'},
              },
              'required': ['query'],
            },
          ),
          McpTool(
            name: 'read_note',
            description: 'Read a note',
            inputSchema: {
              'type': 'object',
              'properties': {
                'noteId': {'type': 'string', 'description': 'Note ID'},
              },
              'required': ['noteId'],
            },
          ),
        ],
      };

      test('LocalMnnModel returns individual declarations (one per tool)', () {
        final model = LocalMnnModel();
        final declarations = model.buildToolDeclarations(tools);
        expect(declarations, hasLength(2));
        expect(declarations[0]['name'], 'search_notes');
        expect(declarations[1]['name'], 'read_note');
        // Each has its own parameters schema
        expect(
          (declarations[0]['parameters'] as Map)['properties'],
          containsPair('query', isA<Map>()),
        );
        expect(
          (declarations[1]['parameters'] as Map)['properties'],
          containsPair('noteId', isA<Map>()),
        );
      });

      test('GeminiModel returns per-tool declarations plus the call_tool '
          'wrapper', () {
        final model = GeminiModel();
        final declarations = model.buildToolDeclarations(tools);
        final names = declarations.map((d) => d['name']).toList();
        expect(names, contains('call_tool'));
        expect(names.last, 'call_tool');
        expect(names.length, greaterThan(1));
        // Per-tool declarations carry real parameter schemas.
        final perTool = declarations.firstWhere(
          (d) => d['name'] != 'call_tool',
        );
        expect((perTool['parameters'] as Map)['properties'], isNotEmpty);
      });

      test('per-tool declarations sanitize schemas and skip duplicates', () {
        final toolSet = <String, List<McpTool>>{
          'A': [
            McpTool(
              name: 'modify_notes',
              description: 'batch modify',
              inputSchema: ModifyNotesTool().inputSchema,
            ),
            McpTool(name: 'dupe_tool', description: 'a', inputSchema: const {}),
            McpTool(
              name: 'weird name!',
              description: 'invalid function name',
              inputSchema: const {},
            ),
          ],
          'B': [
            McpTool(name: 'dupe_tool', description: 'b', inputSchema: const {}),
            McpTool(
              name: 'exotic',
              description: 'unsupported schema',
              inputSchema: const {
                'type': 'object',
                'properties': {
                  'x': {r'$ref': '#/defs/x'},
                },
              },
            ),
          ],
        };

        final declarations =
            McpToolIntegrationService.buildPerToolDeclarations(toolSet);
        final names = declarations.map((d) => d['name']).toList();

        // Duplicate and invalid names are not declared individually.
        expect(names, isNot(contains('dupe_tool')));
        expect(names, isNot(contains('weird name!')));
        expect(names, containsAll(['modify_notes', 'exotic']));

        // The documentation-only `examples` keyword never reaches the
        // structural declaration; nested structure survives sanitization.
        final modifyNotes = declarations.firstWhere(
          (d) => d['name'] == 'modify_notes',
        );
        final parameters = modifyNotes['parameters'] as Map;
        expect(parameters.containsKey('examples'), isFalse);
        final modificationSchema =
            ((((parameters['properties'] as Map)['modifications']
                        as Map)['items']
                    as Map)['properties']
                as Map)['modification'];
        expect((modificationSchema as Map)['type'], 'object');
        expect((modificationSchema['properties'] as Map), isNotEmpty);

        // Unsupported structural keywords degrade to a permissive object
        // instead of dropping or breaking the tool.
        final exotic = declarations.firstWhere((d) => d['name'] == 'exotic');
        expect(exotic['parameters'], {'type': 'object'});
      });

      test('empty tools returns empty list for all model types', () {
        final empty = <String, List<McpTool>>{};
        expect(LocalMnnModel().buildToolDeclarations(empty), isEmpty);
        expect(GeminiModel().buildToolDeclarations(empty), isEmpty);
      });
    });
}
