// test/context_manager_skill_compaction_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/context_node.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/model_selector.dart';

import 'context_manager_skill_compaction_test.mocks.dart';

@GenerateMocks([AIService, ModelSelector])
void main() {
  late MockAIService mockAi;
  late MockModelSelector mockModelSelector;
  late ContextManagerService contextManager;

  setUp(() {
    mockAi = MockAIService();
    mockModelSelector = MockModelSelector();
    // Return null so getModelContextBudget falls back to kDefaultContextBudget
    when(mockModelSelector.currentModelConfig).thenReturn(null);
    contextManager = ContextManagerService(mockModelSelector, mockAi);
  });

  group('loaded skills survive context compaction', () {
    test('skills remain intact after compactNodeContext clears the execution log',
        () async {
      // Arrange: create root context and load two skills
      final root = await contextManager.createRootContext(
        objective: 'Test objective',
        maxTokens: 10000,
      );

      contextManager.addLoadedSkill('skill-note-1', '# Skill 1\nDo step A');
      contextManager.addLoadedSkill('skill-note-2', '# Skill 2\nDo step B');

      // Populate the execution log with enough entries to pass the guard (>= 10)
      for (var i = 0; i < 12; i++) {
        root.log('Log entry $i: some work was done here');
      }

      // Mock the AI summarization call
      when(mockAi.generateWithAttachments(any, any,
              generationContext: anyNamed('generationContext')))
          .thenAnswer((_) async => 'Compacted summary of previous work');

      // Act: compact the execution log
      await contextManager.compactNodeContext(root);

      // Assert: execution log was compacted
      expect(root.executionLog.length, lessThan(12),
          reason: 'Compaction should reduce log size');
      expect(root.executionLog.first, contains('[Previous work summarized]'),
          reason: 'Compacted log should start with summary marker');

      // Assert: skills survived compaction
      expect(root.loadedSkills.length, equals(2),
          reason: 'Both skills must survive compaction');
      expect(root.loadedSkills[0].noteId, equals('skill-note-1'));
      expect(root.loadedSkills[0].content, equals('# Skill 1\nDo step A'));
      expect(root.loadedSkills[1].noteId, equals('skill-note-2'));
      expect(root.loadedSkills[1].content, equals('# Skill 2\nDo step B'));
    });

    test('checkAndCompact compacts when near token limit; skills survive',
        () async {
      // Arrange: create root context with a very small token budget
      // maxTokens=100 means threshold is 80 tokens (80% of 100)
      final root = await contextManager.createRootContext(
        objective: 'Compact threshold test',
        maxTokens: 100,
      );

      contextManager.addLoadedSkill('skill-pinned', 'Pinned skill content');

      // Log enough content to push estimatedTokens past 80% of 100
      // Each log() call recalculates estimatedTokens = executionLog.join().length ~/ 4
      // We need > 80 tokens => > 320 chars in the joined log
      for (var i = 0; i < 15; i++) {
        root.log(
            'Entry $i: ${'x' * 25}'); // ~29 chars each, 15 * 29 = 435 chars => ~108 tokens
      }

      expect(root.isNearTokenLimit(), isTrue,
          reason: 'Must be near token limit to trigger checkAndCompact');

      when(mockAi.generateWithAttachments(any, any,
              generationContext: anyNamed('generationContext')))
          .thenAnswer((_) async => 'Summary');

      // Act
      await contextManager.checkAndCompact(root);

      // Assert: skill still pinned
      expect(root.loadedSkills.length, equals(1));
      expect(root.loadedSkills.first.noteId, equals('skill-pinned'));
      expect(root.loadedSkills.first.content, equals('Pinned skill content'));
    });
  });

  group('addLoadedSkill deduplication', () {
    test('second call with same noteId is ignored', () async {
      await contextManager.createRootContext(
        objective: 'Dedup test',
        maxTokens: 10000,
      );

      contextManager.addLoadedSkill('note-42', 'Original content');
      contextManager.addLoadedSkill('note-42', 'Duplicate content');

      final root = contextManager.rootContext!;
      expect(root.loadedSkills.length, equals(1),
          reason: 'Duplicate noteId must be ignored');
      expect(root.loadedSkills.first.content, equals('Original content'),
          reason: 'First registration wins');
    });

    test('different noteIds are both retained', () async {
      await contextManager.createRootContext(
        objective: 'Multi-skill test',
        maxTokens: 10000,
      );

      contextManager.addLoadedSkill('note-A', 'Content A');
      contextManager.addLoadedSkill('note-B', 'Content B');
      contextManager.addLoadedSkill('note-A', 'Content A duplicate');

      final root = contextManager.rootContext!;
      expect(root.loadedSkills.length, equals(2),
          reason: 'Two distinct noteIds means two skills');
      expect(root.loadedSkills.map((s) => s.noteId),
          containsAll(['note-A', 'note-B']));
    });

    test('addLoadedSkill is a no-op when rootContext is null', () {
      // No createRootContext call — rootContext is null
      expect(
        () => contextManager.addLoadedSkill('note-x', 'content'),
        returnsNormally,
        reason: 'Should not throw when rootContext is null',
      );
    });
  });
}
