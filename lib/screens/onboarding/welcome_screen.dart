import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../l10n/app_localizations.dart';
import 'license_screen.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(
                Icons.auto_awesome,
                size: 80,
                color: Theme.of(context).primaryColor,
              ),
              const SizedBox(height: 24),
              Text(
                l10n.onboardingWelcomeTitle,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                l10n.onboardingWelcomeSubtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              // Language Selector
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Consumer<AppProvider>(
                    builder: (context, appProvider, child) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.language,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ChoiceChip(
                                label: const Text('English'),
                                selected:
                                    appProvider.locale.languageCode == 'en',
                                onSelected: (selected) {
                                  if (selected) {
                                    appProvider.changeLanguage(
                                      const Locale('en', ''),
                                    );
                                  }
                                },
                              ),
                              const SizedBox(width: 12),
                              ChoiceChip(
                                label: const Text('简体中文'),
                                selected:
                                    appProvider.locale.languageCode == 'zh',
                                onSelected: (selected) {
                                  if (selected) {
                                    appProvider.changeLanguage(
                                      const Locale('zh', ''),
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) =>
                            const LicenseScreen(isOnboarding: true),
                      ),
                    );
                  },
                  child: Text(l10n.onboardingStart),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
