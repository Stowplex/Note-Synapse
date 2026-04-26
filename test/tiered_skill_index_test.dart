// test/tiered_skill_index_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'tiered_skill_index_test.mocks.dart';
import 'utils/test_prompt_template_setup.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late SkillService service;

  final tenSkills = Map.fromEntries(
    List.generate(
      10,
      (i) => MapEntry(
        'id-$i',
        SkillMetadata(
          noteId: 'id-$i',
          skillRef: 'skill-$i',
          name: 'Skill $i',
          description: 'Description for skill $i that is somewhat verbose',
          enabled: true,
        ),
      ),
    ),
  );

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    await registerTestPromptTemplateService();
    service = SkillService(mockDb);
  });

  group('buildSkillIndexPrompt with maxBudgetTokens', () {
    test('full format when budget is large (100K+)', () {
      final prompt = service.buildSkillIndexPrompt(
        tenSkills,
        maxBudgetTokens: 100000,
      );
      expect(prompt, contains('skillRef=skill-0'));
      expect(prompt, contains('name=Skill 0'));
      expect(prompt, contains('when=Description for skill 0'));
    });

    test('compact format when budget is medium (15K-50K)', () {
      final prompt = service.buildSkillIndexPrompt(
        tenSkills,
        maxBudgetTokens: 15000,
      );
      expect(prompt, contains('skillRef=skill-0'));
      expect(prompt, contains('name=Skill 0'));
      expect(prompt, isNot(contains('when=Description for skill 0')));
    });

    test('minimal format when budget is small (<15K)', () {
      final prompt = service.buildSkillIndexPrompt(
        tenSkills,
        maxBudgetTokens: 8000,
      );
      expect(prompt, contains('skillRef=skill-0'));
      expect(prompt, contains('name=Skill 0'));
      expect(prompt, contains('skillRef=skill-9'));
      expect(prompt.length, lessThan(900));
    });

    test('returns empty string for empty index regardless of budget', () {
      expect(
        service.buildSkillIndexPrompt({}, maxBudgetTokens: 100000),
        isEmpty,
      );
      expect(service.buildSkillIndexPrompt({}, maxBudgetTokens: 8000), isEmpty);
    });

    test('defaults to full format when maxBudgetTokens not specified', () {
      final prompt = service.buildSkillIndexPrompt(tenSkills);
      expect(prompt, contains('when=Description for skill 0'));
    });
  });
}
