import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import '../l10n/app_localizations.dart';
import 'synapse_code_editor.dart';

class SynapseNoteEditor extends StatefulWidget {
  final CodeLineEditingController controller;
  final FocusNode? focusNode;
  final VoidCallback? onPickImage;
  final String? language;

  const SynapseNoteEditor({
    super.key,
    required this.controller,
    this.focusNode,
    this.onPickImage,
    this.language,
  });

  @override
  State<SynapseNoteEditor> createState() => _SynapseNoteEditorState();
}

class _SynapseNoteEditorState extends State<SynapseNoteEditor> {
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null) {
      _insertText(data.text!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SynapseCodeEditor(
      controller: widget.controller,
      focusNode: widget.focusNode,
      wordWrap: true,
      fontSize: 14.0,
      fontFamily: 'Roboto Mono',
      language: widget.language,
      actions: [
        IconButton(
          icon: const Icon(Icons.paste, size: 20),
          onPressed: _paste,
          tooltip: 'Paste',
        ),
        IconButton(
          icon: const Icon(Icons.format_bold, size: 20),
          onPressed: _toggleBold,
          tooltip: 'Bold',
        ),
        IconButton(
          icon: const Icon(Icons.format_italic, size: 20),
          onPressed: _toggleItalic,
          tooltip: 'Italic',
        ),
        IconButton(
          icon: const Icon(Icons.strikethrough_s, size: 20),
          onPressed: _toggleStrikethrough,
          tooltip: 'Strikethrough',
        ),
        IconButton(
          icon: const Icon(Icons.code, size: 20),
          onPressed: _toggleInlineCode,
          tooltip: l10n.addLink,
        ),
        IconButton(
          icon: const Icon(Icons.data_object, size: 20),
          onPressed: _toggleCodeBlock,
          tooltip: 'Code Block',
        ),
        IconButton(
          icon: const Icon(Icons.format_quote, size: 20),
          onPressed: _toggleQuote,
          tooltip: 'Quote',
        ),
        IconButton(
          icon: const Icon(Icons.list, size: 20),
          onPressed: _toggleBulletList,
          tooltip: 'Bullet List',
        ),
        IconButton(
          icon: const Icon(Icons.format_list_numbered, size: 20),
          onPressed: _toggleNumberedList,
          tooltip: 'Numbered List',
        ),
        Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.check_box_outlined, size: 20),
            onPressed: () => _showCheckboxMenu(context),
            tooltip: 'Checkbox',
          ),
        ),
        Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.title, size: 20),
            onPressed: () => _showHeadingMenu(context),
            tooltip: 'Heading',
          ),
        ),
        IconButton(
          icon: const Icon(Icons.link, size: 20),
          onPressed: _insertLink,
          tooltip: 'Link',
        ),
        if (widget.onPickImage != null)
          IconButton(
            icon: const Icon(Icons.image, size: 20),
            onPressed: widget.onPickImage,
            tooltip: 'Image',
          ),
      ],
    );
  }

  // --- Markdown Formatting Helpers ---

  void _insertText(String text, {int selectionOffset = 0}) {
    final selection = widget.controller.selection;
    final codeLines = widget.controller.value.codeLines;
    final startOffset = _getOffsetForPosition(codeLines, selection.start);
    final endOffset = _getOffsetForPosition(codeLines, selection.end);

    final currentText = widget.controller.text;
    final newText =
        currentText.substring(0, startOffset) +
        text +
        currentText.substring(endOffset);

    widget.controller.text = newText;

    final newCursorOffset = startOffset + selectionOffset;
    final newPos = _getPositionForOffset(
      widget.controller.value.codeLines,
      newCursorOffset,
    );

    widget.controller.selection = CodeLineSelection.collapsed(
      index: newPos.index,
      offset: newPos.offset,
    );
  }

  int _getOffsetForPosition(CodeLines codeLines, CodeLinePosition position) {
    int offset = 0;
    for (int i = 0; i < position.index && i < codeLines.length; i++) {
      offset += codeLines[i].text.length + 1; // +1 for newline
    }
    return offset + position.offset;
  }

  CodeLinePosition _getPositionForOffset(CodeLines codeLines, int offset) {
    int currentOffset = 0;
    for (int i = 0; i < codeLines.length; i++) {
      final lineLength = codeLines[i].text.length + 1; // +1 for newline
      if (currentOffset + lineLength > offset) {
        return CodeLinePosition(index: i, offset: offset - currentOffset);
      }
      currentOffset += lineLength;
    }
    if (codeLines.length > 0) {
      return CodeLinePosition(
        index: codeLines.length - 1,
        offset: codeLines.last.text.length,
      );
    }
    return const CodeLinePosition(index: 0, offset: 0);
  }

  void _toggleBold() => _toggleMarker('**', '**');
  void _toggleItalic() => _toggleMarker('*', '*');
  void _toggleStrikethrough() => _toggleMarker('~~', '~~');
  void _toggleInlineCode() => _toggleMarker('`', '`');
  void _toggleCodeBlock() {
    final sel = widget.controller.selection;
    if (sel.start == sel.end) {
      // Insert ````|````, cursor goes between backticks
      _insertText('``````', selectionOffset: 3);
    } else {
      _toggleMarker('```', '```');
    }
  }

  void _toggleMarker(String prefix, String suffix) {
    final sel = widget.controller.selection;
    final text = widget.controller.text;
    final codeLines = widget.controller.value.codeLines;

    final startOff = _getOffsetForPosition(codeLines, sel.start);
    final endOff = _getOffsetForPosition(codeLines, sel.end);
    final selectedText = text.substring(startOff, endOff);
    final beforeText = text.substring(0, startOff);
    final afterText = text.substring(endOff);

    if (selectedText.isEmpty) {
      // Check if cursor is between markers: **|**
      if (beforeText.endsWith(prefix) && afterText.startsWith(suffix)) {
        // Remove markers
        final newText =
            beforeText.substring(0, beforeText.length - prefix.length) +
            afterText.substring(suffix.length);
        widget.controller.text = newText;

        final newOffset = startOff - prefix.length;
        final newPos = _getPositionForOffset(
          widget.controller.value.codeLines,
          newOffset,
        );
        widget.controller.selection = CodeLineSelection.collapsed(
          index: newPos.index,
          offset: newPos.offset,
        );
      } else {
        // Insert markers with cursor between: **|**
        _insertText('$prefix$suffix', selectionOffset: prefix.length);
      }
    } else if (selectedText.startsWith(prefix) &&
        selectedText.endsWith(suffix) &&
        selectedText.length > prefix.length + suffix.length) {
      // Selection has markers: **abc** → abc (keep abc selected)
      final unwrapped = selectedText.substring(
        prefix.length,
        selectedText.length - suffix.length,
      );
      final sb = StringBuffer();
      sb.write(text.substring(0, startOff));
      sb.write(unwrapped);
      sb.write(text.substring(endOff));

      widget.controller.text = sb.toString();

      // Keep the unwrapped text selected
      final newStartPos = _getPositionForOffset(
        widget.controller.value.codeLines,
        startOff,
      );
      final newEndPos = _getPositionForOffset(
        widget.controller.value.codeLines,
        startOff + unwrapped.length,
      );

      widget.controller.selection = CodeLineSelection(
        baseIndex: newStartPos.index,
        baseOffset: newStartPos.offset,
        extentIndex: newEndPos.index,
        extentOffset: newEndPos.offset,
      );
    } else {
      // Add markers: abc → **abc** (select **abc** including markers for next toggle)
      final sb = StringBuffer();
      sb.write(text.substring(0, startOff));
      sb.write(prefix);
      sb.write(selectedText);
      sb.write(suffix);
      sb.write(text.substring(endOff));

      widget.controller.text = sb.toString();

      // Select the entire wrapped text INCLUDING markers so next toggle can detect them
      final newStartPos = _getPositionForOffset(
        widget.controller.value.codeLines,
        startOff,
      );
      final newEndPos = _getPositionForOffset(
        widget.controller.value.codeLines,
        startOff + prefix.length + selectedText.length + suffix.length,
      );

      widget.controller.selection = CodeLineSelection(
        baseIndex: newStartPos.index,
        baseOffset: newStartPos.offset,
        extentIndex: newEndPos.index,
        extentOffset: newEndPos.offset,
      );
    }
  }

  void _toggleQuote() {
    final sel = widget.controller.selection;

    if (sel.start == sel.end) {
      // Toggle quote on current line
      _toggleLinePrefix(sel.start.index, '> ');
    } else {
      // Toggle quote on selected lines
      for (int i = sel.start.index; i <= sel.end.index; i++) {
        _toggleLinePrefix(i, '> ');
      }
    }
  }

  void _toggleBulletList() {
    final sel = widget.controller.selection;

    if (sel.start == sel.end) {
      _toggleLinePrefix(sel.start.index, '- ');
    } else {
      for (int i = sel.start.index; i <= sel.end.index; i++) {
        _toggleLinePrefix(i, '- ');
      }
    }
  }

  void _toggleNumberedList() {
    final sel = widget.controller.selection;

    if (sel.start == sel.end) {
      _toggleLinePrefix(sel.start.index, '1. ');
    } else {
      for (int i = sel.start.index; i <= sel.end.index; i++) {
        final number = i - sel.start.index + 1;
        _toggleLinePrefix(i, '$number. ');
      }
    }
  }

  void _toggleLinePrefix(int lineIndex, String prefix) {
    // Capture selection BEFORE modifying text to avoid reading reset state
    final currentSelection = widget.controller.selection;
    final codeLines = widget.controller.value.codeLines;
    if (lineIndex < 0 || lineIndex >= codeLines.length) return;

    final line = codeLines[lineIndex].text;
    String newLine;
    int cursorChange = 0;

    if (line.startsWith(prefix)) {
      // Remove prefix
      newLine = line.substring(prefix.length);
      cursorChange = -prefix.length;
    } else {
      // Add prefix
      newLine = prefix + line;
      cursorChange = prefix.length;
    }

    // Calculate offset for this line
    int lineStartOffset = 0;
    for (int i = 0; i < lineIndex; i++) {
      lineStartOffset += codeLines[i].text.length + 1;
    }

    final text = widget.controller.text;
    final beforeLine = text.substring(0, lineStartOffset);
    final afterLine = text.substring(lineStartOffset + line.length);

    widget.controller.text = beforeLine + newLine + afterLine;

    // Update cursor ensuring it stays on the same line and relative position
    // Only update cursor if it was on the modified line
    if (currentSelection.start.index == lineIndex) {
      int newColumn = currentSelection.start.offset + cursorChange;
      if (newColumn < 0) newColumn = 0;

      widget.controller.selection = CodeLineSelection.collapsed(
        index: lineIndex,
        offset: newColumn,
      );
    }
  }

  Future<void> _showHeadingMenu(BuildContext context) async {
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final position = renderBox.localToGlobal(Offset.zero, ancestor: overlay);

    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy + renderBox.size.height,
        position.dx + renderBox.size.width,
        position.dy,
      ),
      items: [
        const PopupMenuItem(value: '# ', child: Text('# Heading 1')),
        const PopupMenuItem(value: '## ', child: Text('## Heading 2')),
        const PopupMenuItem(value: '### ', child: Text('### Heading 3')),
        const PopupMenuItem(value: '#### ', child: Text('#### Heading 4')),
        const PopupMenuItem(value: '##### ', child: Text('##### Heading 5')),
        const PopupMenuItem(value: '###### ', child: Text('###### Heading 6')),
      ],
    );

    if (result != null) {
      _insertAtLineStart(result);
    }
  }

  Future<void> _showCheckboxMenu(BuildContext context) async {
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final position = renderBox.localToGlobal(Offset.zero, ancestor: overlay);

    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy + renderBox.size.height,
        position.dx + renderBox.size.width,
        position.dy,
      ),
      items: [
        const PopupMenuItem(value: '- [ ] ', child: Text('☐ Unchecked')),
        const PopupMenuItem(value: '- [x] ', child: Text('☑ Checked')),
      ],
    );

    if (result != null) {
      _insertAtLineStart(result);
    }
  }

  void _insertAtLineStart(String prefix) {
    final sel = widget.controller.selection;
    final codeLines = widget.controller.value.codeLines;

    if (sel.start == sel.end) {
      // Insert at current line start
      final lineIndex = sel.start.index;
      if (lineIndex >= codeLines.length) return;
      _toggleLinePrefix(lineIndex, prefix);
    } else {
      // Insert at start of each selected line
      for (int i = sel.start.index; i <= sel.end.index; i++) {
        _toggleLinePrefix(i, prefix);
      }
    }
  }

  Future<void> _insertLink() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final link = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.addLink),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: 'URL',
            hintText: 'https://example.com',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    if (link != null && link.isNotEmpty) {
      final sel = widget.controller.selection;
      final codeLines = widget.controller.value.codeLines;
      final startOff = _getOffsetForPosition(codeLines, sel.start);
      final endOff = _getOffsetForPosition(codeLines, sel.end);
      final text = widget.controller.text;
      final selectedText = text.substring(startOff, endOff);

      if (selectedText.isEmpty) {
        _insertText('[$link]($link)');
      } else {
        _insertText('[$selectedText]($link)');
      }
    }
  }
}
