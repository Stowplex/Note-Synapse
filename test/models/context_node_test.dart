import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/context_node.dart';

void main() {
  group('ContextNode', () {
    test('creates with default values', () {
      final node = ContextNode(id: 'test-1', objective: 'Test objective');

      expect(node.id, 'test-1');
      expect(node.objective, 'Test objective');
      expect(node.parentId, isNull);
      expect(node.depth, 0);
      expect(node.status, ContextNodeStatus.pending);
      expect(node.executionLog, isEmpty);
      expect(node.children, isEmpty);
      expect(node.summary, isNull);
      expect(node.maxContextTokens, 100000);
      expect(node.estimatedTokens, 0);
    });

    test('log adds entry and updates token estimate', () {
      final node = ContextNode(id: 'test-1', objective: 'Test objective');

      node.log('First log entry');
      expect(node.executionLog.length, 1);
      expect(node.executionLog[0], 'First log entry');
      expect(node.estimatedTokens, greaterThan(0));

      node.log('Second log entry');
      expect(node.executionLog.length, 2);
    });

    test('addChild adds child and updates timestamp', () {
      final parent = ContextNode(id: 'parent', objective: 'Parent objective');

      final child = ContextNode(
        id: 'child',
        parentId: 'parent',
        objective: 'Child objective',
        depth: 1,
      );

      parent.addChild(child);

      expect(parent.children.length, 1);
      expect(parent.children[0].id, 'child');
      expect(parent.updatedAt, isNotNull);
    });

    test('findChild locates nested children', () {
      final root = ContextNode(id: 'root', objective: 'Root');
      final child1 = ContextNode(
        id: 'child1',
        parentId: 'root',
        objective: 'Child 1',
      );
      final grandchild = ContextNode(
        id: 'grandchild',
        parentId: 'child1',
        objective: 'Grandchild',
      );

      child1.addChild(grandchild);
      root.addChild(child1);

      expect(root.findChild('child1')?.id, 'child1');
      expect(root.findChild('grandchild')?.id, 'grandchild');
      expect(root.findChild('nonexistent'), isNull);
    });

    test(
      'getCompletedChildSummaries returns only completed children summaries',
      () {
        final parent = ContextNode(id: 'parent', objective: 'Parent');

        final completed = ContextNode(
          id: 'completed',
          parentId: 'parent',
          objective: 'Completed task',
          status: ContextNodeStatus.completed,
          summary: 'Task result',
        );

        final pending = ContextNode(
          id: 'pending',
          parentId: 'parent',
          objective: 'Pending task',
          status: ContextNodeStatus.pending,
        );

        parent.addChild(completed);
        parent.addChild(pending);

        final summaries = parent.getCompletedChildSummaries();
        expect(summaries.length, 1);
        expect(summaries[0], contains('Completed task'));
        expect(summaries[0], contains('Task result'));
      },
    );

    test('isNearTokenLimit returns true when approaching limit', () {
      final node = ContextNode(
        id: 'test',
        objective: 'Test',
        maxContextTokens: 100,
        estimatedTokens: 85,
      );

      expect(node.isNearTokenLimit(), isTrue);

      final nodeUnderLimit = ContextNode(
        id: 'test2',
        objective: 'Test',
        maxContextTokens: 100,
        estimatedTokens: 50,
      );

      expect(nodeUnderLimit.isNearTokenLimit(), isFalse);
    });

    test('toJson and fromJson round-trip correctly', () {
      final original = ContextNode(
        id: 'test-1',
        parentId: 'parent-1',
        objective: 'Test objective',
        executionLog: ['Log 1', 'Log 2'],
        summary: 'Test summary',
        status: ContextNodeStatus.completed,
        depth: 2,
        maxContextTokens: 50000,
        estimatedTokens: 1000,
        allowedTools: ['tool1', 'tool2'],
      );

      final child = ContextNode(
        id: 'child-1',
        parentId: 'test-1',
        objective: 'Child objective',
        depth: 3,
      );
      original.addChild(child);

      final json = original.toJson();
      final restored = ContextNode.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.parentId, original.parentId);
      expect(restored.objective, original.objective);
      expect(restored.executionLog, original.executionLog);
      expect(restored.summary, original.summary);
      expect(restored.status, original.status);
      expect(restored.depth, original.depth);
      expect(restored.maxContextTokens, original.maxContextTokens);
      expect(restored.estimatedTokens, original.estimatedTokens);
      expect(restored.allowedTools, original.allowedTools);
      expect(restored.children.length, 1);
      expect(restored.children[0].id, 'child-1');
    });

    test('copyWith creates modified copy', () {
      final original = ContextNode(
        id: 'test',
        objective: 'Original objective',
        status: ContextNodeStatus.pending,
      );

      final modified = original.copyWith(
        objective: 'Modified objective',
        status: ContextNodeStatus.active,
      );

      expect(modified.id, original.id);
      expect(modified.objective, 'Modified objective');
      expect(modified.status, ContextNodeStatus.active);
      // Original unchanged
      expect(original.objective, 'Original objective');
      expect(original.status, ContextNodeStatus.pending);
    });
  });
}
