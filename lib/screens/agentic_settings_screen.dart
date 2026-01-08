import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

import '../services/agentic_settings_service.dart';

/// Settings screen for configuring agentic mode parameters.
class AgenticSettingsScreen extends StatefulWidget {
  const AgenticSettingsScreen({super.key});

  @override
  State<AgenticSettingsScreen> createState() => _AgenticSettingsScreenState();
}

class _AgenticSettingsScreenState extends State<AgenticSettingsScreen> {
  int _compactionThreshold = AgenticSettingsService.defaultCompactionThreshold;
  int _findingLimit = AgenticSettingsService.defaultFindingLimit;
  int _findingMaxWords = AgenticSettingsService.defaultFindingMaxWords;
  int _maxTurns = AgenticSettingsService.defaultMaxTurns;
  int _turnIncrement = AgenticSettingsService.defaultTurnIncrement;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final compaction = await AgenticSettingsService.getCompactionThreshold();
    final limit = await AgenticSettingsService.getFindingLimit();
    final maxWords = await AgenticSettingsService.getFindingMaxWords();
    final maxTurns = await AgenticSettingsService.getMaxTurns();
    final turnIncrement = await AgenticSettingsService.getTurnIncrement();
    if (!mounted) return;
    setState(() {
      _compactionThreshold = compaction;
      _findingLimit = limit;
      _findingMaxWords = maxWords;
      _maxTurns = maxTurns;
      _turnIncrement = turnIncrement;
      _isLoading = false;
    });
  }

  Future<void> _updateCompactionThreshold(int value) async {
    setState(() => _isSaving = true);
    try {
      await AgenticSettingsService.setCompactionThreshold(value);
      if (!mounted) return;
      setState(() => _compactionThreshold = value);
      _showSnackBar(AppLocalizations.of(context)!.settingsSaved);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _updateFindingLimit(int value) async {
    setState(() => _isSaving = true);
    try {
      await AgenticSettingsService.setFindingLimit(value);
      if (!mounted) return;
      setState(() => _findingLimit = value);
      _showSnackBar(AppLocalizations.of(context)!.settingsSaved);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _updateFindingMaxWords(int value) async {
    setState(() => _isSaving = true);
    try {
      await AgenticSettingsService.setFindingMaxWords(value);
      if (!mounted) return;
      setState(() => _findingMaxWords = value);
      _showSnackBar(AppLocalizations.of(context)!.settingsSaved);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _updateMaxTurns(int value) async {
    setState(() => _isSaving = true);
    try {
      await AgenticSettingsService.setMaxTurns(value);
      if (!mounted) return;
      setState(() => _maxTurns = value);
      _showSnackBar(AppLocalizations.of(context)!.settingsSaved);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _updateTurnIncrement(int value) async {
    setState(() => _isSaving = true);
    try {
      await AgenticSettingsService.setTurnIncrement(value);
      if (!mounted) return;
      setState(() => _turnIncrement = value);
      _showSnackBar(AppLocalizations.of(context)!.settingsSaved);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatTokens(int tokens) {
    if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(0)}k';
    }
    return tokens.toString();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.agenticSettings)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Description card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.account_tree_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              l10n.agenticSettings,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.agenticSettingsSubtitle,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Compaction Threshold
                _buildSettingCard(
                  title: l10n.compactionThreshold,
                  description: l10n.compactionThresholdDescription,
                  value: _compactionThreshold,
                  displayValue: '${_formatTokens(_compactionThreshold)} tokens',
                  min: AgenticSettingsService.minCompactionThreshold.toDouble(),
                  max: AgenticSettingsService.maxCompactionThreshold.toDouble(),
                  divisions: 49, // (500000 - 10000) / 10000
                  onChanged: (v) => setState(
                    () => _compactionThreshold = (v ~/ 10000) * 10000,
                  ),
                  onChangeEnd: (v) =>
                      _updateCompactionThreshold((v ~/ 10000) * 10000),
                ),
                const SizedBox(height: 12),

                // Finding Limit
                _buildSettingCard(
                  title: l10n.findingLimit,
                  description: l10n.findingLimitDescription,
                  value: _findingLimit,
                  displayValue: '$_findingLimit findings',
                  min: AgenticSettingsService.minFindingLimit.toDouble(),
                  max: AgenticSettingsService.maxFindingLimit.toDouble(),
                  divisions:
                      AgenticSettingsService.maxFindingLimit -
                      AgenticSettingsService.minFindingLimit,
                  onChanged: (v) => setState(() => _findingLimit = v.round()),
                  onChangeEnd: (v) => _updateFindingLimit(v.round()),
                ),
                const SizedBox(height: 12),

                // Finding Max Words
                _buildSettingCard(
                  title: l10n.findingMaxWords,
                  description: l10n.findingMaxWordsDescription,
                  value: _findingMaxWords,
                  displayValue: '$_findingMaxWords words',
                  min: AgenticSettingsService.minFindingMaxWords.toDouble(),
                  max: AgenticSettingsService.maxFindingMaxWords.toDouble(),
                  divisions:
                      (AgenticSettingsService.maxFindingMaxWords -
                          AgenticSettingsService.minFindingMaxWords) ~/
                      100,
                  onChanged: (v) =>
                      setState(() => _findingMaxWords = (v ~/ 100) * 100),
                  onChangeEnd: (v) => _updateFindingMaxWords((v ~/ 100) * 100),
                ),
                const SizedBox(height: 12),

                // Max Turns
                _buildSettingCard(
                  title: l10n.maxTurns,
                  description: l10n.maxTurnsDescription,
                  value: _maxTurns,
                  displayValue: l10n.turnsValue(_maxTurns),
                  min: AgenticSettingsService.minMaxTurns.toDouble(),
                  max: AgenticSettingsService.maxMaxTurns.toDouble(),
                  divisions:
                      AgenticSettingsService.maxMaxTurns -
                      AgenticSettingsService.minMaxTurns,
                  onChanged: (v) => setState(() => _maxTurns = v.round()),
                  onChangeEnd: (v) => _updateMaxTurns(v.round()),
                ),
                const SizedBox(height: 12),

                // Turn Increment
                _buildSettingCard(
                  title: l10n.turnIncrement,
                  description: l10n.turnIncrementDescription,
                  value: _turnIncrement,
                  displayValue: '+${l10n.turnsValue(_turnIncrement)}',
                  min: AgenticSettingsService.minTurnIncrement.toDouble(),
                  max: AgenticSettingsService.maxTurnIncrement.toDouble(),
                  divisions: 5, // (30 - 5) / 5
                  onChanged: (v) =>
                      setState(() => _turnIncrement = (v ~/ 5) * 5),
                  onChangeEnd: (v) => _updateTurnIncrement((v ~/ 5) * 5),
                ),
              ],
            ),
    );
  }

  Widget _buildSettingCard({
    required String title,
    required String description,
    required int value,
    required String displayValue,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  displayValue,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Slider(
              value: value.toDouble().clamp(min, max),
              min: min,
              max: max,
              divisions: divisions > 0 ? divisions : 1,
              onChanged: _isSaving ? null : onChanged,
              onChangeEnd: _isSaving ? null : onChangeEnd,
            ),
          ],
        ),
      ),
    );
  }
}
