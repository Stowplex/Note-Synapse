import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:note_synapse/models/attachment.dart';

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

/// A widget that lets the user pick a location in a PDF by entering a page
/// number, selecting a bookmark, or selecting a chapter from the outline.
class PdfLocationPicker extends StatefulWidget {
  final int? totalPages;
  final List<PdfBookmark> bookmarks;
  final List<PdfOutlineNode>? outline;
  final Function(PdfLocationSelection?) onSelected;
  final Function(int)? onPageChanged;

  const PdfLocationPicker({
    super.key,
    this.totalPages,
    this.bookmarks = const [],
    this.outline,
    required this.onSelected,
    this.onPageChanged,
  });

  @override
  State<PdfLocationPicker> createState() => _PdfLocationPickerState();
}

class _PdfLocationPickerState extends State<PdfLocationPicker> {
  final TextEditingController _pageController = TextEditingController();
  String? _pageError;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _submitPage() {
    final text = _pageController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _pageError = 'Please enter a page number';
      });
      return;
    }

    final page = int.tryParse(text);
    if (page == null) {
      setState(() {
        _pageError = 'Invalid number';
      });
      return;
    }

    if (widget.totalPages != null && (page < 1 || page > widget.totalPages!)) {
      setState(() {
        _pageError = 'Page must be between 1 and ${widget.totalPages}';
      });
      return;
    }

    if (page < 1) {
      setState(() {
        _pageError = 'Page must be at least 1';
      });
      return;
    }

    setState(() {
      _pageError = null;
    });

    widget.onSelected(PdfLocationSelection(page: page, displayText: 'Page $page'));
    widget.onPageChanged?.call(page);
  }

  void _selectBookmark(PdfBookmark bookmark) {
    widget.onSelected(PdfLocationSelection(
      page: bookmark.pageNumber,
      displayText: bookmark.title,
    ));
    widget.onPageChanged?.call(bookmark.pageNumber);
  }

  void _selectChapter(PdfOutlineNode node) {
    widget.onSelected(PdfLocationSelection(
      page: node.page,
      displayText: node.title,
    ));
    widget.onPageChanged?.call(node.page);
  }

  void _selectNoPage() {
    widget.onSelected(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Page input section
          Text('Go to page', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pageController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    hintText: widget.totalPages != null
                        ? '1 - ${widget.totalPages}'
                        : 'Page number',
                    errorText: _pageError,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submitPage(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _submitPage,
                child: const Text('Go'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // No specific page option
          OutlinedButton.icon(
            onPressed: _selectNoPage,
            icon: const Icon(Icons.link),
            label: const Text('No specific page'),
          ),

          // Bookmarks section
          if (widget.bookmarks.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Bookmarks', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.bookmarks.length,
              itemBuilder: (context, index) {
                final bookmark = widget.bookmarks[index];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.bookmark, size: 20),
                  title: Text(bookmark.title),
                  subtitle: Text('Page ${bookmark.pageNumber}'),
                  onTap: () => _selectBookmark(bookmark),
                );
              },
            ),
          ],

          // Chapters / outline section
          if (widget.outline != null && widget.outline!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Chapters', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.outline!.length,
              itemBuilder: (context, index) {
                final node = widget.outline![index];
                return _buildOutlineNode(node, 0);
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOutlineNode(PdfOutlineNode node, int depth) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.only(left: 16.0 + depth * 16.0),
          leading: const Icon(Icons.article, size: 20),
          title: Text(node.title),
          subtitle: Text('Page ${node.page}'),
          onTap: () => _selectChapter(node),
        ),
        ...node.children.map((child) => _buildOutlineNode(child, depth + 1)),
      ],
    );
  }
}
