import 'package:flutter/material.dart';
import 'package:note_synapse/models/workflow_binding_row.dart';
import 'package:note_synapse/services/skill_service.dart';

class TagWorkflowBindingDraft {
  final String pattern;
  final bool isPrefix;
  final String skillNoteId;
  final String prompt;
  final bool contentImmutable;

  const TagWorkflowBindingDraft({
    required this.pattern,
    required this.isPrefix,
    required this.skillNoteId,
    required this.prompt,
    required this.contentImmutable,
  });
}

class TagWorkflowBindingDialog extends StatefulWidget {
  final WorkflowBindingRow? initialBinding;
  final Map<String, SkillMetadata> skillIndex;
  final List<String> allTagNames;
  final Set<String> existingPatterns;
  final String? fixedExactTag;
  final bool initialIsPrefix;

  const TagWorkflowBindingDialog({
    super.key,
    required this.skillIndex,
    required this.allTagNames,
    required this.existingPatterns,
    this.initialBinding,
    this.fixedExactTag,
    this.initialIsPrefix = false,
  });

  static Future<TagWorkflowBindingDraft?> show(
    BuildContext context, {
    required Map<String, SkillMetadata> skillIndex,
    required List<String> allTagNames,
    required Set<String> existingPatterns,
    WorkflowBindingRow? initialBinding,
    String? fixedExactTag,
    bool initialIsPrefix = false,
  }) {
    return showDialog<TagWorkflowBindingDraft>(
      context: context,
      builder: (context) => TagWorkflowBindingDialog(
        skillIndex: skillIndex,
        allTagNames: allTagNames,
        existingPatterns: existingPatterns,
        initialBinding: initialBinding,
        fixedExactTag: fixedExactTag,
        initialIsPrefix: initialIsPrefix,
      ),
    );
  }

  @override
  State<TagWorkflowBindingDialog> createState() =>
      _TagWorkflowBindingDialogState();
}

class _TagWorkflowBindingDialogState extends State<TagWorkflowBindingDialog> {
  final _formKey = GlobalKey<FormState>();
  late bool _isPrefix;
  late final TextEditingController _patternController;
  late final TextEditingController _promptController;
  String? _selectedExactTag;
  String? _selectedSkillNoteId;
  bool _contentImmutable = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialBinding;
    _isPrefix = widget.fixedExactTag == null
        ? (initial?.isPrefix ?? widget.initialIsPrefix)
        : false;
    _patternController = TextEditingController(
      text: initial?.isPrefix == true ? initial!.pattern : '',
    );
    _promptController = TextEditingController(text: initial?.prompt ?? '');
    _selectedExactTag =
        widget.fixedExactTag ?? _resolveInitialExactTag(initial);
    _selectedSkillNoteId = initial?.skillNoteId;
    _contentImmutable = initial?.contentImmutable ?? false;
  }

  @override
  void dispose() {
    _patternController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  String? _resolveInitialExactTag(WorkflowBindingRow? initial) {
    if (initial == null || initial.isPrefix) return null;
    return initial.pattern;
  }

  List<SkillMetadata> get _skills {
    final skills = widget.skillIndex.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return skills;
  }

  List<String> get _tagOptions {
    final tags = {...widget.allTagNames};
    if (widget.initialBinding != null && !widget.initialBinding!.isPrefix) {
      tags.add(widget.initialBinding!.pattern);
    }
    final values = tags.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return values;
  }

  String get _currentPattern {
    if (_isPrefix) {
      return _normalizePrefix(_patternController.text);
    }
    return (widget.fixedExactTag ?? _selectedExactTag ?? '').trim();
  }

  String _normalizePrefix(String raw) {
    final trimmed = raw.trim();
    if (trimmed.endsWith('*')) {
      return trimmed.substring(0, trimmed.length - 1).trimRight();
    }
    return trimmed;
  }

  List<String> get _ambiguousMatches {
    if (!_isPrefix) return const [];
    final prefix = _normalizePrefix(_patternController.text);
    if (prefix.length < 2) return const [];
    return widget.allTagNames
        .where((tag) => tag.startsWith(prefix) && tag.length > prefix.length)
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    Navigator.of(context).pop(
      TagWorkflowBindingDraft(
        pattern: _currentPattern,
        isPrefix: _isPrefix,
        skillNoteId: _selectedSkillNoteId!,
        prompt: _promptController.text.trim(),
        contentImmutable: _contentImmutable,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initialBinding != null;
    final title = editing ? 'Edit Workflow Binding' : 'Add Workflow Binding';
    final duplicatePatterns = Set<String>.from(widget.existingPatterns);
    final originalPattern = widget.initialBinding?.pattern;
    if (originalPattern != null) {
      duplicatePatterns.remove(originalPattern);
    }

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.fixedExactTag == null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Prefix Binding'),
                    subtitle: const Text(
                      'When enabled, any tag starting with the pattern will use this workflow.',
                    ),
                    value: _isPrefix,
                    onChanged: (value) {
                      setState(() {
                        _isPrefix = value;
                      });
                    },
                  ),
                if (_isPrefix) ...[
                  TextFormField(
                    controller: _patternController,
                    decoration: const InputDecoration(
                      labelText: 'Prefix Pattern',
                      hintText: 'wiki-source-',
                      helperText:
                          'Matches tags that start with this text. A trailing * is optional and will be ignored.',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final pattern = _normalizePrefix(value ?? '');
                      if (pattern.isEmpty) {
                        return 'Enter a prefix pattern';
                      }
                      if (pattern.length < 2) {
                        return 'Prefix pattern must be at least 2 characters';
                      }
                      if (duplicatePatterns.contains(pattern)) {
                        return 'A binding with this pattern already exists';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                ] else ...[
                  DropdownButtonFormField<String>(
                    initialValue: _selectedExactTag,
                    items: _tagOptions
                        .map(
                          (tag) => DropdownMenuItem<String>(
                            value: tag,
                            child: Text(tag, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    decoration: InputDecoration(
                      labelText: widget.fixedExactTag == null
                          ? 'Tag'
                          : 'Exact Tag',
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: widget.fixedExactTag == null
                        ? (value) => setState(() => _selectedExactTag = value)
                        : null,
                    validator: (value) {
                      final pattern = (widget.fixedExactTag ?? value ?? '')
                          .trim();
                      if (pattern.isEmpty) {
                        return 'Select a tag';
                      }
                      if (duplicatePatterns.contains(pattern)) {
                        return 'A binding for this tag already exists';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                DropdownButtonFormField<String>(
                  initialValue: _selectedSkillNoteId,
                  items: _skills
                      .map(
                        (skill) => DropdownMenuItem<String>(
                          value: skill.noteId,
                          child: Text(
                            '${skill.name} — ${skill.description}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  decoration: const InputDecoration(
                    labelText: 'Skill',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) =>
                      setState(() => _selectedSkillNoteId = value),
                  validator: (value) =>
                      value == null || value.isEmpty ? 'Select a skill' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _promptController,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Workflow Prompt Override',
                    hintText:
                        'Optional extra instructions for this tag binding',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: _contentImmutable,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Make matching notes content-immutable'),
                  subtitle: const Text(
                    'Prevents content and title edits; tags, links, and attachments remain editable.',
                  ),
                  onChanged: (value) {
                    setState(() {
                      _contentImmutable = value ?? false;
                    });
                  },
                ),
                if (_ambiguousMatches.length > 1) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.orange.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      'Warning: this prefix currently matches multiple tags: ${_ambiguousMatches.join(', ')}. '
                      'A note carrying more than one of these tags will hit the runtime ambiguity check.',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(editing ? 'Save' : 'Add')),
      ],
    );
  }
}
