import '../models/chip_action.dart';
import 'conversation_service.dart';
import 'fork_service.dart';
import 'logger_service.dart';
import 'service_locator.dart';

/// Orchestrates the 3-step chip-tap flow:
/// 1. Fork the active conversation from the AI message that owns the chip,
///    using `chip.label` as the new conversation's title.
/// 2. Add `chip.prompt` (NOT `chip.label`) as the new conversation's first
///    user message — the prompt is the substantive instruction; the label
///    was display-only.
/// 3. Invoke the host-provided [onSendUserPrompt] callback to trigger the
///    AI reply. The host runs its own send orchestration (model warnings,
///    agent-conflict guards, etc.) so no guard is bypassed.
///
/// Short-circuits silently with a warning log if the fork returns null
/// (programming-error path: source conversation not in available contexts).
/// Rethrows on unexpected error so callers can surface failures to the user.
class ChipTapHandler {
  Future<void> handle({
    required String parentMessageId,
    required ChipAction chip,
    required String sourceConversationId,
    required Future<void> Function(String conversationId, String prompt)
        onSendUserPrompt,
  }) async {
    final forked = await getIt<ForkService>().forkFromMessageInContext(
      forkFromMessageId: parentMessageId,
      sourceConversationId: sourceConversationId,
      suggestedTitle: chip.label,
    );
    if (forked == null) {
      LoggerService.warning(
        'ChipTapHandler: forkFromMessageInContext returned null for '
        'parent=$parentMessageId source=$sourceConversationId; aborting',
      );
      return;
    }
    await getIt<ConversationService>().addUserMessage(
      conversationId: forked.id,
      content: chip.prompt,
    );
    await onSendUserPrompt(forked.id, chip.prompt);
  }
}
