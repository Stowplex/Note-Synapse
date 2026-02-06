import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_provider.dart';
import '../model_selection_screen.dart';
import '../../widgets/interactive_checkbox_markdown.dart';

class PrivacyScreen extends StatelessWidget {
  final bool isOnboarding;

  const PrivacyScreen({super.key, this.isOnboarding = false});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.onboardingPrivacyTitle)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: FutureBuilder<String>(
                future: rootBundle.loadString('assets/PRIVACY.md'),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        'Error loading privacy policy: ${snapshot.error}',
                      ),
                    );
                  }
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(16.0),
                    child: InteractiveCheckboxMarkdown(
                      originalContent:
                          snapshot.data ?? 'No privacy policy found',
                    ),
                  );
                },
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
                      // Navigate to Model Selection (which acts as the final onboarding step)
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) =>
                              const ModelSelectionScreen(isOnboarding: true),
                        ),
                      );
                    },
                    child: Text(l10n.onboardingAccept),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
