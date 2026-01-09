/// Represents a single part in a multi-part AI response.
///
/// Used when `response_type: 'multi_part'` is specified in SynapseAPI calls.
/// Each part is either text content or an image with base64 data URL.
class AiResponsePart {
  /// The type of this response part: 'text' or 'image'.
  final String type;

  /// The content of this part.
  /// For 'text' type: the text content itself.
  /// For 'image' type: a base64 data URL (e.g., 'data:image/png;base64,...').
  final String content;

  const AiResponsePart({required this.type, required this.content});

  /// Creates a text response part.
  factory AiResponsePart.text(String content) =>
      AiResponsePart(type: 'text', content: content);

  /// Creates an image response part from a base64 data URL.
  factory AiResponsePart.image(String base64DataUrl) =>
      AiResponsePart(type: 'image', content: base64DataUrl);

  /// Creates an image response part from raw base64 data and mime type.
  factory AiResponsePart.imageFromBase64(String mimeType, String base64Data) =>
      AiResponsePart(
        type: 'image',
        content: 'data:$mimeType;base64,$base64Data',
      );

  /// Converts this part to a JSON map for serialization.
  Map<String, dynamic> toJson() => {'type': type, 'content': content};

  /// Creates a response part from a JSON map.
  factory AiResponsePart.fromJson(Map<String, dynamic> json) {
    return AiResponsePart(
      type: json['type'] as String,
      content: json['content'] as String,
    );
  }

  /// Whether this part is a text part.
  bool get isText => type == 'text';

  /// Whether this part is an image part.
  bool get isImage => type == 'image';

  @override
  String toString() =>
      'AiResponsePart(type: $type, content: ${content.length > 50 ? '${content.substring(0, 50)}...' : content})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiResponsePart &&
          runtimeType == other.runtimeType &&
          type == other.type &&
          content == other.content;

  @override
  int get hashCode => type.hashCode ^ content.hashCode;
}
