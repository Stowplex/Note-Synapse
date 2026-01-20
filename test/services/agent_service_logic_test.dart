import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/services/agent_service.dart';

void main() {
  group('AgentService Logic Tests with XML Format', () {
    late AgentService agentService;

    setUp(() {
      agentService = AgentService();
    });

    // Helper to run a single task step
    Future<void> runStep(AgentTask task, String mockLlmResponse) async {
      agentService.llmGenerator = (prompt) async => mockLlmResponse;
      // Ensure search_notes is in allowed tools logic if needed
      task.toolNames = ['search_notes'];
      task.allowedTools = ['search_notes'];
      await agentService.performTaskForTest(task, "Global Context Placeholder");
    }

    test(
      'Case 1: Regular task, Missing Action element -> Error reported',
      () async {
        final task = AgentTask(
          id: '1',
          description: 'Regular task',
          isFinalDeliverable: false,
        );

        // Make sure task has tools so it doesn't auto-complete as no-op
        task.toolNames = ['search_notes'];

        // Response: Just text, no XML Action element
        agentService.llmGenerator = (prompt) async {
          return "I am thinking about this problem."; // No XML Action
        };

        await agentService.performTaskForTest(task, "Context");

        // Expectation:
        // - Task should NOT be completed (status != completed)
        // - History should contain error about missing Action element
        expect(task.status, isNot(AgentTaskStatus.completed));
        expect(
          task.executionHistory.any((h) => h.contains('Missing <Action')),
          isTrue,
        );
      },
    );

    test(
      'Case 2: Regular task, Valid XML tool action -> performing action',
      () async {
        final task = AgentTask(
          id: '2',
          description: 'Regular task action',
          isFinalDeliverable: false,
        );

        // Response with valid XML tool action
        const llmResponse = '''
<MyThought>I need to search for relevant notes.</MyThought>
<Action type="tool">
<ToolName>search_notes</ToolName>
<Content>{"query": "test"}</Content>
</Action>
''';

        await runStep(task, llmResponse);

        expect(
          task.executionHistory.any(
            (h) => h.contains('Action: Call search_notes'),
          ),
          isTrue,
        );
      },
    );

    test(
      'Case 3: Final Deliverable, Missing Action -> Complete as Answer (fallback)',
      () async {
        final task = AgentTask(
          id: '3',
          description: 'Final task',
          isFinalDeliverable: true,
        );

        // Response: Just text, no XML. For final deliverable, this is treated as direct answer.
        final llmResponse = "Here is the final report.\n\n# Summary\nIt works.";

        await runStep(task, llmResponse);

        expect(task.status, equals(AgentTaskStatus.completed));
        expect(task.result, contains("Here is the final report"));
      },
    );

    test(
      'Case 4: Final Deliverable, Valid XML tool action -> Perform tool',
      () async {
        final task = AgentTask(
          id: '4',
          description: 'Final task needs info',
          isFinalDeliverable: true,
        );

        // Response: Valid XML tool call. Even if final, it takes priority.
        const llmResponse = '''
<MyThought>I need one more piece of information.</MyThought>
<Action type="tool">
<ToolName>search_notes</ToolName>
<Content>{"query": "final check"}</Content>
</Action>
''';

        await runStep(task, llmResponse);

        // Should interpret as tool call, NOT finish the task yet
        expect(
          task.executionHistory.any(
            (h) => h.contains('Action: Call search_notes'),
          ),
          isTrue,
        );
        expect(task.status, isNot(AgentTaskStatus.completed));
      },
    );

    test(
      'Case 5: Final Deliverable, Valid XML answer -> Complete with content',
      () async {
        final task = AgentTask(
          id: '5',
          description: 'Final task with answer',
          isFinalDeliverable: true,
        );

        // Response: Valid XML answer action
        const llmResponse = '''
<MyThought>I have all the information I need.</MyThought>
<Action type="answer">
<Content>
# Analysis Report

## Summary
The investigation reveals important findings.

## Findings
1. First finding
2. Second finding
</Content>
</Action>
''';

        await runStep(task, llmResponse);

        expect(task.status, equals(AgentTaskStatus.completed));
        expect(task.result, contains("# Analysis Report"));
        expect(task.result, contains("First finding"));
      },
    );

    test(
      'Case 6: Regular Task, Invalid action type -> Error in history',
      () async {
        final task = AgentTask(
          id: '6',
          description: 'Regular task with invalid type',
          isFinalDeliverable: false,
        );

        const llmResponse = '''
<MyThought>Doing something.</MyThought>
<Action type="invalid_action">
<Content>something</Content>
</Action>
''';

        await runStep(task, llmResponse);

        expect(task.status, isNot(AgentTaskStatus.completed));
        expect(
          task.executionHistory.any((h) => h.contains('Invalid action type')),
          isTrue,
        );
      },
    );

    test('Case 7: Tool action without ToolName -> Error reported', () async {
      final task = AgentTask(
        id: '7',
        description: 'Tool without name',
        isFinalDeliverable: false,
      );

      const llmResponse = '''
<MyThought>I'll search.</MyThought>
<Action type="tool">
<Content>{"query": "test"}</Content>
</Action>
''';

      await runStep(task, llmResponse);

      expect(task.status, isNot(AgentTaskStatus.completed));
      expect(
        task.executionHistory.any((h) => h.contains('<ToolName>')),
        isTrue,
      );
    });

    test(
      'Case 8: Tool action with invalid JSON args -> Error reported',
      () async {
        final task = AgentTask(
          id: '8',
          description: 'Tool with bad JSON',
          isFinalDeliverable: false,
        );

        const llmResponse = '''
<MyThought>Searching.</MyThought>
<Action type="tool">
<ToolName>search_notes</ToolName>
<Content>this is not valid json</Content>
</Action>
''';

        await runStep(task, llmResponse);

        expect(task.status, isNot(AgentTaskStatus.completed));
        expect(task.executionHistory.any((h) => h.contains('JSON')), isTrue);
      },
    );

    test('Case 9: Think action continues without tool call', () async {
      final task = AgentTask(
        id: '9',
        description: 'Think action',
        isFinalDeliverable: false,
      );

      const llmResponse = '''
<MyThought>I need to analyze the data.</MyThought>
<Action type="think">
<Content>Looking at the patterns, I notice that the data shows...</Content>
</Action>
''';

      await runStep(task, llmResponse);

      // Task should not complete (continuing reasoning)
      expect(task.status, isNot(AgentTaskStatus.completed));
      expect(task.executionHistory.any((h) => h.contains('Analysis:')), isTrue);
    });

    test('Case 10: spawn_subtasks action creates subtasks', () async {
      final task = AgentTask(
        id: '10',
        description: 'Complex task',
        isFinalDeliverable: false,
        depth: 0, // Root level
      );

      const llmResponse = '''
<MyThought>This is complex, I'll decompose it.</MyThought>
<Action type="spawn_subtasks">
<Content>[{"description": "Research topic A", "tools": ["search"]}, {"description": "Research topic B", "tools": ["search"]}]</Content>
</Action>
''';

      await runStep(task, llmResponse);

      // Should have spawned subtasks
      expect(task.spawnedSubtaskIds.length, equals(2));
    });

    test('Case 11: spawn_subtasks with invalid JSON -> Error', () async {
      final task = AgentTask(
        id: '11',
        description: 'Bad spawn',
        isFinalDeliverable: false,
      );

      const llmResponse = '''
<MyThought>Decomposing.</MyThought>
<Action type="spawn_subtasks">
<Content>{"not": "an array"}</Content>
</Action>
''';

      await runStep(task, llmResponse);

      expect(task.status, isNot(AgentTaskStatus.completed));
      expect(task.executionHistory.any((h) => h.contains('array')), isTrue);
    });

    test('Case 12: spawn_subtasks missing description -> Error', () async {
      final task = AgentTask(
        id: '12',
        description: 'Bad spawn fields',
        isFinalDeliverable: false,
      );

      const llmResponse = '''
<MyThought>Decomposing.</MyThought>
<Action type="spawn_subtasks">
<Content>[{"tools": ["search"]}]</Content>
</Action>
''';

      await runStep(task, llmResponse);

      expect(task.status, isNot(AgentTaskStatus.completed));
      expect(
        task.executionHistory.any((h) => h.contains('description')),
        isTrue,
      );
    });

    test('Case 13: Tool Content with code fences is handled', () async {
      final task = AgentTask(
        id: '13',
        description: 'Tool with fenced JSON',
        isFinalDeliverable: false,
      );

      // Some LLMs wrap JSON in code fences even when told not to
      const llmResponse = '''
<MyThought>Searching with formatted args.</MyThought>
<Action type="tool">
<ToolName>search_notes</ToolName>
<Content>
```json
{"query": "test with fences"}
```
</Content>
</Action>
''';

      await runStep(task, llmResponse);

      expect(
        task.executionHistory.any(
          (h) => h.contains('Action: Call search_notes'),
        ),
        isTrue,
      );
    });

    test('Case 14: Thought extraction from MyThought element', () async {
      final task = AgentTask(
        id: '14',
        description: 'Test thought extraction',
        isFinalDeliverable: false,
      );

      const llmResponse = '''
<MyThought>This is my detailed reasoning about the problem at hand.</MyThought>
<Action type="think">
<Content>Further analysis here.</Content>
</Action>
''';

      await runStep(task, llmResponse);

      expect(
        task.executionHistory.any(
          (h) => h.contains('Thought: This is my detailed reasoning'),
        ),
        isTrue,
      );
    });
  });
}
