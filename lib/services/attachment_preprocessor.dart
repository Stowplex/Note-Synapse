import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/model_capabilities.dart';
import '../models/model_config.dart';
import '../models/model_type.dart';
import '../services/logger_service.dart';
import '../services/pdf_thumbnail_service.dart';
import '../services/svg_renderer_service.dart';
import '../utils/file_type_utils.dart';
import 'prompts/prompt_models.dart';

class UnsupportedAttachmentLogEntry {
  const UnsupportedAttachmentLogEntry({
    required this.fileName,
    required this.mimeType,
    required this.previewBase64,
    this.path,
    this.reason,
  });

  final String fileName;
  final String? path;
  final String mimeType;
  final String previewBase64;
  final String? reason;

  Map<String, String?> toJson() => {
    'fileName': fileName,
    'path': path,
    'mime': mimeType,
    'reason': reason,
    'previewBase64': previewBase64,
  };
}

class AttachmentFilterOutcome {
  const AttachmentFilterOutcome({
    required this.attachments,
    required this.ignored,
  });

  final List<PlatformFile> attachments;
  final List<UnsupportedAttachmentLogEntry> ignored;
}

class MessageSanitizationOutcome {
  const MessageSanitizationOutcome({
    required this.messages,
    required this.ignored,
  });

  final List<PromptMessage> messages;
  final List<UnsupportedAttachmentLogEntry> ignored;
}

class AttachmentProcessingOutcome {
  const AttachmentProcessingOutcome({required this.attachments, this.ignored});

  final List<PlatformFile> attachments;
  final UnsupportedAttachmentLogEntry? ignored;
}

/// Normalizes attachments before they are sent to model adapters.
class AttachmentPreprocessor {
  static final PdfThumbnailService _pdfThumbnailService = PdfThumbnailService(
    maxCacheSize: 128,
  );

  /// Detect required capabilities from attachments.
  /// Returns set of capability hints: 'images', 'video', 'documents', 'audio'.
  static Future<Set<String>> detectRequiredCapabilities(
    List<PlatformFile> attachments,
  ) async {
    final caps = <String>{};
    for (final file in attachments) {
      final bytes = await _readBytes(file);
      if (bytes == null) continue;

      final mime = _detectMimeType(file, bytes);

      if (mime.startsWith('image/')) caps.add('images');
      if (mime.startsWith('audio/')) caps.add('audio');
      if (mime.startsWith('video/')) caps.add('video');
      if (mime.startsWith('application/pdf') ||
          mime.startsWith('text/') ||
          mime.contains('document')) {
        caps.add('documents');
      }
    }
    return caps;
  }

  AttachmentPreprocessor._();

  static Future<AttachmentFilterOutcome> sanitizeAttachments(
    List<PlatformFile> attachments, {
    required ModelConfig? config,
  }) async {
    if (attachments.isEmpty) {
      return const AttachmentFilterOutcome(attachments: [], ignored: []);
    }

    final allowedMimeSet = _normalizedMimeSet(
      config?.supportedAttachmentMimeTypes,
    );
    final capabilities = config?.customCapabilitiesObject;
    final enforceMimeSet = allowedMimeSet.isNotEmpty;

    final sanitized = <PlatformFile>[];
    final ignored = <UnsupportedAttachmentLogEntry>[];

    for (final file in attachments) {
      final result = await _processSingleAttachment(
        file,
        allowedMimeSet: allowedMimeSet,
        enforceMimeSet: enforceMimeSet,
        capabilities: capabilities,
        config: config,
      );

      sanitized.addAll(result.attachments);
      if (result.ignored != null) {
        ignored.add(result.ignored!);
      }
    }

    return AttachmentFilterOutcome(attachments: sanitized, ignored: ignored);
  }

  static Future<MessageSanitizationOutcome> sanitizeMessages(
    List<PromptMessage> messages, {
    required ModelConfig? config,
  }) async {
    if (messages.isEmpty) {
      return MessageSanitizationOutcome(messages: messages, ignored: const []);
    }

    final sanitizedMessages = <PromptMessage>[];
    final ignored = <UnsupportedAttachmentLogEntry>[];

    for (final message in messages) {
      if (message.attachments.isEmpty) {
        sanitizedMessages.add(message);
        continue;
      }

      final outcome = await sanitizeAttachments(
        message.attachments,
        config: config,
      );

      sanitizedMessages.add(message.copyWith(attachments: outcome.attachments));
      ignored.addAll(outcome.ignored);
    }

    return MessageSanitizationOutcome(
      messages: sanitizedMessages,
      ignored: ignored,
    );
  }

  static void logIgnoredAttachments(
    List<UnsupportedAttachmentLogEntry> ignored, {
    required String endpoint,
    String? requestId,
  }) {
    if (ignored.isEmpty) return;

    final payload = {
      'ignoredAttachments': ignored.map((entry) => entry.toJson()).toList(),
    };

    LoggerService.logAiConsole(
      endpoint: endpoint,
      requestId: requestId,
      consoleOutput: jsonEncode(payload),
    );
  }

  static Set<String> _normalizedMimeSet(List<String>? mimes) {
    if (mimes == null || mimes.isEmpty) {
      return {};
    }
    return {
      for (final mime in mimes)
        if (mime.trim().isNotEmpty) mime.trim().toLowerCase(),
    };
  }

  static Future<AttachmentProcessingOutcome> _processSingleAttachment(
    PlatformFile file, {
    required Set<String> allowedMimeSet,
    required bool enforceMimeSet,
    required ModelCapabilities? capabilities,
    required ModelConfig? config,
  }) async {
    // Check if it's a URI attachment - bypass filtering
    if (file.path != null &&
        (file.path!.startsWith('http://') ||
            file.path!.startsWith('https://') ||
            file.path!.startsWith('gs://'))) {
      return AttachmentProcessingOutcome(attachments: [file]);
    }

    final bytes = await _readBytes(file);
    if (bytes == null || bytes.isEmpty) {
      return AttachmentProcessingOutcome(
        attachments: const [],
        ignored: _buildIgnoredEntry(
          file,
          mimeType: 'unknown',
          reason: 'unreadable',
          previewBytes: Uint8List(0),
        ),
      );
    }

    final previewBytes = Uint8List.fromList(
      bytes.sublist(0, min(16, bytes.length)),
    );

    final detectedMime = _detectMimeType(file, bytes);
    var currentMime = detectedMime.toLowerCase();
    var processedBytes = bytes;
    var processedName = file.name;
    var pathToKeep = file.path;

    Future<UnsupportedAttachmentLogEntry?> reject(String reason) async {
      return _buildIgnoredEntry(
        file,
        mimeType: currentMime,
        reason: reason,
        previewBytes: previewBytes,
      );
    }

    bool isMimeAllowed(String mime) {
      if (!enforceMimeSet) return true;
      return allowedMimeSet.contains(mime);
    }

    if (currentMime.startsWith('text/x-')) {
      currentMime = 'text/plain';
      processedName = _replaceExtension(processedName, 'txt');
    }

    if (currentMime == 'image/svg+xml') {
      if (!isMimeAllowed('image/png')) {
        return AttachmentProcessingOutcome(
          attachments: const [],
          ignored: await reject('svg not convertible to allowed mime'),
        );
      }

      final svgContent = _decodeSvgContent(processedBytes);
      if (svgContent == null) {
        return AttachmentProcessingOutcome(
          attachments: const [],
          ignored: await reject('svg decode failed'),
        );
      }

      final pngBytes = await SvgRendererService.renderSvgToPng(
        svgContent,
        canvasWidth: 500,
        canvasHeight: 500,
      );

      if (pngBytes == null) {
        return AttachmentProcessingOutcome(
          attachments: const [],
          ignored: await reject('svg conversion failed'),
        );
      }

      processedBytes = pngBytes;
      currentMime = 'image/png';
      processedName = _replaceExtension(processedName, 'png');
      pathToKeep = null;
    } else if (currentMime == 'image/gif') {
      if (!isMimeAllowed('image/jpeg')) {
        return AttachmentProcessingOutcome(
          attachments: const [],
          ignored: await reject('gif not supported'),
        );
      }

      final decoded = img.decodeImage(processedBytes);
      if (decoded == null) {
        return AttachmentProcessingOutcome(
          attachments: const [],
          ignored: await reject('gif decode failed'),
        );
      }

      processedBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 90));
      currentMime = 'image/jpeg';
      processedName = _replaceExtension(processedName, 'jpg');
      pathToKeep = null;
    } else if (_shouldConvertImageForGemma(currentMime, config)) {
      if (!isMimeAllowed('image/png')) {
        return AttachmentProcessingOutcome(
          attachments: const [],
          ignored: await reject('image not convertible to allowed mime'),
        );
      }

      final decoded = img.decodeImage(processedBytes);
      if (decoded == null) {
        return AttachmentProcessingOutcome(
          attachments: const [],
          ignored: await reject('image decode failed'),
        );
      }

      processedBytes = Uint8List.fromList(img.encodePng(decoded));
      currentMime = 'image/png';
      processedName = _replaceExtension(processedName, 'png');
      pathToKeep = null;
    } else if (_shouldRenderPdfForGemma(currentMime, config)) {
      final renderedPages = await _renderPdfForGemma(
        file,
        processedName,
        bytes,
      );
      if (renderedPages == null || renderedPages.isEmpty) {
        return AttachmentProcessingOutcome(
          attachments: const [],
          ignored: await reject('pdf render failed'),
        );
      }
      return AttachmentProcessingOutcome(attachments: renderedPages);
    }

    if (!_isCapabilityAllowed(currentMime, capabilities)) {
      return AttachmentProcessingOutcome(
        attachments: const [],
        ignored: await reject('capability disabled'),
      );
    }

    if (!isMimeAllowed(currentMime)) {
      return AttachmentProcessingOutcome(
        attachments: const [],
        ignored: await reject('mime not supported'),
      );
    }

    final sanitized = PlatformFile(
      name: processedName,
      bytes: processedBytes,
      size: processedBytes.length,
      path: pathToKeep,
    );

    return AttachmentProcessingOutcome(attachments: [sanitized]);
  }

  static bool _isGemmaLocalModel(ModelConfig? config) {
    return config?.type == ModelType.localMnn &&
        config?.modelName == 'gemma4_e2b';
  }

  static bool _shouldConvertImageForGemma(String mime, ModelConfig? config) {
    if (!_isGemmaLocalModel(config) || !mime.startsWith('image/')) {
      return false;
    }
    return mime != 'image/png' && mime != 'image/jpeg';
  }

  static bool _shouldRenderPdfForGemma(String mime, ModelConfig? config) {
    return _isGemmaLocalModel(config) && mime == 'application/pdf';
  }

  static Future<List<PlatformFile>?> _renderPdfForGemma(
    PlatformFile file,
    String processedName,
    Uint8List bytes,
  ) async {
    final pdfPath = await _ensurePdfPath(file, bytes);
    if (pdfPath == null) return null;

    try {
      Pdfrx.getCacheDirectory ??= () async {
        final tempDir = await getTemporaryDirectory();
        return tempDir.path;
      };

      final document = await PdfDocument.openFile(pdfPath);
      try {
        final rendered = <PlatformFile>[];
        final baseName = _stripExtension(processedName);

        for (int page = 0; page < document.pages.length; page++) {
          final pngBytes = await _pdfThumbnailService.renderPage(
            pdfPath: pdfPath,
            page: page,
            width: 1024,
          );
          if (pngBytes == null || pngBytes.isEmpty) {
            return null;
          }

          rendered.add(
            PlatformFile(
              name: '${baseName}_page_${page + 1}.png',
              bytes: pngBytes,
              size: pngBytes.length,
              path: null,
            ),
          );
        }

        return rendered;
      } finally {
        document.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _ensurePdfPath(
    PlatformFile file,
    Uint8List bytes,
  ) async {
    if (file.path != null && file.path!.isNotEmpty) {
      return file.path;
    }

    try {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
        '${tempDir.path}/${DateTime.now().microsecondsSinceEpoch}_${file.name}',
      );
      await tempFile.writeAsBytes(bytes, flush: true);
      return tempFile.path;
    } catch (_) {
      return null;
    }
  }

  static UnsupportedAttachmentLogEntry _buildIgnoredEntry(
    PlatformFile file, {
    required String mimeType,
    required String reason,
    required Uint8List previewBytes,
  }) {
    return UnsupportedAttachmentLogEntry(
      fileName: file.name,
      path: file.path,
      mimeType: mimeType,
      previewBase64: base64Encode(previewBytes),
      reason: reason,
    );
  }

  static bool _isCapabilityAllowed(
    String mime,
    ModelCapabilities? capabilities,
  ) {
    if (capabilities == null) return true;

    if (mime.startsWith('image/')) {
      return capabilities.supportsImages;
    }
    if (mime.startsWith('audio/')) {
      return capabilities.supportsAudio;
    }
    if (mime.startsWith('video/')) {
      return capabilities.supportsVideo;
    }
    if (mime.startsWith('application/pdf') ||
        mime.startsWith('text/') ||
        mime.contains('document')) {
      return capabilities.supportsDocuments;
    }
    return true;
  }

  static String _detectMimeType(PlatformFile file, Uint8List bytes) {
    final headerBytes = bytes.sublist(0, min(32, bytes.length));
    final ext = FileTypeUtils.getFileExtension(file.name);

    String? detectedMime;
    try {
      detectedMime = lookupMimeType(file.name, headerBytes: headerBytes);
    } catch (_) {}

    if (detectedMime == null && file.path != null) {
      try {
        detectedMime = lookupMimeType(file.path!, headerBytes: headerBytes);
      } catch (_) {}
    }

    final resolvedMime =
        detectedMime ??
        FileTypeUtils.getMimeTypeForBytes(
          bytes,
          extension: ext.isEmpty ? null : ext,
        );

    return resolvedMime.toLowerCase();
  }

  static Future<Uint8List?> _readBytes(PlatformFile file) async {
    if (file.bytes != null) {
      return Uint8List.fromList(file.bytes!);
    }
    if (file.path != null) {
      try {
        final rawBytes = await File(file.path!).readAsBytes();
        return Uint8List.fromList(rawBytes);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static String? _decodeSvgContent(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  static String _replaceExtension(String fileName, String newExt) {
    final segments = fileName.split('.');
    if (segments.length <= 1) {
      return '$fileName.$newExt';
    }
    segments.removeLast();
    return '${segments.join('.')}.${newExt}';
  }

  static String _stripExtension(String fileName) {
    final segments = fileName.split('.');
    if (segments.length <= 1) {
      return fileName;
    }
    segments.removeLast();
    return segments.join('.');
  }
}
