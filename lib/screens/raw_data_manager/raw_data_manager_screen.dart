import 'package:flutter/material.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'file_manager_tab.dart';
import 'database_manager_tab.dart';

class RawDataManagerScreen extends StatefulWidget {
  const RawDataManagerScreen({super.key});

  @override
  State<RawDataManagerScreen> createState() => _RawDataManagerScreenState();
}

class _RawDataManagerScreenState extends State<RawDataManagerScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showWarningDialog();
    });
  }

  Future<void> _showWarningDialog() async {
    final l10n = AppLocalizations.of(context)!;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Colors.orange,
              size: 28,
            ),
            const SizedBox(width: 8),
            Text(l10n.advancedToolTitle),
          ],
        ),
        content: Text(l10n.advancedToolWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.iUnderstand),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.rawDataManagerTitle),
          bottom: TabBar(
            tabs: [
              Tab(icon: const Icon(Icons.folder), text: l10n.fileManagerTab),
              Tab(
                icon: const Icon(Icons.storage),
                text: l10n.databaseManagerTab,
              ),
            ],
          ),
        ),
        body: Column(
          children: [
            Container(
              color: Colors.orange.withOpacity(0.1),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.warningDataInstability,
                      style: TextStyle(
                        color: Colors.orange[800],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Expanded(
              child: TabBarView(
                children: [FileManagerTab(), DatabaseManagerTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
