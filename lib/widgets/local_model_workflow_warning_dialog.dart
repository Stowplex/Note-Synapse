import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Result of the local model workflow warning dialog.
enum LocalModelWorkflowApproval {
  /// Proceed; show warning again next time.
  proceed,

  /// Proceed and suppress this dialog for the rest of the app session.
  proceedAndSuppress,

  /// Do not run the workflow.
  cancel,
}

/// Dialog shown before a tag workflow runs when the active model has
/// [ModelCapabilities.supportsToolOrchestration] == false.
///
/// Three actions:
/// - Continue: proceed, warn again next time
/// - Continue, Don't Warn This Session: proceed, suppress dialog for session
/// - Cancel: skip this workflow
class LocalModelWorkflowWarningDialog extends StatelessWidget {
  const LocalModelWorkflowWarningDialog({super.key});

  /// Show the dialog and return the user's decision.
  static Future<LocalModelWorkflowApproval?> show(BuildContext context) {
    return showDialog<LocalModelWorkflowApproval>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const LocalModelWorkflowWarningDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      icon: Icon(
        Icons.warning_amber_rounded,
        color: Colors.amber.shade700,
        size: 32,
      ),
      title: Text(l10n.localModelWorkflowWarningTitle),
      content: Text(l10n.localModelWorkflowWarningBody),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, LocalModelWorkflowApproval.cancel),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            LocalModelWorkflowApproval.proceedAndSuppress,
          ),
          child: Text(l10n.localModelWorkflowWarningContinueNoWarn),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.amber.shade700,
            foregroundColor: Colors.white,
          ),
          onPressed: () =>
              Navigator.pop(context, LocalModelWorkflowApproval.proceed),
          child: Text(l10n.toolOrchestrationContinue),
        ),
      ],
    );
  }
}
