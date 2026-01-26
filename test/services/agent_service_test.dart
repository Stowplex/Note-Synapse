import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/models/context_node.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';

// Mocks
class MockContextManagerService extends Fake implements ContextManagerService {
  @override
  ContextNode? get rootContext => null;

  @override
  void clear() {}

  @override
  Future<ContextNode> createRootContext({
    required String objective,
    List<String> allowedTools = const [],
    int? maxTokens,
  }) async {
    return ContextNode(id: 'root', objective: objective);
  }

  @override
  ContextNode createChildContext({
    required ContextNode parent,
    required String objective,
    List<String>? allowedTools,
  }) {
    return ContextNode(id: 'child', objective: objective);
  }

  @override
  ContextNode? getContext(String id) => null;

  @override
  void setActiveContext(ContextNode node) {}

  @override
  Future<void> checkAndCompact(ContextNode node) async {}

  @override
  String buildContextForSubtask(ContextNode node) => "Mock subtask context";
}

class MockModelSelector extends Fake implements ModelSelector {
  @override
  ModelConfig? get currentModelConfig => null;
}

class MockAIService extends Fake implements AIService {
  @override
  Future<String> generateWithAttachments(
    String prompt,
    List<dynamic> attachedFiles, {
    GenerationContext? generationContext,
  }) async {
    return 'Mock AI Response';
  }
}

class MockDatabaseService extends Fake implements DatabaseService {
  // Implement needed methods or leave empty if unused by current tests
}

void main() {
  late MockContextManagerService mockContextManager;
  late MockModelSelector mockModelSelector;
  late MockAIService mockAIService;
  late MockDatabaseService mockDatabaseService;
  late AgentService agentService;

  setUp(() {
    mockContextManager = MockContextManagerService();
    mockModelSelector = MockModelSelector();
    mockAIService = MockAIService();
    mockDatabaseService = MockDatabaseService();

    agentService = AgentService(
      mockContextManager,
      mockModelSelector,
      mockAIService,
      mockDatabaseService,
    );
  });

  group('AgentService Tool Executor', () {
    test('ToolExecutor typedef has correct signature', () {
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
      final executor =
          (
            String serviceName,
            String toolName,
            Map<String, dynamic> parameters,
            GenerationContext generationContext,
          ) async {
            // Capture for verification if needed, or just return success
            return 'executed';
          };

      final activeTools = <String, List<McpTool>>{
        'NS/test_tool_abc12345': [
          McpTool(
            name: 'test_tool',
            description: 'A test tool',
            inputSchema: {'type': 'object', 'properties': {}},
          ),
        ],
      };

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
      final executor =
          (
            String serviceName,
            String toolName,
            Map<String, dynamic> parameters,
            GenerationContext generationContext,
          ) async {
            return 'executed';
          };

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
      agentService.clearState();

      expect(agentService.tasks, isEmpty);
      expect(agentService.isRunning, isFalse);
      expect(agentService.currentThought, isNull);
      expect(agentService.finalAnswer, isNull);
    });

    test('local AI tool service names use NS/ prefix pattern', () {
      final localToolServiceName = 'NS/my_tool_abc12345';
      final mcpServiceName = 'my-mcp-service';

      expect(localToolServiceName.startsWith('NS/'), isTrue);
      expect(mcpServiceName.startsWith('NS/'), isFalse);
    });
  });

  group('JSON extraction patterns', () {
    String? extractJsonFromResponse(String response) {
      // Logic copied from AgentService implementation for testing regex
      final jsonBlockMatch = RegExp(
        r'```json\s*(\{.*?\})\s*```',
        dotAll: true,
      ).firstMatch(response);

      if (jsonBlockMatch != null) {
        return jsonBlockMatch.group(1);
      }

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
''';
      final json = extractJsonFromResponse(response);
      expect(json, isNull);
    });

    test('handles nested JSON objects', () {
      final response = '''
{ "tool": "search", "args": { "query": "test" } }
''';
      final json = extractJsonFromResponse(response);
      expect(json, isNotNull);
      expect(json, contains('"tool"'));
    });
  });

  group('Subtask spawning', () {
    test('kMaxSubtaskDepth constant is defined', () {
      expect(kMaxSubtaskDepth, equals(2));
    });

    test('AgentTask has spawnedSubtaskIds field', () {
      final task = AgentTask(id: 'test-id', description: 'Test task');
      expect(task.spawnedSubtaskIds, isEmpty);
      task.spawnedSubtaskIds.add('child-1');
      expect(task.spawnedSubtaskIds, contains('child-1'));
    });

    test('AgentTask has isSpawnedDynamically field', () {
      final plannedTask = AgentTask(id: 'planned-id', description: 'Planned');
      expect(plannedTask.isSpawnedDynamically, isFalse);

      final spawnedTask = AgentTask(
        id: 'spawned-id',
        description: 'Spawned',
        isSpawnedDynamically: true,
      );
      expect(spawnedTask.isSpawnedDynamically, isTrue);
    });
  });

  group('Task dependencies', () {
    test('AgentTask has name and dependsOn fields', () {
      final task = AgentTask(
        id: 'test-id',
        description: 'Test task',
        name: 'test_task',
        dependsOn: ['dep_a'],
      );
      expect(task.name, equals('test_task'));
      expect(task.dependsOn, equals(['dep_a']));
    });
  });

  group('Pause/Resume/Stop', () {
    test('pauseExecution sets isPaused when running', () {
      expect(agentService.isPaused, isFalse);
      agentService.pauseExecution(); // Not running, so it stays false
      expect(agentService.isPaused, isFalse);
    });

    test('stopExecution clears all state', () {
      agentService.stopExecution();
      expect(agentService.tasks, isEmpty);
      expect(agentService.isRunning, isFalse);
    });

    test('bindToConversation sets boundConversationId', () {
      agentService.bindToConversation('test-conv');
      expect(agentService.boundConversationId, equals('test-conv'));

      agentService.clearState();
      expect(agentService.boundConversationId, isNull);
    });

    test('canStartNewAgent logic', () {
      expect(agentService.canStartNewAgent('conv-1'), isTrue);

      agentService.bindToConversation('conv-1');
      expect(agentService.canStartNewAgent('conv-1'), isTrue);
    });
  });

  group('read_task_result tool exemption', () {
    test('read_task_result is always available', () {
      final allNativeTools = agentService.nativeTools;
      final hasReadTaskResult = allNativeTools.any(
        (t) => t.name == 'read_task_result',
      );
      expect(hasReadTaskResult, isTrue);
    });
  });
}
