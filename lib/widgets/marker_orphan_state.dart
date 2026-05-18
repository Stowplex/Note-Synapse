import 'package:flutter/material.dart';

/// Why a marker can no longer be opened in the chat panel.
///
/// - [anchorDeleted]: the message the marker was anchored to was removed
///   (so we can't even fall back to the original conversation meaningfully).
/// - [conversationDeleted]: the original conversation no longer exists, and
///   no [InNoteMarker.lastViewedConversationId] points at a live one either.
enum OrphanReason { anchorDeleted, conversationDeleted }

/// Friendly empty state shown inside the marker bottom sheet when the
/// marker's anchor or conversation has been deleted out from under it.
///
/// Offers the user a single way out: tap "Delete marker" to remove the
/// dangling marker from the note/attachment so it stops cluttering the UI.
class MarkerOrphanState extends StatelessWidget {
  final OrphanReason reason;
  final VoidCallback onDeleteMarker;

  const MarkerOrphanState({
    super.key,
    required this.reason,
    required this.onDeleteMarker,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              reason == OrphanReason.anchorDeleted
                  ? 'This exploration was deleted (anchor message no longer exists).'
                  : 'This exploration was deleted (conversation no longer exists).',
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onDeleteMarker,
            child: const Text('Delete marker'),
          ),
        ],
      ),
    );
  }
}
