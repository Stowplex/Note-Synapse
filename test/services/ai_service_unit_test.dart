import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';

@GenerateMocks([DatabaseService, ModelSelector])
import 'ai_service_unit_test.mocks.dart';
import '../utils/test_prompt_template_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockDatabaseService mockDb;
  late MockModelSelector mockModelSelector;
  late AIService service;

  setUp(() async {
    await resetForTesting();
    SharedPreferences.setMockInitialValues({});
    mockDb = MockDatabaseService();
    mockModelSelector = MockModelSelector();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<ModelSelector>(mockModelSelector);
    await registerTestPromptTemplateService();
    service = AIService(mockDb, mockModelSelector);
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('AIService prompt execution', () {
    test('executePrompt calls ModelSelector.generateFromPrompt', () async {
      when(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async => 'AI response');

      final request = PromptRequest.singleTurn(
        systemMessage: PromptMessage(role: PromptRole.system, content: 'You are helpful'),
        userMessage: PromptMessage(role: PromptRole.user, content: 'Hello'),
      );

      final result = await service.executePrompt(request);

      expect(result, equals('AI response'));
      verify(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).called(1);
    });

    test('executePrompt handles errors gracefully', () async {
      when(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).thenThrow(Exception('Network error'));

      final request = PromptRequest.singleTurn(
        systemMessage: PromptMessage(role: PromptRole.system, content: 'System'),
        userMessage: PromptMessage(role: PromptRole.user, content: 'User'),
      );

      expect(
        () => service.executePrompt(request),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('AIService note transformation', () {
    test('transformNote generates transformed content', () async {
      when(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async => 'Transformed note content');

      final note = Note(
        id: 'test-note-1',
        title: 'Test Note',
        content: 'Original content',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final result = await service.transformNote(note, 'Summarize this note');

      expect(result, equals('Transformed note content'));
    });
  });

  group('AIService text extraction', () {
    test('extractContentFromText returns parsed result', () async {
      when(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async => 'Extracted content here');

      final result = await service.extractContentFromText(
        'Some text to extract from',
        'Article',
        'Test Title',
      );

      expect(result['success'], equals(true));
      expect(result['content'], equals('Extracted content here'));
    });
  });

  group('AIService app generation', () {
    test('generateApp returns HTML code', () async {
      when(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async => '<html><body>Generated App</body></html>');

      final result = await service.generateApp('Create a simple app');

      expect(result, contains('<html>'));
    });
  });

  group('AIService chat', () {
    test('chatAI returns response', () async {
      when(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async => 'Chat response');

      final result = await service.chatAI('Hello');

      expect(result, equals('Chat response'));
    });

    test('chatAI passes temperature parameter', () async {
      when(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async => 'Response with temperature');

      final result = await service.chatAI(
        'Hello',
        temperature: 0.7,
      );

      expect(result, equals('Response with temperature'));
      verify(mockModelSelector.generateFromPrompt(
        any,
        temperature: 0.7,
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).called(1);
    });
  });

  group('AIService dedup rules', () {
    test('suggestDedupRules returns parsed rules', () async {
      // Mock response with JSON array of dedup rules
      when(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async => '''
[
  {"pattern": "test.*", "replacement": "test", "reason": "Normalize test tags"}
]
''');

      final result = await service.suggestDedupRules(['test1', 'test2', 'other']);

      expect(result, isA<List>());
    });

    test('suggestDedupRules handles empty response', () async {
      when(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async => '[]');

      final result = await service.suggestDedupRules(['tag1', 'tag2']);

      expect(result, isEmpty);
    });
  });

  group('AIService block transformation', () {
    test('transformBlock extracts content from transformed tags', () async {
      when(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async =>
          '<transformed>\nTransformed block content\n</transformed>\n\n<notes>\nSome assumption\n</notes>');

      final result = await service.transformBlock(
        '## Original Block\nSome text',
        'Make it shorter',
      );

      expect(result, equals('Transformed block content'));

      // Verify the prompt contains block content and instruction
      final captured = verify(mockModelSelector.generateFromPrompt(
        captureAny,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).captured.single as PromptRequest;
      expect(captured.conversationMessages.first.content,
          contains('Make it shorter'));
      expect(captured.conversationMessages.first.content,
          contains('## Original Block'));
    });

    test('transformBlock falls back to raw response without tags', () async {
      when(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async => 'Raw response without tags');

      final result = await service.transformBlock('content', 'instruction');

      expect(result, equals('Raw response without tags'));
    });

    test('transformBlock propagates errors', () async {
      when(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).thenThrow(Exception('API error'));

      expect(
        () => service.transformBlock('content', 'instruction'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('AIService generateWithAttachments', () {
    test('generateWithAttachments returns response', () async {
      when(mockModelSelector.generateFromPrompt(
        any,
        temperature: anyNamed('temperature'),
        topK: anyNamed('topK'),
        topP: anyNamed('topP'),
        maxOutputTokens: anyNamed('maxOutputTokens'),
        generationContext: anyNamed('generationContext'),
      )).thenAnswer((_) async => 'Response with attachments processed');

      final result = await service.generateWithAttachments(
        'Analyze this',
        [], // empty attachments list
      );

      expect(result, equals('Response with attachments processed'));
    });
  });
}
