import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:mime/mime.dart';

import '../models/model_capabilities.dart';
import '../models/model_config.dart';
import '../services/logger_service.dart';
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

/// Normalizes attachments before they are sent to model adapters.
class AttachmentPreprocessor {
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
      );

      if (result.$1 != null) {
        sanitized.add(result.$1!);
      } else if (result.$2 != null) {
        ignored.add(result.$2!);
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

  static Future<(PlatformFile?, UnsupportedAttachmentLogEntry?)>
  _processSingleAttachment(
    PlatformFile file, {
    required Set<String> allowedMimeSet,
    required bool enforceMimeSet,
    required ModelCapabilities? capabilities,
  }) async {
    // Check if it's a URI attachment - bypass filtering
    if (file.path != null &&
        (file.path!.startsWith('http://') ||
            file.path!.startsWith('https://') ||
            file.path!.startsWith('gs://'))) {
      return (file, null);
    }

    final bytes = await _readBytes(file);
    if (bytes == null || bytes.isEmpty) {
      return (
        null,
        _buildIgnoredEntry(
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
        return (null, await reject('svg not convertible to allowed mime'));
      }

      final svgContent = _decodeSvgContent(processedBytes);
      if (svgContent == null) {
        return (null, await reject('svg decode failed'));
      }

      final pngBytes = await SvgRendererService.renderSvgToPng(
        svgContent,
        canvasWidth: 500,
        canvasHeight: 500,
      );

      if (pngBytes == null) {
        return (null, await reject('svg conversion failed'));
      }

      processedBytes = pngBytes;
      currentMime = 'image/png';
      processedName = _replaceExtension(processedName, 'png');
      pathToKeep = null;
    } else if (currentMime == 'image/gif') {
      if (!isMimeAllowed('image/jpeg')) {
        return (null, await reject('gif not supported'));
      }

      final decoded = img.decodeImage(processedBytes);
      if (decoded == null) {
        return (null, await reject('gif decode failed'));
      }

      processedBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 90));
      currentMime = 'image/jpeg';
      processedName = _replaceExtension(processedName, 'jpg');
      pathToKeep = null;
    }

    if (!_isCapabilityAllowed(currentMime, capabilities)) {
      return (null, await reject('capability disabled'));
    }

    if (!isMimeAllowed(currentMime)) {
      return (null, await reject('mime not supported'));
    }

    final sanitized = PlatformFile(
      name: processedName,
      bytes: processedBytes,
      size: processedBytes.length,
      path: pathToKeep,
    );

    return (sanitized, null);
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
}
