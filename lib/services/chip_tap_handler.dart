import '../models/chip_action.dart';
import '../models/conversation.dart';
import '../utils/conversation_title_directive.dart';
import 'conversation_service.dart';
import 'fork_service.dart';
import 'logger_service.dart';
import 'service_locator.dart';

/// Orchestrates the 3-step chip-tap flow:
/// 1. Fork the active conversation from the AI message that owns the chip,
///    using the pending fork title so the first AI reply can name the branch.
/// 2. Add `chip.prompt` (NOT `chip.label`) as the new conversation's first
///    user message — the prompt is the substantive instruction; the label
///    was display-only.
/// 3. Return the forked conversation so the caller can switch the visible UI
///    before asking its host to continue generation.
///
/// Short-circuits silently with a warning log if the fork returns null
/// (programming-error path: source conversation not in available contexts).
/// Rethrows on unexpected error so callers can surface failures to the user.
class ChipTapHandler {
  Future<Conversation?> handle({
    required String parentMessageId,
    required ChipAction chip,
    required String sourceConversationId,
  }) async {
    final forked = await getIt<ForkService>().forkFromMessageInContext(
      forkFromMessageId: parentMessageId,
      sourceConversationId: sourceConversationId,
      suggestedTitle: ConversationTitleDirective.pendingTitle,
    );
    if (forked == null) {
      LoggerService.warning(
        'ChipTapHandler: forkFromMessageInContext returned null for '
        'parent=$parentMessageId source=$sourceConversationId; aborting',
      );
      return null;
    }
    await getIt<ConversationService>().addUserMessage(
      conversationId: forked.id,
      content: chip.prompt,
    );
    return forked;
  }
}
