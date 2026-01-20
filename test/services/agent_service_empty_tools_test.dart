import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/services/agent_service.dart';

/// Tests for tasks with empty tools arrays.
///
/// These tests verify that tasks with `tools: []` still invoke the LLM
/// to do "thinking" work (creative writing, analysis, reasoning) rather
/// than being skipped as no-ops.
///
/// Bug context: Previously, tasks with empty tools that were NOT marked as
/// `isFinalDeliverable` or `extractFindings` were immediately marked as
/// "completed" without any LLM invocation, causing the "OUTPUT TRANSFORMATION"
/// prompt to appear prematurely.
void main() {
  group('AgentService - Tasks with Empty Tools Array', () {
    late AgentService agentService;
    bool llmWasCalled = false;

    setUp(() {
      agentService = AgentService();
      llmWasCalled = false;
    });

    test(
      'Task with empty tools array should invoke LLM (not skip as no-op)',
      () async {
        // This test verifies the core bug fix:
        // A task like "conceive_story_elements" has tools: [] but should
        // still invoke the LLM to do the creative work.
        final task = AgentTask(
          id: 'conceive_elements',
          name: 'conceive_story_elements',
          description: '构思穿越题材故事的核心元素',
          // No tools - this is a "thinking" task
          toolNames: [],
          allowedTools: [],
          // NOT a final deliverable - this is an intermediate step
          isFinalDeliverable: false,
          // NOT extracting findings
          extractFindings: false,
        );

        // Track if LLM is actually called
        agentService.llmGenerator = (prompt) async {
          llmWasCalled = true;
          // Return a valid answer action to complete the task
          return '''
<MyThought>I'll conceive the story elements for this task.</MyThought>
<Action type="answer">
<Content>
# 故事核心元素

## 主角设定
- 姓名: 王小明
- 身份: 2020年代高中生

## 穿越方式
- 在历史课上打瞌睡，醒来发现自己在三国时代

## 喜剧元素
- 主角用现代梗和古人交流
</Content>
</Action>
''';
        };

        await agentService.performTaskForTest(task, 'Global context here');

        // CRITICAL ASSERTION: The LLM MUST be called for thinking tasks
        expect(
          llmWasCalled,
          isTrue,
          reason:
              'LLM should be invoked for tasks with empty tools array. '
              'These are "thinking" tasks that require LLM reasoning.',
        );

        // Task should complete with actual content from LLM
        expect(task.status, equals(AgentTaskStatus.completed));
        expect(task.result, contains('故事核心元素'));
        expect(task.result, contains('王小明'));
      },
    );

    test(
      'Task with empty tools should NOT be marked completed immediately',
      () async {
        // This tests the specific bug: tasks were marked "completed"
        // with result "Thought step completed." without doing any work.
        final task = AgentTask(
          id: 'analyze_task',
          name: 'analyze_data',
          description: 'Analyze and reason about the data',
          toolNames: [],
          allowedTools: [],
          isFinalDeliverable: false,
          extractFindings: false,
        );

        // If LLM gets called, the bug is fixed
        agentService.llmGenerator = (prompt) async {
          llmWasCalled = true;
          return '''
<MyThought>Analyzing the data carefully.</MyThought>
<Action type="answer">
<Content>Analysis complete: The data shows clear patterns.</Content>
</Action>
''';
        };

        await agentService.performTaskForTest(task, 'Context');

        // Before the fix, this would be false (LLM never called)
        expect(llmWasCalled, isTrue);

        // Before the fix, result would be "Thought step completed."
        expect(task.result, isNot(equals('Thought step completed.')));
        expect(task.result, contains('Analysis complete'));
      },
    );

    test('Creative writing task with no tools invokes LLM', () async {
      // Real-world scenario: creative writing tasks don't need external tools
      final task = AgentTask(
        id: 'create_outline',
        name: 'create_outline',
        description: '基于构思的故事元素，创建小说的基本大纲',
        toolNames: [],
        allowedTools: [],
        isFinalDeliverable: false,
        extractFindings: false,
      );

      String? capturedPrompt;
      agentService.llmGenerator = (prompt) async {
        llmWasCalled = true;
        capturedPrompt = prompt;
        return '''
<MyThought>Creating outline based on story elements.</MyThought>
<Action type="answer">
<Content>
# 小说大纲

## 第一章：穿越
历史课上打瞌睡...

## 第二章：初遇
遇到关羽...
</Content>
</Action>
''';
      };

      await agentService.performTaskForTest(
        task,
        'Previous story elements context...',
      );

      expect(llmWasCalled, isTrue);
      expect(capturedPrompt, isNotNull);
      expect(capturedPrompt, contains('创建小说的基本大纲'));
      expect(task.result, contains('小说大纲'));
    });

    test(
      'Task with extractFindings=true and empty tools invokes LLM (control)',
      () async {
        // This is the existing behavior that works - extractFindings=true
        // causes LLM invocation even without tools.
        final task = AgentTask(
          id: 'extract_task',
          description: 'Task with findings extraction',
          toolNames: [],
          allowedTools: [],
          isFinalDeliverable: false,
          extractFindings: true, // This flag currently enables LLM invocation
        );

        agentService.llmGenerator = (prompt) async {
          llmWasCalled = true;
          return '''
<MyThought>Working on this task.</MyThought>
<Action type="answer">
<Content>Task completed with findings.</Content>
</Action>
''';
        };

        await agentService.performTaskForTest(task, 'Context');

        // This should always pass - it's the existing working path
        expect(llmWasCalled, isTrue);
      },
    );

    test(
      'Task with isFinalDeliverable=true and empty tools invokes LLM (control)',
      () async {
        // Another existing behavior that works - final deliverable tasks
        // invoke LLM even without tools.
        final task = AgentTask(
          id: 'final_task',
          description: 'Final deliverable task',
          toolNames: [],
          allowedTools: [],
          isFinalDeliverable: true, // This flag enables LLM invocation
          extractFindings: false,
        );

        agentService.llmGenerator = (prompt) async {
          llmWasCalled = true;
          return 'Here is the final deliverable content.';
        };

        await agentService.performTaskForTest(task, 'Context');

        expect(llmWasCalled, isTrue);
      },
    );
  });
}
