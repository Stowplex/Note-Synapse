import 'package:flutter/material.dart';
import '../models/conversation.dart';
import '../models/conversation_context.dart';
import '../widgets/fork_context_selection_dialog.dart';
import 'conversation_service.dart';
import 'logger_service.dart';

class ForkService {
  static final ForkService _instance = ForkService._internal();
  factory ForkService() => _instance;
  ForkService._internal();

  final ConversationService _conversationService = ConversationService();

  // Main fork method that handles context selection if needed
  Future<Conversation?> forkFromMessage({
    required BuildContext context,
    required String forkFromMessageId,
    String? suggestedTitle,
  }) async {
    try {
      // Prepare context selection
      final selection = await _conversationService.prepareForkContextSelection(forkFromMessageId);
      
      LoggerService.info('Fork context selection prepared: ${selection.availableContexts.length} contexts found');
      
      // If no conflicts, use the first (and only) context
      if (!selection.requiresUserSelection) {
        final context = selection.availableContexts.first;
        return await _conversationService.forkConversationWithContext(
          forkFromMessageId: forkFromMessageId,
          selectedContext: context,
          newTitle: suggestedTitle ?? 'Fork from ${context.title}',
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
      return await _conversationService.forkConversationWithContext(
        forkFromMessageId: selection.forkMessageId,
        selectedContext: selectedContext!,
        newTitle: customTitle!,
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
      final selection = await _conversationService.prepareForkContextSelection(forkFromMessageId);
      
      if (selection.availableContexts.isEmpty) {
        throw Exception('No conversations found containing this message');
      }
      
      if (selection.requiresUserSelection) {
        throw Exception('Context selection required - use forkFromMessage with BuildContext');
      }
      
      final context = selection.availableContexts.first;
      return await _conversationService.forkConversationWithContext(
        forkFromMessageId: forkFromMessageId,
        selectedContext: context,
        newTitle: newTitle,
      );
      
    } catch (e) {
      LoggerService.error('Error during quick fork: $e', error: e);
      return null;
    }
  }
}
