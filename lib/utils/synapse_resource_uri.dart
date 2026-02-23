/// Utility class for parsing and generating synapseresource:// URIs
///
/// This enables in-app navigation to notes, conversations, and attachments
/// via clickable markdown links.
///
/// URI Format:
/// - synapseresource://note/<note_id>
/// - synapseresource://conversation/<conversation_id>
/// - synapseresource://attachment/<attachment_id>
/// - synapseresource://attachment/<attachment_id>?page=5
library;

import 'package:flutter/foundation.dart';

/// The type of resource a SynapseResourceLink points to.
enum SynapseResourceType { note, conversation, attachment }

/// A parsed synapseresource:// link.
class SynapseResourceLink {
  final SynapseResourceType type;
  final String id;
  final Map<String, String> queryParameters;

  const SynapseResourceLink({
    required this.type,
    required this.id,
    this.queryParameters = const {},
  });

  @override
  String toString() =>
      'SynapseResourceLink(type: $type, id: $id, queryParameters: $queryParameters)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SynapseResourceLink &&
          runtimeType == other.runtimeType &&
          type == other.type &&
          id == other.id &&
          mapEquals(queryParameters, other.queryParameters);

  @override
  int get hashCode =>
      type.hashCode ^
      id.hashCode ^
      Object.hashAll(
        queryParameters.entries
            .map((e) => Object.hash(e.key, e.value)),
      );
}

/// Utilities for working with synapseresource:// URIs.
class SynapseResourceUri {
  static const String scheme = 'synapseresource';

  /// Returns true if [uri] is a synapseresource:// URI.
  static bool isSynapseResourceUri(String uri) {
    return uri.toLowerCase().startsWith('$scheme://');
  }

  /// Parses a synapseresource:// URI and returns the link details.
  ///
  /// Returns null if the URI is invalid or uses an unknown resource type.
  static SynapseResourceLink? parse(String uriString) {
    if (!isSynapseResourceUri(uriString)) {
      return null;
    }

    try {
      final uri = Uri.parse(uriString);
      final host = uri.host.toLowerCase();
      final pathSegments =
          uri.pathSegments.where((s) => s.isNotEmpty).toList();

      if (pathSegments.isEmpty) {
        return null;
      }

      final id = pathSegments.first;
      if (id.isEmpty) {
        return null;
      }

      final SynapseResourceType type;
      switch (host) {
        case 'note':
          type = SynapseResourceType.note;
        case 'conversation':
          type = SynapseResourceType.conversation;
        case 'attachment':
          type = SynapseResourceType.attachment;
        default:
          return null;
      }

      return SynapseResourceLink(
        type: type,
        id: id,
        queryParameters: uri.queryParameters,
      );
    } catch (_) {
      return null;
    }
  }

  /// Generates a synapseresource:// URI for a note.
  static String noteUri(String noteId) {
    return '$scheme://note/$noteId';
  }

  /// Generates a synapseresource:// URI for a conversation.
  static String conversationUri(String conversationId) {
    return '$scheme://conversation/$conversationId';
  }

  /// Generates a synapseresource:// URI for an attachment.
  static String attachmentUri(String attachmentId, {int? page}) {
    final base = '$scheme://attachment/$attachmentId';
    if (page != null) {
      return '$base?page=$page';
    }
    return base;
  }
}
