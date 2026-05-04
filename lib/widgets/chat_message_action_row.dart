import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

class ChatMessageActionRow extends StatelessWidget {
  const ChatMessageActionRow({
    super.key,
    this.onCopy,
    this.onAddNote,
    this.leading,
  });

  final VoidCallback? onCopy;
  final VoidCallback? onAddNote;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      children: [
        if (leading != null) ...[leading!, const Spacer()] else const Spacer(),
        OutlinedButton.icon(
          onPressed: onCopy,
          icon: const Icon(Icons.copy, size: 16),
          label: Text(l10n?.copy ?? 'Copy'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: onAddNote,
          icon: const Icon(Icons.note_add, size: 16),
          label: Text(l10n?.addToNote ?? 'Add to note'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }
}
