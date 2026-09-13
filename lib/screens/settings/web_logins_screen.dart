import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/user_app.dart';
import '../../services/app_domain_grant_service.dart';
import '../../services/database_service.dart';
import '../../services/logger_service.dart';
import '../../services/protocol_study/protocol_study_workspace.dart';
import '../../services/service_locator.dart';
import '../../services/web_session_service.dart';
import '../../utils/user_app_localization.dart';
import 'protocol_studies_screen.dart';
import 'protocol_study_browser_screen.dart';
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
  AppDomainGrantService get _grants => getIt<AppDomainGrantService>();
  DatabaseService get _db => getIt<DatabaseService>();

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
    final grantedApps = await Future.wait(domains.map(_loadGrantedApps));
    return [
      for (var i = 0; i < domains.length; i++)
        _WebLoginEntry(
          domain: domains[i],
          session: sessions[i],
          apps: grantedApps[i],
        ),
    ];
  }

  /// Resolves the apps granted access to [domain] into displayable entries,
  /// skipping grants whose app no longer exists.
  Future<List<_GrantedApp>> _loadGrantedApps(String domain) async {
    final appUuids = await _grants.appsForDomain(domain);
    // The per-uuid lookups are independent — resolve them together.
    final apps = await Future.wait(appUuids.map(_db.getUserAppByUuid));
    return [
      for (var i = 0; i < appUuids.length; i++)
        _GrantedApp(uuid: appUuids[i], app: apps[i]),
    ];
  }

  Future<void> _revokeApp(String domain, _GrantedApp app) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.revokeAppAccessTitle),
        content: Text(l10n.revokeAppAccessConfirm(app.name(context), domain)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.revoke),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _grants.revoke(app.uuid, domain);
      if (!mounted) return;
      _refresh();
    }
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

  Future<void> _openProtocolStudies() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProtocolStudiesScreen(webSessions: _service),
      ),
    );
  }

  Future<void> _studyWithLogin(_WebLoginEntry entry) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProtocolStudyBrowserScreen(
          workspace: ProtocolStudyWorkspace(),
          webSessions: _service,
          initialUrl: entry.session?.savedUrl ?? 'https://${entry.domain}',
          savedLoginDomain: entry.domain,
        ),
      ),
    );
  }

  /// Re-authenticates an existing login in place. Unlike delete-then-add, the
  /// domain's app grants survive, because the session key is simply overwritten.
  Future<void> _refreshLogin(_WebLoginEntry entry) async {
    final savedUrl = entry.session?.savedUrl;
    final refreshed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WebLoginBrowserScreen(
          initialUrl: (savedUrl == null || savedUrl.isEmpty)
              ? 'https://${entry.domain}'
              : savedUrl,
          refreshDomain: entry.domain,
        ),
      ),
    );
    if (refreshed == true) {
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
      try {
        await _service.deleteSession(domain);
      } catch (e) {
        // The delete is aborted rather than half-applied (see
        // WebSessionService.deleteSession), so the login is still here and
        // still revokable. Tell the user instead of failing silently.
        LoggerService.warning('Failed to delete login for $domain: $e');
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.deleteLoginFailed)));
        // Grants are revoked before the session is removed, so a failure part
        // way through leaves the row showing stale "Apps with access" entries.
        _refresh();
        return;
      }
      if (!mounted) return;
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

  /// The line under the domain: when it was captured, when it last rolled
  /// forward on its own, and how much life the cookies claim to have left.
  String _statusLine(AppLocalizations l10n, _WebLoginEntry entry) {
    final savedAt = entry.savedAt;
    final parts = <String>[
      if (savedAt != null) l10n.webLoginSavedAgo(_formatSavedAt(savedAt)),
    ];
    final refreshedAt = entry.session?.refreshedAt;
    if (refreshedAt != null) {
      parts.add(l10n.webLoginRefreshedAgo(_formatSavedAt(refreshedAt)));
    }
    return parts.join(' · ');
  }

  /// Expiry state, or `null` when there is nothing worth saying. The date shown
  /// is the furthest-out cookie expiry (see [WebSession.lastExpiry]).
  ({String text, bool isWarning})? _expiryStatus(
    AppLocalizations l10n,
    _WebLoginEntry entry,
  ) {
    final session = entry.session;
    if (session == null || session.cookies.isEmpty) {
      return null;
    }
    if (session.isFullyExpired) {
      return (text: l10n.webLoginExpired, isWarning: true);
    }
    final expiry = session.lastExpiry;
    if (expiry == null) {
      return (text: l10n.webLoginNoExpiry, isWarning: false);
    }
    final days = expiry.difference(DateTime.now()).inDays;
    if (days < 3) {
      return (text: l10n.webLoginExpiresInDays(days), isWarning: true);
    }
    return (
      text: l10n.webLoginValidUntil(
        '${expiry.year}-${expiry.month.toString().padLeft(2, '0')}-${expiry.day.toString().padLeft(2, '0')}',
      ),
      isWarning: false,
    );
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
              Card(
                child: ListTile(
                  leading: const Icon(Icons.schema_outlined),
                  title: Text(l10n.protocolStudies),
                  subtitle: Text(l10n.protocolStudiesSubtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openProtocolStudies,
                ),
              ),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.cookie_outlined),
                        title: Text(entry.domain),
                        isThreeLine: _expiryStatus(l10n, entry) != null,
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_statusLine(l10n, entry)),
                            ?_buildExpiryLine(context, l10n, entry),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.refresh),
                              tooltip: l10n.refreshLogin,
                              onPressed: () => _refreshLogin(entry),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: l10n.deleteLogin,
                              onPressed: () => _deleteLogin(entry.domain),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: OutlinedButton.icon(
                          onPressed: () => _studyWithLogin(entry),
                          icon: const Icon(Icons.network_check),
                          label: Text(l10n.studyWithLogin),
                        ),
                      ),
                      if (entry.apps.isNotEmpty) ...[
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Text(
                            l10n.webLoginAppsWithAccess,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ),
                        ...entry.apps.map(
                          (app) => ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.extension_outlined,
                              size: 20,
                            ),
                            title: Text(app.name(context)),
                            trailing: TextButton(
                              onPressed: () => _revokeApp(entry.domain, app),
                              child: Text(l10n.revoke),
                            ),
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

  Widget? _buildExpiryLine(
    BuildContext context,
    AppLocalizations l10n,
    _WebLoginEntry entry,
  ) {
    final status = _expiryStatus(l10n, entry);
    if (status == null) {
      return null;
    }
    final scheme = Theme.of(context).colorScheme;
    return Text(
      status.text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: status.isWarning ? scheme.error : null,
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
  const _WebLoginEntry({
    required this.domain,
    required this.session,
    this.apps = const [],
  });

  final String domain;
  final WebSession? session;
  final List<_GrantedApp> apps;

  DateTime? get savedAt => session?.savedAt;
}

class _GrantedApp {
  const _GrantedApp({required this.uuid, required this.app});

  final String uuid;
  final UserApp? app;

  String name(BuildContext context) => app?.displayName(context) ?? uuid;
}
