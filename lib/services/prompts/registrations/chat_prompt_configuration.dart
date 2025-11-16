import '../prompt_configuration_registry.dart';

/// Registration for conversation/chat prompt customization.
class ChatPromptConfiguration {
  static const systemAddendumId = 'chat.system_addendum';
  static const perMessageAddendumId = 'chat.per_message_addendum';

  static bool _registered = false;

  static void register(PromptConfigurationRegistry registry) {
    if (_registered) {
      return;
    }

    registry.registerEntry(
      sectionId: 'chat',
      sectionTitle: 'Chat',
      sectionDescription:
          'Customize how the assistant behaves in conversations.',
      sectionOrder: 10,
      entry: PromptConfigEntry(
        id: systemAddendumId,
        injectionPoint: PromptInjectionPoint.chatSystem,
        title: 'Conversation System Add-on',
        description:
            'Appended to the chat system message before each conversation starts.',
        helperText: 'Provide conversation-wide behavior guidance.',
        multiline: true,
        order: 0,
      ),
    );

    registry.registerEntry(
      sectionId: 'chat',
      sectionTitle: 'Chat',
      sectionDescription:
          'Customize how the assistant behaves in conversations.',
      sectionOrder: 10,
      entry: PromptConfigEntry(
        id: perMessageAddendumId,
        injectionPoint: PromptInjectionPoint.chatTimestamp,
        title: 'Per Message Add-on',
        description:
            'Appended to the timestamp context included ahead of each user message.',
        helperText: 'Use for per-message reminders (e.g., tone, formatting).',
        multiline: true,
        order: 1,
      ),
    );

    _registered = true;
  }
}
