import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/agent_task.dart';
import 'package:note_synapse/models/context_node.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'context_manager_service_test.mocks.dart';

@GenerateMocks([
  ContextManagerService,
  ModelSelector,
  AIService,
  DatabaseService,
])
void main() {
  late MockModelSelector mockModelSelector;
  late MockAIService mockAIService;
  late MockDatabaseService mockDatabaseService;

  group('ContextManagerService', () {
    late ContextManagerService service;

    setUp(() async {
      await getIt.reset();
      mockModelSelector = MockModelSelector();
      mockAIService = MockAIService();
      mockDatabaseService = MockDatabaseService();

      getIt.registerSingleton<ModelSelector>(mockModelSelector);
      getIt.registerSingleton<AIService>(mockAIService);
      getIt.registerSingleton<DatabaseService>(mockDatabaseService);

      service = ContextManagerService(mockModelSelector, mockAIService);
      getIt.registerSingleton<ContextManagerService>(service);

      // Default stubs
      when(mockModelSelector.currentModelConfig).thenReturn(null);
      when(
        mockAIService.generateWithAttachments(
          any,
          any,
          generationContext: anyNamed('generationContext'),
        ),
      ).thenAnswer((_) async => 'Summary from MockAIService');

      // Initialize SharedPreferences with empty values for testing
      SharedPreferences.setMockInitialValues({});
    });

    test('createRootContext creates root with correct properties', () async {
      final root = await service.createRootContext(
        objective: 'Research vaccines',
        allowedTools: ['search', 'read'],
        maxTokens: 50000,
      );

      expect(root.id, isNotEmpty);
      expect(root.objective, 'Research vaccines');
      expect(root.depth, 0);
      expect(root.status, ContextNodeStatus.active);
      expect(root.allowedTools, ['search', 'read']);
      expect(root.maxContextTokens, 50000);
      expect(service.rootContext, root);
      expect(service.currentContext, root);
    });

    test(
      'createChildContext creates child with inherited properties',
      () async {
        final root = await service.createRootContext(
          objective: 'Main objective',
          allowedTools: ['tool1', 'tool2'],
        );

        final child = service.createChildContext(
          parent: root,
          objective: 'Subtask 1',
        );

        expect(child.parentId, root.id);
        expect(child.depth, 1);
        expect(child.objective, 'Subtask 1');
        expect(child.allowedTools, ['tool1', 'tool2']);
        expect(child.maxContextTokens, lessThan(root.maxContextTokens));
        expect(root.children, contains(child));
      },
    );

    test('createChildContext with custom tools', () async {
      final root = await service.createRootContext(
        objective: 'Main objective',
        allowedTools: ['tool1', 'tool2', 'tool3'],
      );

      final child = service.createChildContext(
        parent: root,
        objective: 'Focused subtask',
        allowedTools: ['tool1'],
      );

      expect(child.allowedTools, ['tool1']);
    });

    test('setActiveContext updates current context', () async {
      final root = await service.createRootContext(objective: 'Root');
      final child = service.createChildContext(
        parent: root,
        objective: 'Child',
      );

      expect(service.currentContext, root);

      service.setActiveContext(child);

      expect(service.currentContext, child);
      expect(child.status, ContextNodeStatus.active);
    });

    test('buildContextForNode includes root and ancestor context', () async {
      final root = await service.createRootContext(
        objective: 'Research project',
      );
      root.summary = 'Global progress made';

      final child = service.createChildContext(
        parent: root,
        objective: 'Research subtopic',
      );
      child.log('Started research');
      child.log('Found useful data');

      final context = service.buildContextForNode(child);

      expect(context, contains('GlobalObjective'));
      expect(context, contains('Research project'));
      expect(context, contains('Global progress made'));
      expect(context, contains('CurrentTask'));
      expect(context, contains('Research subtopic'));
      expect(context, contains('Started research'));
      expect(context, contains('Found useful data'));
    });

    test('buildContextForNode includes sibling summaries', () async {
      final root = await service.createRootContext(objective: 'Main task');

      final sibling1 = service.createChildContext(
        parent: root,
        objective: 'Sibling 1',
      );
      sibling1.status = ContextNodeStatus.completed;
      sibling1.summary = 'Sibling 1 results';

      final current = service.createChildContext(
        parent: root,
        objective: 'Current task',
      );

      final context = service.buildContextForNode(current);

      expect(context, contains('CompletedSiblings'));
      expect(context, contains('Sibling 1'));
      expect(context, contains('Sibling 1 results'));
    });

    test('markContextFailed sets status and logs error', () async {
      final root = await service.createRootContext(objective: 'Task');

      service.markContextFailed(root, 'Something went wrong');

      expect(root.status, ContextNodeStatus.failed);
      expect(root.summary, contains('failed'));
      expect(root.executionLog, anyElement(contains('ERROR')));
    });

    test('getContext retrieves context by ID', () async {
      final root = await service.createRootContext(objective: 'Root');
      final child = service.createChildContext(
        parent: root,
        objective: 'Child',
      );

      expect(service.getContext(root.id), root);
      expect(service.getContext(child.id), child);
      expect(service.getContext('nonexistent'), isNull);
    });

    test('clear removes all context state', () async {
      await service.createRootContext(objective: 'Root');

      expect(service.rootContext, isNotNull);
      expect(service.currentContext, isNotNull);

      service.clear();

      expect(service.rootContext, isNull);
      expect(service.currentContext, isNull);
    });

    test('exportSnapshot and importSnapshot preserve context tree', () async {
      final root = await service.createRootContext(objective: 'Root');
      root.log('Root log 1');

      final child = service.createChildContext(
        parent: root,
        objective: 'Child',
      );
      child.log('Child log 1');
      child.status = ContextNodeStatus.completed;
      child.summary = 'Child summary';

      final snapshot = service.exportSnapshot();
      expect(snapshot, isNotNull);

      // Create new service and import
      final newService = ContextManagerService(
        mockModelSelector,
        mockAIService,
      );
      newService.importSnapshot(snapshot!);

      expect(newService.rootContext?.objective, 'Root');
      expect(newService.rootContext?.executionLog, contains('Root log 1'));
      expect(newService.rootContext?.children.length, 1);

      final restoredChild = newService.rootContext!.children[0];
      expect(restoredChild.objective, 'Child');
      expect(restoredChild.status, ContextNodeStatus.completed);
      expect(restoredChild.summary, 'Child summary');
    });

    group('token budget management', () {
      test('child budget is calculated from parent remaining budget', () async {
        final root = await service.createRootContext(
          objective: 'Root',
          maxTokens: 100000,
        );
        root.estimatedTokens = 20000; // 80000 remaining

        final child = service.createChildContext(
          parent: root,
          objective: 'Child',
        );

        // Child should get ~60% of remaining (48000), not total
        expect(child.maxContextTokens, lessThan(100000));
        expect(child.maxContextTokens, greaterThan(kMinSubtaskBudget));
      });

      test('child budget has minimum threshold', () async {
        final root = await service.createRootContext(
          objective: 'Root',
          maxTokens: 10000,
        );
        root.estimatedTokens = 9500; // Only 500 remaining

        final child = service.createChildContext(
          parent: root,
          objective: 'Child',
        );

        // Should use minimum budget
        expect(child.maxContextTokens, kMinSubtaskBudget);
      });
    });

    group('generateTocFromResult', () {
      test('extracts headers with correct breadcrumbs', () {
        final result = service.generateTocFromResult(
          'task-1',
          'Research goal',
          '# Top\nIntro text\n## Sub1\nContent here\n### Sub1a\nDeep content\n## Sub2\nMore content',
        );

        expect(result.sections.length, 4);
        expect(result.sections[0].title, 'Top');
        expect(result.sections[0].breadcrumb, '# Top');
        expect(result.sections[1].title, 'Sub1');
        expect(result.sections[1].breadcrumb, '# Top > ## Sub1');
        expect(result.sections[2].title, 'Sub1a');
        expect(result.sections[2].breadcrumb, '# Top > ## Sub1 > ### Sub1a');
        expect(result.sections[3].title, 'Sub2');
        expect(result.sections[3].breadcrumb, '# Top > ## Sub2');
      });

      test('handles content without headers', () {
        final result = service.generateTocFromResult(
          'task-2',
          'Goal',
          'Plain text paragraph.\n\nAnother paragraph without any headers.',
        );

        expect(result.sections, isEmpty);
        expect(result.fullResult, contains('Plain text'));
      });

      test('handles markdown answer content (not JSON wrapper)', () {
        // Simulates properly extracted answer content
        final result = service.generateTocFromResult(
          'task-3',
          'Analysis task',
          '## Analysis Report\n\nKey findings here.\n\n### Data Points\n\n- Point 1\n- Point 2',
        );

        expect(result.sections.length, 2);
        expect(result.sections[0].title, 'Analysis Report');
        expect(result.sections[1].title, 'Data Points');
        expect(result.toc, contains('Analysis Report'));
      });
    });

    group('structuredResult and context building', () {
      test('structuredResult enables proper context type', () async {
        final root = await service.createRootContext(objective: 'Parent task');

        // Simulate task completion with markdown answer
        const answerContent =
            '# Report\n## Findings\nData here.\n## Conclusion\nSummary.';
        root.structuredResult = service.generateTocFromResult(
          root.id,
          'Parent task',
          answerContent,
        );
        root.status = ContextNodeStatus.completed;

        final child = service.createChildContext(
          parent: root,
          objective: 'Child task',
        );

        final context = service.buildContextForNode(child);

        // Should use type="full" or type="toc", not log-preview
        expect(
          context.contains('type="full"') || context.contains('type="toc"'),
          isTrue,
          reason:
              'Context should use "full" or "toc" type when structuredResult exists',
        );
        expect(context, isNot(contains('type="log-preview"')));
      });

      test('uses type="toc" with low threshold', () async {
        final root = await service.createRootContext(objective: 'Main');

        // Long content that exceeds threshold
        final longContent =
            '# Section 1\n${List.generate(200, (i) => 'word$i').join(' ')}\n# Section 2\n${List.generate(200, (i) => 'word$i').join(' ')}';
        root.structuredResult = service.generateTocFromResult(
          root.id,
          'Main task',
          longContent,
        );
        root.status = ContextNodeStatus.completed;

        final child = service.createChildContext(
          parent: root,
          objective: 'Child',
        );

        // Very low threshold forces TOC mode
        final context = service.buildContextForNode(child, tocThreshold: 100);

        expect(context, contains('type="toc"'));
        expect(context, contains('hint='));
      });

      test(
        'falls back to log-preview only when no structuredResult or summary',
        () async {
          final root = await service.createRootContext(objective: 'Main');
          root.log('Some execution log');
          root.status = ContextNodeStatus.completed;
          // NOTE: no structuredResult set, no summary set

          final child = service.createChildContext(
            parent: root,
            objective: 'Child',
          );
          final context = service.buildContextForNode(child);

          expect(context, contains('type="log-preview"'));
        },
      );
    });
  });

  group('LLM Answer Processing Pipeline - Integration Tests', () {
    late AgentService agentService;
    late ContextManagerService contextManager;

    setUp(() async {
      await getIt.reset();
      SharedPreferences.setMockInitialValues({});

      getIt.registerSingleton<ModelSelector>(mockModelSelector);
      getIt.registerSingleton<AIService>(mockAIService);
      getIt.registerSingleton<DatabaseService>(mockDatabaseService);

      // Register ContextManagerService so AgentService can find it
      final cms = ContextManagerService(mockModelSelector, mockAIService);
      getIt.registerSingleton<ContextManagerService>(cms);

      agentService = AgentService(
        cms,
        mockModelSelector,
        mockAIService,
        mockDatabaseService,
      );
      contextManager = agentService.contextManager;

      // Initialize the context manager with a root context
      await contextManager.createRootContext(objective: 'Test objective');
    });

    tearDown(() {
      agentService.clearState();
    });

    test(
      'performTask processes JSON answer and populates structuredResult',
      () async {
        // Mock the LLM to return an XML answer
        const mockLlmResponse = r'''
<MyThought>Research complete.</MyThought>
<Action type="answer">
<Content>
# Research Report

## Findings

Key data point 1.

## Conclusion

Summary here.
</Content>
</Action>
''';

        // Set the mock LLM generator
        when(
          mockAIService.generateWithAttachments(
            any,
            any,
            generationContext: anyNamed('generationContext'),
          ),
        ).thenAnswer((_) async => mockLlmResponse);

        // Create a task with a context node
        final rootNode = contextManager.rootContext!;
        final task = AgentTask(
          id: 'test-task-1',
          description: 'Research something',
          contextNodeId: rootNode.id,
          maxTurns: 1,
          isFinalDeliverable: true,
        );

        // Execute the task through the real _performTask pipeline
        await agentService.performTaskForTest(task, 'global context');

        // Verify: task result contains the answer content, not the JSON wrapper
        expect(task.result, isNotNull);
        expect(task.result, contains('# Research Report'));
        expect(task.result, contains('## Findings'));
        expect(task.result, isNot(contains('{"answer"')));
        expect(task.status, AgentTaskStatus.completed);

        // Verify: structuredResult was populated with TOC
        expect(rootNode.structuredResult, isNotNull);
        expect(rootNode.structuredResult!.sections.length, 3); // 1 H1 + 2 H2
        expect(rootNode.structuredResult!.toc, contains('Research Report'));
        expect(rootNode.structuredResult!.toc, contains('Findings'));
        expect(rootNode.structuredResult!.toc, contains('Conclusion'));
      },
    );

    test(
      'performTask populates structuredResult with TOC for long answers',
      () async {
        // Mock the LLM to return a long answer that should trigger TOC mode
        final manyWords = List.generate(150, (i) => 'word$i').join(' ');
        final mockLlmResponse =
            '''
<MyThought>Generated long content for TOC test.</MyThought>
<Action type="answer">
<Content>
# Section 1
$manyWords

# Section 2
$manyWords
</Content>
</Action>
''';

        when(
          mockAIService.generateWithAttachments(
            any,
            any,
            generationContext: anyNamed('generationContext'),
          ),
        ).thenAnswer((_) async => mockLlmResponse);

        final rootNode = contextManager.rootContext!;
        final task = AgentTask(
          id: 'test-task-2',
          description: 'Long research',
          contextNodeId: rootNode.id,
          maxTurns: 1,
          isFinalDeliverable: true,
        );

        await agentService.performTaskForTest(task, 'context');

        // Verify task completed
        expect(task.status, AgentTaskStatus.completed);
        expect(task.result, isNotNull);

        // Verify structuredResult has sections
        expect(rootNode.structuredResult, isNotNull);
        expect(rootNode.structuredResult!.sections.length, 2);

        // Verify token count exceeds threshold (for TOC mode)
        expect(
          rootNode.structuredResult!.fullResult.split(' ').length,
          greaterThan(100),
        );
      },
    );

    test(
      'context building uses correct result type based on structuredResult',
      () async {
        // First, complete a task to populate structuredResult
        const mockLlmResponse = r'''
<MyThought>Brief analysis complete.</MyThought>
<Action type="answer">
<Content>
# Short Report

Brief content.
</Content>
</Action>
''';

        when(
          mockAIService.generateWithAttachments(
            any,
            any,
            generationContext: anyNamed('generationContext'),
          ),
        ).thenAnswer((_) async => mockLlmResponse);

        final rootNode = contextManager.rootContext!;
        final task = AgentTask(
          id: 'test-task-3',
          description: 'Brief research',
          contextNodeId: rootNode.id,
          maxTurns: 1,
          isFinalDeliverable: true,
        );

        await agentService.performTaskForTest(task, 'context');
        rootNode.status = ContextNodeStatus.completed;

        // Create a child context to test context building
        final childNode = contextManager.createChildContext(
          parent: rootNode,
          objective: 'Follow-up task',
        );

        final context = contextManager.buildContextForNode(childNode);

        // Should use type="full" or type="toc", NOT log-preview
        expect(
          context.contains('type="full"') || context.contains('type="toc"'),
          isTrue,
          reason:
              'Context should use full/toc type when structuredResult exists',
        );
        expect(context, isNot(contains('type="log-preview"')));
      },
    );

    test(
      'full E2E: mocked LLM → performTask → structuredResult → context',
      () async {
        // This is the full end-to-end test that validates the complete wiring
        const mockLlmResponse = r'''
<MyThought>After analyzing, I have findings.</MyThought>
<Action type="answer">
<Content>
# Key Findings

## Finding 1
Data about X from Source A.

## Finding 2
Insight about Y from Source B.

## Conclusion
Recommend Z.
</Content>
</Action>
''';

        when(
          mockAIService.generateWithAttachments(
            any,
            any,
            generationContext: anyNamed('generationContext'),
          ),
        ).thenAnswer((_) async => mockLlmResponse);

        final rootNode = contextManager.rootContext!;
        final task = AgentTask(
          id: 'test-e2e',
          description: 'Full E2E test',
          contextNodeId: rootNode.id,
          maxTurns: 1,
          isFinalDeliverable: true,
        );

        // Step 1: Execute through real pipeline
        await agentService.performTaskForTest(task, 'global context');

        // Step 2: Verify task result is clean markdown (extracted from JSON)
        expect(task.result, startsWith('# Key Findings'));
        expect(task.result, contains('Finding 1'));
        expect(task.result, contains('Source A'));
        expect(task.result, isNot(contains('{"answer"')));

        // Step 3: Verify structuredResult was created with correct TOC
        expect(rootNode.structuredResult, isNotNull);
        expect(rootNode.structuredResult!.sections.length, 4); // 1 H1 + 3 H2
        expect(rootNode.structuredResult!.toc, contains('Key Findings'));
        expect(rootNode.structuredResult!.toc, contains('Finding 1'));
        expect(rootNode.structuredResult!.toc, contains('Finding 2'));
        expect(rootNode.structuredResult!.toc, contains('Conclusion'));

        // Step 4: Verify context building works with structuredResult
        rootNode.status = ContextNodeStatus.completed;
        final childNode = contextManager.createChildContext(
          parent: rootNode,
          objective: 'Use findings',
        );

        final context = contextManager.buildContextForNode(childNode);
        expect(
          context,
          contains('Key Findings'),
        ); // TOC or full content visible
        expect(context, isNot(contains('type="log-preview"')));
      },
    );
  });
}
