import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/prompts/ai_prompts.dart';
import 'package:note_synapse/services/prompts/note_prompt_builder.dart';
import 'package:note_synapse/services/service_locator.dart';

@GenerateMocks([DatabaseService])
import 'note_prompt_builder_test.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockDatabaseService mockDb;
  late NotePromptBuilder builder;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    builder = NotePromptBuilder(mockDb);
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('buildBlockTransformationPrompt', () {
    test('returns PromptRequest with block content and instruction', () {
      final request = builder.buildBlockTransformationPrompt(
        blockContent: '## Hello World\nSome content here.',
        instruction: 'Make it more concise',
      );

      // System message should contain shared transformation guidelines
      expect(request.systemMessage.content,
          contains(AIPrompts.mathFormulaGuidelines));
      expect(request.systemMessage.content,
          contains(AIPrompts.promptInjectionProtectionGuidelines));

      // User message should contain the instruction and block content
      final userContent = request.conversationMessages.first.content;
      expect(userContent, contains('Make it more concise'));
      expect(userContent, contains('## Hello World'));
      expect(userContent, contains('Some content here.'));
    });

    test('has no context messages (block-level, not note-level)', () {
      final request = builder.buildBlockTransformationPrompt(
        blockContent: 'Some block',
        instruction: 'Fix grammar',
      );

      expect(request.contextMessages, isEmpty);
    });

    test('system prompt is block-specific, not note-specific', () {
      final request = builder.buildBlockTransformationPrompt(
        blockContent: 'content',
        instruction: 'edit',
      );

      // Should NOT mention note metadata, sub-notes, tags, etc.
      expect(request.systemMessage.content, isNot(contains('sub-notes')));
      expect(request.systemMessage.content, isNot(contains('metadata')));
    });
  });
}
