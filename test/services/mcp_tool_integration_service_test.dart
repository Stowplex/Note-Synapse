import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/mcp_tool_integration_service.dart';
import 'package:note_synapse/services/models/local_mnn_model.dart';
import 'package:note_synapse/services/models/gemini_model.dart';

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

      test('GeminiModel returns single call_tool wrapper', () {
        final model = GeminiModel();
        final declarations = model.buildToolDeclarations(tools);
        expect(declarations, hasLength(1));
        expect(declarations[0]['name'], 'call_tool');
      });

      test('empty tools returns empty list for all model types', () {
        final empty = <String, List<McpTool>>{};
        expect(LocalMnnModel().buildToolDeclarations(empty), isEmpty);
        expect(GeminiModel().buildToolDeclarations(empty), isEmpty);
      });
    });
}
