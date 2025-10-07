import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

class InteractiveCheckboxList extends StatefulWidget {
  final String originalContent;
  final Function(String) onContentChanged;
  final TextStyle? style;
  final TextDirection textDirection;

  const InteractiveCheckboxList({
    super.key,
    required this.originalContent,
    required this.onContentChanged,
    this.style,
    this.textDirection = TextDirection.ltr,
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
      final checkboxMatch = RegExp(r'^(\s*)\[([ x])\]\s+(.+)$').firstMatch(line);
      
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
      lines[item.lineIndex] = '${item.indent}[$newCheckbox] ${item.text}';
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
    
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final checkboxMatch = RegExp(r'^(\s*)\[([ x])\]\s+(.+)$').firstMatch(line);
      
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
                    onLinkTap: (url, title) {
                      // Handle link taps if needed
                    },
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
              onLinkTap: (url, title) {
                // Handle link taps if needed
              },
            ),
          ),
        );
      }
    }
    
    return widgets;
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
