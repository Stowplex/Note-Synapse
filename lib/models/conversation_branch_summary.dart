/// One row in the inline branch strip. Identifies a child conversation
/// branched off a particular parent message.
///
/// - [conversationId]: the child branch's conversation.
/// - [title]: the child conversation's auto-extracted title (display).
/// - [forkPointMessageId]: the parent message in `message_parents` —
///   the message that owns the strip when it renders.
/// - [firstChildMessageId]: the new conversation's earliest shared
///   message at this fork point. Used as the scroll target on switch.
/// - [noteIds]: notes attached to the child conversation. Compared
///   against the active conversation's notes by `MessageBranchStrip`
///   to decide whether to show the document-swap confirm dialog.
class ConversationBranchSummary {
  final String conversationId;
  final String title;
  final String forkPointMessageId;
  final String firstChildMessageId;
  final List<String> noteIds;

  const ConversationBranchSummary({
    required this.conversationId,
    required this.title,
    required this.forkPointMessageId,
    required this.firstChildMessageId,
    required this.noteIds,
  });
}
