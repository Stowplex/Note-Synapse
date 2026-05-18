import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'install_user_manual_screen.dart';
import 'install_starter_apps_screen.dart';
import 'install_starter_skills_screen.dart';

class GettingStartedScreen extends StatelessWidget {
  const GettingStartedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.gettingStarted)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.book),
              title: Text(l10n.installUserManual),
              subtitle: Text(l10n.installUserManualSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const InstallUserManualScreen(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.apps),
              title: Text(l10n.installStarterApps),
              subtitle: Text(l10n.installStarterAppsSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const InstallStarterAppsScreen(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: Text(l10n.installStarterSkills),
              subtitle: Text(l10n.installStarterSkillsSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const InstallStarterSkillsScreen(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
