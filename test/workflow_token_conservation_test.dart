import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/agent_service.dart';

void main() {
  group('WorkflowStatusSnapshot extensions', () {
    test('snapshot includes turnsUsed, maxTurns, noteTitle', () {
      final snapshot = WorkflowStatusSnapshot(
        noteId: 'note-1',
        matchedTag: 'wiki-source-ml',
        taskId: 'task-1',
        state: WorkflowExecutionState.running,
        message: 'Running',
        noteTitle: 'Attention is all you need',
        turnsUsed: 3,
        maxTurns: 10,
      );
      expect(snapshot.noteTitle, 'Attention is all you need');
      expect(snapshot.turnsUsed, 3);
      expect(snapshot.maxTurns, 10);
    });
  });

  group('PendingWorkflowInfo', () {
    test('holds noteId, noteTitle, matchedTag', () {
      final info = PendingWorkflowInfo(
        noteId: 'note-2',
        noteTitle: 'BERT paper',
        matchedTag: 'wiki-source-ai',
      );
      expect(info.noteId, 'note-2');
      expect(info.noteTitle, 'BERT paper');
      expect(info.matchedTag, 'wiki-source-ai');
    });
  });
}
