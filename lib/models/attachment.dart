import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Configuration for PDF AI context range
class PdfAiContextConfig {
  /// Mode: 'all', 'window', 'chapters', 'bookmarks'
  final String mode;

  /// For 'window' mode: number of pages (x/2 before, x/2 after current)
  final int? windowSize;

  /// For 'chapters' mode: list of selected chapter titles
  final List<String>? selectedChapters;

  /// For 'bookmarks' mode: list of selected bookmarks (page numbers)
  final List<PdfBookmark>? selectedBookmarks;

  /// For 'bookmarks' mode: window size
  final int? bookmarkWindowSize;

  const PdfAiContextConfig({
    required this.mode,
    this.windowSize,
    this.selectedChapters,
    this.selectedBookmarks,
    this.bookmarkWindowSize,
  });

  factory PdfAiContextConfig.fromJson(Map<String, dynamic> json) {
    return PdfAiContextConfig(
      mode: json['mode'] as String? ?? 'all',
      windowSize: json['windowSize'] as int?,
      selectedChapters: (json['selectedChapters'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      selectedBookmarks: (json['selectedBookmarks'] as List<dynamic>?)
          ?.map((e) => PdfBookmark.fromJson(e as Map<String, dynamic>))
          .toList(),
      bookmarkWindowSize: json['bookmarkWindowSize'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'mode': mode,
      if (windowSize != null) 'windowSize': windowSize,
      if (selectedChapters != null) 'selectedChapters': selectedChapters,
      if (selectedBookmarks != null)
        'selectedBookmarks': selectedBookmarks!.map((e) => e.toJson()).toList(),
      if (bookmarkWindowSize != null) 'bookmarkWindowSize': bookmarkWindowSize,
    };
  }

  /// Returns true if this config limits the PDF content (not 'all' mode)
  bool get hasCustomRange => mode != 'all';
}

/// PDF bookmark entry
class PdfBookmark {
  final String title;
  final int pageNumber;
  final DateTime createdAt;
  final String? annotation;

  const PdfBookmark({
    required this.title,
    required this.pageNumber,
    required this.createdAt,
    this.annotation,
  });

  factory PdfBookmark.fromJson(Map<String, dynamic> json) {
    return PdfBookmark(
      title: json['title'] as String,
      pageNumber: json['page'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String),
      annotation: json['annotation'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'page': pageNumber,
      'createdAt': createdAt.toIso8601String(),
      if (annotation != null) 'annotation': annotation,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PdfBookmark &&
        other.pageNumber == pageNumber &&
        other.title == title;
  }

  @override
  int get hashCode => pageNumber.hashCode ^ title.hashCode;
}

/// Represents an attachment with proper path handling
class Attachment {
  final String id;
  final String noteId;
  final String filePath; // This is always stored as relative path in database
  final String fileName;
  final String fileType;
  final DateTime createdAt;
  final bool isRelativePath; // Always true for new attachments
  final bool includeInAIContext;
  final Map<String, dynamic>? metadata;

  Attachment({
    String? id,
    required this.noteId,
    required this.filePath,
    required this.fileName,
    required this.fileType,
    required this.createdAt,
    this.isRelativePath = true,
    this.includeInAIContext = true,
    this.metadata,
  }) : id = id ?? const Uuid().v4();

  /// Creates an Attachment from database data
  factory Attachment.fromDatabase(Map<String, dynamic> data) {
    Map<String, dynamic>? parsedMetadata;
    final metadataRaw = data['metadata'];
    if (metadataRaw != null &&
        metadataRaw is String &&
        metadataRaw.isNotEmpty) {
      try {
        parsedMetadata = jsonDecode(metadataRaw) as Map<String, dynamic>;
      } catch (_) {
        // Invalid JSON, ignore
      }
    }

    return Attachment(
      id: data['id'] as String,
      noteId: data['noteId'] as String,
      filePath: data['filePath'] as String,
      fileName: data['fileName'] as String,
      fileType: data['fileType'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(data['createdAt'] as int),
      isRelativePath: (data['isRelativePath'] as int) == 1,
      includeInAIContext:
          (data['includeInAIContext'] as int?) !=
          0, // Default to true if null (for backward compatibility during migration)
      metadata: parsedMetadata,
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
      'includeInAIContext': includeInAIContext ? 1 : 0,
      'metadata': metadata != null ? jsonEncode(metadata) : null,
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

  /// Gets the PDF AI context configuration if set
  PdfAiContextConfig? getAiContextConfig() {
    final configData = metadata?['aiContextConfig'];
    if (configData == null) return null;
    if (configData is Map<String, dynamic>) {
      return PdfAiContextConfig.fromJson(configData);
    }
    return null;
  }

  /// Gets the last viewed page number for this PDF
  int? getLastViewedPage() {
    return metadata?['lastViewedPage'] as int?;
  }

  /// Gets the list of PDF bookmarks
  List<PdfBookmark> getBookmarks() {
    final bookmarksData = metadata?['bookmarks'] as List<dynamic>?;
    if (bookmarksData == null) return [];
    return bookmarksData
        .whereType<Map<String, dynamic>>()
        .map((e) => PdfBookmark.fromJson(e))
        .toList();
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
    bool? includeInAIContext,
    Map<String, dynamic>? metadata,
  }) {
    return Attachment(
      id: id ?? this.id,
      noteId: noteId ?? this.noteId,
      filePath: filePath ?? this.filePath,
      fileName: fileName ?? this.fileName,
      fileType: fileType ?? this.fileType,
      createdAt: createdAt ?? this.createdAt,
      isRelativePath: isRelativePath ?? this.isRelativePath,
      includeInAIContext: includeInAIContext ?? this.includeInAIContext,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  String toString() {
    return 'Attachment(id: $id, fileName: $fileName, filePath: $filePath, isRelative: $isRelativePath, includeInAIContext: $includeInAIContext)';
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
