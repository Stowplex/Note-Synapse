import '../prompt_configuration_registry.dart';

/// Registration for global system prompt customization.
class SystemPromptConfiguration {
  static const globalAddendumId = 'system.global_addendum';

  static bool _registered = false;

  static void register(PromptConfigurationRegistry registry) {
    if (_registered) {
      return;
    }
    registry.registerEntry(
      sectionId: 'system',
      sectionTitle: 'System Prompts',
      sectionDescription:
          'Configure global system prompt additions that apply across AI features.',
      sectionOrder: 0,
      entry: PromptConfigEntry(
        id: globalAddendumId,
        injectionPoint: PromptInjectionPoint.globalSystem,
        title: 'Global System Add-on',
        description:
            'Appended to every system prompt after default persona and context.',
        helperText: 'Leave empty to use the default persona only.',
        multiline: true,
        order: 0,
      ),
    );
    _registered = true;
  }
}


