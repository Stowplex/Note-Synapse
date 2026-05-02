import 'dart:async';

import 'package:flutter/material.dart';
import '../models/conversation.dart';
import '../models/conversation_context.dart';
import '../widgets/fork_context_selection_dialog.dart';
import 'conversation_service.dart';
import 'logger_service.dart';
import 'service_locator.dart';

class ForkService {
  static final ForkService _instance = ForkService._internal();
  factory ForkService() => _instance;
  ForkService._internal();

  final _forkCreatedController = StreamController<String>.broadcast();

  /// Emits the parent message ID of every fork created via this service.
  /// Subscribers (typically ChatPanel widgets) use this to invalidate
  /// their branch-summary caches when a sibling appears.
  Stream<String> get forkCreatedStream => _forkCreatedController.stream;

  /// Forks from a message when the source conversation is already known
  /// (chip taps, chat-screen direct fork, programmatic callers). Skips
  /// the context-selection dialog. Does NOT require BuildContext.
  ///
  /// Returns null **only** when [sourceConversationId] is not present in
  /// the message's available conversation contexts. This is a defensive
  /// check against programming errors (every caller is expected to pass
  /// a sourceConversationId that the message belongs to). Callers should
  /// log + abort gracefully on null rather than ignore it; surfacing a
  /// silent no-op to the user is a UX bug.
  ///
  /// Rethrows on unexpected failure (database, IO, etc.).
  Future<Conversation?> forkFromMessageInContext({
    required String forkFromMessageId,
    required String sourceConversationId,
    required String suggestedTitle,
  }) async {
    try {
      final selection = await _conversationService
          .prepareForkContextSelection(forkFromMessageId);
      ConversationContext? matched;
      for (final ctx in selection.availableContexts) {
        if (ctx.conversationId == sourceConversationId) {
          matched = ctx;
          break;
        }
      }
      if (matched == null) {
        LoggerService.warning(
          'forkFromMessageInContext: source $sourceConversationId does not contain message $forkFromMessageId',
        );
        return null;
      }

      final result = await _conversationService.forkConversationWithContext(
        forkFromMessageId: forkFromMessageId,
        selectedContext: matched,
        newTitle: suggestedTitle,
      );

      _forkCreatedController.add(forkFromMessageId);
      return result;
    } catch (e) {
      LoggerService.error('forkFromMessageInContext failed: $e', error: e);
      rethrow;
    }
  }

  ConversationService get _conversationService => getIt<ConversationService>();

  // Main fork method that handles context selection if needed
  Future<Conversation?> forkFromMessage({
    required BuildContext context,
    required String forkFromMessageId,
    String? suggestedTitle,
  }) async {
    try {
      // Prepare context selection
      final selection = await _conversationService.prepareForkContextSelection(
        forkFromMessageId,
      );

      LoggerService.info(
        'Fork context selection prepared: ${selection.availableContexts.length} contexts found',
      );

      // If no conflicts, use the first (and only) context
      if (!selection.requiresUserSelection) {
        final ctx =
            selection.selectedContext ??
            (selection.availableContexts.isNotEmpty
                ? selection.availableContexts.first
                : null);
        if (ctx == null) {
          return null;
        }
        return await forkFromMessageInContext(
          forkFromMessageId: forkFromMessageId,
          sourceConversationId: ctx.conversationId,
          suggestedTitle: suggestedTitle ?? 'Fork from ${ctx.title}',
        );
      }

      // Show selection dialog for conflicting contexts
      return await _showContextSelectionDialog(
        context: context,
        selection: selection,
        suggestedTitle: suggestedTitle,
      );
    } catch (e) {
      LoggerService.error('Error during fork: $e', error: e);
      _showErrorDialog(context, 'Failed to fork conversation: $e');
      return null;
    }
  }

  // Show context selection dialog
  Future<Conversation?> _showContextSelectionDialog({
    required BuildContext context,
    required ForkContextSelection selection,
    String? suggestedTitle,
  }) async {
    ConversationContext? selectedContext;
    String? customTitle;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ForkContextSelectionDialog(
        selection: selection.copyWith(customTitle: suggestedTitle),
        onConfirm: (context, title) {
          selectedContext = context;
          customTitle = title;
        },
      ),
    );

    if (result == true && selectedContext != null && customTitle != null) {
      return await forkFromMessageInContext(
        forkFromMessageId: selection.forkMessageId,
        sourceConversationId: selectedContext!.conversationId,
        suggestedTitle: customTitle!,
      );
    }

    return null;
  }

  // Show error dialog
  void _showErrorDialog(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // Quick fork method for simple cases (no context conflicts)
  Future<Conversation?> quickFork({
    required String forkFromMessageId,
    required String newTitle,
  }) async {
    try {
      // TODO(perf): forkFromMessageInContext re-runs prepareForkContextSelection
      // internally. Acceptable for v1 (user-driven path, not hot loop). Optimize
      // later if needed by adding an overload that accepts a ConversationContext.
      final selection = await _conversationService
          .prepareForkContextSelection(forkFromMessageId);

      if (selection.availableContexts.isEmpty) {
        throw Exception('No conversations found containing this message');
      }

      if (selection.requiresUserSelection) {
        throw Exception(
          'Context selection required - use forkFromMessage with BuildContext',
        );
      }

      return await forkFromMessageInContext(
        forkFromMessageId: forkFromMessageId,
        sourceConversationId: selection.availableContexts.first.conversationId,
        suggestedTitle: newTitle,
      );
    } catch (e) {
      LoggerService.error('Error during quick fork: $e', error: e);
      return null;
    }
  }
}
