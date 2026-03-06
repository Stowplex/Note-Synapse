import 'dart:convert';

class NoteAnnotation {
  final String id;
  final String? noteId;
  final String? attachmentId;
  final String content;
  final List<String> attachmentPaths;
  final DateTime createdAt;

  const NoteAnnotation({
    required this.id,
    this.noteId,
    this.attachmentId,
    required this.content,
    required this.attachmentPaths,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    if (noteId != null) 'note_id': noteId,
    if (attachmentId != null) 'attachment_id': attachmentId,
    'content': content,
    'attachment_paths': jsonEncode(attachmentPaths),
    'created_at': createdAt.toIso8601String(),
  };

  factory NoteAnnotation.fromMap(Map<String, dynamic> map) {
    final rawPaths = map['attachment_paths'] as String?;
    final paths = rawPaths != null
        ? List<String>.from(jsonDecode(rawPaths) as List)
        : <String>[];
    return NoteAnnotation(
      id: map['id'] as String,
      noteId: map['note_id'] as String?,
      attachmentId: map['attachment_id'] as String?,
      content: map['content'] as String,
      attachmentPaths: paths,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
