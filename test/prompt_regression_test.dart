import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/models/relationship.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/mcp_tool_integration_service.dart';
import 'package:note_synapse/services/prompts/ai_prompts.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/services/user_app_service.dart';
import 'package:note_synapse/services/prompts/note_prompt_builder.dart';
import 'package:note_synapse/services/prompts/prompt_models.dart';
import 'package:note_synapse/services/prompts/prompt_template_service.dart';
import 'package:note_synapse/services/prompts/system_prompt_builder.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Mock asset manifest to list all 5 guideline files
    final manifest = <String, List<String>>{
      'assets/prompts/guidelines/math_formula.md': [
        'assets/prompts/guidelines/math_formula.md',
      ],
      'assets/prompts/guidelines/internal_link.md': [
        'assets/prompts/guidelines/internal_link.md',
      ],
      'assets/prompts/guidelines/agentic_deliverable.md': [
        'assets/prompts/guidelines/agentic_deliverable.md',
      ],
      'assets/prompts/guidelines/relationship.md': [
        'assets/prompts/guidelines/relationship.md',
      ],
      'assets/prompts/guidelines/prompt_injection_protection.md': [
        'assets/prompts/guidelines/prompt_injection_protection.md',
      ],
      'assets/prompts/ai_prompts/content_extraction.md': [
        'assets/prompts/ai_prompts/content_extraction.md',
      ],
      'assets/prompts/ai_prompts/audio_transcription.md': [
        'assets/prompts/ai_prompts/audio_transcription.md',
      ],
      'assets/prompts/ai_prompts/audio_summarization.md': [
        'assets/prompts/ai_prompts/audio_summarization.md',
      ],
      'assets/prompts/ai_prompts/image_content_extraction.md': [
        'assets/prompts/ai_prompts/image_content_extraction.md',
      ],
      'assets/prompts/ai_prompts/pdf_content_extraction.md': [
        'assets/prompts/ai_prompts/pdf_content_extraction.md',
      ],
      'assets/prompts/ai_prompts/dedup_rules_suggestion.md': [
        'assets/prompts/ai_prompts/dedup_rules_suggestion.md',
      ],
      'assets/prompts/system_prompt/system.md': [
        'assets/prompts/system_prompt/system.md',
      ],
      'assets/prompts/note_prompts/question_system.md': [
        'assets/prompts/note_prompts/question_system.md',
      ],
      'assets/prompts/note_prompts/question_user.md': [
        'assets/prompts/note_prompts/question_user.md',
      ],
      'assets/prompts/note_prompts/transformation_system.md': [
        'assets/prompts/note_prompts/transformation_system.md',
      ],
      'assets/prompts/note_prompts/transformation_user.md': [
        'assets/prompts/note_prompts/transformation_user.md',
      ],
      'assets/prompts/note_prompts/block_transformation_system.md': [
        'assets/prompts/note_prompts/block_transformation_system.md',
      ],
      'assets/prompts/note_prompts/block_transformation_user.md': [
        'assets/prompts/note_prompts/block_transformation_user.md',
      ],
      'assets/prompts/note_prompts/new_note_creation_system.md': [
        'assets/prompts/note_prompts/new_note_creation_system.md',
      ],
      'assets/prompts/note_prompts/new_note_creation_user.md': [
        'assets/prompts/note_prompts/new_note_creation_user.md',
      ],
      'assets/prompts/skills/skill_index_compact.md': [
        'assets/prompts/skills/skill_index_compact.md',
      ],
      'assets/prompts/skills/skill_index_medium.md': [
        'assets/prompts/skills/skill_index_medium.md',
      ],
      'assets/prompts/skills/skill_index_full.md': [
        'assets/prompts/skills/skill_index_full.md',
      ],
      'assets/prompts/user_app/api_documentation.md': [
        'assets/prompts/user_app/api_documentation.md',
      ],
      'assets/prompts/user_app/requirements.md': [
        'assets/prompts/user_app/requirements.md',
      ],
      'assets/prompts/user_app/note_action_instructions.md': [
        'assets/prompts/user_app/note_action_instructions.md',
      ],
      'assets/prompts/user_app/ai_tool_instructions.md': [
        'assets/prompts/user_app/ai_tool_instructions.md',
      ],
      'assets/prompts/user_app/app_generation.md': [
        'assets/prompts/user_app/app_generation.md',
      ],
      'assets/prompts/user_app/app_edit.md': [
        'assets/prompts/user_app/app_edit.md',
      ],
      'assets/prompts/user_app/libraries_for_prompt.md': [
        'assets/prompts/user_app/libraries_for_prompt.md',
      ],
      'assets/prompts/mcp/tool_catalog.md': [
        'assets/prompts/mcp/tool_catalog.md',
      ],
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(message!.buffer.asUint8List());
      if (key == 'AssetManifest.json') {
        return ByteData.view(
          Uint8List.fromList(utf8.encode(json.encode(manifest))).buffer,
        );
      }
      // Fall through: read real file from disk (cwd is package root in flutter test)
      try {
        final file = File(key);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          return ByteData.view(Uint8List.fromList(bytes).buffer);
        }
      } catch (_) {}
      return null;
    });

    if (getIt.isRegistered<PromptTemplateService>()) {
      await getIt.unregister<PromptTemplateService>();
    }
    final service = PromptTemplateService();
    await service.preloadAll();
    getIt.registerSingleton<PromptTemplateService>(service);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  group('Guidelines regression', () {
    test('mathFormulaGuidelines contains key markers', () {
      final result = AIPrompts.mathFormulaGuidelines;
      expect(result, contains('Math Output Contract:'));
      expect(result, contains(r'\( E = mc^2 \)'));
      expect(result, contains(r'\[ \int_{-\infty}^{\infty}'));
      expect(result, contains(r'$...$'));
      expect(result, contains(r'$$...$$'));
    });

    test('internalLinkGuidelines contains synapseresource links', () {
      final result = AIPrompts.internalLinkGuidelines;
      expect(result, contains('synapseresource://note/'));
      expect(result, contains('synapseresource://conversation/'));
      expect(result, contains('synapseresource://attachment/'));
    });

    test('promptInjectionProtectionGuidelines contains DATA_ONLY_DOCUMENT', () {
      final result = AIPrompts.promptInjectionProtectionGuidelines;
      expect(result, contains('<DATA_ONLY_DOCUMENT>'));
      expect(result, contains('</DATA_ONLY_DOCUMENT>'));
    });

    test('relationshipGuidelines contains relationship types', () {
      final result = AIPrompts.relationshipGuidelines;
      expect(result, contains('answers'));
      expect(result, contains('causality'));
      expect(result, contains('→'));
      expect(result, contains('←'));
    });

    test('agenticDeliverableGuidelines contains formatting sections', () {
      final result = AIPrompts.agenticDeliverableGuidelines;
      expect(result, contains('## Output Formatting'));
      expect(result, contains('### Markdown Structure'));
      expect(result, contains(r'\( E = mc^2 \)'));
    });
  });

  group('AI prompts regression', () {
    test('buildContentExtractionPrompt renders correctly', () {
      final result = AIPrompts.buildContentExtractionPrompt(
        'sample text here',
        'article',
        'Test Title',
      );
      expect(result, contains('extract the key content from this article'));
      expect(result, contains('Title: "Test Title"'));
      expect(result, contains('<DATA_ONLY_DOCUMENT>'));
      expect(result, contains('sample text here'));
      expect(result, contains('</DATA_ONLY_DOCUMENT>'));
      expect(result, contains('Math Output Contract:'));
      // Structural check: prompt starts with a blank line (matches original)
      expect(result.startsWith('\n'), isTrue);
    });

    test('buildAudioTranscriptionPrompt is static text without trailing newline', () {
      final result = AIPrompts.buildAudioTranscriptionPrompt();
      expect(
        result,
        equals(
          'Please transcribe the following audio file. Provide only the transcribed text without any additional commentary or formatting.',
        ),
      );
    });

    test('buildAudioSummarizationPrompt without context', () {
      final result = AIPrompts.buildAudioSummarizationPrompt();
      expect(
        result,
        equals(
          'Please listen to the following audio file and provide a concise summary of its main points and key information.',
        ),
      );
    });

    test('buildAudioSummarizationPrompt with context', () {
      final result = AIPrompts.buildAudioSummarizationPrompt(
        context: 'This is a meeting recording',
      );
      expect(
        result,
        equals(
          'Please listen to the following audio file and provide a concise summary of its main points and key information.\n\nContext: This is a meeting recording',
        ),
      );
    });

    test('buildImageContentExtractionPrompt is static text', () {
      final result = AIPrompts.buildImageContentExtractionPrompt();
      expect(
        result,
        equals(
          'Extract and summarize the content from this image. Provide a detailed description of what you see, including any text, objects, people, or important visual elements.',
        ),
      );
    });

    test('buildPdfContentExtractionPrompt is static text', () {
      final result = AIPrompts.buildPdfContentExtractionPrompt();
      expect(
        result,
        equals(
          'Extract and summarize the content from this PDF document. Provide a detailed summary of the main topics, key points, and important information contained in the document.',
        ),
      );
    });

    test('buildDedupRulesSuggestionPrompt without protected tags', () {
      final result = AIPrompts.buildDedupRulesSuggestionPrompt(
        ['work', 'job', 'career', 'employment'],
      );
      expect(result, contains('Tags: work, job, career, employment'));
      expect(result, isNot(contains('PROTECTED TAGS')));
      expect(result, isNot(contains('8. PROTECTED TAGS')));
      expect(result, contains('"leftTag"'));
      expect(result, contains('Only suggest rules that would genuinely improve'));
    });

    test('buildDedupRulesSuggestionPrompt with protected tags', () {
      final result = AIPrompts.buildDedupRulesSuggestionPrompt(
        ['work', 'job', 'important'],
        protectedTags: ['important', 'urgent'],
      );
      expect(result, contains('Tags: work, job, important'));
      expect(result, contains('PROTECTED TAGS (filter tags'));
      expect(result, contains('important, urgent'));
      expect(result, contains('8. PROTECTED TAGS must NEVER appear as leftTag'));
    });

    test('buildDedupRulesSuggestionPrompt byte-match without protected (reference comparison)', () {
      const tagsJoined = 'a, b';
      final expected = '\n'
          'Analyze the following list of tags and suggest deduplication rules to consolidate similar or redundant tags. \n'
          '\n'
          'Tags: $tagsJoined\n'
          '\n'
          'Please suggest rules in the format "leftTag -> rightTag" where:\n'
          '- leftTag is the tag that should be replaced\n'
          '- rightTag is the tag that should replace it\n'
          '\n'
          'Rules to follow:\n'
          '1. No tag should appear as leftTag in multiple rules (each tag can only be replaced once)\n'
          '2. No tag should appear as both leftTag in one rule and rightTag in another rule (no cross-references)\n'
          '3. Do not suggest self-replacement (A -> A)\n'
          '4. It IS allowed for a tag to appear as rightTag in multiple rules (consolidating multiple tags into one)\n'
          '5. Focus on consolidating similar tags, typos, or variations\n'
          '6. Prefer shorter, more standard tag names\n'
          '7. Consider semantic similarity (e.g., "work" and "job" could be consolidated)\n'
          '\n'
          '\n'
          'Please respond with a JSON array of objects in this format:\n'
          '[\n'
          '  {"leftTag": "old_tag_name", "rightTag": "new_tag_name"},\n'
          '  {"leftTag": "another_old_tag", "rightTag": "another_new_tag"}\n'
          ']\n'
          '\n'
          'IMPORTANT: Ensure all tag names are properly escaped for valid JSON (escape special characters like backslashes and quotes).\n'
          '\n'
          'Only suggest rules that would genuinely improve tag organization. If no meaningful consolidations are possible, return an empty array.\n';

      final actual = AIPrompts.buildDedupRulesSuggestionPrompt(['a', 'b']);
      expect(actual, equals(expected));
    });
  });

  group('SystemPromptBuilder regression', () {
    test('byte-match: minimal (default persona, no task context, no guidelines)', () {
      final result = SystemPromptBuilder.build(
        now: DateTime(2026, 4, 11, 10, 30, 0),
        needTimeInContext: false,
      );
      final expected =
          'Persona: ${SystemPromptBuilder.defaultPersona}\n'
          'Conversation start at: ${SystemPromptBuilder.formatTimestamp(DateTime(2026, 4, 11, 10, 30, 0), needTimeInContext: false)}';
      expect(result.content, equals(expected));
      expect(result.role, equals(PromptRole.system));
    });

    test('byte-match: with custom persona', () {
      final result = SystemPromptBuilder.build(
        persona: 'Custom AI',
        now: DateTime(2026, 4, 11),
        needTimeInContext: false,
      );
      final ts = SystemPromptBuilder.formatTimestamp(
        DateTime(2026, 4, 11),
        needTimeInContext: false,
      );
      expect(
        result.content,
        equals('Persona: Custom AI\nConversation start at: $ts'),
      );
    });

    test('byte-match: with task context', () {
      final result = SystemPromptBuilder.build(
        taskContext: '  Transform the note content.  ',
        now: DateTime(2026, 4, 11),
        needTimeInContext: false,
      );
      final ts = SystemPromptBuilder.formatTimestamp(
        DateTime(2026, 4, 11),
        needTimeInContext: false,
      );
      final expected =
          'Persona: ${SystemPromptBuilder.defaultPersona}\n'
          'Conversation start at: $ts\n'
          '\n'
          'Task Context:\n'
          'Transform the note content.';
      expect(result.content, equals(expected));
    });

    test('byte-match: with guidelines (tests dash prefix logic)', () {
      final result = SystemPromptBuilder.build(
        guidelines: [
          'Be concise.',
          '- Already dashed',
          'Multi\nline',
          '  ',
        ],
        now: DateTime(2026, 4, 11),
        needTimeInContext: false,
      );
      final ts = SystemPromptBuilder.formatTimestamp(
        DateTime(2026, 4, 11),
        needTimeInContext: false,
      );
      final expected =
          'Persona: ${SystemPromptBuilder.defaultPersona}\n'
          'Conversation start at: $ts\n'
          '\n'
          'Guidelines:\n'
          '- Be concise.\n'
          '- Already dashed\n'
          'Multi\nline';
      expect(result.content, equals(expected));
    });

    test('byte-match: empty task context is skipped', () {
      final result = SystemPromptBuilder.build(
        taskContext: '   ',
        now: DateTime(2026, 4, 11),
        needTimeInContext: false,
      );
      expect(result.content, isNot(contains('Task Context:')));
    });
  });

  group('NotePromptBuilder question regression', () {
    late NotePromptBuilder builder;

    setUp(() {
      final fakeDb = _FakeDatabaseService();
      if (getIt.isRegistered<DatabaseService>()) {
        getIt.unregister<DatabaseService>();
      }
      getIt.registerSingleton<DatabaseService>(fakeDb);
      builder = NotePromptBuilder(fakeDb);
    });

    tearDown(() {
      if (getIt.isRegistered<DatabaseService>()) {
        getIt.unregister<DatabaseService>();
      }
    });

    test('byte-match: question prompt without context notes, no own knowledge',
        () async {
      final result = await builder.buildQuestionPrompt(
        question: 'What is Flutter?',
        contextNotes: const [],
        useOwnKnowledge: false,
      );
      final expected =
          'Question: "What is Flutter?"\n'
          'No note context is provided. Use the system guidance to determine how to answer.\n'
          'Do not rely on information outside the provided materials.\n'
          'If the answer cannot be found, state explicitly that the information is unavailable.';
      expect(result.conversationMessages.first.content, equals(expected));
      expect(
        result.systemMessage.content,
        contains("You answer detailed questions about the user's notes."),
      );
      expect(
        result.systemMessage.content,
        contains(
          'Do not use outside knowledge unless the notes lack the answer.',
        ),
      );
      expect(
        result.systemMessage.content,
        isNot(contains('You may augment answers with general knowledge')),
      );
      // No context notes -> no context message emitted
      expect(result.contextMessages, isEmpty);
    });

    test(
        'byte-match: question prompt without context notes, with own knowledge',
        () async {
      final result = await builder.buildQuestionPrompt(
        question: 'Explain AI',
        contextNotes: const [],
        useOwnKnowledge: true,
      );
      final expected =
          'Question: "Explain AI"\n'
          'No note context is provided. Use the system guidance to determine how to answer.\n'
          'Supplement with general knowledge only when it clarifies gaps, and identify assumptions.\n'
          'If the answer cannot be found, state explicitly that the information is unavailable.';
      expect(result.conversationMessages.first.content, equals(expected));
      expect(
        result.systemMessage.content,
        contains(
          'You may augment answers with general knowledge when helpful.',
        ),
      );
      expect(
        result.systemMessage.content,
        isNot(contains('Do not use outside knowledge')),
      );
    });
  });

  group('NotePromptBuilder transformation regression', () {
    late NotePromptBuilder builder;

    setUp(() {
      final fakeDb = _FakeDatabaseService();
      if (getIt.isRegistered<DatabaseService>()) {
        getIt.unregister<DatabaseService>();
      }
      getIt.registerSingleton<DatabaseService>(fakeDb);
      builder = NotePromptBuilder(fakeDb);
    });

    tearDown(() {
      if (getIt.isRegistered<DatabaseService>()) {
        getIt.unregister<DatabaseService>();
      }
    });

    test('byte-match: block transformation user message', () {
      final result = builder.buildBlockTransformationPrompt(
        blockContent: '# Hello World\nSome content here.',
        instruction: 'Make it more concise',
      );
      final expected =
          'Transformation instruction: "Make it more concise"\n'
          '\n'
          'Block content to transform:\n'
          '# Hello World\n'
          'Some content here.';
      expect(result.conversationMessages.first.content, equals(expected));
    });

    test('block transformation system message contains format markers', () {
      final result = builder.buildBlockTransformationPrompt(
        blockContent: 'X',
        instruction: 'Y',
      );
      expect(result.systemMessage.content, contains('<transformed>'));
      expect(result.systemMessage.content, contains('</transformed>'));
      expect(result.systemMessage.content, contains('<notes>'));
      expect(
        result.systemMessage.content,
        contains(
          'IMPORTANT: The <transformed> section must contain ONLY',
        ),
      );
    });

    test(
        'block transformation system message preserves task context structure',
        () {
      final result = builder.buildBlockTransformationPrompt(
        blockContent: 'X',
        instruction: 'Y',
      );
      // The task context should contain the exact framing sentence.
      expect(
        result.systemMessage.content,
        contains(
          'Transform the provided markdown block based on the user instruction.',
        ),
      );
      // Guidelines section should include the preserve-info guideline.
      expect(
        result.systemMessage.content,
        contains(
          '- Preserve critical information unless explicitly told to remove it.',
        ),
      );
    });
  });

  group('NotePromptBuilder new note creation regression', () {
    late NotePromptBuilder builder;

    setUp(() {
      final fakeDb = _FakeDatabaseService();
      if (getIt.isRegistered<DatabaseService>()) {
        getIt.unregister<DatabaseService>();
      }
      getIt.registerSingleton<DatabaseService>(fakeDb);
      builder = NotePromptBuilder(fakeDb);
    });

    tearDown(() {
      if (getIt.isRegistered<DatabaseService>()) {
        getIt.unregister<DatabaseService>();
      }
    });

    test('byte-match: new note creation without context or addendum',
        () async {
      final result = await builder.buildNewNoteCreationPrompt(
        userInstruction: 'Create a task for grocery shopping',
        contextNotes: const [],
      );
      const expected =
          'Use the provided note context (previous message) and the instruction below to create new notes.\n'
          '\n'
          'User Prompt: "Create a task for grocery shopping"\n'
          '\n'
          'Return a single JSON object with the following structure:\n'
          '{\n'
          '  "notes": [\n'
          '    {\n'
          '      "title": "Note Title",\n'
          '      "content": "Note content here",\n'
          '      "type": "note" or "task",\n'
          '      "tags": ["tag1", "tag2"],\n'
          '      "subNotes": [\n'
          '        {\n'
          '          "name": "Sub-note name",\n'
          '          "content": "Sub-note content",\n'
          '          "isCompleted": false\n'
          '        }\n'
          '      ],\n'
          '      "scheduledAt": "YYYY-MM-DD" (only for tasks),\n'
          '      "completeBy": "YYYY-MM-DD" (only for tasks),\n'
          '      "status": "todo" (only for tasks)\n'
          '    }\n'
          '  ]\n'
          '}\n'
          '\n'
          'Critical JSON rules:\n'
          '1. The response must be valid JSON with no additional commentary.\n'
          '2. Escape all quotes, backslashes, newlines, and control characters.\n'
          r'3. When using LaTeX (e.g., \( E = mc^2 \)), double-escape backslashes (\\) to keep JSON valid.'
          '\n'
          '4. Preserve arrays even when empty (e.g., "tags": []).\n'
          '\n'
          'Additional requirements:\n'
          '- Calculate relative dates (e.g., "next Wednesday") using the current date/time provided in the system message.\n'
          '- Ensure each generated note relates to the user prompt and the supplied context hierarchy.\n'
          '- Reference note relationships (answers, causality, related, etc.) when deciding how new notes connect.\n'
          '- Follow the LaTeX formatting guidance from the system message when including formulas.';

      expect(result.conversationMessages.first.content, equals(expected));
    });

    test('new note creation system contains relationships mention', () async {
      final result = await builder.buildNewNoteCreationPrompt(
        userInstruction: 'X',
        contextNotes: const [],
      );
      expect(
        result.systemMessage.content,
        contains('Generate new notes based on user goals'),
      );
      expect(
        result.systemMessage.content,
        contains('including relationships'),
      );
    });
  });

  group('SkillService skill index regression', () {
    late SkillService service;

    setUp(() {
      final fakeDb = _FakeDatabaseService();
      if (getIt.isRegistered<DatabaseService>()) {
        getIt.unregister<DatabaseService>();
      }
      getIt.registerSingleton<DatabaseService>(fakeDb);
      service = SkillService(fakeDb);
    });

    tearDown(() {
      if (getIt.isRegistered<DatabaseService>()) {
        getIt.unregister<DatabaseService>();
      }
    });

    SkillMetadata makeSkill({
      String noteId = 'note-1',
      String skillRef = 'skill1',
      String name = 'Test Skill',
      String description = 'A description',
      int? minContext,
    }) {
      return SkillMetadata(
        noteId: noteId,
        skillRef: skillRef,
        name: name,
        description: description,
        enabled: true,
        minContext: minContext,
      );
    }

    test('returns empty string for empty index', () {
      final result = service.buildSkillIndexPrompt({});
      expect(result, equals(''));
    });

    test('byte-match: compact tier with one skill (no description)', () {
      final index = {'note-1': makeSkill()};
      final result = service.buildSkillIndexPrompt(
        index,
        maxBudgetTokens: 1000,
      );
      const expected =
          '\n## Available Agent Skills\n'
          'If a skill matches the request, call load_skill using the listed skillRef.\n'
          '- skillRef=skill1 | name=Test Skill\n';
      expect(result, equals(expected));
    });

    test('byte-match: medium tier with one skill (no description)', () {
      final index = {'note-1': makeSkill()};
      final result = service.buildSkillIndexPrompt(
        index,
        maxBudgetTokens: 20000,
      );
      const expected =
          '\n## Available Agent Skills\n'
          'If a skill matches the request, call load_skill using the listed skillRef.\n'
          '\n'
          '- skillRef=skill1 | name=Test Skill\n';
      expect(result, equals(expected));
    });

    test('byte-match: full tier with one skill (always includes description)',
        () {
      final index = {'note-1': makeSkill()};
      final result = service.buildSkillIndexPrompt(
        index,
        maxBudgetTokens: 100000,
      );
      const expected =
          '\n## Available Agent Skills\n'
          'If a skill matches the request, call load_skill using the listed skillRef to retrieve its workflow instructions.\n'
          '\n'
          '- skillRef=skill1 | name=Test Skill | when=A description\n';
      expect(result, equals(expected));
    });

    test('forLocalModel=true includes description in compact tier', () {
      final index = {'note-1': makeSkill(description: 'Use for X')};
      final result = service.buildSkillIndexPrompt(
        index,
        maxBudgetTokens: 1000,
        forLocalModel: true,
      );
      expect(result, contains('when=Use for X'));
    });

    test('limited mode shown when minContext exceeds budget', () {
      final index = {'note-1': makeSkill(minContext: 200000)};
      final result = service.buildSkillIndexPrompt(
        index,
        maxBudgetTokens: 100000,
      );
      expect(result, contains('mode=limited'));
    });
  });

  group('UserAppService app generation regression', () {
    test('app generation prompt contains all sections', () {
      final result = UserAppService.testBuildAppGenerationPrompt(
        'Test App',
        'A test application',
        ['Step 1', 'Step 2'],
        UserAppType.normal,
      );
      expect(result, contains('App Name: Test App'));
      expect(result, contains('Description: A test application'));
      expect(result, contains('Step 1'));
      expect(result, contains('Synapse.runQuery'));
      expect(result, contains('Database Schema:'));
      expect(result, contains('```html'));
    });

    test('note action type includes Synapse.Notes instructions', () {
      final result = UserAppService.testBuildAppGenerationPrompt(
        'Note App',
        'Processes notes',
        ['Process'],
        UserAppType.noteAction,
      );
      expect(result, contains('NOTE ACTION APP'));
      expect(result, contains('window.Synapse.Notes'));
    });
  });

  group('UserAppService static sections regression', () {
    test('API documentation contains all Synapse methods', () {
      final result = UserAppService.testBuildApiDocumentationSection();
      expect(result, contains('Synapse.runQuery'));
      expect(result, contains('Synapse.storeAppState'));
      expect(result, contains('Synapse.chatAI'));
      expect(result, contains('Synapse.proxyFetch'));
      expect(result, contains('Synapse.fetchWebPage'));
      expect(result, contains('Synapse.readAttachment'));
      expect(result, contains('Synapse.saveTemp'));
      expect(result, contains('Synapse.saveNotes'));
      expect(result, contains('Synapse.updateNotes'));
      expect(result, contains('Synapse.deleteNotes'));
      expect(result, contains('Synapse.openNote'));
      expect(result, contains('Synapse.openConversations'));
      expect(result, contains('Synapse.openAIActions'));
      expect(result, contains(r'${result1.updatedCount}'));
    });

    test('requirements section contains numbered rules', () {
      final result = UserAppService.testBuildRequirementsSection();
      expect(result, contains('DO NOT mock Synapse'));
      expect(result, contains('PROMPT INJECTION PROTECTION'));
    });

    test('note action instructions contain Synapse.Notes', () {
      final result = UserAppService.testGetNoteActionAppInstructions();
      expect(result, contains('window.Synapse.Notes'));
      expect(result, contains('NOTE ACTION APP'));
    });

    test('AI tool instructions contain tool_spec', () {
      final result = UserAppService.testGetAiToolAppInstructions();
      expect(result, contains('AI TOOL APP'));
      expect(result, contains('tool_spec'));
    });
  });

  group('MCP tool catalog regression', () {
    test('renders tool catalog with header and intro', () {
      final tools = {
        'weather-api': [
          McpTool(name: 'get_forecast', description: 'Get weather forecast'),
        ],
      };
      final result = McpToolIntegrationService.testBuildToolCatalogDescription(
        tools,
        compact: false,
        includeHeader: true,
        includeWrapperIntro: true,
      );
      expect(result, contains('=== MCP TOOLS AVAILABLE ==='));
      expect(result, contains('call_tool'));
      expect(result, contains('weather-api'));
      expect(result, contains('get_forecast'));
    });

    test('renders compact catalog without header', () {
      final tools = {
        'test': [
          McpTool(name: 'test_tool', description: 'A test tool'),
        ],
      };
      final result = McpToolIntegrationService.testBuildToolCatalogDescription(
        tools,
        compact: true,
        includeHeader: false,
      );
      expect(result, isNot(contains('=== MCP TOOLS AVAILABLE ===')));
      expect(result, contains('- test_tool: A test tool'));
    });
  });

  group('PromptTemplateService preload', () {
    test('preloadAll loads all expected templates', () {
      // setUpAll at the top of main() loads all templates via mock manifest.
      // Verify the cache contains all template files across all 7 directories.
      final service = getIt<PromptTemplateService>();
      expect(service.cacheSize, greaterThanOrEqualTo(29));
    });
  });
}

class _FakeDatabaseService extends Fake implements DatabaseService {
  @override
  Future<List<Attachment>> getAttachmentsForNote(String noteId) async => [];

  @override
  Future<List<Relationship>> getRelationships(String noteId) async => [];
}
