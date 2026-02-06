import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_localizations.dart';
import 'privacy_screen.dart';

class LicenseScreen extends StatelessWidget {
  final bool isOnboarding;

  const LicenseScreen({super.key, this.isOnboarding = false});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.onboardingLicenseTitle)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.stowplexCopyright,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.noWarranty,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Colors.red,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FutureBuilder<String>(
                      future: rootBundle.loadString('assets/LICENSE'),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (snapshot.hasError) {
                          return Text(
                            'Error loading license: ${snapshot.error}',
                          );
                        }
                        return Text(
                          snapshot.data ?? 'No license found',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            if (isOnboarding)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) =>
                              const PrivacyScreen(isOnboarding: true),
                        ),
                      );
                    },
                    child: Text(l10n.onboardingNext),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
