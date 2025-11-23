import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/css.dart';

class SynapseCodeEditor extends StatefulWidget {
  final CodeLineEditingController controller;
  final FocusNode? focusNode;
  final bool readOnly;
  final List<Widget>? actions;
  final bool wordWrap;

  const SynapseCodeEditor({
    super.key,
    required this.controller,
    this.focusNode,
    this.readOnly = false,
    this.actions,
    this.wordWrap = false,
  });

  @override
  State<SynapseCodeEditor> createState() => _SynapseCodeEditorState();
}

class _SynapseCodeEditorState extends State<SynapseCodeEditor> {
  late final CodeFindController _findController;
  late final MobileSelectionToolbarController _mobileToolbarController;
  bool _isSearchVisible = false;

  @override
  void initState() {
    super.initState();
    _findController = CodeFindController(widget.controller);
    _mobileToolbarController = MobileSelectionToolbarController(
      builder: _buildMobileToolbar,
    );
    _isSearchVisible = false;
  }

  @override
  void didUpdateWidget(SynapseCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    _findController.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _isSearchVisible = !_isSearchVisible;
    });
    if (_isSearchVisible) {
      _findController.findMode();
    } else {
      _findController.close();
    }
  }

  void _undo() {
    widget.controller.undo();
  }

  void _redo() {
    widget.controller.redo();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final style = isDark ? atomOneDarkTheme : atomOneLightTheme;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top Toolbar
        if (!widget.readOnly)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                bottom: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.undo, size: 20),
                    onPressed: _undo,
                    tooltip: 'Undo',
                  ),
                  IconButton(
                    icon: const Icon(Icons.redo, size: 20),
                    onPressed: _redo,
                    tooltip: 'Redo',
                  ),
                  IconButton(
                    icon: Icon(
                      _isSearchVisible ? Icons.search_off : Icons.search,
                      size: 20,
                    ),
                    onPressed: _toggleSearch,
                    tooltip: _isSearchVisible ? 'Hide Search' : 'Show Search',
                  ),
                  if (widget.actions != null && widget.actions!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Container(
                      height: 24,
                      width: 1,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    const SizedBox(width: 8),
                    ...widget.actions!,
                  ],
                ],
              ),
            ),
          ),

        // Search Bar (conditionally visible)
        if (_isSearchVisible) _buildSearchBar(context),

        Expanded(
          child: CodeEditor(
            controller: widget.controller,
            focusNode: widget.focusNode,
            toolbarController: _mobileToolbarController,
            style: CodeEditorStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              codeTheme: CodeHighlightTheme(
                languages: {
                  'markdown': CodeHighlightThemeMode(mode: langMarkdown),
                  'dart': CodeHighlightThemeMode(mode: langDart),
                  'json': CodeHighlightThemeMode(mode: langJson),
                  'xml': CodeHighlightThemeMode(mode: langXml),
                  'yaml': CodeHighlightThemeMode(mode: langYaml),
                  'javascript': CodeHighlightThemeMode(mode: langJavascript),
                  'css': CodeHighlightThemeMode(mode: langCss),
                },
                theme: style,
              ),
            ),
            wordWrap: widget.wordWrap,
            findController: _findController,
            readOnly: widget.readOnly,
          ),
        ),
      ],
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(8),
      color: theme.colorScheme.surface,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _findController.findInputController,
                decoration: const InputDecoration(
                  hintText: 'Find...',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
                style: theme.textTheme.bodyMedium,
                onSubmitted: (_) => _findController.nextMatch(),
              ),
            ),
            // Match counter
            ValueListenableBuilder<CodeFindValue?>(
              valueListenable: _findController,
              builder: (context, findValue, child) {
                final allMatches = _findController.allMatchSelections;
                final currentMatch = _findController.currentMatchSelection;

                if (allMatches == null || allMatches.isEmpty) {
                  return const SizedBox.shrink();
                }

                // Find current match index
                int currentIndex = 0;
                if (currentMatch != null) {
                  currentIndex = allMatches.indexOf(currentMatch) + 1;
                }

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '$currentIndex / ${allMatches.length}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_up, size: 20),
              onPressed: () => _findController.previousMatch(),
              tooltip: 'Previous',
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down, size: 20),
              onPressed: () => _findController.nextMatch(),
              tooltip: 'Next',
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: _toggleSearch,
              tooltip: 'Close',
            ),
          ],
        ),
      ),
    );
  }

  // Mobile toolbar for text selection
  Widget _buildMobileToolbar({
    required BuildContext context,
    required TextSelectionToolbarAnchors anchors,
    required CodeLineEditingController controller,
    required VoidCallback onDismiss,
    required VoidCallback onRefresh,
  }) {
    final hasSelection = !controller.selection.isCollapsed;

    return Align(
      alignment: Alignment.center,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: hasSelection ? 140 : 100,
          height: 40,
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (hasSelection && !widget.readOnly)
                _buildCompactToolbarButton(
                  context: context,
                  icon: Icons.content_cut,
                  onPressed: () {
                    _cutSelectedText();
                    onDismiss();
                    onRefresh();
                  },
                ),
              if (hasSelection)
                _buildCompactToolbarButton(
                  context: context,
                  icon: Icons.copy,
                  onPressed: () {
                    _copySelectedText();
                    onDismiss();
                  },
                ),
              _buildCompactToolbarButton(
                context: context,
                icon: Icons.select_all,
                onPressed: () {
                  _selectAll();
                  onRefresh();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactToolbarButton({
    required BuildContext context,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: 40,
      height: 32,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.all(4),
          child: Icon(
            icon,
            size: 16,
            color: onPressed != null
                ? Theme.of(context).textTheme.bodyMedium?.color
                : Theme.of(context).disabledColor,
          ),
        ),
      ),
    );
  }

  void _copySelectedText() {
    final selection = widget.controller.selection;
    if (!selection.isCollapsed) {
      final codeLines = widget.controller.value.codeLines;
      final selectedText = _getSelectedTextFromCodeLines(codeLines, selection);
      Clipboard.setData(ClipboardData(text: selectedText));
    }
  }

  void _cutSelectedText() {
    final selection = widget.controller.selection;
    if (!selection.isCollapsed) {
      final codeLines = widget.controller.value.codeLines;
      final selectedText = _getSelectedTextFromCodeLines(codeLines, selection);
      Clipboard.setData(ClipboardData(text: selectedText));
      _deleteSelection(codeLines, selection);
    }
  }

  void _selectAll() {
    final codeLines = widget.controller.value.codeLines;
    if (codeLines.isNotEmpty) {
      widget.controller.selection = CodeLineSelection(
        baseIndex: 0,
        baseOffset: 0,
        extentIndex: codeLines.length - 1,
        extentOffset: codeLines.last.length,
      );
    }
  }

  String _getSelectedTextFromCodeLines(
    CodeLines codeLines,
    CodeLineSelection selection,
  ) {
    final startIndex = selection.startIndex;
    final endIndex = selection.endIndex;
    final startOffset = selection.startOffset;
    final endOffset = selection.endOffset;

    if (startIndex == endIndex) {
      return codeLines[startIndex].text.substring(startOffset, endOffset);
    } else {
      final buffer = StringBuffer();
      buffer.write(codeLines[startIndex].text.substring(startOffset));
      for (int i = startIndex + 1; i < endIndex; i++) {
        buffer.write('\n');
        buffer.write(codeLines[i].text);
      }
      if (endIndex < codeLines.length) {
        buffer.write('\n');
        buffer.write(codeLines[endIndex].text.substring(0, endOffset));
      }
      return buffer.toString();
    }
  }

  void _deleteSelection(CodeLines codeLines, CodeLineSelection selection) {
    final startIndex = selection.startIndex;
    final endIndex = selection.endIndex;
    final startOffset = selection.startOffset;
    final endOffset = selection.endOffset;

    final newLines = <String>[];
    for (int i = 0; i < codeLines.length; i++) {
      if (i < startIndex || i > endIndex) {
        newLines.add(codeLines[i].text);
      } else if (i == startIndex && i == endIndex) {
        newLines.add(
          codeLines[i].text.substring(0, startOffset) +
              codeLines[i].text.substring(endOffset),
        );
      } else if (i == startIndex) {
        newLines.add(codeLines[i].text.substring(0, startOffset));
      } else if (i == endIndex) {
        final lastLineIndex = newLines.length - 1;
        newLines[lastLineIndex] += codeLines[i].text.substring(endOffset);
      }
    }

    widget.controller.text = newLines.join('\n');
    widget.controller.selection = CodeLineSelection.collapsed(
      index: startIndex,
      offset: startOffset,
    );
  }
}
