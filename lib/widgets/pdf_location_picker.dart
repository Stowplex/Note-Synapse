import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/services/attachment_link_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/pdf_thumbnail_service.dart';
import 'package:note_synapse/services/service_locator.dart';

/// Represents a selected location within a PDF.
class PdfLocationSelection {
  final int page;
  final String? displayText;

  const PdfLocationSelection({required this.page, this.displayText});
}

/// Represents a node in a PDF's table-of-contents / outline.
class PdfOutlineNode {
  final String title;
  final int page;
  final List<PdfOutlineNode> children;

  const PdfOutlineNode({
    required this.title,
    required this.page,
    this.children = const [],
  });
}

/// A widget that provides a full PDF location picker with page preview,
/// navigation controls, ToC/bookmark dropdowns, and link text + insert button.
///
/// Returns a markdown link string via [onInsert], or calls [onCancel].
class PdfLocationPicker extends StatefulWidget {
  final int? totalPages;
  final List<PdfBookmark> bookmarks;
  final List<PdfOutlineNode>? outline;
  final String? pdfPath;
  final String attachmentId;
  final String fileName;
  final PdfThumbnailService? thumbnailService;
  final Function(String markdownLink)? onInsert;
  final VoidCallback? onCancel;

  const PdfLocationPicker({
    super.key,
    this.totalPages,
    this.bookmarks = const [],
    this.outline,
    this.pdfPath,
    required this.attachmentId,
    required this.fileName,
    this.thumbnailService,
    this.onInsert,
    this.onCancel,
  });

  @override
  State<PdfLocationPicker> createState() => _PdfLocationPickerState();
}

class _PdfLocationPickerState extends State<PdfLocationPicker> {
  int _currentPage = 1;
  final TextEditingController _pageInputController = TextEditingController();
  final TextEditingController _linkTextController = TextEditingController();
  Uint8List? _thumbnailBytes;
  bool _loadingThumbnail = false;

  PdfThumbnailService get _thumbnailService =>
      widget.thumbnailService ?? PdfThumbnailService();

  @override
  void initState() {
    super.initState();
    _pageInputController.text = '1';
    _updateLinkText();
    _loadThumbnail();
  }

  @override
  void dispose() {
    _pageInputController.dispose();
    _linkTextController.dispose();
    super.dispose();
  }

  void _updateLinkText({String? chapterTitle, String? bookmarkTitle}) {
    final linkService = AttachmentLinkService(getIt<DatabaseService>());
    _linkTextController.text = linkService.defaultLinkText(
      fileName: widget.fileName,
      page: _currentPage,
      bookmarkTitle: bookmarkTitle,
      chapterTitle: chapterTitle,
    );
  }

  Future<void> _loadThumbnail() async {
    if (widget.pdfPath == null) return;
    setState(() {
      _loadingThumbnail = true;
    });
    final bytes = await _thumbnailService.renderPage(
      pdfPath: widget.pdfPath!,
      page: _currentPage - 1, // 0-indexed
      width: 400,
    );
    if (mounted) {
      setState(() {
        _thumbnailBytes = bytes;
        _loadingThumbnail = false;
      });
    }
  }

  void _goToPage(int page) {
    final maxPage = widget.totalPages ?? page;
    final clamped = page.clamp(1, maxPage);
    if (clamped == _currentPage) return;
    setState(() {
      _currentPage = clamped;
      _pageInputController.text = '$clamped';
    });
    _updateLinkText();
    _loadThumbnail();
  }

  void _onPageInputSubmitted(String text) {
    final page = int.tryParse(text.trim());
    if (page != null) {
      _goToPage(page);
    }
  }

  void _selectBookmark(PdfBookmark bookmark) {
    _goToPage(bookmark.pageNumber);
    _updateLinkText(bookmarkTitle: bookmark.title);
  }

  void _selectOutlineNode(PdfOutlineNode node) {
    _goToPage(node.page);
    _updateLinkText(chapterTitle: node.title);
  }

  List<PdfOutlineNode> _flattenOutline(
    List<PdfOutlineNode> nodes, [
    int depth = 0,
  ]) {
    final result = <PdfOutlineNode>[];
    for (final node in nodes) {
      result.add(node);
      if (node.children.isNotEmpty) {
        result.addAll(_flattenOutline(node.children, depth + 1));
      }
    }
    return result;
  }

  void _insertLink() {
    final linkService = AttachmentLinkService(getIt<DatabaseService>());
    final markdownLink = linkService.generateMarkdownLink(
      attachmentId: widget.attachmentId,
      linkText: _linkTextController.text,
      page: _currentPage,
    );
    widget.onInsert?.call(markdownLink);
  }

  String _abbreviate(String text, int maxLen) {
    if (text.length <= maxLen) return text;
    return '${text.substring(0, maxLen - 1)}…';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxPage = widget.totalPages ?? 1;

    return Column(
      children: [
        // Top toolbar
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Prev page
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Previous page',
                  onPressed: _currentPage > 1
                      ? () => _goToPage(_currentPage - 1)
                      : null,
                ),
                // Page input
                SizedBox(
                  width: 60,
                  child: TextField(
                    controller: _pageInputController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 8,
                      ),
                      border: const OutlineInputBorder(),
                      suffixText: '/ $maxPage',
                      suffixStyle: theme.textTheme.bodySmall,
                    ),
                    onSubmitted: _onPageInputSubmitted,
                  ),
                ),
                const SizedBox(width: 4),
                // ToC dropdown
                if (widget.outline != null && widget.outline!.isNotEmpty)
                  PopupMenuButton<PdfOutlineNode>(
                    tooltip: 'Table of Contents',
                    itemBuilder: (context) {
                      final flat = _flattenOutline(widget.outline!);
                      return flat.map((node) {
                        return PopupMenuItem<PdfOutlineNode>(
                          value: node,
                          child: Text(
                            '${node.title} · p.${node.page}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList();
                    },
                    onSelected: _selectOutlineNode,
                    child: Chip(
                      avatar: const Icon(Icons.list, size: 18),
                      visualDensity: VisualDensity.compact,
                      label: const Text('ToC'),
                    ),
                  ),
                // Bookmarks dropdown
                if (widget.bookmarks.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  PopupMenuButton<PdfBookmark>(
                    tooltip: 'Bookmarks',
                    itemBuilder: (context) {
                      return widget.bookmarks.map((bookmark) {
                        final hasAnnotation =
                            bookmark.annotation != null &&
                            bookmark.annotation!.isNotEmpty;
                        final subtitle = hasAnnotation
                            ? '${_abbreviate(bookmark.annotation!, 80)} · Page ${bookmark.pageNumber}'
                            : 'Page ${bookmark.pageNumber}';
                        return PopupMenuItem<PdfBookmark>(
                          value: bookmark,
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(bookmark.title),
                            subtitle: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        );
                      }).toList();
                    },
                    onSelected: _selectBookmark,
                    child: Chip(
                      avatar: const Icon(Icons.bookmark, size: 18),
                      visualDensity: VisualDensity.compact,
                      label: const Text('Bookmarks'),
                    ),
                  ),
                ],
                // Next page
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Next page',
                  onPressed: _currentPage < maxPage
                      ? () => _goToPage(_currentPage + 1)
                      : null,
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        // PDF page preview
        Expanded(child: Center(child: _buildPreview())),
        const Divider(height: 1),
        // Bottom area: link text + buttons
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _linkTextController,
                decoration: const InputDecoration(
                  labelText: 'Link text',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: widget.onCancel,
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _linkTextController.text.isNotEmpty
                        ? _insertLink
                        : null,
                    child: const Text('Insert Link'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    if (widget.pdfPath == null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.picture_as_pdf, size: 64, color: Colors.grey),
          const SizedBox(height: 8),
          Text(
            'Page $_currentPage',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      );
    }
    if (_loadingThumbnail) {
      return const CircularProgressIndicator();
    }
    if (_thumbnailBytes != null) {
      return InteractiveViewer(
        minScale: 1.0,
        maxScale: 4.0,
        child: Image.memory(_thumbnailBytes!, fit: BoxFit.contain),
      );
    }
    return const Text('Preview not available');
  }
}
