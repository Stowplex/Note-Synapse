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

class InNoteMarker {
  final String id;
  final int index;
  final String conversationId;
  final String messageId;
  final DateTime createdAt;

  // PDF/image fields
  final int? page;
  final NormalizedRect? normalizedRect;

  // Text note fields
  final int? charStart;
  final int? charEnd;

  const InNoteMarker({
    required this.id,
    required this.index,
    required this.conversationId,
    required this.messageId,
    required this.createdAt,
    this.page,
    this.normalizedRect,
    this.charStart,
    this.charEnd,
  });

  factory InNoteMarker.forAttachment({
    String? id,
    required int index,
    required int page,
    required NormalizedRect normalizedRect,
    required String conversationId,
    required String messageId,
    DateTime? createdAt,
  }) => InNoteMarker(
    id: id ?? const Uuid().v4(),
    index: index,
    page: page,
    normalizedRect: normalizedRect,
    conversationId: conversationId,
    messageId: messageId,
    createdAt: createdAt ?? DateTime.now(),
  );

  factory InNoteMarker.forNote({
    String? id,
    required int index,
    required int charStart,
    required int charEnd,
    required String conversationId,
    required String messageId,
    DateTime? createdAt,
  }) => InNoteMarker(
    id: id ?? const Uuid().v4(),
    index: index,
    charStart: charStart,
    charEnd: charEnd,
    conversationId: conversationId,
    messageId: messageId,
    createdAt: createdAt ?? DateTime.now(),
  );

  factory InNoteMarker.fromJson(Map<String, dynamic> json) {
    final rectJson = json['normalizedRect'] as Map<String, dynamic>?;
    return InNoteMarker(
      id: json['id'] as String,
      index: json['index'] as int,
      conversationId: json['conversationId'] as String,
      messageId: json['messageId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      page: json['page'] as int?,
      normalizedRect:
          rectJson != null ? NormalizedRect.fromJson(rectJson) : null,
      charStart: json['charStart'] as int?,
      charEnd: json['charEnd'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'index': index,
    'conversationId': conversationId,
    'messageId': messageId,
    'createdAt': createdAt.toIso8601String(),
    if (page != null) 'page': page,
    if (normalizedRect != null) 'normalizedRect': normalizedRect!.toJson(),
    if (charStart != null) 'charStart': charStart,
    if (charEnd != null) 'charEnd': charEnd,
  };
}
