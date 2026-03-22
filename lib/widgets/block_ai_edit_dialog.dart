import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Dialog for entering an AI edit instruction for selected block(s).
class BlockAIEditDialog extends StatefulWidget {
  const BlockAIEditDialog({super.key});

  /// Shows the dialog and returns the instruction string, or null if cancelled.
  static Future<String?> show(BuildContext context) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const BlockAIEditDialog(),
    );
  }

  @override
  State<BlockAIEditDialog> createState() => _BlockAIEditDialogState();
}

class _BlockAIEditDialogState extends State<BlockAIEditDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleSubmit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      Navigator.of(context).pop(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.auto_awesome,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(l10n.aiEditPromptTitle),
        ],
      ),
      content: TextField(
        controller: _controller,
        focusNode: _focusNode,
        decoration: InputDecoration(
          hintText: l10n.aiEditPromptHint,
          border: const OutlineInputBorder(),
        ),
        maxLines: 3,
        onSubmitted: (_) => _handleSubmit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _handleSubmit,
          child: Text(l10n.send),
        ),
      ],
    );
  }
}
