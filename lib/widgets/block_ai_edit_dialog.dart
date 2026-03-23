import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Callback that takes the user's instruction and returns the AI-transformed content.
typedef AIEditCallback = Future<String> Function(String instruction);

/// Dialog for entering an AI edit instruction for selected block(s).
/// Handles loading state inline — shows a spinner while the AI processes.
/// Returns the transformed content string, or null if cancelled/error.
class BlockAIEditDialog extends StatefulWidget {
  final AIEditCallback onTransform;

  const BlockAIEditDialog({super.key, required this.onTransform});

  /// Shows the dialog and returns the transformed content, or null if cancelled.
  static Future<String?> show(
    BuildContext context, {
    required AIEditCallback onTransform,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => BlockAIEditDialog(onTransform: onTransform),
    );
  }

  @override
  State<BlockAIEditDialog> createState() => _BlockAIEditDialogState();
}

class _BlockAIEditDialogState extends State<BlockAIEditDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _isLoading = false;
  String? _error;

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

  Future<void> _handleSubmit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isLoading) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await widget.onTransform(text);
      if (mounted) {
        Navigator.of(context).pop(result);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
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
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            decoration: InputDecoration(
              hintText: l10n.aiEditPromptHint,
              border: const OutlineInputBorder(),
            ),
            maxLines: 3,
            enabled: !_isLoading,
            onSubmitted: (_) => _handleSubmit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(null),
          child: Text(l10n.cancel),
        ),
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else
          FilledButton(
            onPressed: _handleSubmit,
            child: Text(l10n.send),
          ),
      ],
    );
  }
}
