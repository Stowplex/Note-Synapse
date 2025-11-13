import 'prompt_configuration_service.dart';
import 'registrations/app_prompt_configuration.dart';
import 'registrations/note_prompt_configuration.dart';

/// Centralized AI prompts for all AI services
/// This ensures consistency across different model providers
class AIPrompts {
  // Common math formula guidelines used across all prompts
  static const String mathFormulaGuidelines = '''
IMPORTANT - Math Formula Guidelines:
- When including mathematical formulas, equations, or expressions in your response, use LaTeX format
- Use the format: \\( formula \\) for inline math (without leading and ending \$ symbols)
- Use the format: \\[ formula \\] for display math (without leading and ending \$ symbols)
- Examples:
  - Inline: \\( E = mc^2 \\) or \\( \\frac{a}{b} \\)
  - Display: \\[ \\int_{-\\infty}^{\\infty} e^{-x^2} dx = \\sqrt{\\pi} \\]
- Preserve all mathematical notation, symbols, and formatting accurately
- If explaining complex equations, break them down into logical components''';

  // Common relationship guidelines for note operations
  static const String relationshipGuidelines = '''
- The hierarchical structure shown (indented linked notes)
- The relationship types between notes (answers, causality, related, subnote, parent, references, expands, contradicts, supports)
- How linked notes might provide additional context or clarification
- The direction of relationships (→ for outgoing, ← for incoming)''';

  /// Build prompt for note transformation
  static String buildNoteTransformationPrompt(
    String noteTitle,
    String noteContent,
    String transformationPrompt, {
    List<String> attachmentPaths = const [],
    List<String> subNotes = const [],
    List<String> tags = const [],
    String linkedNotesContext = '',
  }) {
    final buffer = StringBuffer();
    buffer.writeln(
      'Please transform the following note according to the instruction: "$transformationPrompt"',
    );
    buffer.writeln();
    buffer.writeln('Original Note:');
    buffer.writeln('Title: $noteTitle');
    buffer.writeln('Content: $noteContent');

    // Add file attachment info if any
    if (attachmentPaths.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('File Attachments:');
      for (final attachmentPath in attachmentPaths) {
        final fileName = attachmentPath.split('/').last;
        buffer.writeln('- $fileName');
      }
    }

    // Add sub-notes if any
    if (subNotes.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Sub-notes:');
      for (final subNote in subNotes) {
        buffer.writeln('- $subNote');
      }
    }

    // Add tags if any
    if (tags.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Tags: ${tags.join(', ')}');
    }

    // Add linked notes context if any
    if (linkedNotesContext.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Linked Notes Context:');
      buffer.writeln(linkedNotesContext);
    }

    buffer.writeln();
    buffer.writeln(mathFormulaGuidelines);
    buffer.writeln();
    buffer.writeln(
      'Please provide the transformed version of this note, maintaining the same structure but with the requested changes applied. Consider the linked notes context when making transformations.',
    );

    final addOn = PromptConfigurationService.instance.getValue(
      NotePromptConfiguration.transformationAddendumId,
    );
    return _appendAddOn(
      buffer.toString(),
      addOn,
      header: 'User-defined guidance:',
    );
  }

  /// Build prompt for new note creation
  static String buildNewNoteCreationPrompt(String userPrompt, String context) {
    final addOn = PromptConfigurationService.instance.getValue(
      NotePromptConfiguration.creationAddendumId,
    );

    final prompt =
        '''
Based on the following context and prompt, please create one or more new notes.

Context Notes (including linked notes and their relationships):
$context

User Prompt: "$userPrompt"

IMPORTANT: 
- When creating tasks with dates, use the format YYYY-MM-DD and consider the current date context provided. For relative dates like "next Wednesday" or "tomorrow", calculate the actual date based on today's date.
- Consider the relationships between notes in the context when creating new notes. If the context shows linked notes with specific relationship types (answers, causality, related, subnote, parent, references, expands, contradicts, supports), consider how your new notes might relate to existing ones.
- Pay attention to the hierarchical structure shown in the context (indented linked notes) to understand the note relationships.

$mathFormulaGuidelines

Please create the new note(s) in the following JSON format:
{
  "notes": [
    {
      "title": "Note Title",
      "content": "Note content here",
      "type": "note" or "task",
      "tags": ["tag1", "tag2"],
      "subNotes": [
        {
          "name": "Sub-note name",
          "content": "Sub-note content",
          "isCompleted": either false (default value) or true (if the sub-note is deemed completed, derived from the context)
        }
      ],
      "scheduledAt": "YYYY-MM-DD" (only for tasks - when the task should start),
      "completeBy": "YYYY-MM-DD" (only for tasks - when the task should be completed),
      "status": "todo" (only for tasks)
    }
  ]
}

CRITICAL JSON FORMATTING RULES:
1. Ensure ALL text in "content" and other string fields are properly escaped for valid JSON
2. For mathematical formulas using LaTeX notation (e.g., \\( E = mc^2 \\)), you MUST double-escape the backslashes in JSON:
   - Write \\\\( instead of \\(
   - Write \\\\) instead of \\)
   - Write \\\\[ instead of \\[
   - Write \\\\] instead of \\]
   - Example: "content": "The equation \\\\( E = mc^2 \\\\) shows..."
3. Also escape other special JSON characters: " (use \\"), \\ (use \\\\), newlines (use \\n), tabs (use \\t)
4. Test that your JSON is valid - backslash sequences like \\( are INVALID and will cause parsing errors

If creating multiple notes, ensure they are related and useful based on the context and prompt. Consider how the new notes might fit into the existing network of relationships shown in the context. For tasks, make sure to set appropriate scheduledAt and completeBy dates based on the user's request and current date context.
''';
    return _appendAddOn(prompt, addOn, header: 'User-defined guidance:');
  }

  /// Build prompt for content extraction from text
  static String buildContentExtractionPrompt(
    String text,
    String contentType,
    String title,
  ) {
    return '''
Please analyze and extract the key content from this $contentType. 

Title: $title

Content:
$text

Please provide a well-structured summary that includes:
1. Main topics and themes
2. Key points and important information
3. Any actionable items or insights
4. Relevant context or background information

$mathFormulaGuidelines

Format the response in a clear, organized manner that would be useful for note-taking and future reference.
''';
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
    return 'Please transcribe the following audio file. Provide only the transcribed text without any additional commentary or formatting.';
  }

  /// Build prompt for audio summarization
  static String buildAudioSummarizationPrompt({String? context}) {
    final contextText = context != null ? "\n\nContext: $context" : "";
    return 'Please listen to the following audio file and provide a concise summary of its main points and key information.$contextText';
  }

  /// Build prompt for image content extraction
  static String buildImageContentExtractionPrompt() {
    return 'Extract and summarize the content from this image. Provide a detailed description of what you see, including any text, objects, people, or important visual elements.';
  }

  /// Build prompt for PDF content extraction
  static String buildPdfContentExtractionPrompt() {
    return 'Extract and summarize the content from this PDF document. Provide a detailed summary of the main topics, key points, and important information contained in the document.';
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
