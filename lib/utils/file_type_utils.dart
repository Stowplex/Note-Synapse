import 'dart:io';
import 'dart:typed_data';

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

  /// Get MIME type from file content (magic bytes) when extension is not available
  /// [filePath] - Path to the file to check
  /// Returns MIME type based on file content, or null if unable to detect
  static Future<String?> getMimeTypeFromContent(String filePath) async {
    RandomAccessFile? raf;
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return null;
      }
      
      // Open file for reading with explicit resource management
      raf = await file.open(mode: FileMode.read);
      
      // Read first 512 bytes (enough for magic numbers and text detection)
      final headerBytes = await raf.read(512);
      
      if (headerBytes.isEmpty) {
        return null;
      }
      
      return _detectMimeTypeFromBytes(headerBytes);
    } catch (e) {
      return null;
    } finally {
      // Explicitly close the file handle
      await raf?.close();
    }
  }

  /// Get MIME type from file bytes (magic bytes) when extension is not available
  /// [bytes] - File content bytes
  /// Returns MIME type based on file content, or null if unable to detect
  static String? getMimeTypeFromBytes(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    // Use up to 512 bytes for detection (enough for magic numbers and text detection)
    final headerBytes = bytes.length > 512 ? bytes.take(512).toList() : bytes.toList();
    return _detectMimeTypeFromBytes(headerBytes);
  }

  /// Detect MIME type from magic bytes (file header)
  static String? _detectMimeTypeFromBytes(List<int> headerBytes) {
    if (headerBytes.isEmpty) return null;
    
    // Check common file signatures (magic numbers)
    final header = Uint8List.fromList(headerBytes);
    
    // PDF: %PDF (check first as it's common and detection must be early)
    // Magic bytes: 25 50 44 46 (%PDF)
    if (header.length >= 4 && 
        header[0] == 0x25 && header[1] == 0x50 && header[2] == 0x44 && header[3] == 0x46) {
      return 'application/pdf';
    }
    
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (header.length >= 8 &&
        header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E && header[3] == 0x47 &&
        header[4] == 0x0D && header[5] == 0x0A && header[6] == 0x1A && header[7] == 0x0A) {
      return 'image/png';
    }
    
    // JPEG: FF D8 FF
    if (header.length >= 3 &&
        header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF) {
      return 'image/jpeg';
    }
    
    // GIF: 47 49 46 38 (GIF8)
    if (header.length >= 6 &&
        header[0] == 0x47 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x38) {
      // GIF89a or GIF87a
      if (header[4] == 0x39 && header[5] == 0x61) {
        return 'image/gif'; // GIF89a
      } else if (header[4] == 0x37 && header[5] == 0x61) {
        return 'image/gif'; // GIF87a
      }
    }
    
    // WebP: RIFF...WEBP
    if (header.length >= 12 &&
        header[0] == 0x52 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x46 &&
        header[8] == 0x57 && header[9] == 0x45 && header[10] == 0x42 && header[11] == 0x50) {
      return 'image/webp';
    }
    
    // ZIP/Office docs: 50 4B 03 04 (PK..)
    if (header.length >= 4 &&
        header[0] == 0x50 && header[1] == 0x4B && header[2] == 0x03 && header[3] == 0x04) {
      // Check if it's an Office document
      if (header.length >= 30) {
        // Look for Office document signatures in the ZIP structure
        // DOCX, XLSX, PPTX all start with PK and contain specific files
        // For now, return application/zip - could be enhanced to detect specific Office types
        return 'application/zip';
      }
      return 'application/zip';
    }
    
    // BMP: 42 4D (BM)
    if (header.length >= 2 && header[0] == 0x42 && header[1] == 0x4D) {
      return 'image/bmp';
    }
    
    // MP3: ID3 tag (49 44 33) or MPEG header (FF FB, FF F3, FF F2)
    if (header.length >= 3 && header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33) {
      return 'audio/mpeg'; // ID3 tag
    }
    if (header.length >= 2 && header[0] == 0xFF && (header[1] == 0xFB || header[1] == 0xF3 || header[1] == 0xF2)) {
      return 'audio/mpeg'; // MPEG audio
    }
    
    // WAV: RIFF...WAVE
    if (header.length >= 12 &&
        header[0] == 0x52 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x46 &&
        header[8] == 0x57 && header[9] == 0x41 && header[10] == 0x56 && header[11] == 0x45) {
      return 'audio/wav';
    }
    
    // MP4: ftyp box (00 00 00 ?? 66 74 79 70)
    if (header.length >= 8 &&
        header[4] == 0x66 && header[5] == 0x74 && header[6] == 0x79 && header[7] == 0x70) {
      return 'video/mp4';
    }
    
    // UTF-8 BOM: EF BB BF
    if (header.length >= 3 && header[0] == 0xEF && header[1] == 0xBB && header[2] == 0xBF) {
      return 'text/plain; charset=utf-8';
    }
    
    // UTF-16 BOM: FE FF or FF FE
    if (header.length >= 2 && ((header[0] == 0xFE && header[1] == 0xFF) || (header[0] == 0xFF && header[1] == 0xFE))) {
      return 'text/plain; charset=utf-16';
    }
    
    // Text files: Check if it's likely text (printable ASCII)
    if (header.length >= 1) {
      bool isLikelyText = true;
      for (int i = 0; i < header.length; i++) {
        final byte = header[i];
        // Allow common text characters: printable ASCII (0x20-0x7E), tab (0x09), LF (0x0A), CR (0x0D)
        if (byte != 0x09 && byte != 0x0A && byte != 0x0D && (byte < 0x20 || byte > 0x7E)) {
          // Check for UTF-8 continuation bytes (0x80-0xBF) - might be UTF-8 text
          if (byte >= 0x80 && byte <= 0xBF && i > 0) {
            // Could be UTF-8, continue checking
            continue;
          }
          isLikelyText = false;
          break;
        }
      }
      if (isLikelyText) {
        return 'text/plain';
      }
    }
    
    return null; // Unable to detect
  }

  /// Get MIME type for a file, prioritizing extension if available and valid,
  /// otherwise attempting to detect from file content
  /// [filePath] - Path to the file
  /// [extension] - File extension (optional, will be extracted from filePath if not provided)
  /// Returns MIME type string
  static Future<String> getMimeTypeForFile(String filePath, {String? extension}) async {
    // Get extension from parameter or file path
    final ext = extension ?? getFileExtension(filePath);
    
    // If extension exists and is valid (maps to a known MIME type), trust it
    if (ext.isNotEmpty) {
      final extensionMimeType = getMimeType(ext);
      
      // If extension maps to a known type (not octet-stream), trust the extension
      // This prevents false positives where content might contain magic bytes by coincidence
      if (extensionMimeType != 'application/octet-stream') {
        return extensionMimeType;
      }
      
      // Extension exists but is unrecognized (e.g., random "." in filename or unknown extension)
      // Fall back to content-based detection
      final contentMimeType = await getMimeTypeFromContent(filePath);
      return contentMimeType ?? extensionMimeType; // Use content if detected, otherwise unknown extension
    }
    
    // No extension, use content detection
    final contentMimeType = await getMimeTypeFromContent(filePath);
    return contentMimeType ?? 'application/octet-stream';
  }

  /// Get MIME type for file bytes, prioritizing extension if available and valid,
  /// otherwise attempting to detect from file content
  /// [bytes] - File content bytes
  /// [extension] - File extension (optional)
  /// Returns MIME type string
  static String getMimeTypeForBytes(Uint8List bytes, {String? extension}) {
    // If extension is provided and is valid (maps to a known MIME type), trust it
    if (extension != null && extension.isNotEmpty) {
      final extensionMimeType = getMimeType(extension);
      
      // If extension maps to a known type (not octet-stream), trust the extension
      // This prevents false positives where content might contain magic bytes by coincidence
      if (extensionMimeType != 'application/octet-stream') {
        return extensionMimeType;
      }
      
      // Extension exists but is unrecognized (e.g., random "." in filename or unknown extension)
      // Fall back to content-based detection
      final contentMimeType = getMimeTypeFromBytes(bytes);
      return contentMimeType ?? extensionMimeType; // Use content if detected, otherwise unknown extension
    }
    
    // No extension, use content detection
    final contentMimeType = getMimeTypeFromBytes(bytes);
    return contentMimeType ?? 'application/octet-stream';
  }

  /// Get MIME type for a file extension
  /// If extension is null or empty, returns 'application/octet-stream'
  static String getMimeType(String? extension) {
    if (extension == null || extension.isEmpty) return 'application/octet-stream';

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

  /// Get a preferred file extension (without dot) for a given MIME type
  /// Falls back to 'bin' for unknown or generic types
  static String getExtensionForMime(String mimeType) {
    final type = mimeType.toLowerCase();
    if (type.startsWith('image/jpeg')) return 'jpg';
    if (type.startsWith('image/png')) return 'png';
    if (type.startsWith('image/gif')) return 'gif';
    if (type.startsWith('image/webp')) return 'webp';
    if (type.startsWith('image/bmp')) return 'bmp';
    if (type.startsWith('image/svg+xml')) return 'svg';

    if (type.startsWith('application/pdf')) return 'pdf';
    if (type.startsWith('text/plain')) return 'txt';
    if (type.startsWith('application/msword')) return 'doc';
    if (type.startsWith('application/vnd.openxmlformats-officedocument.wordprocessingml.document')) return 'docx';
    if (type.startsWith('application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')) return 'xlsx';
    if (type.startsWith('application/vnd.openxmlformats-officedocument.presentationml.presentation')) return 'pptx';
    if (type.startsWith('application/rtf')) return 'rtf';
    if (type.startsWith('application/vnd.oasis.opendocument.text')) return 'odt';

    if (type.startsWith('video/mp4')) return 'mp4';
    if (type.startsWith('video/x-msvideo')) return 'avi';
    if (type.startsWith('video/quicktime')) return 'mov';
    if (type.startsWith('video/x-ms-wmv')) return 'wmv';
    if (type.startsWith('video/x-flv')) return 'flv';
    if (type.startsWith('video/webm')) return 'webm';

    if (type.startsWith('audio/mpeg')) return 'mp3';
    if (type.startsWith('audio/wav')) return 'wav';
    if (type.startsWith('audio/aac')) return 'aac';
    if (type.startsWith('audio/mp4')) return 'm4a';
    if (type.startsWith('audio/ogg')) return 'ogg';
    if (type.startsWith('audio/flac')) return 'flac';

    if (type.startsWith('application/zip')) return 'zip';
    if (type.startsWith('application/x-rar')) return 'rar';
    if (type.startsWith('application/x-tar')) return 'tar';
    if (type.startsWith('application/gzip')) return 'gz';

    // Generic binary
    if (type == 'application/octet-stream') return 'bin';

    return 'bin';
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
