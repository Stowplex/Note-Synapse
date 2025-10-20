/// Utility functions for file type classification and MIME type detection
class FileTypeUtils {
  /// Extract file extension from filename, handling files without extensions
  static String getFileExtension(String fileName) {
    final parts = fileName.split('.');
    if (parts.length < 2) {
      return ''; // No extension
    }
    return parts.last.toLowerCase();
  }

  /// Get MIME type for a file extension
  static String getMimeType(String? extension) {
    if (extension == null) return 'application/octet-stream';

    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'bmp':
        return 'image/bmp';
      case 'webp':
        return 'image/webp';
      case 'svg':
        return 'image/svg+xml';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'rtf':
        return 'application/rtf';
      case 'odt':
        return 'application/vnd.oasis.opendocument.text';
      case 'mp4':
        return 'video/mp4';
      case 'avi':
        return 'video/x-msvideo';
      case 'mov':
        return 'video/quicktime';
      case 'wmv':
        return 'video/x-ms-wmv';
      case 'flv':
        return 'video/x-flv';
      case 'webm':
        return 'video/webm';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'aac':
        return 'audio/aac';
      case 'm4a':
        return 'audio/mp4';
      case 'ogg':
        return 'audio/ogg';
      case 'flac':
        return 'audio/flac';
      default:
        return 'application/octet-stream';
    }
  }

  /// Get file category based on extension
  static String getFileCategory(String extension) {
    final ext = extension.toLowerCase();
    
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg'].contains(ext)) {
      return 'image';
    } else if (['pdf', 'txt', 'doc', 'docx', 'rtf', 'odt'].contains(ext)) {
      return 'document';
    } else if (['mp3', 'wav', 'aac', 'm4a', 'ogg', 'flac'].contains(ext)) {
      return 'audio';
    } else if (['mp4', 'avi', 'mov', 'wmv', 'flv', 'webm'].contains(ext)) {
      return 'video';
    } else {
      return 'unknown';
    }
  }

  /// Check if a file extension is an image
  static bool isImage(String extension) {
    return getFileCategory(extension) == 'image';
  }

  /// Check if a file extension is a document
  static bool isDocument(String extension) {
    return getFileCategory(extension) == 'document';
  }

  /// Check if a file extension is audio
  static bool isAudio(String extension) {
    return getFileCategory(extension) == 'audio';
  }

  /// Check if a file extension is video
  static bool isVideo(String extension) {
    return getFileCategory(extension) == 'video';
  }
}
