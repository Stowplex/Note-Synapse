import 'dart:io';

import 'package:flutter/material.dart';

import '../utils/file_type_utils.dart';
import '../utils/file_utils.dart';
import '../utils/synapse_temp_utils.dart';

class AttachmentPreviewTile extends StatefulWidget {
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

  @override
  State<AttachmentPreviewTile> createState() => _AttachmentPreviewTileState();
}

class _AttachmentPreviewTileState extends State<AttachmentPreviewTile> {
  late Future<String> _resolvedPathFuture;

  @override
  void initState() {
    super.initState();
    _resolvedPathFuture = _createResolvedPathFuture();
  }

  @override
  void didUpdateWidget(covariant AttachmentPreviewTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachmentPath != widget.attachmentPath) {
      _resolvedPathFuture = _createResolvedPathFuture();
    }
  }

  Future<String> _createResolvedPathFuture() {
    if (SynapseTempUtils.isSynapseTempUri(widget.attachmentPath)) {
      return FileUtils.resolvePortableAttachmentPath(widget.attachmentPath);
    }
    if (widget.attachmentPath.startsWith('/')) {
      return Future.value(widget.attachmentPath);
    }
    return FileUtils.getFullFilePath(widget.attachmentPath, true);
  }

  bool get _isRemoteHttpImage =>
      widget.attachmentPath.startsWith('http://') ||
      widget.attachmentPath.startsWith('https://');

  bool get _isRemoteUnsupported => widget.attachmentPath.startsWith('gs://');

  String get _label {
    if (_isRemoteHttpImage || _isRemoteUnsupported) {
      try {
        final uri = Uri.parse(widget.attachmentPath);
        if (uri.pathSegments.isNotEmpty) {
          return uri.pathSegments.last;
        }
      } catch (_) {
        // Fall through to basename extraction.
      }
    }

    if (widget.attachmentPath.contains(Platform.pathSeparator)) {
      return widget.attachmentPath.split(Platform.pathSeparator).last;
    }

    return widget.attachmentPath.split('/').last;
  }

  String get _extension => FileTypeUtils.getFileExtension(_label);
  bool get _isImage => FileTypeUtils.isImage(_extension);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: widget.onTap,
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
      width: widget.thumbnailSize,
      height: widget.thumbnailSize,
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
        widget.attachmentPath,
        fit: BoxFit.cover,
        gaplessPlayback: true,
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

    return FutureBuilder<String>(
      future: _resolvedPathFuture,
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
          gaplessPlayback: true,
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
      width: widget.thumbnailSize,
      height: widget.thumbnailSize,
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
