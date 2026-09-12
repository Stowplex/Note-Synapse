import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../l10n/app_localizations.dart';
import '../models/user_app.dart';
import '../services/starter_service.dart';
import '../services/logger_service.dart';
import '../utils/user_app_localization.dart';
import 'import_app_screen.dart';

class InstallStarterAppsScreen extends StatefulWidget {
  const InstallStarterAppsScreen({super.key});

  @override
  State<InstallStarterAppsScreen> createState() =>
      _InstallStarterAppsScreenState();
}

class _InstallStarterAppsScreenState extends State<InstallStarterAppsScreen> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _starterApps = [];
  Set<int> _selectedApps = {};
  bool _isInstalling = false;

  @override
  void initState() {
    super.initState();
    _loadStarterApps();
  }

  Future<void> _loadStarterApps() async {
    try {
      setState(() {
        _isLoading = true;
      });

      final apps = await StarterService.getStarterApps();

      setState(() {
        _starterApps = apps;
        _isLoading = false;
      });
    } catch (e) {
      LoggerService.error('Error loading starter apps: $e');
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

  Future<void> _installSelectedApps() async {
    if (_selectedApps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.noAppsSelected),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _isInstalling = true;
    });

    try {
      final l10n = AppLocalizations.of(context)!;
      int successCount = 0;
      int failureCount = 0;
      final List<String> errors = [];

      for (final index in _selectedApps) {
        final app = _starterApps[index];

        try {
          // Copy YAML asset to temporary file
          final tempFile = await _copyAssetToTempFile(app['filePath']);

          // Navigate to import screen and wait for result
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  ImportAppScreen(yamlFilePath: tempFile.path),
            ),
          );

          // Clean up temp file
          await tempFile.delete();

          if (result == true) {
            successCount++;
          } else {
            failureCount++;
            errors.add(app['name']);
          }
        } catch (e) {
          LoggerService.error('Error installing ${app['name']}: $e');
          failureCount++;
          errors.add(app['name']);
        }
      }

      if (mounted) {
        String message;
        Color backgroundColor;

        if (failureCount == 0) {
          message = l10n.starterAppsInstalledSuccessfully(successCount);
          backgroundColor = Colors.green;
        } else if (successCount == 0) {
          message = l10n.starterAppsInstallFailed(failureCount);
          backgroundColor = Colors.red;
        } else {
          message = l10n.starterAppsPartialInstall(successCount, failureCount);
          backgroundColor = Colors.orange;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: backgroundColor),
        );

        // Refresh the list
        _selectedApps.clear();
        await _loadStarterApps();
      }
    } catch (e) {
      LoggerService.error('Error installing starter apps: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(
                context,
              )!.errorInstallingStarterApps(e.toString()),
            ),
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

  Future<File> _copyAssetToTempFile(String assetPath) async {
    final byteData = await rootBundle.load(assetPath);
    final tempDir = await getTemporaryDirectory();
    final fileName = assetPath.split('/').last;
    final tempFile = File('${tempDir.path}/$fileName');

    await tempFile.writeAsBytes(byteData.buffer.asUint8List());

    return tempFile;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.installStarterApps),
        actions: [
          if (_starterApps.isNotEmpty && !_isLoading)
            TextButton(
              onPressed: _selectedApps.isEmpty
                  ? null
                  : () {
                      setState(() {
                        _selectedApps.clear();
                      });
                    },
              child: Text(
                l10n.clearAll,
                style: TextStyle(
                  color: _selectedApps.isEmpty
                      ? Colors.grey
                      : Theme.of(context).primaryColor,
                ),
              ),
            ),
          if (_starterApps.isNotEmpty && !_isLoading)
            TextButton(
              onPressed: () {
                setState(() {
                  if (_selectedApps.length == _starterApps.length) {
                    _selectedApps.clear();
                  } else {
                    _selectedApps = Set.from(
                      List.generate(_starterApps.length, (i) => i),
                    );
                  }
                });
              },
              child: Text(
                _selectedApps.length == _starterApps.length
                    ? l10n.deselectAll
                    : l10n.selectAll,
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _starterApps.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.apps, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 16),
                  Text(
                    l10n.noStarterAppsAvailable,
                    style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _starterApps.length,
                    itemBuilder: (context, index) {
                      final app = _starterApps[index];
                      final isSelected = _selectedApps.contains(index);
                      final isInstalled = app['isInstalled'] as bool;
                      final i18n =
                          app['i18n']
                              as Map<String, UserAppLocalizedMetadata>? ??
                          const {};
                      final metadata = resolveUserAppLocalizedMetadata(
                        i18n,
                        userAppLocaleTag(Localizations.localeOf(context)),
                      );
                      final displayName = metadata?.name ?? app['name'];
                      final displayDescription =
                          metadata?.description ?? app['description'];

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: CheckboxListTile(
                          value: isSelected,
                          onChanged: _isInstalling
                              ? null
                              : (value) {
                                  setState(() {
                                    if (value == true) {
                                      _selectedApps.add(index);
                                    } else {
                                      _selectedApps.remove(index);
                                    }
                                  });
                                },
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  displayName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              if (isInstalled)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.green.shade50,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.green),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.check_circle,
                                        size: 14,
                                        color: Colors.green.shade700,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        l10n.installed,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.green.shade700,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text(
                                '${l10n.type}: ${_getAppTypeDisplayName(app['appType'])}',
                                style: TextStyle(
                                  color: Colors.blue.shade700,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                StarterService.getAppTypeExplanation(
                                  app['appType'],
                                ),
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                displayDescription,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                          ),
                          isThreeLine: true,
                        ),
                      );
                    },
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: const Offset(0, -2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      if (_selectedApps.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            l10n.appsSelected(_selectedApps.length),
                            style: TextStyle(
                              color: Theme.of(context).primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isInstalling || _selectedApps.isEmpty
                              ? null
                              : _installSelectedApps,
                          icon: _isInstalling
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.download),
                          label: Text(
                            _isInstalling
                                ? l10n.installing
                                : l10n.proceedWithInstallation,
                          ),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  String _getAppTypeDisplayName(String appType) {
    final l10n = AppLocalizations.of(context)!;
    switch (appType.toLowerCase()) {
      case 'normal':
        return l10n.appTypeNormal;
      case 'note_action':
        return l10n.appTypeNoteAction;
      case 'ai_tool':
        return l10n.appTypeAiTool;
      default:
        return appType;
    }
  }
}
