import '../prompt_configuration_registry.dart';

/// Registration for user app generation prompt customization.
class AppPromptConfiguration {
  static const generationAddendumId = 'apps.generation_addendum';

  static bool _registered = false;

  static void register(PromptConfigurationRegistry registry) {
    if (_registered) {
      return;
    }

    registry.registerEntry(
      sectionId: 'apps',
      sectionTitle: 'User Apps',
      sectionDescription:
          'Control how the AI scaffolds and edits user-defined applications.',
      sectionOrder: 30,
      entry: PromptConfigEntry(
        id: generationAddendumId,
        injectionPoint: PromptInjectionPoint.appGeneration,
        title: 'App Generation Add-on',
        description:
            'Appended to the app generation prompt after core requirements.',
        helperText: 'Use to enforce frameworks, style guides, or constraints.',
        multiline: true,
        order: 0,
      ),
    );

    _registered = true;
  }
}
