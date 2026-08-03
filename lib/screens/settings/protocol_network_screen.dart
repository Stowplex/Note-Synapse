import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/protocol_exchange.dart';
import '../../services/protocol_study/protocol_capture_controller.dart';
import '../../services/protocol_study/protocol_recipe_runner.dart';
import '../../services/web_session_service.dart';

enum _NetworkFilter { all, fetch, xhr, form }

class ProtocolNetworkScreen extends StatefulWidget {
  const ProtocolNetworkScreen({
    super.key,
    required this.controller,
    required this.webSessions,
    this.savedLoginDomain,
    this.onAnalyze,
  });

  final ProtocolCaptureController controller;
  final WebSessionService webSessions;
  final String? savedLoginDomain;
  final VoidCallback? onAnalyze;

  @override
  State<ProtocolNetworkScreen> createState() => _ProtocolNetworkScreenState();
}

class _ProtocolNetworkScreenState extends State<ProtocolNetworkScreen> {
  _NetworkFilter _filter = _NetworkFilter.all;
  bool _running = false;

  List<ProtocolExchange> _visible() => widget.controller.exchanges
      .where((item) {
        return switch (_filter) {
          _NetworkFilter.all => true,
          _NetworkFilter.fetch => item.source == ProtocolRequestSource.fetch,
          _NetworkFilter.xhr => item.source == ProtocolRequestSource.xhr,
          _NetworkFilter.form => item.source == ProtocolRequestSource.form,
        };
      })
      .toList(growable: false);

  Future<void> _runSelected() async {
    final l10n = AppLocalizations.of(context)!;
    final selected = widget.controller.exchanges
        .where((exchange) => exchange.selected)
        .toList();
    if (selected.isEmpty) return;
    if (selected.any((exchange) => exchange.mutatesState)) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.protocolStudyRunRepro),
          content: Text(l10n.protocolStudyMutationWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.continueButton),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
    }
    setState(() => _running = true);
    final runner = ProtocolRecipeRunner(webSessions: widget.webSessions);
    try {
      final steps = await runner.runWorkflow(
        selected,
        useSavedLogin: widget.savedLoginDomain != null,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.protocolStudyReproResult),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: SelectableText(
                steps.indexed
                    .map((entry) {
                      final (index, step) = entry;
                      return '${index + 1}. ${step.exchange.method} ${step.exchange.url}\n'
                          '${l10n.protocolStudyStatus}: ${step.result.statusCode}\n'
                          '${step.result.body}'
                          '${step.result.truncated ? '\n<${l10n.protocolStudyTruncated}>' : ''}';
                    })
                    .join('\n\n'),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.close),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${l10n.protocolStudyReproResult}: $error')),
      );
    } finally {
      runner.close();
      if (mounted) setState(() => _running = false);
    }
  }

  void _showDetails(ProtocolExchange exchange) {
    final l10n = AppLocalizations.of(context)!;
    final requestHeaders = exchange.requestHeaders
        .map((field) => '${field.name}: ${field.value}')
        .join('\n');
    final responseHeaders = exchange.responseHeaders
        .map((field) => '${field.name}: ${field.value}')
        .join('\n');
    final metadata = exchange.requestMetadata.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n');
    final fidelityIssues = <String>{
      ...exchange.captureIssues,
      if (exchange.requestBody?.omittedReason case final reason?) reason,
      if (exchange.responseBody?.omittedReason case final reason?) reason,
    }.join('\n');
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${exchange.method} ${exchange.status ?? ''}'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: SelectableText(
              '${exchange.url}\n\n'
              '${exchange.redirected ? '${l10n.protocolStudyFinalUrl}\n${exchange.responseUrl}\n\n' : ''}'
              '${metadata.isEmpty ? '' : '${l10n.protocolStudyTransportMetadata}\n$metadata\n\n'}'
              '${fidelityIssues.isEmpty ? '' : '${l10n.protocolStudyFidelityWarning}\n$fidelityIssues\n\n'}'
              '${l10n.protocolStudyRequestHeaders}\n$requestHeaders\n\n'
              '${l10n.protocolStudyRequestBody}\n${exchange.requestBody?.text ?? '<${l10n.protocolStudyNotCaptured}>'}\n\n'
              '${l10n.protocolStudyResponseHeaders}\n$responseHeaders\n\n'
              '${l10n.protocolStudyResponseBody}\n${exchange.responseBody?.text ?? '<${l10n.protocolStudyNotCaptured}: ${exchange.responseBody?.omittedReason ?? 'unknown'}>'}',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context)!.close),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.protocolStudyNetwork)),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final exchanges = _visible();
          final selectedCount = widget.controller.exchanges
              .where((exchange) => exchange.selected)
              .length;
          return Column(
            children: [
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SegmentedButton<_NetworkFilter>(
                          segments: [
                            ButtonSegment(
                              value: _NetworkFilter.all,
                              label: Text(l10n.protocolStudyAll),
                            ),
                            const ButtonSegment(
                              value: _NetworkFilter.fetch,
                              label: Text('Fetch'),
                            ),
                            const ButtonSegment(
                              value: _NetworkFilter.xhr,
                              label: Text('XHR'),
                            ),
                            ButtonSegment(
                              value: _NetworkFilter.form,
                              label: Text(l10n.protocolStudyForm),
                            ),
                          ],
                          selected: {_filter},
                          onSelectionChanged: (value) =>
                              setState(() => _filter = value.single),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(l10n.protocolStudySelectRequests),
                      Text(
                        l10n.protocolStudyRawLocal,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              if (widget.controller.stoppedByLimit)
                ListTile(
                  leading: const Icon(Icons.warning_amber),
                  title: Text(l10n.protocolStudyCaptureLimit),
                ),
              Expanded(
                child: exchanges.isEmpty
                    ? Center(child: Text(l10n.protocolStudyNoRequests))
                    : ListView.builder(
                        itemCount: exchanges.length,
                        itemBuilder: (context, index) {
                          final exchange = exchanges[index];
                          final uri = Uri.tryParse(exchange.url);
                          return CheckboxListTile(
                            value: exchange.selected,
                            onChanged: (value) => widget.controller.setSelected(
                              exchange.id,
                              value ?? false,
                            ),
                            secondary: IconButton(
                              onPressed: () => _showDetails(exchange),
                              icon: Icon(
                                exchange.mutatesState
                                    ? Icons.edit_note
                                    : Icons.download_outlined,
                                color: exchange.mutatesState
                                    ? Theme.of(context).colorScheme.error
                                    : null,
                              ),
                              tooltip: l10n.protocolStudyViewRaw,
                            ),
                            title: Text(
                              '${exchange.method}  ${exchange.status ?? '…'}  ${uri?.host ?? exchange.url}',
                            ),
                            subtitle: Text(
                              '${exchange.source.name}  ${uri?.path ?? ''}'
                              '${exchange.responseBody?.truncated == true ? '  • ${l10n.protocolStudyTruncated}' : ''}'
                              '${exchange.captureIssues.isNotEmpty || exchange.requestBody?.omittedReason != null || exchange.responseBody?.omittedReason != null ? '  • ${l10n.protocolStudyPartial}' : ''}'
                              '${exchange.exampleIndex > 1 ? '  • #${exchange.exampleIndex}' : ''}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                          );
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: selectedCount == 0 || _running
                              ? null
                              : _runSelected,
                          icon: _running
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.science_outlined),
                          label: Text(l10n.protocolStudyRunRepro),
                        ),
                      ),
                      if (widget.onAnalyze != null) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: selectedCount == 0
                                ? null
                                : widget.onAnalyze,
                            icon: const Icon(Icons.auto_awesome),
                            label: Text(l10n.protocolStudyAnalyze),
                          ),
                        ),
                      ],
                    ],
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
