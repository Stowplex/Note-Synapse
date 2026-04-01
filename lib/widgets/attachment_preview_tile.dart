import 'dart:io';

import 'package:flutter/material.dart';

import '../utils/file_type_utils.dart';
import '../utils/file_utils.dart';
import '../utils/synapse_temp_utils.dart';

class AttachmentPreviewTile extends StatelessWidget {
  const AttachmentPreviewTile({
    super.key,
    required this.attachmentPath,
    required this.onTap,
    this.width = 104,
    this.thumbnailSize = 88,
  });

  final String attachmentPath;
  final VoidCallback onTap;
  final double width;
  final double thumbnailSize;

  bool get _isRemoteHttpImage =>
      attachmentPath.startsWith('http://') ||
      attachmentPath.startsWith('https://');

  bool get _isRemoteUnsupported => attachmentPath.startsWith('gs://');

  String get _label {
    if (_isRemoteHttpImage || _isRemoteUnsupported) {
      try {
        final uri = Uri.parse(attachmentPath);
        if (uri.pathSegments.isNotEmpty) {
          return uri.pathSegments.last;
        }
      } catch (_) {
        // Fall through to basename extraction.
      }
    }

    if (attachmentPath.contains(Platform.pathSeparator)) {
      return attachmentPath.split(Platform.pathSeparator).last;
    }

    return attachmentPath.split('/').last;
  }

  String get _extension => FileTypeUtils.getFileExtension(_label);
  bool get _isImage => FileTypeUtils.isImage(_extension);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _isImage
                ? _buildImageThumbnail(context)
                : _buildFileFallback(context),
            const SizedBox(height: 6),
            Text(
              _label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageThumbnail(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: thumbnailSize,
      height: thumbnailSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildImageContent(context),
    );
  }

  Widget _buildImageContent(BuildContext context) {
    if (_isRemoteHttpImage) {
      return Image.network(
        attachmentPath,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildThumbnailFallback(context),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return _buildLoadingState(context);
        },
      );
    }

    if (_isRemoteUnsupported) {
      return _buildThumbnailFallback(context);
    }

    final futurePath = SynapseTempUtils.isSynapseTempUri(attachmentPath)
        ? FileUtils.resolvePortableAttachmentPath(attachmentPath)
        : attachmentPath.startsWith('/')
        ? Future.value(attachmentPath)
        : FileUtils.getFullFilePath(attachmentPath, true);

    return FutureBuilder<String>(
      future: futurePath,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildLoadingState(context);
        }

        final resolvedPath = snapshot.data;
        if (resolvedPath == null || resolvedPath.isEmpty) {
          return _buildThumbnailFallback(context);
        }

        final file = File(resolvedPath);
        if (!file.existsSync()) {
          return _buildThumbnailFallback(context);
        }

        return Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _buildThumbnailFallback(context),
        );
      },
    );
  }

  Widget _buildLoadingState(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildThumbnailFallback(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.broken_image_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildFileFallback(BuildContext context) {
    final theme = Theme.of(context);
    final icon = _iconForExtension(_extension);

    return Container(
      width: thumbnailSize,
      height: thumbnailSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: theme.colorScheme.onSurfaceVariant, size: 28),
    );
  }

  IconData _iconForExtension(String extension) {
    switch (extension.toLowerCase()) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
      case 'txt':
      case 'rtf':
      case 'odt':
        return Icons.description_outlined;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart_outlined;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow_outlined;
      case 'mp4':
      case 'avi':
      case 'mov':
      case 'wmv':
      case 'webm':
        return Icons.videocam_outlined;
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'm4a':
      case 'aac':
      case 'ogg':
        return Icons.audiotrack_outlined;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.archive_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}
