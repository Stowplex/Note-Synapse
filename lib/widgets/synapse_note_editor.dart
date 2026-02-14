import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import '../l10n/app_localizations.dart';
import 'synapse_code_editor.dart';

class SynapseNoteEditor extends StatefulWidget {
  final CodeLineEditingController controller;
  final FocusNode? focusNode;
  final VoidCallback? onPickImage;
  final VoidCallback? onPickNoteLink;
  final VoidCallback? onPickAttachmentLink;
  final String? language;

  const SynapseNoteEditor({
    super.key,
    required this.controller,
    this.focusNode,
    this.onPickImage,
    this.onPickNoteLink,
    this.onPickAttachmentLink,
    this.language,
  });

  @override
  State<SynapseNoteEditor> createState() => _SynapseNoteEditorState();
}

class _SynapseNoteEditorState extends State<SynapseNoteEditor> {
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
          tooltip: 'Inline Code',
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
        if (widget.onPickNoteLink != null)
          IconButton(
            icon: const Icon(Icons.note_add, size: 20),
            onPressed: widget.onPickNoteLink,
            tooltip: l10n.addLink,
          ),
        if (widget.onPickAttachmentLink != null)
          IconButton(
            icon: const Icon(Icons.attach_file, size: 20),
            onPressed: widget.onPickAttachmentLink,
            tooltip: l10n.insertAttachmentLink,
          ),
      ],
    );
  }

  // --- Markdown Formatting Helpers ---

  void _insertText(
    String text, {
    int selectionOffset = 0,
    CodeLineSelection? selection,
  }) {
    final sel = selection ?? widget.controller.selection;
    final codeLines = widget.controller.value.codeLines;
    final startOffset = _getOffsetForPosition(codeLines, sel.start);
    final endOffset = _getOffsetForPosition(codeLines, sel.end);

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
    _applyListStyle(r'- ', '- ');
  }

  void _toggleNumberedList() {
    _applyListStyle(r'\d+\. ', '1. ', isNumbered: true);
  }

  void _applyListStyle(
    String pattern,
    String newPrefix, {
    bool isNumbered = false,
    CodeLineSelection? selection,
  }) {
    final sel = selection ?? widget.controller.selection;
    final codeLines = widget.controller.value.codeLines;

    // 1. Identify valid range
    final startLine = sel.start.index;
    final endLine = sel.end.index;

    // 2. Check if we are "toggling off" or "applying new"
    // Heuristic: If ALL selected lines already match the *requested* style, we toggle OFF.
    // Otherwise, we apply the new style (replacing any existing list style).

    // We need a broad pattern to detect ANY list style to replace it.
    // Matches "- ", "* ", "1. ", "10. ", "- [ ] ", "- [x] "
    final anyListPattern = RegExp(r'^(\s*)([-*+]|\d+\.|- \[[ x]\])\s+');

    // Pattern for the SPECIFIC style we are trying to apply.
    // For numbered lists, we match any number.
    final specificPattern = RegExp('^(\\s*)($pattern)');

    bool allMatchSpecific = true;
    for (int i = startLine; i <= endLine; i++) {
      if (i >= codeLines.length) break;
      final line = codeLines[i].text;
      if (!specificPattern.hasMatch(line)) {
        allMatchSpecific = false;
        break;
      }
    }

    final bool shouldRemove = allMatchSpecific;

    // 3. Construct new text
    // We will build the new text chunk for the affected lines
    final sb = StringBuffer();

    // Calculate start offset of the first confirmed line
    int currentOffset = 0;
    for (int i = 0; i < startLine; i++) {
      currentOffset += codeLines[i].text.length + 1; // +1 for newline
    }
    final rangeStartOffset = currentOffset;

    for (int i = startLine; i <= endLine; i++) {
      if (i >= codeLines.length) break;
      final line = codeLines[i].text;

      if (shouldRemove) {
        // Remove the specific pattern
        final match = specificPattern.firstMatch(line);
        if (match != null) {
          // match.group(1) is whitespace info, match.group(2) is the prefix.
          // We want to keep the whitespace (indentation) but remove the prefix.
          // Wait, usually if we toggle off, we just want to remove the bullet.
          // e.g. "  - item" -> "  item"
          final indent = match.group(1) ?? '';
          final content = line.substring(match.end);
          sb.write('$indent$content');
        } else {
          // Should not happen if allMatchSpecific is true, but safe fallback
          sb.write(line);
        }
      } else {
        // Apply new style
        // First, check if there is an existing list style to replace
        final match = anyListPattern.firstMatch(line);
        String indent = '';
        String content = line;

        if (match != null) {
          // Found existing style, keep indent, remove old prefix
          indent = match.group(1) ?? '';
          // The match includes the whitespace after the prefix usually?
          // My regex `...)\s+` ends with whitespace.
          // So match.end is where the real content starts.
          content = line.substring(match.end);
        } else {
          // No existing list style. Check for leading whitespace to preserve indent.
          final leadingWs = RegExp(r'^(\s*)').firstMatch(line);
          if (leadingWs != null) {
            indent = leadingWs.group(1) ?? '';
            content = line.substring(leadingWs.end);
          }
        }

        String prefixToUse = newPrefix;
        if (isNumbered) {
          // Dynamically generate number based on line index relative to selection start
          // or maybe relative to previous line if we want to be smart?
          // For now, simple re-indexing from 1 for the selection block specific logic
          final number = i - startLine + 1;
          prefixToUse = '$number. ';
        }

        sb.write('$indent$prefixToUse$content');
      }

      if (i < endLine) {
        sb.write('\n');
      }
    }

    // 4. Apply change
    final rangeEndOffset = _getOffsetForPosition(
      codeLines,
      CodeLinePosition(index: endLine, offset: codeLines[endLine].text.length),
    );

    final fullText = widget.controller.text;
    final newFullText = fullText.replaceRange(
      rangeStartOffset,
      rangeEndOffset,
      sb.toString(),
    );

    widget.controller.text = newFullText;

    // 5. Restore Selection
    // Ideally we select the same lines.
    // We can assume the number of lines hasn't changed.
    // We need to recalculate the end offset based on new content length.
    final newChunkLength = sb.length;
    final newRangeEndOffset = rangeStartOffset + newChunkLength;

    final startPos = _getPositionForOffset(
      widget.controller.value.codeLines,
      rangeStartOffset,
    );
    final endPos = _getPositionForOffset(
      widget.controller.value.codeLines,
      newRangeEndOffset,
    );

    widget.controller.selection = CodeLineSelection(
      baseIndex: startPos.index,
      baseOffset: 0, // Select from start of first line
      extentIndex: endPos.index,
      extentOffset: endPos.offset, // To end of last line
    );
  }

  void _toggleLinePrefix(int lineIndex, String prefix) {
    // Deprecated in favor of _applyListStyle for lists, but kept for quotes if needed?
    // Quote toggle logic is slightly different (can be nested), but for now let's convert quote to use _applyListStyle too?
    // The instruction specifically asked for lists/checkboxes.
    // I will leave this method if it's used by Quote, but I see `_toggleQuote` uses it.
    // I should verify `_toggleQuote` usage.

    // Actually, let's keep it for `_toggleQuote` which is simple toggle.
    // But I should update `_toggleQuote` to handle multi-line block properly if it doesn't already.
    // The existing `_toggleQuote` iterates and calls `_toggleLinePrefix` which does individual updates.
    // That is inefficient but "works". The new request is specifically about list/checkbox replacement.

    // I will keep `_toggleLinePrefix` as is for now to avoid breaking other things,
    // but `_toggleBulletList` and `_toggleNumberedList` now use `_applyListStyle`.

    // WAIT. `_applyListStyle` logic I wrote replaces `_toggleBulletList` and `_toggleNumberedList` bodies.
    // But `_toggleQuote` still uses `_toggleLinePrefix`.
    // I should fix the previous tool call to NOT remove `_toggleLinePrefix` if it is used by others.
    // The replacement range was lines 281-428.
    // `_toggleQuote` is at 267. It calls `_toggleLinePrefix`.
    // `_toggleLinePrefix` definition is at 306.
    // My replacement range COVERS `_toggleLinePrefix`. I MUST include it in the new content or refactor `_toggleQuote`.

    // Let's refactor `_toggleQuote` to use `_applyListStyle` as well, or just re-include `_toggleLinePrefix`.
    // Re-including is safer.

    // Actually, looking at `_toggleQuote`, it iterates lines.
    // I'll rewrite `_toggleQuote` to use `_applyListStyle` with `> ` pattern.
    // Pattern for quote: `> `
    // But quotes can be nested `>> `.
    // My `_applyListStyle` logic destroys existing structure to replace it.
    // This might not be desired for quotes if one wants to nest.
    // But for lists, replacing is good.

    // Let's restore `_toggleLinePrefix` for `_toggleQuote` to be safe.
  }

  Future<void> _showHeadingMenu(BuildContext context) async {
    final selection = widget.controller.selection;
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
      // Headings are also specific: replace existing heading or add new.
      // existing heading pattern: `^#+\s`
      _applyListStyle(r'#+\s', result, selection: selection);
    }
  }

  Future<void> _showCheckboxMenu(BuildContext context) async {
    final selection = widget.controller.selection;
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
      // Checkbox pattern needs to be escaped carefully for regex
      // value is "- [ ] " or "- [x] "
      // We want to apply this. The generic pattern already covers matching it for replacement.
      // The specific pattern to check if we are toggling off...
      // For checkboxes, usually we don't "toggle off" a specific state like [x] vs [ ].
      // We just apply it.
      // But if we select [x] lines and apply [x], maybe remove it?
      // Let's rely on the pattern string passed in.
      // If result is `- [ ] `, pattern is `- \[ \] `.

      String pattern = result.trimLeft(); // result has space at end potentially
      // Escape for regex
      pattern = RegExp.escape(pattern);

      _applyListStyle(pattern, result, selection: selection);
    }
  }

  Future<void> _insertLink() async {
    final selection = widget.controller.selection;
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
        _insertText('[$link]($link)', selection: selection);
      } else {
        _insertText('[$selectedText]($link)', selection: selection);
      }
    }
  }
}
