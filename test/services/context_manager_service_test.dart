import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/context_node.dart';
import 'package:note_synapse/services/context_manager_service.dart';

void main() {
  group('ContextManagerService', () {
    late ContextManagerService service;

    setUp(() {
      service = ContextManagerService();
    });

    test('createRootContext creates root with correct properties', () {
      final root = service.createRootContext(
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

    test('createChildContext creates child with inherited properties', () {
      final root = service.createRootContext(
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
    });

    test('createChildContext with custom tools', () {
      final root = service.createRootContext(
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

    test('setActiveContext updates current context', () {
      final root = service.createRootContext(objective: 'Root');
      final child = service.createChildContext(
        parent: root,
        objective: 'Child',
      );

      expect(service.currentContext, root);

      service.setActiveContext(child);

      expect(service.currentContext, child);
      expect(child.status, ContextNodeStatus.active);
    });

    test('buildContextForNode includes root and ancestor context', () {
      final root = service.createRootContext(objective: 'Research project');
      root.summary = 'Global progress made';

      final child = service.createChildContext(
        parent: root,
        objective: 'Research subtopic',
      );
      child.log('Started research');
      child.log('Found useful data');

      final context = service.buildContextForNode(child);

      expect(context, contains('Global Objective'));
      expect(context, contains('Research project'));
      expect(context, contains('Global progress made'));
      expect(context, contains('Current Task: Research subtopic'));
      expect(context, contains('Started research'));
      expect(context, contains('Found useful data'));
    });

    test('buildContextForNode includes sibling summaries', () {
      final root = service.createRootContext(objective: 'Main task');

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

      expect(context, contains('Related Completed Work'));
      expect(context, contains('Sibling 1'));
      expect(context, contains('Sibling 1 results'));
    });

    test('markContextFailed sets status and logs error', () {
      final root = service.createRootContext(objective: 'Task');

      service.markContextFailed(root, 'Something went wrong');

      expect(root.status, ContextNodeStatus.failed);
      expect(root.summary, contains('failed'));
      expect(root.executionLog, anyElement(contains('ERROR')));
    });

    test('getContext retrieves context by ID', () {
      final root = service.createRootContext(objective: 'Root');
      final child = service.createChildContext(
        parent: root,
        objective: 'Child',
      );

      expect(service.getContext(root.id), root);
      expect(service.getContext(child.id), child);
      expect(service.getContext('nonexistent'), isNull);
    });

    test('clear removes all context state', () {
      service.createRootContext(objective: 'Root');

      expect(service.rootContext, isNotNull);
      expect(service.currentContext, isNotNull);

      service.clear();

      expect(service.rootContext, isNull);
      expect(service.currentContext, isNull);
    });

    test('exportSnapshot and importSnapshot preserve context tree', () {
      final root = service.createRootContext(objective: 'Root');
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
      final newService = ContextManagerService();
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
      test('child budget is calculated from parent remaining budget', () {
        final root = service.createRootContext(
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

      test('child budget has minimum threshold', () {
        final root = service.createRootContext(
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
  });
}
