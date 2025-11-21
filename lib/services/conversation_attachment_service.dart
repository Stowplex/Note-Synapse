import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../utils/file_utils.dart';
import '../utils/synapse_temp_utils.dart';
import 'logger_service.dart';

class ConversationAttachmentService {
  /// Process content for temporary attachments.
  ///
  /// Scans the [content] for `synapsetemp:///` URIs. For each found URI:
  /// 1. Resolves the temporary file.
  /// 2. Generates a SHA256 hash of the URI to use as the filename.
  /// 3. Copies the file to the permanent attachments directory.
  /// 4. Replaces the `synapsetemp:///` URI in the content with the new local path (or keeps it if needed,
  ///    but usually we want to reference the attachment).
  ///    *Self-correction*: The requirement says "associating them with the newly created notes".
  ///    Usually, the content of the note might still refer to the original URL or a markdown link.
  ///    If the original content had `[file](synapsetemp://...)`, we might want to update it to point to the new attachment?
  ///    However, standard note attachments are often just linked via the `attachments` table and not necessarily embedded in text
  ///    unless it's an image.
  ///    Let's assume we return the *original* content but with the *new* attachment paths added to the note's attachment list.
  ///    Wait, if the content has `synapsetemp://` links, they will become invalid once the temp file is gone.
  ///    So we SHOULD probably update the content to point to the new file if possible, or at least ensure the file is saved.
  ///
  ///    Actually, `synapsetemp` URIs are usually internal. If they are in the text (e.g. markdown image),
  ///    we should probably update the markdown to point to the new local file.
  ///
  /// Returns a record containing the (potentially modified) content and a list of new attachment paths.
  static Future<({String content, List<String> attachmentPaths})>
  processContentForAttachments({
    required String content,
    required String noteId,
  }) async {
    final List<String> newAttachmentPaths = [];

    // Regex to find synapsetemp URIs
    // Matches synapsetemp:// followed by non-whitespace, non-parenthesis, non-bracket characters
    final regex = RegExp(r'synapsetemp://[^\s)\]]+');

    final matches = regex.allMatches(content).toList();

    // Process matches in reverse order to avoid invalidating indices when replacing
    for (final match in matches.reversed) {
      final uriString = match.group(0);
      if (uriString == null) continue;

      try {
        // 1. Resolve temp file
        final tempFile = await SynapseTempUtils.resolveUri(uriString);
        if (!await tempFile.exists()) {
          LoggerService.warning('Temp file not found for URI: $uriString');
          continue;
        }

        // 2. Generate SHA256 hash of the URI for the filename
        final hash = sha256.convert(utf8.encode(uriString)).toString();

        // Get extension from the temp file or URI
        String extension = p.extension(tempFile.path);
        if (extension.isEmpty) {
          // Try to guess from URI if file has no extension
          final uriPath = Uri.parse(uriString).path;
          extension = p.extension(uriPath);
        }

        // Sanitize extension
        final sanitizedExtension = extension
            .replaceAll(RegExp(r'[^a-zA-Z0-9.]'), '')
            .toLowerCase();
        // Ensure dot
        final ext = sanitizedExtension.startsWith('.')
            ? sanitizedExtension
            : '.$sanitizedExtension';

        final fileName = '${noteId}_$hash$ext';

        // 3. Copy to attachments directory
        final attachmentsDir = await FileUtils.getPrivateStorageDirectory();
        final newFilePath = p.join(attachmentsDir.path, fileName);
        final newFile = File(newFilePath);

        if (!await newFile.exists()) {
          await tempFile.copy(newFilePath);
        }

        final relativePath = 'attachments/$fileName';
        newAttachmentPaths.add(relativePath);

        // 4. Do NOT update content. The renderer will handle the lookup using the SHA256 hash.
      } catch (e) {
        LoggerService.error(
          'Failed to process temp attachment: $uriString',
          error: e,
        );
      }
    }

    return (content: content, attachmentPaths: newAttachmentPaths);
  }

  /// Process a list of file paths for attachments.
  ///
  /// Copies the files to the permanent attachments directory and returns the new relative paths.
  static Future<List<String>> processFilesForAttachments({
    required List<String> filePaths,
    required String noteId,
  }) async {
    final List<String> newAttachmentPaths = [];
    final attachmentsDir = await FileUtils.getPrivateStorageDirectory();

    for (final path in filePaths) {
      try {
        final file = File(path);
        if (!await file.exists()) {
          LoggerService.warning('Attachment file not found: $path');
          continue;
        }

        final fileName = p.basename(path);
        // Generate a unique name to avoid collisions
        final uniqueName =
            '${noteId}_${DateTime.now().millisecondsSinceEpoch}_$fileName';
        final newFilePath = p.join(attachmentsDir.path, uniqueName);

        await file.copy(newFilePath);

        newAttachmentPaths.add('attachments/$uniqueName');
      } catch (e) {
        LoggerService.error(
          'Failed to process attachment file: $path',
          error: e,
        );
      }
    }

    return newAttachmentPaths;
  }
}
