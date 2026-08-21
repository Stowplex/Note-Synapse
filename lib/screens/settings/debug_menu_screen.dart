import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_provider.dart';
import '../../services/database_service.dart';
import '../../services/service_locator.dart';
import '../../services/sync/debug_loopback_backend.dart';
import '../../services/sync/sync_session.dart';

class DebugMenuScreen extends StatefulWidget {
  const DebugMenuScreen({super.key});

  @override
  State<DebugMenuScreen> createState() => _DebugMenuScreenState();
}

class _DebugMenuScreenState extends State<DebugMenuScreen> {
  // Held for the lifetime of this screen instance (not persisted anywhere
  // else) so a second tap demonstrates the loop is idempotent (drain/pull/
  // push all report zero new work) against the SAME in-memory log, rather
  // than trivially starting fresh every time — see
  // `debug_loopback_backend.dart`'s own top doc comment.
  final DebugLoopbackSyncBackend _debugSyncBackend = DebugLoopbackSyncBackend();
  bool _syncing = false;

  Future<void> _triggerSync() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _syncing = true);
    try {
      final result = await SyncSession(getIt<DatabaseService>()).run(_debugSyncBackend);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.triggerSyncResult(
              result.drain.touchesProcessed,
              result.seed.operationsSeeded,
              result.pull.commitsApplied,
              result.totalPublished,
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.triggerSyncError('$e'))),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.debugMenu)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.refresh),
              title: Text(l10n.resetOnboardingTitle),
              onTap: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(l10n.resetOnboardingTitle),
                    content: Text(l10n.resetOnboarding),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(l10n.cancel),
                      ),
                      TextButton(
                        onPressed: () async {
                          await context
                              .read<AppProvider>()
                              .setOnboardingCompleted(false);
                          if (context.mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(l10n.resetOnboardingSuccess),
                              ),
                            );
                          }
                        },
                        child: Text(l10n.reset),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: _syncing
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              title: Text(l10n.triggerSyncTitle),
              subtitle: Text(l10n.triggerSyncSubtitle),
              onTap: _syncing ? null : _triggerSync,
            ),
          ),
        ],
      ),
    );
  }
}
