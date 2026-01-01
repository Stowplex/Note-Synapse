import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/agent_service.dart';

void main() {
  group('AgentService Tool Executor', () {
    test('ToolExecutor typedef has correct signature', () {
      // This test verifies the ToolExecutor typedef exists and has the expected signature
      ToolExecutor executor =
          (
            String serviceName,
            String toolName,
            Map<String, dynamic> parameters,
            GenerationContext generationContext,
          ) async {
            return 'test result';
          };

      expect(executor, isNotNull);
    });

    test('generatePlan accepts executeTool parameter', () async {
      final agentService = AgentService();

      String? capturedServiceName;
      String? capturedToolName;
      Map<String, dynamic>? capturedParams;

      final executor =
          (
            String serviceName,
            String toolName,
            Map<String, dynamic> parameters,
            GenerationContext generationContext,
          ) async {
            capturedServiceName = serviceName;
            capturedToolName = toolName;
            capturedParams = parameters;
            return 'executed';
          };

      // Define external tools with a local AI tool service name pattern
      final activeTools = <String, List<McpTool>>{
        'NS/test_tool_abc12345': [
          McpTool(
            name: 'test_tool',
            description: 'A test tool',
            inputSchema: {'type': 'object', 'properties': {}},
          ),
        ],
      };

      // Verify that generatePlan accepts the executeTool parameter
      // The actual plan generation requires AI service which we can't run in tests,
      // but we can verify the API accepts the parameter
      expect(
        () => agentService.generatePlan(
          'Test objective',
          activeTools: activeTools,
          executeTool: executor,
        ),
        returnsNormally,
      );
    });

    test('startObjective accepts executeTool parameter', () async {
      final agentService = AgentService();

      final executor =
          (
            String serviceName,
            String toolName,
            Map<String, dynamic> parameters,
            GenerationContext generationContext,
          ) async {
            return 'executed';
          };

      // Verify that startObjective accepts the executeTool parameter
      expect(
        () => agentService.startObjective(
          'Test objective',
          activeTools: const {},
          executeTool: executor,
        ),
        returnsNormally,
      );
    });

    test('clearState resets tool executor', () {
      final agentService = AgentService();

      // After clearState, the internal state should be reset
      agentService.clearState();

      expect(agentService.tasks, isEmpty);
      expect(agentService.isRunning, isFalse);
      expect(agentService.currentThought, isNull);
      expect(agentService.finalAnswer, isNull);
    });

    test('local AI tool service names use NS/ prefix pattern', () {
      // Service names for local AI tools follow the pattern NS/<slug>_<uuid8>
      // This test documents the expected pattern for identification

      final localToolServiceName = 'NS/my_tool_abc12345';
      final mcpServiceName = 'my-mcp-service';

      expect(localToolServiceName.startsWith('NS/'), isTrue);
      expect(mcpServiceName.startsWith('NS/'), isFalse);
    });
  });
}
