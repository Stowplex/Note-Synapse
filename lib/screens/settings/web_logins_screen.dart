import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/service_locator.dart';
import '../../services/web_session_service.dart';
import 'web_login_browser_screen.dart';

/// Lists saved web logins (one per registrable domain) and lets the user add a
/// new login via an in-app browser or delete an existing one.
class WebLoginsScreen extends StatefulWidget {
  const WebLoginsScreen({super.key});

  @override
  State<WebLoginsScreen> createState() => _WebLoginsScreenState();
}

class _WebLoginsScreenState extends State<WebLoginsScreen> {
  WebSessionService get _service => getIt<WebSessionService>();

  late Future<List<_WebLoginEntry>> _entriesFuture;

  @override
  void initState() {
    super.initState();
    _entriesFuture = _loadEntries();
  }

  Future<List<_WebLoginEntry>> _loadEntries() async {
    final domains = await _service.listDomains();
    // The per-domain reads are independent, so issue them together.
    final sessions = await Future.wait(domains.map(_service.getSession));
    return [
      for (var i = 0; i < domains.length; i++)
        _WebLoginEntry(domain: domains[i], savedAt: sessions[i]?.savedAt),
    ];
  }

  void _refresh() {
    setState(() {
      _entriesFuture = _loadEntries();
    });
  }

  Future<void> _addLogin() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const WebLoginBrowserScreen()),
    );
    if (added == true) {
      _refresh();
    }
  }

  Future<void> _deleteLogin(String domain) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteLogin),
        content: Text(l10n.deleteLoginConfirm(domain)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _service.deleteSession(domain);
      _refresh();
    }
  }

  String _formatSavedAt(DateTime? savedAt) {
    if (savedAt == null) {
      return '';
    }
    final now = DateTime.now();
    final diff = now.difference(savedAt);
    if (diff.inMinutes < 1) {
      return 'just now';
    }
    if (diff.inHours < 1) {
      return '${diff.inMinutes}m ago';
    }
    if (diff.inDays < 1) {
      return '${diff.inHours}h ago';
    }
    if (diff.inDays < 30) {
      return '${diff.inDays}d ago';
    }
    return '${savedAt.year}-${savedAt.month.toString().padLeft(2, '0')}-${savedAt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.webLogins)),
      floatingActionButton: _service.isSupported
          ? FloatingActionButton.extended(
              onPressed: _addLogin,
              icon: const Icon(Icons.add),
              label: Text(l10n.addWebLogin),
            )
          : null,
      body: FutureBuilder<List<_WebLoginEntry>>(
        future: _entriesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snapshot.data ?? const [];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!_service.isSupported)
                _buildNotice(
                  context,
                  icon: Icons.block,
                  text: l10n.webLoginCaptureFailed,
                )
              else if (_service.isStorageInsecure)
                _buildNotice(
                  context,
                  icon: Icons.warning_amber,
                  text: l10n.webLoginSecurityNote,
                ),
              if (entries.isEmpty && _service.isSupported)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: Center(
                    child: Text(
                      l10n.webLoginsEmpty,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                ),
              ...entries.map(
                (entry) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.cookie_outlined),
                    title: Text(entry.domain),
                    subtitle: Text(_formatSavedAt(entry.savedAt)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: l10n.deleteLogin,
                      onPressed: () => _deleteLogin(entry.domain),
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

  Widget _buildNotice(
    BuildContext context, {
    required IconData icon,
    required String text,
  }) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}

class _WebLoginEntry {
  const _WebLoginEntry({required this.domain, required this.savedAt});

  final String domain;
  final DateTime? savedAt;
}
