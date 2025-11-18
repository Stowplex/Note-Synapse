import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/starter_service.dart';
import '../services/logger_service.dart';

class InstallUserManualScreen extends StatefulWidget {
  const InstallUserManualScreen({super.key});

  @override
  State<InstallUserManualScreen> createState() =>
      _InstallUserManualScreenState();
}

class _InstallUserManualScreenState extends State<InstallUserManualScreen> {
  bool _isLoading = true;
  bool _isInstalling = false;
  String? _currentVersion;
  String? _newVersion;
  String? _updateDate;
  bool _isInstalled = false;
  bool _hasUpdate = false;

  @override
  void initState() {
    super.initState();
    _checkUserManual();
  }

  Future<void> _checkUserManual() async {
    try {
      setState(() {
        _isLoading = true;
      });

      // Check if User Manual exists
      final existingNote = await StarterService.getUserManualNote();
      
      // Parse YAML for new version info
      final yamlData = await StarterService.parseUserManualYaml();
      _newVersion = yamlData['version'];
      _updateDate = yamlData['updateDate'];

      if (existingNote != null) {
        _isInstalled = true;
        _currentVersion = StarterService.parseVersionFromNoteContent(
          existingNote.content,
        );

        if (_currentVersion != null && _newVersion != null) {
          _hasUpdate = StarterService.isNewerVersion(
            _newVersion!,
            _currentVersion!,
          );
        }
      } else {
        _isInstalled = false;
      }

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      LoggerService.error('Error checking user manual: $e');
      setState(() {
        _isLoading = false;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.errorLoadingData),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _installOrUpdateUserManual() async {
    final l10n = AppLocalizations.of(context)!;

    // If updating, show confirmation dialog
    if (_hasUpdate) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.updateUserManual),
          content: Text(
            l10n.updateUserManualConfirm(
              _currentVersion ?? 'Unknown',
              _newVersion ?? 'Unknown',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.update),
            ),
          ],
        ),
      );

      if (confirmed != true) return;
    }

    setState(() {
      _isInstalling = true;
    });

    try {
      await StarterService.installUserManual();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isInstalled
                  ? l10n.userManualUpdatedSuccessfully
                  : l10n.userManualInstalledSuccessfully,
            ),
            backgroundColor: Colors.green,
          ),
        );

        // Refresh the state
        await _checkUserManual();
      }
    } catch (e) {
      LoggerService.error('Error installing user manual: $e');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorInstallingUserManual(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isInstalling = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.installUserManual)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.userManualInfo,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 16),
                        _buildInfoRow(
                          l10n.status,
                          _isInstalled
                              ? l10n.installed
                              : l10n.notInstalled,
                          _isInstalled ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(height: 8),
                        if (_isInstalled && _currentVersion != null)
                          _buildInfoRow(
                            l10n.currentVersion,
                            _currentVersion!,
                            Colors.blue,
                          ),
                        const SizedBox(height: 8),
                        _buildInfoRow(
                          l10n.latestVersion,
                          _newVersion ?? 'Unknown',
                          Colors.blue,
                        ),
                        const SizedBox(height: 8),
                        _buildInfoRow(
                          l10n.lastUpdated,
                          _updateDate ?? 'Unknown',
                          Colors.grey,
                        ),
                        if (_hasUpdate) ...[
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.orange),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.update,
                                  color: Colors.orange.shade700,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    l10n.newVersionAvailable,
                                    style: TextStyle(
                                      color: Colors.orange.shade700,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _isInstalling ? null : _installOrUpdateUserManual,
                  icon: _isInstalling
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(_hasUpdate ? Icons.update : Icons.download),
                  label: Text(
                    _isInstalling
                        ? l10n.installing
                        : _hasUpdate
                            ? l10n.updateUserManual
                            : _isInstalled
                                ? l10n.reinstallUserManual
                                : l10n.installUserManual,
                  ),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor:
                        _hasUpdate ? Colors.orange : Theme.of(context).primaryColor,
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.whatIsUserManual,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.userManualDescription,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildInfoRow(String label, String value, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

