import 'package:flutter_test/flutter_test.dart';
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
    });
  });
}
