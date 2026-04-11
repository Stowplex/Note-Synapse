# Prompt Template Externalization

Refactor all AI prompt text from inline Dart strings into Mustache `.md` template files under `assets/prompts/`, delivered as Flutter assets. Zero behavior change.

## Motivation

Prompt text is currently embedded in Dart code as multi-line string literals with interpolation. This makes prompts hard to review, edit, and diff independently of code logic. Externalizing to template files separates concerns: prompt authors edit `.md` files, code changes are limited to data preparation.

## Scope

### In Scope (prompt instruction text to .md templates)

| Source File | Templates | Complexity |
|---|---|---|
| `ai_prompts.dart` | `content_extraction`, `dedup_rules_suggestion`, `audio_transcription`, `audio_summarization`, `image_content_extraction`, `pdf_content_extraction` | Simple |
| `ai_prompts.dart` | `math_formula`, `internal_link`, `agentic_deliverable`, `relationship`, `prompt_injection_protection` (guidelines) | Static |
| `note_prompt_builder.dart` | `question_system`, `question_user`, `transformation_system`, `transformation_user`, `block_transformation_system`, `block_transformation_user`, `new_note_creation_system`, `new_note_creation_user` | Medium |
| `system_prompt_builder.dart` | `system` | Medium |
| `skill_service.dart` | `skill_index_compact`, `skill_index_medium`, `skill_index_full` | Low |
| `user_app_service.dart` | `app_generation`, `app_edit`, `api_documentation`, `requirements`, `note_action_instructions`, `ai_tool_instructions`, `libraries_for_prompt` | Mixed |
| `mcp_tool_integration_service.dart` | `tool_catalog` | Medium |

**Dead code to remove**: `AIPrompts.buildAppGenerationPrompt`, `AIPrompts.buildAppEditPrompt` (never called, superseded by `user_app_service.dart` versions).

### Out of Scope (data assembly, stays in Dart)

- `_addNoteToContext` -- recursive note tree with depth-based indentation, DB queries, security wrapping
- `_addNoteAttachments` / `_addRemoteImageAttachments` -- file I/O, PDF page extraction
- `_getChapterPageRanges`, `_flattenOutline`, `_mergeRanges` -- PDF helpers
- `loadNoteAttachments`, `buildContextMessage` -- data orchestration
- `_buildLibrariesSection` -- reads from `GlobalLibraryService` at runtime
- `_buildDatabaseSchemaSection` -- reads from `DatabaseService.getSchemaDescription()` at runtime
- `formatTimestamp` -- date/timezone computation
- `_buildLibrariesSectionForPrompt` -- complex nested map/join chain
- `_formatSkillEntry` -- conditional list construction with `parts.join(' | ')`

## Template Engine

**Mustache** via the `mustache_template` package (^2.0.0). Logic-less templates with sections, inverted sections, iteration, and lambdas.

Mustache was chosen over Jinja2/Handlebars because:
- Mature, well-maintained Dart package
- Logic-less design keeps templates focused on text, not code
- All existing prompt patterns map cleanly with minor pre-processing in Dart

### Mustache Pattern Mapping

| Dart Pattern | Mustache Equivalent | Pre-processing |
|---|---|---|
| `$variable` | `{{{variable}}}` (triple-stache, unescaped) | None |
| `${list.join(', ')}` | `{{{listJoined}}}` | Pre-join in Dart |
| `${enum.name}` | `{{{enumName}}}` | Resolve to string in Dart |
| `${x?.name ?? 'default'}` | `{{{xName}}}` | Resolve default in Dart |
| `if (x.isNotEmpty) { ... }` | `{{#hasX}}...{{/hasX}}` | Set boolean in context |
| `if (x.isEmpty) { ... }` | `{{^hasX}}...{{/hasX}}` | Inverted section |
| `for (item in list)` | `{{#items}}{{{.}}}{{/items}}` | Pass list in context |
| `PromptInjectionProtection.format(x)` | `{{#safeWrap}}{{{content}}}{{/safeWrap}}` | Mustache lambda |
| Ternary `cond ? a : b` | `{{#cond}}a{{/cond}}{{^cond}}b{{/cond}}` | Pass boolean |

**Important**: All variable interpolations use triple-stache `{{{variable}}}` (unescaped) because prompts contain `<DATA_ONLY_DOCUMENT>` tags, HTML examples, and `<script>` blocks that must not be HTML-escaped.

## File Structure

```
assets/prompts/
  guidelines/
    math_formula.md
    internal_link.md
    agentic_deliverable.md
    relationship.md
    prompt_injection_protection.md
  ai_prompts/
    content_extraction.md
    dedup_rules_suggestion.md
    audio_transcription.md
    audio_summarization.md
    image_content_extraction.md
    pdf_content_extraction.md
  note_prompts/
    question_system.md
    question_user.md
    transformation_system.md
    transformation_user.md
    block_transformation_system.md
    block_transformation_user.md
    new_note_creation_system.md
    new_note_creation_user.md
  system_prompt/
    system.md
  skills/
    skill_index_compact.md
    skill_index_medium.md
    skill_index_full.md
  user_app/
    app_generation.md
    app_edit.md
    api_documentation.md
    requirements.md
    note_action_instructions.md
    ai_tool_instructions.md
    libraries_for_prompt.md
  mcp/
    tool_catalog.md
```

~30 template files. Each directory registered in `pubspec.yaml` under `flutter.assets`.

## PromptTemplateService

New service: `lib/services/prompts/prompt_template_service.dart`

```dart
class PromptTemplateService {
  final Map<String, Template> _cache = {};

  /// Load and render a template with the given context.
  /// [templatePath] is relative to assets/prompts/, without .md extension.
  Future<String> render(
    String templatePath,
    Map<String, dynamic> context,
  ) async {
    final template = await _getTemplate(templatePath);
    return template.renderString(context);
  }

  Future<Template> _getTemplate(String path) async {
    if (_cache.containsKey(path)) return _cache[path]!;
    final content = await rootBundle.loadString('assets/prompts/$path.md');
    final template = Template(content, name: path);
    _cache[path] = template;
    return template;
  }
}
```

- Registered in `service_locator.dart` via GetIt as a lazy singleton
- Methods on existing builders (e.g., `AIPrompts`, `NotePromptBuilder`) keep their current signatures but internally delegate to `PromptTemplateService`

### Pre-loading

To keep existing synchronous callers unchanged, the service pre-loads and caches all templates at app startup:

```dart
/// Call once during app initialization (after WidgetsFlutterBinding).
Future<void> preloadAll() async {
  final manifestJson = await rootBundle.loadString('AssetManifest.json');
  final manifest = json.decode(manifestJson) as Map<String, dynamic>;
  final promptPaths = manifest.keys
      .where((key) => key.startsWith('assets/prompts/') && key.endsWith('.md'));
  for (final fullPath in promptPaths) {
    final templatePath = fullPath
        .replaceFirst('assets/prompts/', '')
        .replaceFirst('.md', '');
    await _getTemplate(templatePath);
  }
}
```

After pre-loading, `renderSync` is available for synchronous callers:

```dart
String renderSync(String templatePath, Map<String, dynamic> context) {
  final template = _cache[templatePath];
  if (template == null) {
    throw StateError('Template $templatePath not pre-loaded');
  }
  return template.renderString(context);
}
```

This is called in `service_locator.dart` during the existing async initialization sequence.

### Lambdas

Lambdas are passed as context entries for security wrapping:

```dart
final baseContext = {
  'safeWrap': (LambdaContext ctx) =>
    PromptInjectionProtection.formatNoteContentAsData(ctx.renderString()),
  'safeTitle': (LambdaContext ctx) =>
    PromptInjectionProtection.formatTitleAsData(ctx.renderString()),
};
```

Used in templates as:
```mustache
{{#safeWrap}}{{{noteContent}}}{{/safeWrap}}
```

### Addendum Handling

User-defined guidance from `PromptConfigurationService` is passed as context variables:

```dart
final context = {
  'hasAddendum': addendum != null && addendum.trim().isNotEmpty,
  'addendum': addendum?.trim(),
};
```

```mustache
{{#hasAddendum}}

User-defined guidance:
{{{addendum}}}
{{/hasAddendum}}
```

## Migration Strategy Per File

### ai_prompts.dart

Static guidelines become standalone .md files (no Mustache variables). Prompt methods become thin wrappers: prepare context map, call `_templateService.render()`.

- `buildContentExtractionPrompt(text, contentType, title)` -> context: `{contentType, title, text, mathFormulaGuidelines}`
- `buildDedupRulesSuggestionPrompt(tagNames, protectedTags)` -> context: `{tagsJoined, hasProtectedTags, protectedTagsJoined}`
- `buildAudioSummarizationPrompt(context)` -> context: `{hasContext, context}`
- `buildAudioTranscriptionPrompt()`, `buildImageContentExtractionPrompt()`, `buildPdfContentExtractionPrompt()` -> no variables, pure static
- Dead code `buildAppGenerationPrompt`, `buildAppEditPrompt` -> deleted
- `_appendAddOn` helper -> replaced by Mustache `{{#hasAddendum}}` sections

Methods stay synchronous because `PromptTemplateService` pre-loads all templates at startup (see Pre-loading section).

### system_prompt_builder.dart

Template skeleton with sections for persona, timestamp, task context, guidelines, addendum. Pre-line formatting logic (dash prefix, multiline detection) stays in Dart as data formatting. `formatTimestamp` stays in Dart.

### note_prompt_builder.dart

Each method's system and user messages get separate templates (8 templates). Methods remain async and handle data assembly unchanged. Instruction text comes from templates.

Example -- `buildQuestionPrompt`:
- `question_system.md`: task context with `{{#useOwnKnowledge}}` / `{{^useOwnKnowledge}}` sections
- `question_user.md`: question + guidance with `{{#hasContextNotes}}` / `{{^hasContextNotes}}` and `{{#useOwnKnowledge}}` sections

Data assembly (`buildNoteContext`, `_addNoteToContext`, attachments) unchanged.

### skill_service.dart

Three tier templates iterate over pre-formatted skill entries:
```mustache
## Available Agent Skills
If a skill matches the request, call load_skill using the listed skillRef.

{{#skills}}
{{{entryLine}}}
{{/skills}}
```

`_formatSkillEntry` stays in Dart (conditional list construction).

### user_app_service.dart

~500 lines of static API documentation moves to `api_documentation.md`. Other static sections (`requirements.md`, `note_action_instructions.md`, `ai_tool_instructions.md`) move out as-is.

`app_generation.md` and `app_edit.md` contain the prompt skeleton with variables: `{{{name}}}`, `{{{description}}}`, `{{{stepsJoined}}}`, `{{{librariesSection}}}`, `{{{noteContextSection}}}`, `{{{apiDocumentation}}}`, `{{{databaseSchema}}}`, `{{{typeSpecificInstructions}}}`.

Dart code pre-assembles dynamic parts (libraries from `GlobalLibraryService`, database schema from `DatabaseService`, type-specific instructions) and injects them as context strings.

`_buildLibrariesSectionForPrompt` (complex nested map/join) stays in Dart, output passed as context string.

### mcp_tool_integration_service.dart

Static intro text and structural skeleton move to `tool_catalog.md` with sections for `{{#includeHeader}}`, `{{#includeWrapperIntro}}`, and iteration over pre-formatted endpoint blocks. Schema introspection and compact/detailed formatting stay in Dart.

## Escape Handling

### Dart to .md Conversion Rules

| Dart Escape | .md File |
|---|---|
| `\\(` in triple-quote string | `\(` (literal backslash-paren) |
| `\\[` in triple-quote string | `\[` (literal backslash-bracket) |
| `\$` in triple-quote string | `$` (literal dollar) |
| `\'` in single-quote string | `'` (literal quote) |
| `\"` in double-quote string | `"` (literal quote) |

Each extraction must interpret Dart escape sequences and write the actual intended characters.

### Mustache-Specific

- **HTML escaping**: Use `{{{triple-stache}}}` for ALL variable interpolations. Prompts contain `<DATA_ONLY_DOCUMENT>` tags, HTML code, `<script>` blocks.
- **Literal curly braces**: JSON examples in templates (e.g., `new_note_creation_user.md`) contain `{` and `}`. Options:
  - Pass JSON blocks as pre-rendered context variables (preferred -- JSON schemas are static)
  - Use Mustache set-delimiter `{{=<% %>=}}` for templates with heavy JSON
- **JavaScript `${}`**: Not a problem -- Mustache only interprets `{{...}}`, not `${...}`.

## pubspec.yaml Changes

```yaml
dependencies:
  mustache_template: ^2.0.0

flutter:
  assets:
    - assets/prompts/guidelines/
    - assets/prompts/ai_prompts/
    - assets/prompts/note_prompts/
    - assets/prompts/system_prompt/
    - assets/prompts/skills/
    - assets/prompts/user_app/
    - assets/prompts/mcp/
```

## Service Registration

In `lib/services/service_locator.dart`:

```dart
getIt.registerLazySingleton<PromptTemplateService>(
  () => PromptTemplateService(),
);
```

## Testing Strategy

### Regression Tests (highest priority)

For every migrated prompt method, a test compares template-rendered output against the original Dart-built output with identical inputs. The original string-building logic is preserved temporarily in test helpers during migration.

```dart
test('content extraction prompt matches original', () async {
  final templateResult = await newBuilder.buildContentExtractionPrompt(
    'sample text', 'article', 'Test Title',
  );
  final originalResult = OriginalAIPrompts.buildContentExtractionPrompt(
    'sample text', 'article', 'Test Title',
  );
  expect(templateResult, equals(originalResult));
});
```

### Template Loading Tests

Verify every template file loads from assets and parses without Mustache syntax errors.

### Lambda Tests

Verify `safeWrap` and `safeTitle` lambdas produce correct `<DATA_ONLY_DOCUMENT>` wrapping.

### Edge Cases

- Empty lists (inverted sections trigger)
- Null/empty addendums (addendum sections skipped)
- Special characters in user input (quotes, backslashes, angle brackets)
- Templates with literal curly braces (JSON examples)

Test infrastructure: existing Flutter test framework with `TestWidgetsFlutterBinding.ensureInitialized()` for asset loading.

## Risks

1. **Startup cost**: Pre-loading ~30 templates adds a small delay to app initialization. These are small text files so the cost should be negligible, but it should be measured.
2. **Mustache limitations**: If a future prompt requires logic that Mustache cannot express (beyond sections/lambdas), the Dart caller can pre-compute the value and pass it as a context variable. Mustache remains the renderer, Dart remains the logic layer.
3. **Test asset bundling**: Flutter test runner needs explicit asset configuration to load `.md` files from `assets/prompts/`. This is standard but must be set up.
