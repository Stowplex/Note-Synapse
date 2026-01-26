// Tests for XML tag stripping in final deliverable fallback path.
//
// These tests verify that when XML parsing fails for a final deliverable task,
// the fallback behavior properly strips XML wrapper tags from the response.
//
// TDD approach: These tests should FAIL with current implementation
// and PASS after the fix.

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'mock_agent_dependencies.dart';

void main() {
  group('AgentService - XML Tag Stripping in Final Deliverable Fallback', () {
    late AgentService agentService;

    setUp(() {
      agentService = AgentService(
        MockContextManagerService(),
        MockModelSelector(),
        MockAIService(),
        MockDatabaseService(),
      );
    });

    test(
      'REGRESSION: Final deliverable fallback should strip <answer> tags',
      () async {
        // This is the main regression test for the bug reported by the user.
        // When a final deliverable's XML parsing fails (e.g., LLM uses <answer>
        // instead of <Action type="answer"><Content>), the fallback uses the
        // entire response but should strip the invalid tags.

        final task = AgentTask(
          id: 'final_story',
          name: 'write_story',
          description: 'Write a short detective story',
          toolNames: [],
          allowedTools: [],
          isFinalDeliverable: true,
          extractFindings: false,
        );

        // Response that FAILS XML parsing because it uses wrong format:
        // <answer> instead of <Action type="answer"><Content>
        // This triggers the fallback path for isFinalDeliverable tasks.
        agentService.llmGenerator = (prompt) async {
          return '''
<MyThought>Completing the story now.</MyThought>
<answer>
# The Detective's Last Case

Inspector Chen examined the crime scene carefully.
"Elementary," he muttered, spotting the mud on the carpet.

## The End
Justice was served.
</answer>
''';
        };

        await agentService.performTaskForTest(task, 'Story context');

        expect(task.status, equals(AgentTaskStatus.completed));

        // REGRESSION: <answer> tags should be stripped from final answer
        // Currently this FAILS because fallback doesn't strip <answer> tags
        expect(
          task.result,
          isNot(contains('<answer>')),
          reason: '<answer> tag should be stripped from final answer',
        );
        expect(
          task.result,
          isNot(contains('</answer>')),
          reason: '</answer> tag should be stripped from final answer',
        );

        // But the actual content should be present
        expect(task.result, contains("Detective's Last Case"));
        expect(task.result, contains('Inspector Chen'));
        expect(task.result, contains('Justice was served'));
      },
    );

    test(
      'Final deliverable result already clean if XML parsing succeeds',
      () async {
        // Control test: When XML parsing succeeds, the content is already clean.
        // This verifies the normal (non-fallback) path works correctly.

        final task = AgentTask(
          id: 'clean_task',
          name: 'clean_output',
          description: 'Task with clean XML response',
          toolNames: [],
          allowedTools: [],
          isFinalDeliverable: true,
          extractFindings: false,
        );

        agentService.llmGenerator = (prompt) async {
          // Clean, well-formed XML that parses successfully
          return '''
<MyThought>Generating clean output.</MyThought>
<Action type="answer">
<Content>
# Clean Output

This is properly formatted content.
- Item 1
- Item 2
</Content>
</Action>
''';
        };

        await agentService.performTaskForTest(task, 'Context');

        expect(task.status, equals(AgentTaskStatus.completed));

        // Result should NOT contain XML tags (XML parser extracts content)
        expect(task.result, isNot(contains('<Action')));
        expect(task.result, isNot(contains('<Content>')));
        expect(task.result, isNot(contains('<MyThought>')));

        // Should contain actual content
        expect(task.result, contains('Clean Output'));
        expect(task.result, contains('Item 1'));
      },
    );

    test('Fallback strips <MyThought> tags when XML parsing fails', () async {
      // Verify that the existing stripping for <MyThought> works.
      // This should already pass.

      final task = AgentTask(
        id: 'thought_strip',
        name: 'thought_strip_task',
        description: 'Task testing thought stripping',
        toolNames: [],
        allowedTools: [],
        isFinalDeliverable: true,
        extractFindings: false,
      );

      agentService.llmGenerator = (prompt) async {
        // Invalid format that triggers fallback
        return '''
<MyThought>This thought should be stripped.</MyThought>

# My Answer

This is the content that should remain.
''';
      };

      await agentService.performTaskForTest(task, 'Context');

      expect(task.status, equals(AgentTaskStatus.completed));

      // <MyThought> should be stripped (this already works)
      expect(task.result, isNot(contains('<MyThought>')));
      expect(task.result, isNot(contains('</MyThought>')));
      expect(task.result, isNot(contains('This thought should be stripped')));

      // Content should remain
      expect(task.result, contains('My Answer'));
    });
  });
}
