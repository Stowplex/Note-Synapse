import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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

import '../l10n/app_localizations.dart';
import '../services/editor_navigation_settings_service.dart';
import 'editor_navigation_pad.dart';

class SynapseCodeEditor extends StatefulWidget {
  final CodeLineEditingController controller;
  final FocusNode? focusNode;
  final bool readOnly;
  final List<Widget>? actions;
  final bool wordWrap;
  final double fontSize;
  final String fontFamily;
  final String? language;

  const SynapseCodeEditor({
    super.key,
    required this.controller,
    this.focusNode,
    this.readOnly = false,
    this.actions,
    this.wordWrap = false,
    this.fontSize = 12.0,
    this.fontFamily = 'monospace',
    this.language,
  });

  @override
  State<SynapseCodeEditor> createState() => _SynapseCodeEditorState();
}

class _SynapseCodeEditorState extends State<SynapseCodeEditor> {
  late final CodeFindController _findController;
  late final MobileSelectionToolbarController _mobileToolbarController;
  bool _isSearchVisible = false;
  /// Whether the pad is switched on at all. Persisted, so dismissing it from
  /// the toolbar or its own close button turns it off for good rather than for
  /// one session. Starts false and is only trusted once the stored value has
  /// loaded, so a pad the user turned off cannot flash up in the meantime.
  bool _padEnabled = false;
  bool _keyboardOpen = false;

  /// Supplied by the caller when there is one, ours otherwise. The pad needs a
  /// focus node to know when to reset its granularity dial, and
  /// `user_app_edit_screen` does not pass one.
  late FocusNode _focusNode;
  bool _ownsFocusNode = false;

  /// The pad is for editing, so it appears when this editor is being edited —
  /// which on a phone means the soft keyboard is up, and elsewhere means the
  /// editor holds focus.
  bool get _isPadVisible =>
      _padEnabled && !widget.readOnly && (_keyboardOpen || _focusNode.hasFocus);

  late final ValueNotifier<bool> _hasSelectionNotifier;

  @override
  void initState() {
    super.initState();
    _findController = CodeFindController(widget.controller);
    _mobileToolbarController = MobileSelectionToolbarController(
      builder: _buildMobileToolbar,
    );
    _isSearchVisible = false;
    _focusNode = widget.focusNode ?? FocusNode();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode.addListener(_onFocusChanged);
    _loadPadPreference();
    _hasSelectionNotifier = ValueNotifier(
      !widget.controller.selection.isCollapsed,
    );
    widget.controller.addListener(_onCodeControllerChanged);
  }

  @override
  void didUpdateWidget(SynapseCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(_onCodeControllerChanged);
      widget.controller.addListener(_onCodeControllerChanged);
      _onCodeControllerChanged();
    }
    if (widget.focusNode != oldWidget.focusNode) {
      _focusNode.removeListener(_onFocusChanged);
      if (_ownsFocusNode) _focusNode.dispose();
      _focusNode = widget.focusNode ?? FocusNode();
      _ownsFocusNode = widget.focusNode == null;
      _focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    _findController.dispose();
    _focusNode.removeListener(_onFocusChanged);
    if (_ownsFocusNode) _focusNode.dispose();
    widget.controller.removeListener(_onCodeControllerChanged);
    _hasSelectionNotifier.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadPadPreference() async {
    final enabled = await EditorNavigationSettingsService.isPadVisible();
    if (mounted && enabled != _padEnabled) {
      setState(() => _padEnabled = enabled);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (keyboardOpen != _keyboardOpen) {
      setState(() => _keyboardOpen = keyboardOpen);
    }
  }

  Future<void> _setPadVisible(bool visible) async {
    setState(() => _padEnabled = visible);
    await EditorNavigationSettingsService.setPadVisible(visible);
  }

  void _onCodeControllerChanged() {
    final hasSelection = !widget.controller.selection.isCollapsed;
    if (hasSelection != _hasSelectionNotifier.value) {
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _hasSelectionNotifier.value = hasSelection;
        });
      } else {
        if (mounted) _hasSelectionNotifier.value = hasSelection;
      }
    }
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

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null) {
      final text = data.text!;
      // First delete any selection
      if (!widget.controller.selection.isCollapsed) {
        final codeLines = widget.controller.value.codeLines;
        _deleteSelection(codeLines, widget.controller.selection);
      }

      // Now insert at cursor
      final selection = widget.controller.selection;
      // We must get the updated codelines after deletion
      final codeLines = widget.controller.value.codeLines;

      final insertionIndex = selection.startIndex;
      final insertionOffset = selection.startOffset;

      // If paste contains newlines
      final newLines = text.split('\n');

      // Construct the new list of lines
      final List<String> lines = [];
      for (int i = 0; i < codeLines.length; i++) {
        lines.add(codeLines[i].text);
      }

      // If lineIndex is out of bounds (empty file?), handle it
      if (lines.isEmpty) {
        widget.controller.text = text;
        return;
      }

      if (insertionIndex < lines.length) {
        final lineContent = lines[insertionIndex];
        final prefix = lineContent.substring(0, insertionOffset);
        final suffix = lineContent.substring(insertionOffset);

        if (newLines.length == 1) {
          lines[insertionIndex] = prefix + newLines[0] + suffix;
        } else {
          lines[insertionIndex] = prefix + newLines.first;
          for (int i = 1; i < newLines.length - 1; i++) {
            lines.insert(insertionIndex + i, newLines[i]);
          }
          lines.insert(
            insertionIndex + newLines.length - 1,
            newLines.last + suffix,
          );
        }

        widget.controller.text = lines.join('\n');

        // Update cursor
        final endLineIndex = insertionIndex + newLines.length - 1;

        // Clean logic for offset:
        // The last line becomes: prefix + newLines[0] + suffix (if 1 line)
        // OR: newLines.last + suffix (if multiline).
        // Wait. if multiline:
        // Line N (insertionIndex): prefix + newLines.first
        // Line N+M (end): newLines.last + suffix
        // Cursor should be at end of pasted text.
        // So cursor is at: length of newLines.last.
        // wait. The last line content is `newLines.last + suffix`.
        // The cursor should be BEFORE `suffix`.
        // So offset is `newLines.last.length`.

        widget.controller.selection = CodeLineSelection.collapsed(
          index: endLineIndex,
          offset: newLines.length == 1
              ? insertionOffset + text.length
              : newLines.last.length,
        );
      }
    }
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
          CodeEditorTapRegion(
            child: Container(
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
                      icon: const Icon(Icons.paste, size: 20),
                      onPressed: _paste,
                      tooltip: 'Paste',
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: _hasSelectionNotifier,
                      builder: (context, hasSelection, child) {
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (hasSelection) ...[
                              IconButton(
                                icon: const Icon(Icons.content_cut, size: 20),
                                onPressed: _cutSelectedText,
                                tooltip: 'Cut',
                              ),
                              IconButton(
                                icon: const Icon(Icons.copy, size: 20),
                                onPressed: _copySelectedText,
                                tooltip: 'Copy',
                              ),
                            ],
                            IconButton(
                              icon: const Icon(Icons.select_all, size: 20),
                              onPressed: _selectAll,
                              tooltip: 'Select All',
                            ),
                          ],
                        );
                      },
                    ),
                    IconButton(
                      icon: Icon(
                        _isSearchVisible ? Icons.search_off : Icons.search,
                        size: 20,
                      ),
                      onPressed: _toggleSearch,
                      tooltip: _isSearchVisible ? 'Hide Search' : 'Show Search',
                    ),
                    IconButton(
                      icon: Icon(
                        _padEnabled ? Icons.unfold_less : Icons.open_with,
                        size: 20,
                        color: _padEnabled ? theme.colorScheme.primary : null,
                      ),
                      onPressed: () => _setPadVisible(!_padEnabled),
                      tooltip: _padEnabled
                          ? AppLocalizations.of(context)!.navPadHide
                          : AppLocalizations.of(context)!.navPadShow,
                    ),
                    if (widget.actions != null &&
                        widget.actions!.isNotEmpty) ...[
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
          ),

        // Search Bar (conditionally visible)
        if (_isSearchVisible)
          CodeEditorTapRegion(child: _buildSearchBar(context)),

        Expanded(
          child: Stack(
            children: [
              Builder(
                builder: (context) {
                  final Map<String, CodeHighlightThemeMode> allLanguages = {
                    'markdown': CodeHighlightThemeMode(mode: langMarkdown),
                    'dart': CodeHighlightThemeMode(mode: langDart),
                    'json': CodeHighlightThemeMode(mode: langJson),
                    'xml': CodeHighlightThemeMode(mode: langXml),
                    'yaml': CodeHighlightThemeMode(mode: langYaml),
                    'javascript': CodeHighlightThemeMode(mode: langJavascript),
                    'css': CodeHighlightThemeMode(mode: langCss),
                  };

                  CodeHighlightTheme codeTheme;
                  if (widget.language != null &&
                      allLanguages.containsKey(widget.language)) {
                    codeTheme = CodeHighlightTheme(
                      languages: {
                        widget.language!: allLanguages[widget.language]!,
                      },
                      theme: style,
                    );
                  } else {
                    codeTheme = CodeHighlightTheme(
                      languages: allLanguages,
                      theme: style,
                    );
                  }

                  return CodeEditor(
                    controller: widget.controller,
                    focusNode: _focusNode,
                    toolbarController: _mobileToolbarController,
                    style: CodeEditorStyle(
                      fontSize: widget.fontSize,
                      fontFamily: widget.fontFamily,
                      codeTheme: codeTheme,
                    ),
                    wordWrap: widget.wordWrap,
                    findController: _findController,
                    readOnly: widget.readOnly,
                  );
                },
              ),
              if (_isPadVisible)
                EditorNavigationPad(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  onDismiss: () => _setPadVisible(false),
                ),
            ],
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
