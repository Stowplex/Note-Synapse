// test/min_context_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/service_locator.dart';

import 'min_context_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late SkillService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = SkillService(mockDb);
  });

  group('parseSkillMetadata with min_context', () {
    test('parses min_context field', () {
      const content =
          '---\nname: Wiki Ingest\ndescription: Ingest sources\nmin_context: 50000\n---\n\nbody';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta, isNotNull);
      expect(meta!.minContext, 50000);
    });

    test('defaults minContext to null when absent', () {
      const content = '---\nname: Simple\ndescription: A skill\n---\n\nbody';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta!.minContext, isNull);
    });

    test('handles non-numeric min_context gracefully', () {
      const content =
          '---\nname: Bad\ndescription: Desc\nmin_context: lots\n---\n\nbody';
      final meta = service.parseSkillMetadata('note-1', content);
      expect(meta!.minContext, isNull);
    });
  });

  group('buildSkillIndexPrompt with min_context annotations', () {
    test('annotates constrained skills when budget is small', () {
      final index = {
        'id-1': SkillMetadata(
          noteId: 'id-1',
          skillRef: 'wiki-ingest',
          name: 'Wiki Ingest',
          description: 'Ingest',
          enabled: true,
          minContext: 50000,
        ),
        'id-2': SkillMetadata(
          noteId: 'id-2',
          skillRef: 'simple',
          name: 'Simple',
          description: 'Simple skill',
          enabled: true,
        ),
      };
      final prompt = service.buildSkillIndexPrompt(
        index,
        maxBudgetTokens: 16000,
      );
      expect(prompt, contains('limited'));
      expect(prompt, contains('Wiki Ingest'));
    });
  });
}
