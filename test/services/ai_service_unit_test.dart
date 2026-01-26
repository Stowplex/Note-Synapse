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
}
