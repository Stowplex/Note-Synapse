import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/services/agent_service.dart';

void main() {
  group('AgentService Logic Tests', () {
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
      'Case 1: Regular task, Invalid JSON (Just Text) -> Fallback to Verdict',
      () async {
        final task = AgentTask(
          id: '1',
          description: 'Regular task',
          isFinalDeliverable: false,
        );

        // Mocks:
        // 1. Initial response: returns generic text (invalid action JSON)
        // 2. Verdict response: returns "think" verdict to continue analysis
        int callCount = 0;
        // Make sure task has tools so it doesn't auto-complete as no-op
        task.toolNames = ['search_notes'];

        agentService.llmGenerator = (prompt) async {
          callCount++;
          if (callCount == 1) {
            return "I am thinking about this problem."; // No JSON
          } else {
            // Verdict prompt
            return "<verdict>think</verdict><content>I am thinking about this problem.</content>";
          }
        };

        await agentService.performTaskForTest(task, "Context");

        // Expectation:
        // - Task should NOT be completed (status != completed)
        // - History should contain the "Analysis" from verdict
        expect(task.status, isNot(AgentTaskStatus.completed));
        expect(
          task.executionHistory.any(
            (h) => h.contains('Analysis: I am thinking'),
          ),
          isTrue,
        );
      },
    );

    test('Case 2: Regular task, Valid JSON Action -> performing action', () async {
      final task = AgentTask(
        id: '2',
        description: 'Regular task action',
        isFinalDeliverable: false,
      );

      // Response with valid tool action
      final jsonAction = jsonEncode({
        "tool": "search_notes",
        "args": {"query": "test"},
      });
      final llmResponse =
          'My thought: checking notes.\n```json\n$jsonAction\n```';

      // We need to mock the tool executor or native tool execution will fail/try real tools
      // For this test, valid JSON parsing is enough to verify it TRIES to call tool.
      // Since we don't mock tools here easily without more setup, we expect
      // checking executionHistory for "Action: Call search_notes"

      await runStep(task, llmResponse);

      expect(
        task.executionHistory.any(
          (h) => h.contains('Action: Call search_notes'),
        ),
        isTrue,
      );
    });

    test(
      'Case 3: Final Deliverable, Invalid JSON (Just Text) -> Complete as Answer',
      () async {
        final task = AgentTask(
          id: '3',
          description: 'Final task',
          isFinalDeliverable: true,
        );

        // Response: Just text, no JSON.
        // Should trigger the "direct markdown result" path for final deliverables.
        final llmResponse = "Here is the final report.\n\n# Summary\nIt works.";

        await runStep(task, llmResponse);

        expect(task.status, equals(AgentTaskStatus.completed));
        expect(task.result, contains("Here is the final report"));
      },
    );

    test(
      'Case 4: Final Deliverable, Valid JSON Action -> Perform Action',
      () async {
        final task = AgentTask(
          id: '4',
          description: 'Final task needs info',
          isFinalDeliverable: true,
        );

        // Response: Valid tool call. Even if final, it takes priority if formatted correctly.
        final jsonAction = jsonEncode({
          "tool": "search_notes",
          "args": {"query": "final check"},
        });
        final llmResponse =
            'My thought: checking one last thing.\n```json\n$jsonAction\n```';

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
      'Case 5: Final Deliverable, Valid JSON NO Action -> Complete as Answer',
      () async {
        // This is the FIX scenario.
        final task = AgentTask(
          id: '5',
          description: 'Final task with code block',
          isFinalDeliverable: true,
        );

        // Response contains valid JSON but it is DATA (code block), not an action.
        // E.g. a JSON snippet illustrative of something
        final jsonSnippet = jsonEncode({
          "some_key": "some_value",
          "data": [1, 2, 3],
        });

        final llmResponse =
            '''
Here is the API response example you asked for:

```json
$jsonSnippet
```

This confirms the schema.
''';

        await runStep(task, llmResponse);

        // Expectation with FIX:
        // The JSON should be ignored (validation fails).
        // The fallback to direct markdown should happen.
        // Task should be completed.
        // Result should contain the full text.
        expect(task.status, equals(AgentTaskStatus.completed));
        expect(task.result, contains("Here is the API response example"));
        expect(task.result, contains('"some_key":"some_value"'));
      },
    );
  });
}
