import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Represents an attachment with proper path handling
class Attachment {
  final String id;
  final String noteId;
  final String filePath; // This is always stored as relative path in database
  final String fileName;
  final String fileType;
  final DateTime createdAt;
  final bool isRelativePath; // Always true for new attachments

  const Attachment({
    required this.id,
    required this.noteId,
    required this.filePath,
    required this.fileName,
    required this.fileType,
    required this.createdAt,
    this.isRelativePath = true,
  });

  /// Creates an Attachment from database data
  factory Attachment.fromDatabase(Map<String, dynamic> data) {
    return Attachment(
      id: data['id'] as String,
      noteId: data['noteId'] as String,
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
      'noteId': noteId,
      'filePath': filePath,
      'fileName': fileName,
      'fileType': fileType,
      'isRelativePath': isRelativePath ? 1 : 0,
      'createdAt': createdAt.millisecondsSinceEpoch,
    };
  }

  /// Gets the absolute file path for file operations
  Future<String> getAbsolutePath() async {
    if (isRelativePath) {
      final appDir = await getApplicationDocumentsDirectory();
      return '${appDir.path}/$filePath';
    } else {
      // Legacy absolute path - return as is
      return filePath;
    }
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
  Attachment copyWith({
    String? id,
    String? noteId,
    String? filePath,
    String? fileName,
    String? fileType,
    DateTime? createdAt,
    bool? isRelativePath,
  }) {
    return Attachment(
      id: id ?? this.id,
      noteId: noteId ?? this.noteId,
      filePath: filePath ?? this.filePath,
      fileName: fileName ?? this.fileName,
      fileType: fileType ?? this.fileType,
      createdAt: createdAt ?? this.createdAt,
      isRelativePath: isRelativePath ?? this.isRelativePath,
    );
  }

  @override
  String toString() {
    return 'Attachment(id: $id, fileName: $fileName, filePath: $filePath, isRelative: $isRelativePath)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Attachment &&
        other.id == id &&
        other.noteId == noteId &&
        other.filePath == filePath;
  }

  @override
  int get hashCode {
    return id.hashCode ^ noteId.hashCode ^ filePath.hashCode;
  }
}
