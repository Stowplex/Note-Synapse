// Test file for agentic mode state reset issues.
//
// These tests verify that agent state is properly cleared after task completion.

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'mock_agent_dependencies.dart';

void main() {
  group('Issue: Task state not resetting after completion', () {
    late AgentService agentService;

    setUp(() {
      agentService = AgentService(
        MockContextManagerService(),
        MockModelSelector(),
        MockAIService(),
        MockDatabaseService(),
      );
    });

    test('canStartNewAgent returns true when bound to same conversation', () {
      agentService.bindToConversation('convo1');

      expect(
        agentService.canStartNewAgent('convo1'),
        isTrue,
        reason: 'Should be able to start when bound to same conversation',
      );
    });

    test('canStartNewAgent returns true after clearState is called', () async {
      // This test documents the expected behavior after the fix.
      // The fix in _onAgentStateChange calls clearState after posting the answer,
      // which resets the agent state and allows new tasks.

      agentService.bindToConversation('convo-completed');

      // Simulate the fix: clearState should be called after task completion
      agentService.clearState();

      expect(agentService.isRunning, isFalse);
      expect(agentService.isPaused, isFalse);
      expect(agentService.tasks, isEmpty);
      // After clearState, canStartNewAgent should return true for any conversation
      expect(agentService.canStartNewAgent('different-convo'), isTrue);
    });

    test('clearState resets all agent state correctly', () {
      agentService.bindToConversation('convo1');

      agentService.clearState();

      expect(agentService.boundConversationId, isNull);
      expect(agentService.tasks, isEmpty);
      expect(agentService.isRunning, isFalse);
      expect(agentService.isPaused, isFalse);
      expect(agentService.finalAnswer, isNull);
      expect(agentService.currentThought, isNull);

      // Now a new conversation should be able to start
      expect(agentService.canStartNewAgent('any-new-convo'), isTrue);
    });

    test(
      'canStartNewAgent returns true when isRunning=false, isPaused=false, tasks empty',
      () {
        // Baseline test - this should pass
        expect(agentService.isRunning, isFalse);
        expect(agentService.isPaused, isFalse);
        expect(agentService.tasks, isEmpty);

        expect(agentService.canStartNewAgent('new-convo'), isTrue);
      },
    );
  });
}
