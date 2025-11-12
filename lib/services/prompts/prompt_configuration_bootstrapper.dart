import 'prompt_configuration_registry.dart';
import 'prompt_configuration_service.dart';
import 'registrations/app_prompt_configuration.dart';
import 'registrations/chat_prompt_configuration.dart';
import 'registrations/note_prompt_configuration.dart';
import 'registrations/system_prompt_configuration.dart';

/// Initializes prompt configuration infrastructure and ensures all modules are
/// registered before user interaction.
class PromptConfigurationBootstrapper {
  PromptConfigurationBootstrapper._();

  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    final registry = PromptConfigurationRegistry.instance;
    SystemPromptConfiguration.register(registry);
    ChatPromptConfiguration.register(registry);
    NotePromptConfiguration.register(registry);
    AppPromptConfiguration.register(registry);

    await PromptConfigurationService.instance.initialize();
    _initialized = true;
  }
}
