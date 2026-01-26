import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'mock_agent_dependencies.dart';

import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('AgentService Resume', () {
    test('resumeExecution should parse XML final answer', () async {
      final agentService = AgentService(
        MockContextManagerService(),
        MockModelSelector(),
        MockAIService(),
        MockDatabaseService(),
      );

      // Mock the LLM generator to return a valid XML final answer
      agentService.llmGenerator = (prompt) async {
        // If the prompt is asking for a plan, return a JSON list
        if (prompt.contains('TASK CONFIGURATION')) {
          return '''
[
  {
    "name": "main_task",
    "description": "Just do it",
    "tools": [],
    "dependsOn": [],
    "isFinalDeliverable": true,
    "extractFindings": false
  }
]
''';
        }

        // Return XML answer
        return '''
<MyThought>I have finished the task.</MyThought>
<Action type="answer">
<Content>parsed final result</Content>
</Action>
''';
      };

      await agentService.startObjective("test");

      if (agentService.finalAnswer == null) {
        for (var t in agentService.tasks) {
          print(
            'Task: ${t.description}, Status: ${t.status}, Result: ${t.result}',
          );
          print('History: ${t.executionHistory}');
        }
      }

      // Verify parsing functionality
      expect(agentService.finalAnswer, equals('parsed final result'));
      expect(
        agentService.finalAnswer,
        isNot(contains('<Action')),
      ); // Should not contain raw tags

      agentService.pauseExecution();

      await agentService.resumeExecution();

      // Verify persistence after resume
      expect(agentService.finalAnswer, equals('parsed final result'));
    });
  });
}
