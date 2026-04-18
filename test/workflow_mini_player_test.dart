// test/workflow_mini_player_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/widgets/workflow_mini_player.dart';

void main() {
  group('WorkflowMiniPlayer', () {
    testWidgets('hidden when no active workflow', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkflowMiniPlayer(
              activeStatus: null,
              pendingWorkflows: const [],
              currentThought: null,
              onStop: () {},
              onPause: () {},
              onResume: () {},
              onViewLog: () {},
              onCancelPending: (_) {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      // Should render as zero-height
      expect(find.byType(WorkflowMiniPlayer), findsOneWidget);
      expect(find.text('Running'), findsNothing);
    });

    testWidgets('shows collapsed state when running', (tester) async {
      final status = WorkflowStatusSnapshot(
        noteId: 'note-1',
        matchedTag: 'wiki-source-ml',
        taskId: 'task-1',
        state: WorkflowExecutionState.running,
        message: 'Running workflow',
        noteTitle: 'Attention is all you need',
        turnsUsed: 3,
        maxTurns: 10,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkflowMiniPlayer(
              activeStatus: status,
              pendingWorkflows: const [],
              currentThought: 'Searching compiled notes...',
              onStop: () {},
              onPause: () {},
              onResume: () {},
              onViewLog: () {},
              onCancelPending: (_) {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      expect(find.textContaining('Attention is all you need'), findsOneWidget);
      expect(find.textContaining('Searching compiled notes'), findsOneWidget);
    });

    testWidgets('shows queue badge when pending workflows exist', (tester) async {
      final status = WorkflowStatusSnapshot(
        noteId: 'note-1',
        matchedTag: 'wiki-source-ml',
        taskId: 'task-1',
        state: WorkflowExecutionState.running,
        message: 'Running',
        noteTitle: 'Paper A',
        turnsUsed: 1,
        maxTurns: 10,
      );
      final pending = [
        PendingWorkflowInfo(noteId: 'n2', noteTitle: 'Paper B', matchedTag: 'wiki-source-ml'),
        PendingWorkflowInfo(noteId: 'n3', noteTitle: 'Paper C', matchedTag: 'wiki-source-ml'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkflowMiniPlayer(
              activeStatus: status,
              pendingWorkflows: pending,
              currentThought: 'Working...',
              onStop: () {},
              onPause: () {},
              onResume: () {},
              onViewLog: () {},
              onCancelPending: (_) {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      expect(find.text('+2'), findsOneWidget);
    });

    testWidgets('expands on tap to show actions and queue', (tester) async {
      final status = WorkflowStatusSnapshot(
        noteId: 'note-1',
        matchedTag: 'wiki-source-ml',
        taskId: 'task-1',
        state: WorkflowExecutionState.running,
        message: 'Running',
        noteTitle: 'Paper A',
        turnsUsed: 3,
        maxTurns: 10,
      );
      final pending = [
        PendingWorkflowInfo(noteId: 'n2', noteTitle: 'Paper B', matchedTag: 'wiki-source-ml'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkflowMiniPlayer(
              activeStatus: status,
              pendingWorkflows: pending,
              currentThought: 'Working...',
              onStop: () {},
              onPause: () {},
              onResume: () {},
              onViewLog: () {},
              onCancelPending: (_) {},
              onDismiss: () {},
            ),
          ),
        ),
      );

      // Tap to expand
      await tester.tap(find.byType(InkWell).first);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Stop'), findsOneWidget);
      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('View Log'), findsOneWidget);
      expect(find.textContaining('Paper B'), findsOneWidget);
    });

    testWidgets('shows Add Turns and Abort when pausedTurnLimit', (tester) async {
      final status = WorkflowStatusSnapshot(
        noteId: 'note-1',
        matchedTag: 'wiki-source-ml',
        taskId: 'task-1',
        state: WorkflowExecutionState.pausedTurnLimit,
        message: 'Turn limit reached',
        noteTitle: 'Paper A',
        turnsUsed: 10,
        maxTurns: 10,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkflowMiniPlayer(
              activeStatus: status,
              pendingWorkflows: const [],
              currentThought: null,
              onStop: () {},
              onPause: () {},
              onResume: () {},
              onViewLog: () {},
              onCancelPending: (_) {},
              onDismiss: () {},
            ),
          ),
        ),
      );

      // Auto-expanded when paused
      expect(find.text('Abort'), findsOneWidget);
      expect(find.text('Add Turns'), findsOneWidget);
    });

    testWidgets('shows Resume and Abort when pausedManual', (tester) async {
      final status = WorkflowStatusSnapshot(
        noteId: 'note-1',
        matchedTag: 'wiki-source-ml',
        taskId: 'task-1',
        state: WorkflowExecutionState.pausedManual,
        message: 'Paused by user',
        noteTitle: 'Paper A',
        turnsUsed: 5,
        maxTurns: 10,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkflowMiniPlayer(
              activeStatus: status,
              pendingWorkflows: const [],
              currentThought: null,
              onStop: () {},
              onPause: () {},
              onResume: () {},
              onViewLog: () {},
              onCancelPending: (_) {},
              onDismiss: () {},
            ),
          ),
        ),
      );

      // Auto-expanded when paused
      expect(find.text('Abort'), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Add Turns'), findsNothing);
    });

    testWidgets('completed state auto-dismisses after 2 seconds', (tester) async {
      bool dismissed = false;
      final status = WorkflowStatusSnapshot(
        noteId: 'note-1',
        matchedTag: 'wiki-source-ml',
        taskId: 'task-1',
        state: WorkflowExecutionState.completed,
        message: 'Done',
        noteTitle: 'Paper A',
        turnsUsed: 5,
        maxTurns: 10,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkflowMiniPlayer(
              activeStatus: status,
              pendingWorkflows: const [],
              currentThought: null,
              onStop: () {},
              onPause: () {},
              onResume: () {},
              onViewLog: () {},
              onCancelPending: (_) {},
              onDismiss: () { dismissed = true; },
            ),
          ),
        ),
      );

      // Not dismissed yet
      expect(dismissed, isFalse);

      // After 2 seconds, onDismiss should be called
      await tester.pump(const Duration(seconds: 2));
      expect(dismissed, isTrue);
    });
  });
}
