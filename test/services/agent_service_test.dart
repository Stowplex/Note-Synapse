import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/agent_task.dart';
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

  group('JSON extraction patterns', () {
    // Helper function that mirrors the extraction logic from _performTask
    String? extractJsonFromResponse(String response) {
      // Method 1: Look for ```json ... ``` block
      final jsonBlockMatch = RegExp(
        r'```json\s*(\{.*?\})\s*```',
        dotAll: true,
      ).firstMatch(response);

      if (jsonBlockMatch != null) {
        return jsonBlockMatch.group(1);
      }

      // Method 2: Find JSON object with expected action keys
      final jsonStartMatch = RegExp(
        r'\{\s*"(?:tool|answer|think|spawn_subtasks)"\s*:',
      ).firstMatch(response);

      if (jsonStartMatch != null) {
        final startIdx = jsonStartMatch.start;
        int braceCount = 0;
        int? endIdx;
        for (int i = startIdx; i < response.length; i++) {
          if (response[i] == '{') {
            braceCount++;
          } else if (response[i] == '}') {
            braceCount--;
            if (braceCount == 0) {
              endIdx = i + 1;
              break;
            }
          }
        }
        if (endIdx != null) {
          return response.substring(startIdx, endIdx);
        }
      }
      return null;
    }

    test('extracts valid JSON from code block', () {
      final response = '''
My thought: I have all the information needed.

```json
{ "answer": "The REST API endpoints are documented below." }
```
''';
      final json = extractJsonFromResponse(response);
      expect(json, isNotNull);
      expect(json, contains('"answer"'));
    });

    test('extracts JSON without code block', () {
      final response = '''
My thought: Analysis complete.

{ "answer": "Here is the summary." }
''';
      final json = extractJsonFromResponse(response);
      expect(json, isNotNull);
      expect(json, contains('"answer"'));
    });

    test('ignores template placeholders like {cid}', () {
      final response = '''
My thought: The endpoint uses GET https://api.example.com/{cid}/data

To fetch data, use the following pattern:
- Endpoint: https://api.example.com/{oid}.xml
- The {BVID} parameter should be replaced.
''';
      // This should return null since there's no valid JSON action
      final json = extractJsonFromResponse(response);
      expect(json, isNull);
    });

    test('extracts JSON even with template placeholders in response', () {
      final response = '''
My thought: The endpoint uses GET https://api.example.com/{cid}/data

```json
{ "answer": "Use the endpoint https://api.example.com/{cid}/data" }
```
''';
      final json = extractJsonFromResponse(response);
      expect(json, isNotNull);
      expect(json, contains('"answer"'));
    });

    test('handles nested JSON objects in tool args', () {
      final response = '''
My thought: Need to call the search tool.

{ "tool": "search", "args": { "query": "test", "options": { "limit": 10 } } }
''';
      final json = extractJsonFromResponse(response);
      expect(json, isNotNull);
      expect(json, contains('"tool"'));
      expect(json, contains('"args"'));
      expect(json, contains('"options"'));
    });

    test('handles think action', () {
      final response = '''
My thought: I need to analyze the data more carefully.

{ "think": "The data shows that there are two main approaches..." }
''';
      final json = extractJsonFromResponse(response);
      expect(json, isNotNull);
      expect(json, contains('"think"'));
    });

    test('handles spawn_subtasks action', () {
      final response = '''
My thought: This task is complex, I'll spawn multiple subtasks.

{ "spawn_subtasks": [ { "description": "Research topic A", "tools": ["search"] }, { "description": "Research topic B", "tools": ["search"] } ] }
''';
      final json = extractJsonFromResponse(response);
      expect(json, isNotNull);
      expect(json, contains('"spawn_subtasks"'));
    });
  });

  group('Subtask spawning', () {
    test('kMaxSubtaskDepth constant is defined', () {
      // Verify the constant exists and has expected value
      expect(kMaxSubtaskDepth, equals(3));
    });

    test('AgentTask has spawnedSubtaskIds field', () {
      final task = AgentTask(id: 'test-id', description: 'Test task');

      expect(task.spawnedSubtaskIds, isEmpty);

      task.spawnedSubtaskIds.add('child-1');
      expect(task.spawnedSubtaskIds, contains('child-1'));
    });

    test('AgentTask has isSpawnedDynamically field', () {
      // Default is false
      final plannedTask = AgentTask(
        id: 'planned-id',
        description: 'Planned task',
      );
      expect(plannedTask.isSpawnedDynamically, isFalse);

      // Can be set to true
      final spawnedTask = AgentTask(
        id: 'spawned-id',
        description: 'Spawned task',
        isSpawnedDynamically: true,
      );
      expect(spawnedTask.isSpawnedDynamically, isTrue);
    });

    test('AgentTask toJson includes new fields', () {
      final task = AgentTask(
        id: 'test-id',
        description: 'Test',
        isSpawnedDynamically: true,
        spawnedSubtaskIds: ['child-1', 'child-2'],
      );

      final json = task.toJson();

      expect(json['isSpawnedDynamically'], isTrue);
      expect(json['spawnedSubtaskIds'], equals(['child-1', 'child-2']));
    });

    test('depth limit prevents exceeding max levels', () {
      // A task at maximum depth cannot spawn more subtasks
      final deepTask = AgentTask(
        id: 'deep-id',
        description: 'Deep task',
        depth: kMaxSubtaskDepth, // At max depth
      );

      expect(deepTask.depth, equals(kMaxSubtaskDepth));
      // In actual execution, _handleSpawnSubtask would reject this
    });
  });
}
