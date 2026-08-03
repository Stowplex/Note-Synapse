import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/note.dart';
import '../../models/protocol_exchange.dart';
import '../../models/protocol_knowledge.dart';
import '../../models/protocol_study.dart';
import '../../models/user_app.dart';
import '../../services/database_service.dart';
import '../../services/note_modification_service.dart';
import '../../services/protocol_study/protocol_capture_controller.dart';
import '../../services/protocol_study/protocol_report_renderer.dart';
import '../../services/protocol_study/protocol_study_workspace.dart';
import '../../services/service_locator.dart';
import '../../services/web_session_service.dart';
import '../user_app_creation_screen.dart';
import 'protocol_network_screen.dart';

class ProtocolKnowledgeScreen extends StatefulWidget {
  const ProtocolKnowledgeScreen({
    super.key,
    required this.study,
    required this.knowledge,
    required this.workspace,
  });

  final ProtocolStudy study;
  final ProtocolKnowledge knowledge;
  final ProtocolStudyWorkspace workspace;

  @override
  State<ProtocolKnowledgeScreen> createState() =>
      _ProtocolKnowledgeScreenState();
}

class _ProtocolKnowledgeScreenState extends State<ProtocolKnowledgeScreen> {
  bool _exporting = false;
  bool _editing = false;
  bool _saving = false;
  late ProtocolKnowledge _knowledge;
  late ProtocolStudy _study;

  @override
  void initState() {
    super.initState();
    _knowledge = widget.knowledge;
    _study = widget.study.copyWith(knowledge: widget.knowledge);
  }

  void _replaceParameter(int index, ProtocolParameterKnowledge value) {
    final parameters = [..._knowledge.parameters];
    parameters[index] = value;
    setState(() => _knowledge = _knowledge.copyWith(parameters: parameters));
  }

  void _replaceStep(int index, ProtocolStepKnowledge value) {
    final steps = [..._knowledge.steps];
    steps[index] = value;
    setState(() => _knowledge = _knowledge.copyWith(steps: steps));
  }

  void _replaceCaveat(int index, String value) {
    final caveats = [..._knowledge.caveats];
    caveats[index] = value;
    setState(() => _knowledge = _knowledge.copyWith(caveats: caveats));
  }

  Future<void> _saveEdits() async {
    setState(() => _saving = true);
    try {
      _study = _study.copyWith(
        updatedAt: DateTime.now(),
        knowledge: _knowledge,
      );
      await widget.workspace.save(_study);
      if (mounted) setState(() => _editing = false);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<Note?> _exportNote({bool announce = true}) async {
    if (_exporting) return null;
    setState(() => _exporting = true);
    try {
      final view = ProtocolExportView.build(
        study: _study,
        knowledge: _knowledge,
      );
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            AppLocalizations.of(context)!.protocolStudyReviewSanitizedNote,
          ),
          content: SizedBox(
            width: 760,
            child: SingleChildScrollView(child: SelectableText(view.markdown)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppLocalizations.of(context)!.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                AppLocalizations.of(context)!.protocolStudyExportNote,
              ),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return null;
      final id = await ProtocolNoteExporter(
        getIt<NoteModificationService>(),
      ).export(view);
      _study = _study.copyWith(
        updatedAt: DateTime.now(),
        noteExportedAt: DateTime.now(),
      );
      await widget.workspace.save(_study);
      final note = await getIt<DatabaseService>().getNote(id);
      if (announce && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.protocolStudyNoteSaved),
          ),
        );
      }
      return note;
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _createApp(UserAppType type) async {
    final note = await _exportNote(announce: false);
    if (note == null || !mounted) return;
    final steps = _knowledge.steps
        .map(
          (step) =>
              '${step.method} ${step.urlTemplate}: ${step.purpose}${step.mutatesState ? ' (mutates state; request approval)' : ''}',
        )
        .toList(growable: false);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => UserAppCreationScreen(
          initialName: _knowledge.title,
          initialDescription: _knowledge.summary,
          initialSteps: steps,
          initialContextNotes: [note],
          initialAppType: type,
        ),
      ),
    );
  }

  Future<void> _openRepro() async {
    final controller = ProtocolCaptureController.fromExchanges(
      exchanges: _study.exchanges,
      limits: _study.limits,
    );
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ProtocolNetworkScreen(
            controller: controller,
            webSessions: getIt<WebSessionService>(),
            savedLoginDomain: _study.savedLoginDomain,
            onExchangesChanged: (exchanges) async {
              final updated = _study.copyWith(
                updatedAt: DateTime.now(),
                exchanges: List<ProtocolExchange>.unmodifiable(exchanges),
              );
              await widget.workspace.save(updated);
              if (mounted) setState(() => _study = updated);
            },
          ),
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_knowledge.title),
        actions: [
          if (_editing)
            IconButton(
              onPressed: _saving ? null : _saveEdits,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              tooltip: l10n.save,
            )
          else
            IconButton(
              onPressed: () => setState(() => _editing = true),
              icon: const Icon(Icons.edit_outlined),
              tooltip: l10n.edit,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_editing) ...[
            TextFormField(
              initialValue: _knowledge.title,
              decoration: InputDecoration(labelText: l10n.title),
              onChanged: (value) =>
                  _knowledge = _knowledge.copyWith(title: value),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _knowledge.summary,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(labelText: l10n.description),
              onChanged: (value) =>
                  _knowledge = _knowledge.copyWith(summary: value),
            ),
          ] else
            Text(
              _knowledge.summary,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _knowledge.confidence),
          const SizedBox(height: 24),
          Text(
            l10n.protocolStudyParameters,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (_knowledge.parameters.isEmpty)
            ListTile(title: Text(l10n.protocolStudyNoneIdentified)),
          ..._knowledge.parameters.indexed.map((entry) {
            final (index, parameter) = entry;
            if (_editing) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      TextFormField(
                        initialValue: parameter.name,
                        decoration: InputDecoration(labelText: l10n.name),
                        onChanged: (value) => _replaceParameter(
                          index,
                          parameter.copyWith(name: value),
                        ),
                      ),
                      TextFormField(
                        initialValue: parameter.location,
                        onChanged: (value) => _replaceParameter(
                          index,
                          parameter.copyWith(location: value),
                        ),
                      ),
                      TextFormField(
                        initialValue: parameter.description,
                        decoration: InputDecoration(
                          labelText: l10n.description,
                        ),
                        onChanged: (value) => _replaceParameter(
                          index,
                          parameter.copyWith(description: value),
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.required),
                        value: parameter.required,
                        onChanged: (value) => _replaceParameter(
                          index,
                          parameter.copyWith(required: value),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }
            return ListTile(
              leading: const Icon(Icons.data_object),
              title: Text(parameter.name),
              subtitle: Text(
                '${parameter.location} • ${parameter.required ? l10n.required : l10n.protocolStudyOptional}\n${parameter.description}',
              ),
            );
          }),
          const SizedBox(height: 16),
          Text(
            l10n.protocolStudyWorkflow,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          ..._knowledge.steps.indexed.map((entry) {
            final (index, step) = entry;
            if (_editing) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      TextFormField(
                        initialValue: step.method,
                        textCapitalization: TextCapitalization.characters,
                        onChanged: (value) =>
                            _replaceStep(index, step.copyWith(method: value)),
                      ),
                      TextFormField(
                        initialValue: step.urlTemplate,
                        decoration: InputDecoration(labelText: l10n.url),
                        onChanged: (value) => _replaceStep(
                          index,
                          step.copyWith(urlTemplate: value),
                        ),
                      ),
                      TextFormField(
                        initialValue: step.purpose,
                        decoration: InputDecoration(
                          labelText: l10n.description,
                        ),
                        onChanged: (value) =>
                            _replaceStep(index, step.copyWith(purpose: value)),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.protocolStudyMutationWarning),
                        value: step.mutatesState,
                        onChanged: (value) => _replaceStep(
                          index,
                          step.copyWith(mutatesState: value),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }
            return Card(
              child: ListTile(
                leading: CircleAvatar(child: Text('${index + 1}')),
                title: Text('${step.method} ${step.urlTemplate}'),
                subtitle: Text(step.purpose),
                trailing: step.mutatesState
                    ? Icon(
                        Icons.warning_amber,
                        color: Theme.of(context).colorScheme.error,
                      )
                    : null,
              ),
            );
          }),
          if (_knowledge.caveats.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              l10n.protocolStudyCaveats,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            ..._knowledge.caveats.indexed.map((entry) {
              final (index, caveat) = entry;
              if (_editing) {
                return TextFormField(
                  initialValue: caveat,
                  minLines: 1,
                  maxLines: 4,
                  onChanged: (value) => _replaceCaveat(index, value),
                );
              }
              return ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(caveat),
              );
            }),
          ],
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: _openRepro,
            icon: const Icon(Icons.science_outlined),
            label: Text(l10n.protocolStudyRunRepro),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _exporting ? null : () => _exportNote(),
            icon: const Icon(Icons.note_add_outlined),
            label: Text(l10n.protocolStudyExportNote),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _exporting ? null : () => _createApp(UserAppType.aiTool),
            icon: const Icon(Icons.build_outlined),
            label: Text(l10n.protocolStudyCreateTool),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _exporting ? null : () => _createApp(UserAppType.normal),
            icon: const Icon(Icons.apps_outlined),
            label: Text(l10n.protocolStudyCreateApp),
          ),
        ],
      ),
    );
  }
}
