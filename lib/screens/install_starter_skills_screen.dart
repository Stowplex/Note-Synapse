import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/logger_service.dart';
import '../services/starter_service.dart';

class InstallStarterSkillsScreen extends StatefulWidget {
  const InstallStarterSkillsScreen({super.key});

  @override
  State<InstallStarterSkillsScreen> createState() =>
      _InstallStarterSkillsScreenState();
}

class _InstallStarterSkillsScreenState
    extends State<InstallStarterSkillsScreen> {
  bool _isLoading = true;
  bool _isInstalling = false;
  List<Map<String, dynamic>> _skills = const [];
  final Set<String> _selectedRefs = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final skills = await StarterService.getStarterSkills();
      if (!mounted) return;
      setState(() {
        _skills = skills;
        _selectedRefs
          ..clear()
          ..addAll(
            skills
                .where((skill) => skill['isInstalled'] != true)
                .map((skill) => skill['skillRef'] as String),
          );
        _isLoading = false;
      });
    } catch (e) {
      LoggerService.error('Error loading starter skills: $e');
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.errorLoadingStarterSkills(e.toString()))),
      );
    }
  }

  Future<void> _installSelected() async {
    final l10n = AppLocalizations.of(context)!;
    if (_selectedRefs.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.noStarterSkillsSelected)));
      return;
    }
    setState(() => _isInstalling = true);
    try {
      final count = await StarterService.installStarterSkills(
        skillRefs: Set<String>.from(_selectedRefs),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.starterSkillsInstalledSuccessfully(count))),
      );
      await _load();
    } catch (e) {
      LoggerService.error('Error installing starter skills: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.errorInstallingStarterSkills(e.toString())),
        ),
      );
    } finally {
      if (mounted) setState(() => _isInstalling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.installStarterSkills),
        actions: [
          if (_skills.isNotEmpty && !_isLoading)
            TextButton(
              onPressed: _isInstalling
                  ? null
                  : () {
                      setState(() {
                        if (_selectedRefs.length == _skills.length) {
                          _selectedRefs.clear();
                        } else {
                          _selectedRefs
                            ..clear()
                            ..addAll(
                              _skills.map(
                                (skill) => skill['skillRef'] as String,
                              ),
                            );
                        }
                      });
                    },
              child: Text(
                _selectedRefs.length == _skills.length
                    ? l10n.deselectAll
                    : l10n.selectAll,
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _skills.isEmpty
          ? Center(child: Text(l10n.noStarterSkillsAvailable))
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _skills.length,
                    itemBuilder: (context, index) {
                      final skill = _skills[index];
                      final ref = skill['skillRef'] as String;
                      final installed = skill['isInstalled'] == true;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: CheckboxListTile(
                          value: _selectedRefs.contains(ref),
                          onChanged: _isInstalling
                              ? null
                              : (value) {
                                  setState(() {
                                    if (value == true) {
                                      _selectedRefs.add(ref);
                                    } else {
                                      _selectedRefs.remove(ref);
                                    }
                                  });
                                },
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  skill['name'] as String,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              if (installed)
                                Chip(
                                  label: Text(l10n.installed),
                                  avatar: const Icon(
                                    Icons.check_circle,
                                    size: 16,
                                  ),
                                ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text(
                                l10n.skillRefLabel(ref),
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                l10n.sourceLabel(skill['filePath'] as String),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 4),
                              Text(skill['description'] as String),
                            ],
                          ),
                          isThreeLine: true,
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isInstalling || _selectedRefs.isEmpty
                          ? null
                          : _installSelected,
                      icon: _isInstalling
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download),
                      label: Text(
                        _isInstalling
                            ? l10n.installing
                            : l10n.installSelectedSkills,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
