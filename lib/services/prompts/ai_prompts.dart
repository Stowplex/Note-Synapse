import '../service_locator.dart';
import 'prompt_template_service.dart';

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
    return getIt<PromptTemplateService>().renderSync(
      'ai_prompts/dedup_rules_suggestion',
      {
        'tagsJoined': tagNames.join(', '),
        'hasProtectedTags': protectedTags.isNotEmpty,
        'protectedTagsJoined': protectedTags.join(', '),
      },
    );
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
}
