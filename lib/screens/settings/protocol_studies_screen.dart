import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/protocol_exchange.dart';
import '../../models/protocol_study.dart';
import '../../services/protocol_study/protocol_capture_controller.dart';
import '../../services/protocol_study/protocol_study_workspace.dart';
import '../../services/web_session_service.dart';
import 'protocol_analysis_screen.dart';
import 'protocol_knowledge_screen.dart';
import 'protocol_network_screen.dart';
import 'protocol_study_browser_screen.dart';

class ProtocolStudiesScreen extends StatefulWidget {
  const ProtocolStudiesScreen({
    super.key,
    required this.webSessions,
    this.workspace,
  });

  final WebSessionService webSessions;
  final ProtocolStudyWorkspace? workspace;

  @override
  State<ProtocolStudiesScreen> createState() => _ProtocolStudiesScreenState();
}

class _ProtocolStudiesScreenState extends State<ProtocolStudiesScreen> {
  late final ProtocolStudyWorkspace _workspace;
  late Future<List<ProtocolStudy>> _studies;

  @override
  void initState() {
    super.initState();
    _workspace = widget.workspace ?? ProtocolStudyWorkspace();
    _studies = _workspace.listStudies();
  }

  void _refresh() {
    final studies = _workspace.listStudies();
    setState(() {
      _studies = studies;
    });
  }

  Future<void> _newStudy() async {
    final study = await Navigator.of(context).push<ProtocolStudy>(
      MaterialPageRoute(
        builder: (_) => ProtocolStudyBrowserScreen(
          workspace: _workspace,
          webSessions: widget.webSessions,
        ),
      ),
    );
    if (study != null && mounted) _refresh();
  }

  Future<void> _delete(ProtocolStudy study) async {
    final l10n = AppLocalizations.of(context)!;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.protocolStudyDelete),
        content: Text(l10n.protocolStudyDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (approved == true) {
      await _workspace.delete(study.id);
      if (mounted) _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.protocolStudies)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newStudy,
        icon: const Icon(Icons.add),
        label: Text(l10n.newProtocolStudy),
      ),
      body: FutureBuilder<List<ProtocolStudy>>(
        future: _studies,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final studies = snapshot.data ?? const [];
          if (studies.isEmpty) {
            return Center(child: Text(l10n.protocolStudyEmpty));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: studies.length,
            itemBuilder: (context, index) {
              final study = studies[index];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.schema_outlined),
                  title: Text(study.title),
                  subtitle: Text(
                    '${study.exchanges.length} ${l10n.protocolStudyRequests} • ${study.updatedAt.toLocal()}',
                    maxLines: 2,
                  ),
                  trailing: IconButton(
                    onPressed: () => _delete(study),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: l10n.protocolStudyDelete,
                  ),
                  onTap: () async {
                    await Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => _ProtocolStudyDetailScreen(
                          study: study,
                          workspace: _workspace,
                          webSessions: widget.webSessions,
                        ),
                      ),
                    );
                    if (mounted) _refresh();
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ProtocolStudyDetailScreen extends StatefulWidget {
  const _ProtocolStudyDetailScreen({
    required this.study,
    required this.workspace,
    required this.webSessions,
  });

  final ProtocolStudy study;
  final ProtocolStudyWorkspace workspace;
  final WebSessionService webSessions;

  @override
  State<_ProtocolStudyDetailScreen> createState() =>
      _ProtocolStudyDetailScreenState();
}

class _ProtocolStudyDetailScreenState
    extends State<_ProtocolStudyDetailScreen> {
  late final ProtocolCaptureController _controller;
  late ProtocolStudy _study;

  @override
  void initState() {
    super.initState();
    _study = widget.study;
    _controller = ProtocolCaptureController.fromExchanges(
      exchanges: _study.exchanges,
      limits: _study.limits,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _analyze() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProtocolAnalysisScreen(
          study: _study,
          controller: _controller,
          workspace: widget.workspace,
        ),
      ),
    );
  }

  Future<void> _saveExchanges(List<ProtocolExchange> exchanges) async {
    final updated = _study.copyWith(
      updatedAt: DateTime.now(),
      exchanges: List<ProtocolExchange>.unmodifiable(exchanges),
    );
    await widget.workspace.save(updated);
    if (mounted) setState(() => _study = updated);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(_study.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.public),
            title: Text(_study.startUrl),
            subtitle: Text(_study.sessionProvenance.name),
          ),
          ListTile(
            leading: const Icon(Icons.security_outlined),
            title: Text(l10n.protocolStudyRawLocal),
            subtitle: Text(l10n.protocolStudyFidelityWarning),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => ProtocolNetworkScreen(
                  controller: _controller,
                  webSessions: widget.webSessions,
                  savedLoginDomain: _study.savedLoginDomain,
                  onAnalyze: _analyze,
                  onExchangesChanged: _saveExchanges,
                ),
              ),
            ),
            icon: const Icon(Icons.network_check),
            label: Text(
              '${l10n.protocolStudyNetwork} (${_controller.exchanges.length})',
            ),
          ),
          if (_study.knowledge != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => ProtocolKnowledgeScreen(
                    study: _study,
                    knowledge: _study.knowledge!,
                    workspace: widget.workspace,
                  ),
                ),
              ),
              icon: const Icon(Icons.auto_awesome),
              label: Text(l10n.protocolStudyAnalyze),
            ),
          ],
        ],
      ),
    );
  }
}
