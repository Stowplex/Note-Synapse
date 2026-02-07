import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_provider.dart';

class DebugMenuScreen extends StatelessWidget {
  const DebugMenuScreen({super.key});

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
        ],
      ),
    );
  }
}
