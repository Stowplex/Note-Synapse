import '../prompt_configuration_registry.dart';

/// Registration for note-centric prompt customization.
class NotePromptConfiguration {
  static const qaAddendumId = 'notes.qa_addendum';
  static const transformationAddendumId = 'notes.transformation_addendum';
  static const creationAddendumId = 'notes.creation_addendum';

  static bool _registered = false;

  static void register(PromptConfigurationRegistry registry) {
    if (_registered) {
      return;
    }

    registry.registerEntry(
      sectionId: 'notes',
      sectionTitle: 'Notes & Tasks',
      sectionDescription:
          'Adjust how AI features interact with your notes and tasks.',
      sectionOrder: 20,
      entry: PromptConfigEntry(
        id: qaAddendumId,
        injectionPoint: PromptInjectionPoint.noteQuestionAnswering,
        title: 'Notes Q&A Add-on',
        description:
            'Appended to the question answering prompt for note analysis.',
        multiline: true,
        order: 0,
      ),
    );

    registry.registerEntry(
      sectionId: 'notes',
      sectionTitle: 'Notes & Tasks',
      sectionDescription:
          'Adjust how AI features interact with your notes and tasks.',
      sectionOrder: 20,
      entry: PromptConfigEntry(
        id: transformationAddendumId,
        injectionPoint: PromptInjectionPoint.noteTransformation,
        title: 'Note Transformation Add-on',
        description:
            'Appended to the instruction when transforming existing notes.',
        multiline: true,
        order: 1,
      ),
    );

    registry.registerEntry(
      sectionId: 'notes',
      sectionTitle: 'Notes & Tasks',
      sectionDescription:
          'Adjust how AI features interact with your notes and tasks.',
      sectionOrder: 20,
      entry: PromptConfigEntry(
        id: creationAddendumId,
        injectionPoint: PromptInjectionPoint.noteCreation,
        title: 'Note Creation Add-on',
        description:
            'Appended to the new note creation instruction before JSON output requirements.',
        multiline: true,
        order: 2,
      ),
    );

    _registered = true;
  }
}
