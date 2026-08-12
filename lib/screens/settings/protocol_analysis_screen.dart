import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/model_config.dart';
import '../../models/model_type.dart';
import '../../models/protocol_exchange.dart';
import '../../models/protocol_study.dart';
import '../../services/model_selector.dart';
import '../../services/model_storage_service.dart';
import '../../services/protocol_study/protocol_ai_projection.dart';
import '../../services/protocol_study/protocol_analysis_service.dart';
import '../../services/protocol_study/protocol_capture_controller.dart';
import '../../services/protocol_study/protocol_sensitivity_classifier.dart';
import '../../services/protocol_study/protocol_study_workspace.dart';
import '../../services/service_locator.dart';
import 'protocol_knowledge_screen.dart';

class ProtocolAnalysisScreen extends StatefulWidget {
  const ProtocolAnalysisScreen({
    super.key,
    required this.study,
    required this.controller,
    required this.workspace,
  });

  final ProtocolStudy study;
  final ProtocolCaptureController controller;
  final ProtocolStudyWorkspace workspace;

  @override
  State<ProtocolAnalysisScreen> createState() => _ProtocolAnalysisScreenState();
}

class _ProtocolAnalysisScreenState extends State<ProtocolAnalysisScreen> {
  final _classifier = const ProtocolSensitivityClassifier();
  late Future<List<ModelConfig>> _modelsFuture;
  ModelConfig? _model;
  ProtocolDisclosureSession? _disclosure;
  bool _analyzing = false;
  int _analysisPair = 0;
  int _analysisPairCount = 0;

  @override
  void initState() {
    super.initState();
    _modelsFuture = getIt<ModelStorageService>().getConfiguredModels();
  }

  List<ProtocolExchange> get _selected => widget.controller.exchanges
      .where((exchange) => exchange.selected)
      .toList(growable: false);

  List<ProtocolField> get _fields =>
      _selected.expand(_classifier.fieldsFor).toList(growable: false);

  void _selectModel(ModelConfig? model) {
    setState(() {
      _model = model;
      _disclosure = model == null
          ? null
          : ProtocolDisclosureSession(ProtocolAIDestination.forModel(model));
    });
  }

  void _applyRecommendations() {
    final disclosure = _disclosure;
    if (disclosure == null || disclosure.destination.isLocal) return;
    setState(() {
      for (final field in _fields) {
        disclosure.setDisclosed(
          field.id,
          field.sensitivity == ProtocolSensitivity.none,
        );
      }
    });
  }

  Future<bool> _showPreview(ProtocolAIPreview preview) async {
    final l10n = AppLocalizations.of(context)!;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.protocolStudyOutboundPreview),
            content: SizedBox(
              width: 760,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${l10n.protocolStudyModelLabel}: ${preview.destination.displayName}',
                  ),
                  Text(
                    '${l10n.protocolStudyDestinationLabel}: ${preview.destination.endpoint}',
                  ),
                  Text(
                    '${preview.disclosedFields.length} ${l10n.protocolStudyDisclosed} • ${preview.redactedFieldCount} ${l10n.protocolStudyRedacted}',
                  ),
                  if (preview.excludedFieldCount > 0)
                    Text(
                      '${preview.excludedFieldCount} ${l10n.protocolStudyExcluded}',
                    ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(preview.formattedPayload),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.protocolStudySendForAnalysis),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _analyze() async {
    final model = _model;
    final disclosure = _disclosure;
    if (model == null || disclosure == null || _selected.isEmpty) return;
    final preview = const ProtocolAIProjectionBuilder().build(
      exchanges: _selected,
      disclosure: disclosure,
    );
    if (!await _showPreview(preview) || !mounted) return;
    setState(() => _analyzing = true);
    try {
      final knowledge = await ProtocolAnalysisService(getIt<ModelSelector>())
          .analyze(
            model: model,
            preview: preview,
            disclosure: disclosure,
            sourceExchanges: _selected,
            onProgress: (current, total) {
              if (!mounted) return;
              setState(() {
                _analysisPair = current;
                _analysisPairCount = total;
              });
            },
          );
      final updated = widget.study.copyWith(
        updatedAt: DateTime.now(),
        exchanges: List.unmodifiable(widget.controller.exchanges),
        knowledge: knowledge,
      );
      await widget.workspace.save(updated);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute(
          builder: (_) => ProtocolKnowledgeScreen(
            study: updated,
            knowledge: knowledge,
            workspace: widget.workspace,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${AppLocalizations.of(context)!.protocolStudyAnalysisFailed}: $error',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _analyzing = false;
          _analysisPair = 0;
          _analysisPairCount = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.protocolStudyAnalyze)),
      body: FutureBuilder<List<ModelConfig>>(
        future: _modelsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final models = snapshot.data ?? const [];
          if (models.isEmpty) {
            return Center(child: Text(l10n.protocolStudyNoModel));
          }
          if (_model == null) {
            final local = models.where(
              (model) => model.type == ModelType.localMnn,
            );
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _model == null) {
                _selectModel(local.isNotEmpty ? local.first : models.first);
              }
            });
          }
          final disclosure = _disclosure;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: DropdownButtonFormField<ModelConfig>(
                  initialValue: _model,
                  decoration: InputDecoration(
                    labelText: l10n.protocolStudyChooseModel,
                    border: const OutlineInputBorder(),
                  ),
                  items: models
                      .map(
                        (model) => DropdownMenuItem(
                          value: model,
                          child: Text(
                            '${model.displayName ?? model.modelName ?? model.type.displayName}${model.type == ModelType.localMnn ? ' • on-device' : ' • remote'}',
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _analyzing ? null : _selectModel,
                ),
              ),
              if (disclosure != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          disclosure.destination.isLocal
                              ? l10n.protocolStudyLocalDisclosure
                              : l10n.protocolStudyRemoteDisclosure,
                        ),
                      ),
                      if (!disclosure.destination.isLocal)
                        TextButton(
                          onPressed: _applyRecommendations,
                          child: Text(l10n.protocolStudyApplyRecommendations),
                        ),
                    ],
                  ),
                ),
              const Divider(),
              Expanded(
                child: disclosure == null
                    ? const SizedBox.shrink()
                    : ListView.builder(
                        itemCount: _fields.length,
                        itemBuilder: (context, index) {
                          final field = _fields[index];
                          final local = disclosure.destination.isLocal;
                          final included = disclosure.isIncluded(field.id);
                          return CheckboxListTile(
                            value: local
                                ? included
                                : included && disclosure.isDisclosed(field.id),
                            onChanged: local
                                ? (value) => setState(
                                    () => disclosure.setIncluded(
                                      field.id,
                                      value ?? false,
                                    ),
                                  )
                                : !included
                                ? null
                                : (value) => setState(
                                    () => disclosure.setDisclosed(
                                      field.id,
                                      value ?? false,
                                    ),
                                  ),
                            title: Text(
                              '${field.location.name}: ${field.name}',
                            ),
                            subtitle: Text(
                              '${field.sensitivity.name} • ${field.value}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            secondary: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!local)
                                  IconButton(
                                    onPressed: () => setState(
                                      () => disclosure.setIncluded(
                                        field.id,
                                        !included,
                                      ),
                                    ),
                                    icon: Icon(
                                      included
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                    ),
                                    tooltip: included
                                        ? l10n.protocolStudyExcludeField
                                        : l10n.protocolStudyIncludeField,
                                  ),
                                IconButton(
                                  onPressed: () {
                                    widget.controller.setParameter(
                                      field.id,
                                      !field.isParameter,
                                    );
                                    setState(() {});
                                  },
                                  icon: Icon(
                                    field.isParameter
                                        ? Icons.flag
                                        : Icons.outlined_flag,
                                  ),
                                  tooltip: l10n.protocolStudyMarkParameter,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _analyzing || disclosure == null
                          ? null
                          : _analyze,
                      icon: _analyzing
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome),
                      label: Text(
                        _analyzing && _analysisPairCount > 1
                            ? l10n.protocolStudyAnalyzingPair(
                                _analysisPair,
                                _analysisPairCount,
                              )
                            : l10n.protocolStudySendForAnalysis,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
