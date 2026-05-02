import 'package:uuid/uuid.dart';

class NormalizedRect {
  final double x, y, w, h;

  const NormalizedRect({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  factory NormalizedRect.fromJson(Map<String, dynamic> json) => NormalizedRect(
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    w: (json['w'] as num).toDouble(),
    h: (json['h'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};
}

enum MarkerType { ai, annotation }

class InNoteMarker {
  final String id;
  final int index;
  final String conversationId;
  final String messageId;
  final DateTime createdAt;
  final MarkerType type;

  // PDF/image fields
  final int? page;
  final NormalizedRect? normalizedRect; // legacy primary rect
  final List<NormalizedRect>? normalizedRects; // multiple queued rects

  // Text note fields
  final int? charStart;
  final int? charEnd;

  /// The conversation the user was last viewing in this marker's subtree.
  /// Used by the marker re-entry flow to restore the previously-viewed
  /// branch (Kindle resumption semantics). Null for markers that haven't
  /// had their branch switched yet, or for pre-v1 markers.
  final String? lastViewedConversationId;

  const InNoteMarker({
    required this.id,
    required this.index,
    required this.conversationId,
    required this.messageId,
    required this.createdAt,
    this.type = MarkerType.ai,
    this.page,
    this.normalizedRect,
    this.normalizedRects,
    this.charStart,
    this.charEnd,
    this.lastViewedConversationId,
  });

  factory InNoteMarker.forAttachment({
    String? id,
    required int index,
    required int page,
    NormalizedRect? normalizedRect,
    List<NormalizedRect>? normalizedRects,
    required String conversationId,
    required String messageId,
    DateTime? createdAt,
    MarkerType type = MarkerType.ai,
    String? lastViewedConversationId,
  }) => InNoteMarker(
    id: id ?? const Uuid().v4(),
    index: index,
    page: page,
    normalizedRect: normalizedRect,
    normalizedRects: normalizedRects,
    conversationId: conversationId,
    messageId: messageId,
    createdAt: createdAt ?? DateTime.now(),
    type: type,
    lastViewedConversationId: lastViewedConversationId,
  );

  factory InNoteMarker.forNote({
    String? id,
    required int index,
    required int charStart,
    required int charEnd,
    NormalizedRect? normalizedRect,
    List<NormalizedRect>? normalizedRects,
    required String conversationId,
    required String messageId,
    DateTime? createdAt,
    MarkerType type = MarkerType.ai,
    String? lastViewedConversationId,
  }) => InNoteMarker(
    id: id ?? const Uuid().v4(),
    index: index,
    charStart: charStart,
    charEnd: charEnd,
    normalizedRect: normalizedRect,
    normalizedRects: normalizedRects,
    conversationId: conversationId,
    messageId: messageId,
    createdAt: createdAt ?? DateTime.now(),
    type: type,
    lastViewedConversationId: lastViewedConversationId,
  );

  factory InNoteMarker.fromJson(Map<String, dynamic> json) {
    final rectJson = json['normalizedRect'] as Map<String, dynamic>?;
    final rectsJson = json['normalizedRects'] as List<dynamic>?;
    final typeStr = json['type'] as String?;
    return InNoteMarker(
      id: json['id'] as String,
      index: json['index'] as int,
      conversationId: json['conversationId'] as String,
      messageId: json['messageId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      type: typeStr == 'annotation' ? MarkerType.annotation : MarkerType.ai,
      page: json['page'] as int?,
      normalizedRect: rectJson != null
          ? NormalizedRect.fromJson(rectJson)
          : null,
      normalizedRects: rectsJson
          ?.map((e) => NormalizedRect.fromJson(e as Map<String, dynamic>))
          .toList(),
      charStart: json['charStart'] as int?,
      charEnd: json['charEnd'] as int?,
      lastViewedConversationId: json['lastViewedConversationId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'index': index,
    'conversationId': conversationId,
    'messageId': messageId,
    'createdAt': createdAt.toIso8601String(),
    if (type == MarkerType.annotation) 'type': 'annotation',
    if (page != null) 'page': page,
    if (normalizedRect != null) 'normalizedRect': normalizedRect!.toJson(),
    if (normalizedRects != null)
      'normalizedRects': normalizedRects!.map((r) => r.toJson()).toList(),
    if (charStart != null) 'charStart': charStart,
    if (charEnd != null) 'charEnd': charEnd,
    if (lastViewedConversationId != null)
      'lastViewedConversationId': lastViewedConversationId,
  };
}
