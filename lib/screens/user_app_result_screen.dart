import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/user_app.dart';
import 'user_app_view_screen.dart';

class UserAppResultScreen extends StatelessWidget {
  final UserApp? app;
  final bool isSuccess;
  final String? errorMessage;

  const UserAppResultScreen({
    super.key,
    this.app,
    required this.isSuccess,
    this.errorMessage,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(isSuccess ? l10n.appCreated : l10n.appCantCreate),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icon
              Icon(
                isSuccess ? Icons.check_circle : Icons.error,
                size: 80,
                color: isSuccess ? Colors.green : Colors.red,
              ),
              const SizedBox(height: 24),
              
              // Title
              Text(
                isSuccess ? l10n.appCreated : l10n.appCantCreate,
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              
              // Content
              if (isSuccess && app != null) ...[
                Text(
                  '${l10n.appCreatedSuccessfully} "${app!.name}"',
                  style: Theme.of(context).textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                
                // Action Buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton(
                      onPressed: () {
                        Navigator.pop(context);
                      },
                      child: Text(l10n.close),
                    ),
                    const SizedBox(width: 16),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (context) => UserAppViewScreen(app: app!, selectedNotes: null),
                          ),
                        );
                      },
                      child: Text(l10n.toApp),
                    ),
                  ],
                ),
              ] else ...[
                // Error message
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        Text(
                          l10n.reason,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onErrorContainer,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          errorMessage ?? 'Unknown error occurred',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onErrorContainer,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Please check your API key and try again.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onErrorContainer,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                
                // Action Buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton(
                      onPressed: () {
                        Navigator.pop(context);
                      },
                      child: Text(l10n.close),
                    ),
                    const SizedBox(width: 16),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        Navigator.pop(context);
                      },
                      child: Text(l10n.createNewApp),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
