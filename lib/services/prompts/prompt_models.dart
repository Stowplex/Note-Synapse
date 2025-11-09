import 'package:file_picker/file_picker.dart';

/// Roles supported in prompt orchestration layers.
enum PromptRole {
  system,
  user,
  assistant,
  tool,
}

extension PromptRoleName on PromptRole {
  String get apiName {
    switch (this) {
      case PromptRole.system:
        return 'system';
      case PromptRole.user:
        return 'user';
      case PromptRole.assistant:
        return 'assistant';
      case PromptRole.tool:
        return 'tool';
    }
  }
}

/// Message representation shared between application-facing prompt builders
/// and model adapters.
class PromptMessage {
  final PromptRole role;
  final String content;
  final List<PlatformFile> attachments;
  final Map<String, dynamic>? metadata;
  final bool isContext;

  const PromptMessage({
    required this.role,
    required this.content,
    this.attachments = const [],
    this.metadata,
    this.isContext = false,
  });

  PromptMessage copyWith({
    PromptRole? role,
    String? content,
    List<PlatformFile>? attachments,
    Map<String, dynamic>? metadata,
    bool? isContext,
  }) {
    return PromptMessage(
      role: role ?? this.role,
      content: content ?? this.content,
      attachments: attachments ?? this.attachments,
      metadata: metadata ?? this.metadata,
      isContext: isContext ?? this.isContext,
    );
  }
}

/// High-level request that separates immutable system context and conversation
/// history.
class PromptRequest {
  final PromptMessage systemMessage;
  final List<PromptMessage> contextMessages;
  final List<PromptMessage> conversationMessages;
  final Map<String, dynamic>? metadata;

  PromptRequest({
    required this.systemMessage,
    List<PromptMessage>? contextMessages,
    List<PromptMessage>? conversationMessages,
    this.metadata,
  })  : contextMessages = List.unmodifiable(contextMessages ?? const []),
        conversationMessages =
            List.unmodifiable(conversationMessages ?? const []);

  /// Convenience constructor for single-turn prompts (system + user message).
  factory PromptRequest.singleTurn({
    required PromptMessage systemMessage,
    required PromptMessage userMessage,
    Map<String, dynamic>? metadata,
  }) {
    return PromptRequest(
      systemMessage: systemMessage,
      conversationMessages: [userMessage],
      metadata: metadata,
    );
  }

  List<PromptMessage> buildFullMessageList() {
    return [
      systemMessage,
      ...contextMessages,
      ...conversationMessages,
    ];
  }

  PromptRequest appendConversation(PromptMessage message) {
    return PromptRequest(
      systemMessage: systemMessage,
      contextMessages: contextMessages,
      conversationMessages: [
        ...conversationMessages,
        message,
      ],
      metadata: metadata,
    );
  }

  PromptRequest replaceContext(List<PromptMessage> messages) {
    return PromptRequest(
      systemMessage: systemMessage,
      contextMessages: messages,
      conversationMessages: conversationMessages,
      metadata: metadata,
    );
  }

  PromptRequest replaceConversation(List<PromptMessage> messages) {
    return PromptRequest(
      systemMessage: systemMessage,
      contextMessages: contextMessages,
      conversationMessages: messages,
      metadata: metadata,
    );
  }
}

