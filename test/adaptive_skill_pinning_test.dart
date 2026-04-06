// test/adaptive_skill_pinning_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'adaptive_skill_pinning_test.mocks.dart';

@GenerateMocks([DatabaseService, AIService, ModelSelector])
void main() {
  late ContextManagerService contextManager;
  late MockAIService mockAi;
  late MockModelSelector mockModelSelector;

  setUp(() async {
    await resetForTesting();
    mockAi = MockAIService();
    mockModelSelector = MockModelSelector();
    getIt.registerSingleton<AIService>(mockAi);
    getIt.registerSingleton<ModelSelector>(mockModelSelector);
    contextManager = ContextManagerService(mockModelSelector, mockAi);
  });

  group('addLoadedSkill with budget', () {
    test('stores full content when under 30% pinning budget on 100K model', () async {
      await contextManager.createRootContext(
        objective: 'Test',
        maxTokens: 100000,
      );
      final skillContent = '## Skill\n' + 'Step: do something.\n' * 50;
      contextManager.addLoadedSkill('skill-1', skillContent);
      final root = contextManager.rootContext!;
      expect(root.loadedSkills.length, 1);
      expect(root.loadedSkills[0].content, skillContent);
    });

    test('stores summary when skill would exceed 30% budget on 8K model', () async {
      await contextManager.createRootContext(
        objective: 'Test',
        maxTokens: 8000,
      );
      // 30% of 8K = 2400 tokens = ~9600 chars

      // skill1: ~1600 tokens (~6400 chars at 4 chars/token)
      final skill1 = '## Big Skill\n' + 'Detailed step with explanation.\n' * 200;
      contextManager.addLoadedSkill('skill-1', skill1);
      expect(contextManager.rootContext!.loadedSkills[0].content, skill1);

      // skill2: ~1100 tokens more would make total ~2700 > 2400
      final skill2 = '## Second Skill\n' + 'Another detailed step.\n' * 200;
      contextManager.addLoadedSkill('skill-2', skill2);

      final stored = contextManager.rootContext!.loadedSkills[1];
      expect(stored.noteId, 'skill-2');
      expect(stored.content.length, lessThan(skill2.length));
      expect(stored.content, contains('Skill loaded but summarized'));
    });
  });
}
