import 'package:collection/collection.dart';

/// Identifiers for prompt injection targets.
enum PromptInjectionPoint {
  globalSystem,
  chatSystem,
  chatTimestamp,
  noteQuestionAnswering,
  noteTransformation,
  noteCreation,
  appGeneration,
}

/// Metadata describing a configurable prompt entry exposed to the user.
class PromptConfigEntry {
  PromptConfigEntry({
    required this.id,
    required this.injectionPoint,
    required this.title,
    this.description,
    this.placeholder,
    this.helperText,
    this.multiline = true,
    this.order = 0,
  });

  final String id;
  final PromptInjectionPoint injectionPoint;
  final String title;
  final String? description;
  final String? placeholder;
  final String? helperText;
  final bool multiline;
  final int order;
}

/// Grouping of related prompt entries in the settings UI.
class PromptConfigSection {
  PromptConfigSection._({
    required this.id,
    required this.title,
    this.description,
    required List<PromptConfigEntry> entries,
    this.order = 0,
  }) : entries = List.unmodifiable(
         entries.sorted((a, b) => a.order.compareTo(b.order)),
       );

  final String id;
  final String title;
  final String? description;
  final List<PromptConfigEntry> entries;
  final int order;
}

class _SectionDraft {
  _SectionDraft({
    required this.id,
    required this.title,
    this.description,
    this.order = 0,
  });

  final String id;
  String title;
  String? description;
  int order;
  final List<PromptConfigEntry> entries = [];
}

/// Registry that allows individual modules to contribute prompt configuration
/// entries without coupling to the settings UI.
class PromptConfigurationRegistry {
  PromptConfigurationRegistry._internal();

  static final PromptConfigurationRegistry instance =
      PromptConfigurationRegistry._internal();

  final Map<String, _SectionDraft> _sections = {};
  final Set<String> _entryIds = {};

  void registerEntry({
    required String sectionId,
    required String sectionTitle,
    String? sectionDescription,
    int sectionOrder = 0,
    required PromptConfigEntry entry,
  }) {
    final section = _sections.putIfAbsent(
      sectionId,
      () => _SectionDraft(
        id: sectionId,
        title: sectionTitle,
        description: sectionDescription,
        order: sectionOrder,
      ),
    );

    section.title = sectionTitle;
    if (sectionDescription != null) {
      section.description = sectionDescription;
    }
    section.order = sectionOrder;

    if (_entryIds.contains(entry.id)) {
      throw ArgumentError.value(
        entry.id,
        'entry.id',
        'Prompt configuration entry ID must be unique.',
      );
    }

    section.entries.add(entry);
    _entryIds.add(entry.id);
  }

  List<PromptConfigSection> listSections() {
    final drafts = _sections.values.sorted(
      (a, b) => a.order.compareTo(b.order),
    );
    return drafts
        .map(
          (draft) => PromptConfigSection._(
            id: draft.id,
            title: draft.title,
            description: draft.description,
            entries: draft.entries,
            order: draft.order,
          ),
        )
        .toList(growable: false);
  }
}
