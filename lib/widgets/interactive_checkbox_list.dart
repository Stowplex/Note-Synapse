import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

class InteractiveCheckboxList extends StatefulWidget {
  final String originalContent;
  final Function(String) onContentChanged;
  final TextStyle? style;
  final TextDirection textDirection;
  final Function(String, String)? onLinkTap;

  const InteractiveCheckboxList({
    super.key,
    required this.originalContent,
    required this.onContentChanged,
    this.style,
    this.textDirection = TextDirection.ltr,
    this.onLinkTap,
  });

  @override
  State<InteractiveCheckboxList> createState() => _InteractiveCheckboxListState();
}

class _InteractiveCheckboxListState extends State<InteractiveCheckboxList> {
  late String _currentContent;
  final List<CheckboxItem> _checkboxItems = [];

  @override
  void initState() {
    super.initState();
    _currentContent = widget.originalContent;
    _parseCheckboxes();
  }

  @override
  void didUpdateWidget(InteractiveCheckboxList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.originalContent != widget.originalContent) {
      _currentContent = widget.originalContent;
      _parseCheckboxes();
    }
  }

  void _parseCheckboxes() {
    _checkboxItems.clear();
    final lines = _currentContent.split('\n');
    
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final checkboxMatch = RegExp(r'^(\s*)(?:-\s+)?\[([ x])\]\s+(.+)$').firstMatch(line);
      
      if (checkboxMatch != null) {
        _checkboxItems.add(CheckboxItem(
          lineIndex: i,
          indent: checkboxMatch.group(1) ?? '',
          isChecked: checkboxMatch.group(2) == 'x',
          text: checkboxMatch.group(3) ?? '',
          originalLine: line,
        ));
      }
    }
  }

  void _toggleCheckbox(int itemIndex) {
    if (itemIndex >= 0 && itemIndex < _checkboxItems.length) {
      setState(() {
        _checkboxItems[itemIndex].isChecked = !_checkboxItems[itemIndex].isChecked;
        _updateContent();
      });
    }
  }

  void _updateContent() {
    final lines = _currentContent.split('\n');
    
    for (final item in _checkboxItems) {
      final newCheckbox = item.isChecked ? 'x' : ' ';
      // Check if the original line had a dash prefix
      final hasDashPrefix = item.originalLine.trim().startsWith('-');
      final dashPrefix = hasDashPrefix ? '- ' : '';
      lines[item.lineIndex] = '${item.indent}$dashPrefix[$newCheckbox] ${item.text}';
    }
    
    _currentContent = lines.join('\n');
    widget.onContentChanged(_currentContent);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _buildContent(),
    );
  }

  List<Widget> _buildContent() {
    final lines = _currentContent.split('\n');
    final widgets = <Widget>[];
    
    // Track if we're inside a code block or table
    bool inCodeBlock = false;
    bool inTable = false;
    final List<String> codeBlockLines = [];
    final List<String> tableLines = [];
    
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      
      // Check for code block markers
      if (line.trim().startsWith('```')) {
        if (inCodeBlock) {
          // End of code block - render the accumulated code block
          codeBlockLines.add(line);
          widgets.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2.0),
              child: GptMarkdown(
                codeBlockLines.join('\n'),
                style: widget.style,
                textDirection: widget.textDirection,
                onLinkTap: widget.onLinkTap,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
          codeBlockLines.clear();
          inCodeBlock = false;
        } else {
          // Start of code block
          inCodeBlock = true;
          codeBlockLines.add(line);
        }
        continue;
      }
      
      if (inCodeBlock) {
        // We're inside a code block - accumulate lines
        codeBlockLines.add(line);
        continue;
      }
      
      // Check for table markers
      if (_isTableLine(line)) {
        if (!inTable) {
          // Start of table
          inTable = true;
          tableLines.clear();
        }
        tableLines.add(line);
        continue;
      } else if (inTable) {
        // End of table - render the accumulated table
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.0),
            child: GptMarkdown(
              tableLines.join('\n'),
              style: widget.style,
              textDirection: widget.textDirection,
              onLinkTap: widget.onLinkTap,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
        tableLines.clear();
        inTable = false;
      }
      
      if (inTable) {
        // We're inside a table - accumulate lines
        tableLines.add(line);
        continue;
      }
      
      // Not in a code block - check for checkboxes
      final checkboxMatch = RegExp(r'^(\s*)(?:-\s+)?\[([ x])\]\s+(.+)$').firstMatch(line);
      
      if (checkboxMatch != null) {
        // This is a checkbox line - create interactive checkbox
        final indent = checkboxMatch.group(1) ?? '';
        final isChecked = checkboxMatch.group(2) == 'x';
        final text = checkboxMatch.group(3) ?? '';
        
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(indent),
                GestureDetector(
                  onTap: () {
                    final itemIndex = _checkboxItems.indexWhere(
                      (item) => item.lineIndex == i,
                    );
                    if (itemIndex != -1) {
                      _toggleCheckbox(itemIndex);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(2.0),
                    child: Checkbox(
                      value: isChecked,
                      onChanged: (value) {
                        final itemIndex = _checkboxItems.indexWhere(
                          (item) => item.lineIndex == i,
                        );
                        if (itemIndex != -1) {
                          _toggleCheckbox(itemIndex);
                        }
                      },
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GptMarkdown(
                    text,
                    style: widget.style,
                    textDirection: widget.textDirection,
                    onLinkTap: widget.onLinkTap,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        // Regular line - render normally
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.0),
            child: GptMarkdown(
              line,
              style: widget.style,
              textDirection: widget.textDirection,
              onLinkTap: widget.onLinkTap,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
    }
    
    // If we ended while still in a code block, render it
    if (inCodeBlock && codeBlockLines.isNotEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.0),
          child: GptMarkdown(
            codeBlockLines.join('\n'),
            style: widget.style,
            textDirection: widget.textDirection,
            onLinkTap: widget.onLinkTap,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    
    // If we ended while still in a table, render it
    if (inTable && tableLines.isNotEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.0),
          child: GptMarkdown(
            tableLines.join('\n'),
            style: widget.style,
            textDirection: widget.textDirection,
            onLinkTap: widget.onLinkTap,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    
    return widgets;
  }

  /// Determines if a line is part of a markdown table
  bool _isTableLine(String line) {
    final trimmedLine = line.trim();
    
    // Empty lines are not table lines
    if (trimmedLine.isEmpty) return false;
    
    // Check if line contains table separators (|)
    if (!trimmedLine.contains('|')) return false;
    
    // Check if it's a table separator line (contains only |, -, :, and spaces)
    final separatorPattern = RegExp(r'^[\s\|\-\:]+$');
    if (separatorPattern.hasMatch(trimmedLine)) return true;
    
    // Check if it's a table data row (contains | and has reasonable table structure)
    final parts = trimmedLine.split('|');
    if (parts.length >= 2) {
      // Remove empty parts at the beginning and end (common in markdown tables)
      final nonEmptyParts = parts.where((part) => part.trim().isNotEmpty).toList();
      return nonEmptyParts.isNotEmpty;
    }
    
    return false;
  }
}

class CheckboxItem {
  final int lineIndex;
  final String indent;
  bool isChecked;
  final String text;
  final String originalLine;

  CheckboxItem({
    required this.lineIndex,
    required this.indent,
    required this.isChecked,
    required this.text,
    required this.originalLine,
  });
}
