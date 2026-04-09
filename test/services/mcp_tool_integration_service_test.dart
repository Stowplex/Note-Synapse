import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/mcp_tool_integration_service.dart';

void main() {
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
  });
}
