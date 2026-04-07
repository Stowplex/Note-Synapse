import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/widgets/workflow_status_banner.dart';

void main() {
  Widget buildHarness(WorkflowStatusSnapshot status) {
    return MaterialApp(
      home: Scaffold(
        body: WorkflowStatusBanner(
          status: status,
          onAbort: () {},
          onResume: () {},
          onBail: () {},
        ),
      ),
    );
  }

  testWidgets('shows recovery actions for turn-limit pauses', (tester) async {
    await tester.pumpWidget(
      buildHarness(
        const WorkflowStatusSnapshot(
          noteId: 'note-1',
          matchedTag: 'wiki-source-ai',
          taskId: 'task-1',
          state: WorkflowExecutionState.pausedTurnLimit,
          message: 'Max turns reached. Paused.',
        ),
      ),
    );

    expect(find.text('Max turns reached. Paused.'), findsOneWidget);
    expect(find.text('Abort'), findsOneWidget);
    expect(find.text('Add Turns'), findsOneWidget);
    expect(find.text('Bail'), findsOneWidget);
  });

  testWidgets('does not show action buttons while workflow is running', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildHarness(
        const WorkflowStatusSnapshot(
          noteId: 'note-1',
          matchedTag: 'wiki-source-ai',
          taskId: 'task-1',
          state: WorkflowExecutionState.running,
          message: 'Running workflow for "wiki-source-ai"',
        ),
      ),
    );

    expect(find.text('Running workflow for "wiki-source-ai"'), findsOneWidget);
    expect(find.text('Abort'), findsNothing);
    expect(find.text('Add Turns'), findsNothing);
    expect(find.text('Bail'), findsNothing);
  });
}
