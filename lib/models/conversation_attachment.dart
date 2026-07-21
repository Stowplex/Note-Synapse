import 'dart:io';
import '../utils/file_utils.dart';

/// Represents an attachment for conversation messages
class ConversationAttachment {
  final String id;
  final String messageId;
  final String filePath; // This is always stored as relative path in database
  final String fileName;
  final String fileType;
  final DateTime createdAt;
  final bool isRelativePath; // Always true for new attachments

  const ConversationAttachment({
    required this.id,
    required this.messageId,
    required this.filePath,
    required this.fileName,
    required this.fileType,
    required this.createdAt,
    this.isRelativePath = true,
  });

  /// Creates a ConversationAttachment from database data
  factory ConversationAttachment.fromDatabase(Map<String, dynamic> data) {
    return ConversationAttachment(
      id: data['id'] as String,
      messageId: data['messageId'] as String,
      filePath: data['filePath'] as String,
      fileName: data['fileName'] as String,
      fileType: data['fileType'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(data['createdAt'] as int),
      isRelativePath: (data['isRelativePath'] as int) == 1,
    );
  }

  /// Converts to database format
  Map<String, dynamic> toDatabase() {
    return {
      'id': id,
      'messageId': messageId,
      'filePath': filePath,
      'fileName': fileName,
      'fileType': fileType,
      'isRelativePath': isRelativePath ? 1 : 0,
      'createdAt': createdAt.millisecondsSinceEpoch,
    };
  }

  /// Gets the absolute file path for file operations
  Future<String> getAbsolutePath() {
    return FileUtils.getFullFilePath(filePath, isRelativePath);
  }

  /// Checks if the file exists
  Future<bool> exists() async {
    final absolutePath = await getAbsolutePath();
    return File(absolutePath).exists();
  }

  /// Gets the file size in bytes
  Future<int> getFileSize() async {
    final absolutePath = await getAbsolutePath();
    final file = File(absolutePath);
    if (await file.exists()) {
      return await file.length();
    }
    return 0;
  }

  /// Gets the file for reading
  Future<File> getFile() async {
    final absolutePath = await getAbsolutePath();
    return File(absolutePath);
  }

  /// Creates a copy with updated fields
  ConversationAttachment copyWith({
    String? id,
    String? messageId,
    String? filePath,
    String? fileName,
    String? fileType,
    DateTime? createdAt,
    bool? isRelativePath,
  }) {
    return ConversationAttachment(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      filePath: filePath ?? this.filePath,
      fileName: fileName ?? this.fileName,
      fileType: fileType ?? this.fileType,
      createdAt: createdAt ?? this.createdAt,
      isRelativePath: isRelativePath ?? this.isRelativePath,
    );
  }

  @override
  String toString() {
    return 'ConversationAttachment(id: $id, fileName: $fileName, filePath: $filePath, isRelative: $isRelativePath)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ConversationAttachment &&
        other.id == id &&
        other.messageId == messageId &&
        other.filePath == filePath;
  }

  @override
  int get hashCode {
    return id.hashCode ^ messageId.hashCode ^ filePath.hashCode;
  }
}
