import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';

import '../models/model_config.dart';
import '../models/model_type.dart';
import '../utils/file_type_utils.dart';
import '../utils/token_estimator.dart';
import 'model_selector.dart';
import 'service_locator.dart';

class LocalModelAttachmentConstraintWarning {
  const LocalModelAttachmentConstraintWarning({
    required this.messages,
    required this.suggestedModel,
  });

  final List<String> messages;
  final ModelConfig? suggestedModel;
}

class LocalModelAttachmentConstraintService {
  static const int estimatedTokensPerVisualPage = 800;
  static const double contextWindowWarningFraction = 0.7;
  static const int gemmaMaxImages = 8;

  const LocalModelAttachmentConstraintService._();

  static Future<LocalModelAttachmentConstraintWarning?> analyzeForGemma4({
    required ModelConfig? config,
    required String prompt,
    required List<PlatformFile> attachments,
  }) async {
    if (config == null ||
        config.type != ModelType.localMnn ||
        config.modelName != 'gemma4_e2b' ||
        attachments.isEmpty) {
      return null;
    }

    final messages = <String>[];
    final tokenWindow = config.tokenWindow ?? config.maxInputTokens ?? 16384;
    final tokenBudget = (tokenWindow * contextWindowWarningFraction).floor();
    var estimatedVisualTokens = 0;
    var estimatedImageCount = 0;
    final unsupportedFiles = <String>[];

    for (final file in attachments) {
      final bytes = await _readBytes(file);
      if (bytes == null || bytes.isEmpty) {
        unsupportedFiles.add(file.name);
        continue;
      }

      final mime = _detectMimeType(file, bytes);
      if (mime == 'application/pdf') {
        final pageCount = await _getPdfPageCount(file, bytes);
        if (pageCount == null) {
          unsupportedFiles.add(file.name);
          continue;
        }
        estimatedVisualTokens += pageCount * estimatedTokensPerVisualPage;
        estimatedImageCount += pageCount;
        continue;
      }

      if (mime.startsWith('image/')) {
        estimatedVisualTokens += estimatedTokensPerVisualPage;
        estimatedImageCount += 1;
        continue;
      }

      unsupportedFiles.add(file.name);
    }

    final promptTokens = TokenEstimator.estimateTokens(prompt);
    final estimatedTotalTokens = promptTokens + estimatedVisualTokens;

    if (unsupportedFiles.isNotEmpty) {
      messages.add(
        'Gemma 4 cannot use these attachments directly: ${unsupportedFiles.join(', ')}.',
      );
    }

    if (estimatedImageCount > gemmaMaxImages) {
      messages.add(
        'This input expands to about $estimatedImageCount images, but Gemma 4 only handles up to $gemmaMaxImages images reliably in one request.',
      );
    }

    if (estimatedTotalTokens >= tokenBudget) {
      messages.add(
        'Estimated input is about ${_formatTokens(estimatedTotalTokens)} tokens, which is near ${_formatTokens(tokenBudget)} (70% of Gemma 4\'s context window).',
      );
    }

    if (messages.isEmpty) {
      return null;
    }

    final suggestedModel = await getIt<ModelSelector>().getModelByHint([
      'documents',
    ], currentOverride: config);

    return LocalModelAttachmentConstraintWarning(
      messages: messages,
      suggestedModel: suggestedModel,
    );
  }

  static String _formatTokens(int tokens) {
    if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(1)}K';
    }
    return tokens.toString();
  }

  static Future<Uint8List?> _readBytes(PlatformFile file) async {
    if (file.bytes != null) {
      return Uint8List.fromList(file.bytes!);
    }
    final path = file.path;
    if (path == null || path.isEmpty) return null;
    try {
      return Uint8List.fromList(await File(path).readAsBytes());
    } catch (_) {
      return null;
    }
  }

  static String _detectMimeType(PlatformFile file, Uint8List bytes) {
    final headerBytes = bytes.sublist(0, bytes.length > 32 ? 32 : bytes.length);
    final ext = FileTypeUtils.getFileExtension(file.name);
    return (lookupMimeType(file.name, headerBytes: headerBytes) ??
            FileTypeUtils.getMimeTypeForBytes(
              bytes,
              extension: ext.isEmpty ? null : ext,
            ))
        .toLowerCase();
  }

  static Future<int?> _getPdfPageCount(
    PlatformFile file,
    Uint8List bytes,
  ) async {
    try {
      final content = latin1.decode(bytes, allowInvalid: true);
      final matches = RegExp(r'/Type\s*/Page\b').allMatches(content).length;
      return matches > 0 ? matches : null;
    } catch (_) {
      return null;
    }
  }
}
