/// Utility class for parsing and generating synapseresource:// URIs
///
/// This enables in-app navigation to notes and conversations via clickable
/// markdown links.
///
/// URI Format:
/// - synapseresource://note/<note_id>
/// - synapseresource://conversation/<conversation_id>
library;

/// The type of resource a SynapseResourceLink points to.
enum SynapseResourceType { note, conversation }

/// A parsed synapseresource:// link.
class SynapseResourceLink {
  final SynapseResourceType type;
  final String id;

  const SynapseResourceLink({required this.type, required this.id});

  @override
  String toString() => 'SynapseResourceLink(type: $type, id: $id)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SynapseResourceLink &&
          runtimeType == other.runtimeType &&
          type == other.type &&
          id == other.id;

  @override
  int get hashCode => type.hashCode ^ id.hashCode;
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
      final pathSegments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

      if (pathSegments.isEmpty) {
        return null;
      }

      final id = pathSegments.first;
      if (id.isEmpty) {
        return null;
      }

      switch (host) {
        case 'note':
          return SynapseResourceLink(type: SynapseResourceType.note, id: id);
        case 'conversation':
          return SynapseResourceLink(
            type: SynapseResourceType.conversation,
            id: id,
          );
        default:
          return null;
      }
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
}
