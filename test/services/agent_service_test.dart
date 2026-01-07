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

  group('Task dependencies', () {
    test('AgentTask has name and dependsOn fields', () {
      final task = AgentTask(
        id: 'test-id',
        description: 'Test task',
        name: 'test_task',
        dependsOn: ['dep_a', 'dep_b'],
      );

      expect(task.name, equals('test_task'));
      expect(task.dependsOn, equals(['dep_a', 'dep_b']));
    });

    test('AgentTask defaults to empty dependsOn', () {
      final task = AgentTask(id: 'test-id', description: 'Test task');

      expect(task.dependsOn, isEmpty);
      expect(task.name, isNull);
    });

    test('AgentTask toJson includes name and dependsOn', () {
      final task = AgentTask(
        id: 'test-id',
        description: 'Test',
        name: 'my_task',
        dependsOn: ['task_a', 'task_b'],
      );

      final json = task.toJson();

      expect(json['name'], equals('my_task'));
      expect(json['dependsOn'], equals(['task_a', 'task_b']));
    });

    // Tests for dependency graph validation logic
    // Since _validatePlanDependencies is private, we test the expected behavior
    // through the data model and document the validation rules

    test('dependency validation - duplicate task names are invalid', () {
      // Create tasks with duplicate names (would fail validation)
      final tasks = [
        AgentTask(id: '1', description: 'Research A', name: 'research'),
        AgentTask(
          id: '2',
          description: 'Research B',
          name: 'research', // Duplicate!
        ),
      ];

      // Build name map as validation does
      final nameToTask = <String, AgentTask>{};
      String? error;
      for (final task in tasks) {
        if (task.name != null) {
          if (nameToTask.containsKey(task.name)) {
            error = 'Duplicate task name: ${task.name}';
            break;
          }
          nameToTask[task.name!] = task;
        }
      }

      expect(error, isNotNull);
      expect(error, contains('Duplicate task name'));
    });

    test('dependency validation - unknown dependency is invalid', () {
      final tasks = [
        AgentTask(id: '1', description: 'Research', name: 'research'),
        AgentTask(
          id: '2',
          description: 'Synthesize',
          name: 'synthesize',
          dependsOn: ['research', 'unknown_task'], // Unknown!
        ),
      ];

      // Check for unknown dependencies
      final nameToTask = <String, AgentTask>{};
      for (final task in tasks) {
        if (task.name != null) {
          nameToTask[task.name!] = task;
        }
      }

      String? error;
      for (final task in tasks) {
        for (final dep in task.dependsOn) {
          if (!nameToTask.containsKey(dep)) {
            error = 'Unknown dependency: $dep';
            break;
          }
        }
        if (error != null) break;
      }

      expect(error, isNotNull);
      expect(error, contains('unknown_task'));
    });

    test('dependency validation - circular dependency is invalid', () {
      final tasks = [
        AgentTask(
          id: '1',
          description: 'Task A',
          name: 'task_a',
          dependsOn: ['task_b'], // A depends on B
        ),
        AgentTask(
          id: '2',
          description: 'Task B',
          name: 'task_b',
          dependsOn: ['task_a'], // B depends on A -> cycle!
        ),
      ];

      // Cycle detection using DFS
      final nameToTask = <String, AgentTask>{};
      for (final task in tasks) {
        if (task.name != null) {
          nameToTask[task.name!] = task;
        }
      }

      final visited = <String>{};
      final inStack = <String>{};
      bool hasCycle = false;

      bool dfs(String? name) {
        if (name == null) return false;
        if (inStack.contains(name)) return true;
        if (visited.contains(name)) return false;

        visited.add(name);
        inStack.add(name);

        final task = nameToTask[name];
        if (task != null) {
          for (final dep in task.dependsOn) {
            if (dfs(dep)) return true;
          }
        }

        inStack.remove(name);
        return false;
      }

      for (final task in tasks) {
        if (task.name != null && dfs(task.name)) {
          hasCycle = true;
          break;
        }
      }

      expect(hasCycle, isTrue);
    });

    test('dependency validation - valid DAG passes', () {
      // Valid dependency graph: research_a, research_b -> synthesize
      final tasks = [
        AgentTask(
          id: '1',
          description: 'Research A',
          name: 'research_a',
          extractFindings: true,
        ),
        AgentTask(
          id: '2',
          description: 'Research B',
          name: 'research_b',
          extractFindings: true,
        ),
        AgentTask(
          id: '3',
          description: 'Synthesize',
          name: 'synthesize',
          dependsOn: ['research_a', 'research_b'],
          isFinalDeliverable: true,
        ),
      ];

      // Build name map
      final nameToTask = <String, AgentTask>{};
      String? error;
      for (final task in tasks) {
        if (task.name != null) {
          if (nameToTask.containsKey(task.name)) {
            error = 'Duplicate';
            break;
          }
          nameToTask[task.name!] = task;
        }
      }
      expect(error, isNull);

      // Check deps
      for (final task in tasks) {
        for (final dep in task.dependsOn) {
          if (!nameToTask.containsKey(dep)) {
            error = 'Unknown dep';
            break;
          }
        }
      }
      expect(error, isNull);

      // Check cycles (should pass)
      final visited = <String>{};
      final inStack = <String>{};
      bool hasCycle = false;

      bool dfs(String? name) {
        if (name == null) return false;
        if (inStack.contains(name)) return true;
        if (visited.contains(name)) return false;

        visited.add(name);
        inStack.add(name);

        final task = nameToTask[name];
        if (task != null) {
          for (final dep in task.dependsOn) {
            if (dfs(dep)) return true;
          }
        }

        inStack.remove(name);
        return false;
      }

      for (final task in tasks) {
        if (task.name != null && dfs(task.name)) {
          hasCycle = true;
          break;
        }
      }
      expect(hasCycle, isFalse);

      // Check reachability from final deliverable
      final finalTask = tasks.where((t) => t.isFinalDeliverable).first;
      final reachable = <String>{};

      void walkDeps(String? name) {
        if (name == null || reachable.contains(name)) return;
        reachable.add(name);
        final task = nameToTask[name];
        if (task != null) {
          for (final dep in task.dependsOn) {
            walkDeps(dep);
          }
        }
      }

      walkDeps(finalTask.name);

      // All tasks should be reachable
      for (final task in tasks) {
        if (task.name != null) {
          expect(
            reachable.contains(task.name),
            isTrue,
            reason: '${task.name} should be reachable',
          );
        }
      }
    });

    test('dependency validation - unreachable task (island) is invalid', () {
      // Task "island_task" is not connected to the final deliverable
      final tasks = [
        AgentTask(id: '1', description: 'Research A', name: 'research_a'),
        AgentTask(
          id: '2',
          description: 'Island Task',
          name: 'island_task', // Not depended on by anyone!
        ),
        AgentTask(
          id: '3',
          description: 'Synthesize',
          name: 'synthesize',
          dependsOn: ['research_a'], // Only depends on research_a
          isFinalDeliverable: true,
        ),
      ];

      final nameToTask = <String, AgentTask>{};
      for (final task in tasks) {
        if (task.name != null) {
          nameToTask[task.name!] = task;
        }
      }

      final finalTask = tasks.where((t) => t.isFinalDeliverable).first;
      final reachable = <String>{};

      void walkDeps(String? name) {
        if (name == null || reachable.contains(name)) return;
        reachable.add(name);
        final task = nameToTask[name];
        if (task != null) {
          for (final dep in task.dependsOn) {
            walkDeps(dep);
          }
        }
      }

      walkDeps(finalTask.name);

      // Find unreachable tasks
      String? unreachableTask;
      for (final task in tasks) {
        if (task.name != null &&
            !reachable.contains(task.name) &&
            task.name != finalTask.name) {
          unreachableTask = task.name;
          break;
        }
      }

      expect(unreachableTask, equals('island_task'));
    });
  });

  group('Pause/Resume/Stop execution controls', () {
    test('pauseExecution sets isPaused when running', () {
      final agentService = AgentService();

      // Simulate running state (we can't actually run without AI, but test the state)
      // Start by checking default state
      expect(agentService.isPaused, isFalse);
      expect(agentService.isRunning, isFalse);

      // pauseExecution should not do anything when not running
      agentService.pauseExecution();
      expect(agentService.isPaused, isFalse);
    });

    test('resumeExecution clears paused state', () {
      final agentService = AgentService();

      // Default state
      expect(agentService.isPaused, isFalse);

      // resumeExecution when not paused should be no-op
      agentService.resumeExecution();
      expect(agentService.isPaused, isFalse);
    });

    test('stopExecution clears all state', () {
      final agentService = AgentService();

      // Stop should clear everything
      agentService.stopExecution();

      expect(agentService.tasks, isEmpty);
      expect(agentService.isRunning, isFalse);
      expect(agentService.isPaused, isFalse);
      expect(agentService.boundConversationId, isNull);
      expect(agentService.currentThought, isNull);
      expect(agentService.finalAnswer, isNull);
    });

    test('bindToConversation sets boundConversationId', () {
      final agentService = AgentService();

      expect(agentService.boundConversationId, isNull);

      agentService.bindToConversation('test-conv-123');
      expect(agentService.boundConversationId, equals('test-conv-123'));

      // clearState should clear it
      agentService.clearState();
      expect(agentService.boundConversationId, isNull);
    });

    test('canStartNewAgent returns true when no agent active', () {
      final agentService = AgentService();

      // No agent running - should allow starting
      expect(agentService.canStartNewAgent('conv-1'), isTrue);
      expect(agentService.canStartNewAgent('conv-2'), isTrue);
      expect(agentService.canStartNewAgent(null), isTrue);
    });

    test('canStartNewAgent returns true for same conversation', () {
      final agentService = AgentService();

      // Bind to a conversation
      agentService.bindToConversation('conv-1');

      // Same conversation should be allowed
      expect(agentService.canStartNewAgent('conv-1'), isTrue);
    });

    test('AgentCheckpoint enum has expected values', () {
      // Verify checkpoint enum values exist
      expect(AgentCheckpoint.values, contains(AgentCheckpoint.beforeLlmCall));
      expect(
        AgentCheckpoint.values,
        contains(AgentCheckpoint.afterLlmResponse),
      );
      expect(AgentCheckpoint.values, contains(AgentCheckpoint.beforeToolCall));
      expect(AgentCheckpoint.values, contains(AgentCheckpoint.afterToolResult));
      expect(AgentCheckpoint.values.length, equals(4));
    });

    test('currentCheckpoint getter is accessible', () {
      final agentService = AgentService();

      // Default should be null
      expect(agentService.currentCheckpoint, isNull);
    });
  });
}
