import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/protocol_exchange.dart';
import '../../services/protocol_study/protocol_capture_controller.dart';
import '../../services/protocol_study/protocol_recipe_runner.dart';
import '../../services/web_session_service.dart';

enum _NetworkFilter { all, fetch, xhr, form, page }

class ProtocolNetworkScreen extends StatefulWidget {
  const ProtocolNetworkScreen({
    super.key,
    required this.controller,
    required this.webSessions,
    this.savedLoginDomain,
    this.onAnalyze,
    this.onExchangesChanged,
    this.runnerFactory,
  });

  final ProtocolCaptureController controller;
  final WebSessionService webSessions;
  final String? savedLoginDomain;
  final VoidCallback? onAnalyze;
  final Future<void> Function(List<ProtocolExchange> exchanges)?
  onExchangesChanged;
  final ProtocolRecipeRunner Function()? runnerFactory;

  @override
  State<ProtocolNetworkScreen> createState() => _ProtocolNetworkScreenState();
}

class _ProtocolNetworkScreenState extends State<ProtocolNetworkScreen> {
  _NetworkFilter _filter = _NetworkFilter.all;
  bool _running = false;
  final Set<String> _runningExchangeIds = {};

  List<ProtocolExchange> _visible() => widget.controller.exchanges
      .where((item) {
        return switch (_filter) {
          _NetworkFilter.all => true,
          _NetworkFilter.fetch => item.source == ProtocolRequestSource.fetch,
          _NetworkFilter.xhr => item.source == ProtocolRequestSource.xhr,
          _NetworkFilter.form => item.source == ProtocolRequestSource.form,
          _NetworkFilter.page =>
            item.source == ProtocolRequestSource.navigation,
        };
      })
      .toList(growable: false);

  ProtocolRecipeRunner _newRunner() =>
      widget.runnerFactory?.call() ??
      ProtocolRecipeRunner(webSessions: widget.webSessions);

  Future<bool> _approveMutation(Iterable<ProtocolExchange> exchanges) async {
    if (!exchanges.any((exchange) => exchange.mutatesState)) return true;
    final l10n = AppLocalizations.of(context)!;
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
    return approved == true && mounted;
  }

  Future<void> _prepareLogin(String url) async {
    if (widget.savedLoginDomain != null) {
      await widget.webSessions.restoreCookies(url);
    }
  }

  void _attachResult(String exchangeId, ProtocolRecipeResult result) {
    widget.controller.attachReplay(
      exchangeId: exchangeId,
      replayedAt: DateTime.now(),
      statusCode: result.statusCode,
      finalUrl: result.finalUrl,
      headers: result.headers,
      bodyText: result.body,
      mimeType: result.mimeType,
      byteLength: result.byteLength,
      truncated: result.truncated,
      omittedReason: result.omittedReason,
      redirectChain: result.redirectChain,
      usedSessionCookies: result.usedSessionCookies,
      fidelityIssues: result.fidelityIssues,
    );
  }

  Future<void> _persistExchanges() async {
    await widget.onExchangesChanged?.call(
      List<ProtocolExchange>.unmodifiable(widget.controller.exchanges),
    );
  }

  Future<void> _runOne(ProtocolExchange exchange) async {
    if (_runningExchangeIds.contains(exchange.id) ||
        !await _approveMutation([exchange])) {
      return;
    }
    setState(() => _runningExchangeIds.add(exchange.id));
    final runner = _newRunner();
    try {
      await _prepareLogin(exchange.url);
      final result = await runner.run(
        exchange,
        // An explicit replay may use either a restored saved login or the
        // current ambient WebView jar. Cookie values never enter the result.
        useSessionCookies: true,
        maxResponseBytes: widget.controller.limits.maxResponseBodyBytes,
      );
      _attachResult(exchange.id, result);
      await _persistExchanges();
      if (!mounted) return;
      _showDetails(
        widget.controller.exchanges.firstWhere(
          (item) => item.id == exchange.id,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${AppLocalizations.of(context)!.protocolStudyReplayFailed}: $error',
          ),
        ),
      );
    } finally {
      runner.close();
      if (mounted) setState(() => _runningExchangeIds.remove(exchange.id));
    }
  }

  Future<void> _runSelected() async {
    final l10n = AppLocalizations.of(context)!;
    final selected = widget.controller.exchanges
        .where((exchange) => exchange.selected)
        .toList();
    if (selected.isEmpty || !await _approveMutation(selected)) return;
    setState(() => _running = true);
    final runner = _newRunner();
    final results =
        <({ProtocolExchange exchange, ProtocolRecipeResult result})>[];
    try {
      for (final exchange in selected) {
        await _prepareLogin(exchange.url);
        final result = await runner.run(
          exchange,
          useSessionCookies: true,
          maxResponseBytes: widget.controller.limits.maxResponseBodyBytes,
        );
        _attachResult(exchange.id, result);
        results.add((exchange: exchange, result: result));
      }
      await _persistExchanges();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.protocolStudyReproResult),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: SelectableText(
                results.indexed
                    .map((entry) {
                      final (index, step) = entry;
                      final result = step.result;
                      return '${index + 1}. ${step.exchange.method} ${step.exchange.url}\n'
                          '${l10n.protocolStudyStatus}: ${result.statusCode}\n'
                          '${result.body ?? '<${result.omittedReason ?? l10n.protocolStudyNotCaptured}>'}'
                          '${result.truncated ? '\n<${l10n.protocolStudyTruncated}>' : ''}';
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
      // Successful earlier steps are already visible in-memory; persist them
      // even if a later workflow step cannot be reproduced.
      if (results.isNotEmpty) await _persistExchanges();
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
    final replay = exchange.replayObservation;
    final replayHeaders =
        replay?.responseHeaders
            .map((field) => '${field.name}: ${field.value}')
            .join('\n') ??
        '';
    final replayIssues = replay?.fidelityIssues.join('\n') ?? '';
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
              '${l10n.protocolStudyResponseBody}\n${exchange.responseBody?.text ?? '<${l10n.protocolStudyNotCaptured}: ${exchange.responseBody?.omittedReason ?? 'unknown'}>'}'
              '${replay == null ? '' : '\n\n${l10n.protocolStudyReplayResponse}\n${l10n.protocolStudyReplayedAt}: ${replay.replayedAt.toLocal()}\n${l10n.protocolStudyStatus}: ${replay.statusCode}\n${l10n.protocolStudyFinalUrl}: ${replay.finalUrl}\n${l10n.protocolStudyReplayUsedSession}: ${replay.usedSessionCookies ? l10n.yes : l10n.no}\n\n${l10n.protocolStudyResponseHeaders}\n$replayHeaders\n\n${l10n.protocolStudyResponseBody}\n${replay.responseBody.text ?? '<${replay.responseBody.omittedReason ?? l10n.protocolStudyNotCaptured}>'}${replay.responseBody.truncated ? '\n<${l10n.protocolStudyTruncated}>' : ''}${replayIssues.isEmpty ? '' : '\n\n${l10n.protocolStudyFidelityWarning}\n$replayIssues'}'}',
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
                            ButtonSegment(
                              value: _NetworkFilter.page,
                              label: Text(l10n.protocolStudyPageSnapshot),
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
                          final replaying = _runningExchangeIds.contains(
                            exchange.id,
                          );
                          return CheckboxListTile(
                            value: exchange.selected,
                            onChanged: (value) => widget.controller.setSelected(
                              exchange.id,
                              value ?? false,
                            ),
                            secondary: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: _running || replaying
                                      ? null
                                      : () => _runOne(exchange),
                                  icon: replaying
                                      ? const SizedBox.square(
                                          dimension: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Icon(
                                          exchange.replayObservation == null
                                              ? Icons.replay_outlined
                                              : Icons.replay_circle_filled,
                                        ),
                                  tooltip: l10n.protocolStudyReplay,
                                ),
                                IconButton(
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
                              ],
                            ),
                            title: Text(
                              '${exchange.method}  ${exchange.status ?? '…'}  ${uri?.host ?? exchange.url}',
                            ),
                            subtitle: Text(
                              '${exchange.source.name}  ${uri?.path ?? ''}'
                              '${exchange.replayObservation != null ? '  • ${l10n.protocolStudyReplayResponse}' : ''}'
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
