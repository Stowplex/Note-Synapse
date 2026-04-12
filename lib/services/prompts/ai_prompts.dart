import '../service_locator.dart';
import 'prompt_configuration_service.dart';
import 'prompt_template_service.dart';
import 'registrations/app_prompt_configuration.dart';
import 'registrations/note_prompt_configuration.dart';

/// Centralized AI prompts for all AI services
/// This ensures consistency across different model providers
class AIPrompts {
  // Common math formula guidelines used across all prompts
  static String get mathFormulaGuidelines =>
      getIt<PromptTemplateService>().renderSync('guidelines/math_formula');

  static String get internalLinkGuidelines =>
      getIt<PromptTemplateService>().renderSync('guidelines/internal_link');

  /// Formatting guidelines for agentic mode final deliverables
  static String get agenticDeliverableGuidelines => getIt<PromptTemplateService>()
      .renderSync('guidelines/agentic_deliverable');

  // Common relationship guidelines for note operations
  static String get relationshipGuidelines =>
      getIt<PromptTemplateService>().renderSync('guidelines/relationship');

  // Prompt injection protection guidelines
  static String get promptInjectionProtectionGuidelines =>
      getIt<PromptTemplateService>()
          .renderSync('guidelines/prompt_injection_protection');

  /// Build prompt for content extraction from text
  static String buildContentExtractionPrompt(
    String text,
    String contentType,
    String title,
  ) {
    return getIt<PromptTemplateService>().renderSync(
      'ai_prompts/content_extraction',
      {
        'text': text,
        'contentType': contentType,
        'title': title,
        'mathFormulaGuidelines': mathFormulaGuidelines,
      },
    );
  }

  /// Build prompt for dedup rules suggestion
  static String buildDedupRulesSuggestionPrompt(
    List<String> tagNames, {
    List<String> protectedTags = const [],
  }) {
    final protectedTagsSection = protectedTags.isNotEmpty
        ? '''
        
PROTECTED TAGS (filter tags - must NOT appear as leftTag in any rule):
${protectedTags.join(', ')}

CRITICAL: These protected tags are used by filters and MUST NOT be replaced. They can only appear as rightTag (the replacement target), never as leftTag (the tag being replaced).
'''
        : '';

    return '''
Analyze the following list of tags and suggest deduplication rules to consolidate similar or redundant tags. 

Tags: ${tagNames.join(', ')}$protectedTagsSection

Please suggest rules in the format "leftTag -> rightTag" where:
- leftTag is the tag that should be replaced
- rightTag is the tag that should replace it

Rules to follow:
1. No tag should appear as leftTag in multiple rules (each tag can only be replaced once)
2. No tag should appear as both leftTag in one rule and rightTag in another rule (no cross-references)
3. Do not suggest self-replacement (A -> A)
4. It IS allowed for a tag to appear as rightTag in multiple rules (consolidating multiple tags into one)
5. Focus on consolidating similar tags, typos, or variations
6. Prefer shorter, more standard tag names
7. Consider semantic similarity (e.g., "work" and "job" could be consolidated)
${protectedTags.isNotEmpty ? '8. PROTECTED TAGS must NEVER appear as leftTag - they can only appear as rightTag' : ''}

Please respond with a JSON array of objects in this format:
[
  {"leftTag": "old_tag_name", "rightTag": "new_tag_name"},
  {"leftTag": "another_old_tag", "rightTag": "another_new_tag"}
]

IMPORTANT: Ensure all tag names are properly escaped for valid JSON (escape special characters like backslashes and quotes).

Only suggest rules that would genuinely improve tag organization. If no meaningful consolidations are possible, return an empty array.
''';
  }

  /// Build prompt for audio transcription
  static String buildAudioTranscriptionPrompt() {
    return getIt<PromptTemplateService>()
        .renderSync('ai_prompts/audio_transcription')
        .trimRight();
  }

  /// Build prompt for audio summarization
  static String buildAudioSummarizationPrompt({String? context}) {
    return getIt<PromptTemplateService>()
        .renderSync('ai_prompts/audio_summarization', {
          'hasContext': context != null,
          'context': context,
        })
        .trimRight();
  }

  /// Build prompt for image content extraction
  static String buildImageContentExtractionPrompt() {
    return getIt<PromptTemplateService>()
        .renderSync('ai_prompts/image_content_extraction')
        .trimRight();
  }

  /// Build prompt for PDF content extraction
  static String buildPdfContentExtractionPrompt() {
    return getIt<PromptTemplateService>()
        .renderSync('ai_prompts/pdf_content_extraction')
        .trimRight();
  }

  /// Build prompt for app generation
  static String buildAppGenerationPrompt(
    String name,
    String description,
    List<String> steps,
    String type,
  ) {
    final addOn = PromptConfigurationService.instance.getValue(
      AppPromptConfiguration.generationAddendumId,
    );

    final prompt =
        '''
Create a single-page self-contained HTML application based on the following requirements:

App Name: $name
Description: $description
Type: $type
Steps: ${steps.join(', ')}

Requirements:
1. The app should be a complete, self-contained HTML file
2. Include all necessary CSS and JavaScript inline
3. Make it responsive and user-friendly
4. Follow modern web development best practices
5. Include proper error handling and validation
6. Make the interface intuitive and visually appealing

Please generate the complete HTML code for this application.
''';
    return _appendAddOn(prompt, addOn, header: 'User-defined guidance:');
  }

  /// Build prompt for app editing
  static String buildAppEditPrompt(
    String name,
    String currentCode,
    String editSuggestion,
  ) {
    return '''
Edit the following HTML application based on the user's suggestion:

Original App Name: $name
User Suggestion: $editSuggestion

Current App Code:
$currentCode

Please generate the updated HTML application that incorporates the user's suggestions while maintaining the same structure and API integrations.

IMPORTANT: Your response must be formatted as follows:

EXPLANATION:
[Provide a brief explanation of what changes were made]

HTML:
[The complete updated HTML code]

Make sure the updated code is complete, functional, and addresses the user's request.
''';
  }

  static String _appendAddOn(String prompt, String? addOn, {String? header}) {
    if (addOn == null || addOn.trim().isEmpty) {
      return prompt;
    }

    final buffer = StringBuffer(prompt.trimRight());
    buffer.writeln();
    if (header != null && header.trim().isNotEmpty) {
      buffer.writeln(header.trim());
    }
    buffer.writeln(addOn.trim());
    return buffer.toString();
  }
}
