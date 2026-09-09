import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import '../l10n/app_localizations.dart';
import '../services/editor_navigation_settings_service.dart';
import '../utils/markdown_navigation.dart';
import '../utils/markdown_semantic_selection.dart';

/// A nine-key cursor pad: four arrows choose direction, four corners choose
/// distance, and the centre switches between moving and selecting.
///
/// The corners are a radio group over [NavGranularity], which is what lets nine
/// keys cover sixteen motions — every direction combines with every unit. That
/// second piece of state is only affordable because it is permanently visible:
/// the lit corner, the status chip and the transient motion label are the
/// feature, not decoration.
///
/// Motion never goes through `re_editor`'s word API, which raises `RangeError`
/// on ordinary markdown; see [MarkdownNavigation].
class EditorNavigationPad extends StatefulWidget {
  final CodeLineEditingController controller;
  final FocusNode? focusNode;

  /// Called when the user dismisses the pad from its own close affordance.
  final VoidCallback? onDismiss;

  const EditorNavigationPad({
    super.key,
    required this.controller,
    this.focusNode,
    this.onDismiss,
  });

  /// Stable keys so tests can drive every cell of the dispatch matrix.
  static Key unitKeyOf(NavGranularity unit) =>
      ValueKey('nav_pad_unit_${unit.name}');
  static Key arrowKeyOf(AxisDirection direction) =>
      ValueKey('nav_pad_arrow_${direction.name}');
  static const Key modeKey = ValueKey('nav_pad_mode');
  static const Key dragHandleKey = ValueKey('nav_pad_drag_handle');

  @override
  State<EditorNavigationPad> createState() => _EditorNavigationPadState();
}

class _EditorNavigationPadState extends State<EditorNavigationPad> {
  /// How long a key must be held before it starts repeating.
  static const int _initialDelayMs = 400;

  /// The repeat period at the start of a hold, and the floor it decays to.
  static const int _slowPeriodMs = 120;
  static const int _fastPeriodMs = 45;

  /// How long the hold takes to reach [_fastPeriodMs].
  static const int _accelerationMs = 1000;

  /// One haptic tick at most this often, so a fast repeat does not buzz.
  static const int _hapticIntervalMs = 60;

  /// How long the "what did that key just do" label stays up.
  static const Duration _labelDuration = Duration(milliseconds: 700);

  /// How long the pad waits before fading out of the way.
  static const Duration _idleDelay = Duration(seconds: 2);

  NavGranularity _unit = NavGranularity.char;
  bool _selectionMode = false;
  bool _onLeft = false;
  bool _idle = false;
  String? _motionLabel;

  Timer? _repeatTimer;

  /// Set when something cancels the hold from *inside* the repeated action.
  /// Cancelling the timer cannot work there — it has already fired — so the
  /// re-arm sites have to consult this instead.
  bool _repeatCancelled = false;
  Timer? _labelTimer;
  Timer? _idleTimer;
  int _heldMs = 0;
  DateTime? _lastHaptic;

  final SemanticSelectionHistory<CodeLineSelection> _history =
      SemanticSelectionHistory<CodeLineSelection>();

  /// Bumped on every status change so the label's AnimatedSwitcher never sees
  /// the same key twice; keying by the label text made repeated labels collide
  /// and threw "Duplicate keys found".
  int _statusSeq = 0;

  @override
  void initState() {
    super.initState();
    _loadSide();
    _restartIdleTimer();
    widget.controller.addListener(_onControllerChanged);
    widget.focusNode?.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(EditorNavigationPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      // A different document is a different context, so the dial goes home and
      // the ladder is forgotten. Without the clear, a shrink would assign a
      // selection from the old document to the new one — and a line index past
      // its end makes re_editor throw on the next motion or paint.
      _history.clear();
      _stopRepeat();
      _resetUnit();
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_onFocusChanged);
      widget.focusNode?.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    _repeatTimer?.cancel();
    _labelTimer?.cancel();
    _idleTimer?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    widget.focusNode?.removeListener(_onFocusChanged);
    super.dispose();
  }

  Future<void> _loadSide() async {
    final onLeft = await EditorNavigationSettingsService.isPadOnLeft();
    if (mounted && onLeft != _onLeft) {
      setState(() => _onLeft = onLeft);
    }
  }

  void _onFocusChanged() {
    // Stale granularity must never survive a context change: coming back to the
    // editor later and finding `block` still lit is exactly the trap a modal
    // dial is accused of.
    if (widget.focusNode?.hasFocus == false) _resetUnit();
  }

  void _onControllerChanged() {
    // Guard first: `controller.text` rebuilds the whole document, and this runs
    // on every keystroke.
    if (_history.isEmpty) return;
    _history.invalidateIfForeign(
      text: widget.controller.text,
      current: widget.controller.selection,
    );
  }

  void _resetUnit() {
    if (!mounted || _unit == NavGranularity.char) return;
    setState(() => _unit = NavGranularity.char);
  }

  // ---------------------------------------------------------------------------
  // Motion — the 4 x 4 matrix
  // ---------------------------------------------------------------------------

  /// Applies one step in [direction] using the lit granularity.
  void _move(AxisDirection direction) {
    final before = widget.controller.selection;
    final horizontal =
        direction == AxisDirection.left || direction == AxisDirection.right;
    final forward =
        direction == AxisDirection.right || direction == AxisDirection.down;

    switch (_unit) {
      case NavGranularity.char:
        _stepChar(direction);
      case NavGranularity.token:
        if (horizontal) {
          _stepToken(forward);
        } else {
          // "One token up" has no meaning, so the vertical axis has three rungs
          // rather than four and this cell collapses onto `char`.
          _stepChar(direction);
        }
      case NavGranularity.line:
        if (horizontal) {
          _stepLineEdge(forward);
        } else {
          _stepLogicalLine(forward);
        }
      case NavGranularity.block:
        if (horizontal) {
          _stepBlockEdge(forward);
        } else {
          _stepBlockLine(forward);
        }
    }
    if (widget.controller.selection == before) {
      // Nothing moved — the cursor is parked at a document or block edge.
      // Ending the hold beats buzzing once per 60 ms and re-scanning the
      // document on every tick for a step that cannot happen.
      _stopRepeat();
      return;
    }
    _afterMotion(_motionLabelFor(direction));
  }

  /// `char` — delegated to the controller, which is wrap-aware, grapheme-aware
  /// and scrolls the cursor back into view. The pad's old hand-rolled version
  /// was none of those things.
  void _stepChar(AxisDirection direction) {
    if (_selectionMode) {
      widget.controller.extendSelection(direction);
    } else {
      widget.controller.moveCursor(direction);
    }
  }

  void _stepToken(bool forward) {
    final controller = widget.controller;
    final selection = controller.selection;
    final lines = controller.codeLines;
    var index = selection.extentIndex;
    final line = lines[index].text;
    final offset = selection.extentOffset;

    if (forward) {
      final next = MarkdownNavigation.nextTokenStart(line, offset);
      if (next != null) {
        _applyPosition(index, next);
        return;
      }
      // No token left on this line: carry on into the next one rather than
      // stalling, which is what makes a held key cross a paragraph.
      if (offset < line.length) {
        _applyPosition(index, line.length);
        return;
      }
      if (index + 1 >= lines.length) return;
      index += 1;
      final nextLine = lines[index].text;
      _applyPosition(
        index,
        MarkdownNavigation.nextTokenStart(nextLine, -1) ?? 0,
      );
    } else {
      final previous = MarkdownNavigation.previousTokenStart(line, offset);
      if (previous != null) {
        _applyPosition(index, previous);
        return;
      }
      if (offset > 0) {
        _applyPosition(index, 0);
        return;
      }
      if (index == 0) return;
      index -= 1;
      final previousLine = lines[index].text;
      final last = MarkdownNavigation.previousTokenStart(
        previousLine,
        previousLine.length,
      );
      _applyPosition(index, last ?? previousLine.length);
    }
  }

  /// `line` horizontally — `^` and `$`.
  ///
  /// Hand-written rather than delegated, because re_editor's two halves
  /// disagree: `moveCursorToLineStart` toggles between the first non-space and
  /// column 0, but `extendSelectionToLineStart` is a bare `extentOffset: 0`.
  /// Delegating would make the same key mean two different things depending on
  /// the mode, on every indented list item. Its `_prefixWhitespaceCount` also
  /// counts only U+0020, so tab-indented lines got no toggle at all.
  void _stepLineEdge(bool forward) {
    final controller = widget.controller;
    final selection = controller.selection;
    final index = selection.extentIndex;
    final line = controller.codeLines[index].text;
    if (forward) {
      _applyPosition(index, line.length);
      return;
    }
    final indent = _leadingWhitespace(line);
    _applyPosition(index, selection.extentOffset == indent ? 0 : indent);
  }

  /// `line` vertically — one *logical* line, keeping the column. This is the
  /// escape hatch from a wrapped paragraph that a plain arrow cannot express,
  /// since the arrow deliberately steps by visual line.
  void _stepLogicalLine(bool forward) {
    final controller = widget.controller;
    final selection = controller.selection;
    final lines = controller.codeLines;
    final target = selection.extentIndex + (forward ? 1 : -1);
    if (target < 0 || target >= lines.length) return;
    final offset = math.min(selection.extentOffset, lines[target].text.length);
    _applyPosition(target, offset);
  }

  /// `block` horizontally — the first non-space character of the block's first
  /// line, and the end of its last line.
  void _stepBlockEdge(bool forward) {
    final controller = widget.controller;
    final lines = _CodeLinesView(controller.codeLines);
    final selection = controller.selection;
    final (start, end) = MarkdownNavigation.blockRange(
      lines,
      selection.extentIndex,
    );
    if (forward) {
      _applyPosition(end, lines[end].length);
    } else {
      _applyPosition(start, _indentOf(lines[start]));
    }
  }

  /// `block` vertically — `{` and `}`.
  void _stepBlockLine(bool forward) {
    final controller = widget.controller;
    final lines = _CodeLinesView(controller.codeLines);
    final from = controller.selection.extentIndex;
    final target = forward
        ? MarkdownNavigation.nextBlockLine(lines, from)
        : MarkdownNavigation.previousBlockLine(lines, from);
    if (target == null) {
      // Already at the outermost block: go to the document edge rather than
      // doing nothing, so a held key always terminates somewhere sensible.
      final edge = forward ? lines.length - 1 : 0;
      if (edge == from) return;
      _applyPosition(
        edge,
        forward ? lines[edge].length : _indentOf(lines[edge]),
      );
      return;
    }
    _applyPosition(target, _indentOf(lines[target]));
  }

  /// Moves the cursor, or drags the selection's free end when selection mode is
  /// on. Every non-delegated motion goes through here so the two modes can
  /// never diverge.
  void _applyPosition(int index, int offset) {
    final controller = widget.controller;
    final selection = controller.selection;
    if (_selectionMode) {
      controller.selection = CodeLineSelection(
        baseIndex: selection.baseIndex,
        baseOffset: selection.baseOffset,
        extentIndex: index,
        extentOffset: offset,
      );
    } else {
      controller.selection = CodeLineSelection.collapsed(
        index: index,
        offset: offset,
      );
    }
    controller.makeCursorVisible();
  }

  /// Leading spaces and tabs. Unlike re_editor's version this counts tabs.
  static int _leadingWhitespace(String line) {
    var i = 0;
    while (i < line.length &&
        (line.codeUnitAt(i) == 0x20 || line.codeUnitAt(i) == 0x09)) {
      i++;
    }
    return i;
  }

  /// Where a block motion should land on [line]: its first real character, or
  /// column 0 when the line holds nothing but whitespace.
  static int _indentOf(String line) {
    final indent = _leadingWhitespace(line);
    return indent == line.length ? 0 : indent;
  }

  // ---------------------------------------------------------------------------
  // Expand / shrink
  // ---------------------------------------------------------------------------

  /// Grows the selection one semantic rung, starting from the lit granularity:
  /// with `block` lit the first press takes the whole block.
  void _expand() {
    final controller = widget.controller;
    final text = controller.text;
    final selection = controller.selection;
    final start = _absoluteOffset(
      text,
      selection.startIndex,
      selection.startOffset,
    );
    final end = _absoluteOffset(text, selection.endIndex, selection.endOffset);

    final next = MarkdownSemanticSelection.expand(
      text,
      start,
      end,
      floor: _unit,
    );
    if (next == null) {
      _feedback();
      return;
    }
    _applyAbsoluteSelection(text, next.start, next.end, replaced: selection);
    _afterMotion(AppLocalizations.of(context)!.navPadLabelExpand);
  }

  /// Puts back the selection the last [_expand] replaced.
  void _shrink() {
    final previous = _history.shrink(text: widget.controller.text);
    if (previous == null) {
      _feedback();
      return;
    }
    widget.controller.selection = previous;
    widget.controller.makeCursorVisible();
    _afterMotion(AppLocalizations.of(context)!.navPadLabelShrink);
  }

  void _applyAbsoluteSelection(
    String text,
    int start,
    int end, {
    required CodeLineSelection replaced,
  }) {
    final controller = widget.controller;
    final from = _positionFor(text, start);
    final to = _positionFor(text, end);
    final selection = CodeLineSelection(
      baseIndex: from.$1,
      baseOffset: from.$2,
      extentIndex: to.$1,
      extentOffset: to.$2,
    );
    // Record before assigning: the controller notifies synchronously, and
    // [_onControllerChanged] would otherwise see a selection it does not
    // recognise and discard the entry just pushed.
    _history.record(previous: replaced, result: selection, text: text);
    controller.selection = selection;
    controller.makeCursorVisible();
    // An expanded selection is a selection, so the pad's mode follows it and
    // the arrows keep adjusting rather than collapsing what was just selected.
    if (!_selectionMode) setState(() => _selectionMode = true);
  }

  /// Line and column to an absolute offset in [text].
  ///
  /// Walks [text] rather than summing `codeLines[i].length + 1` so that it is
  /// the exact inverse of [_positionFor]. Summing line lengths would also
  /// assume a one-character line break and an un-collapsed document — true
  /// today, but only because nothing configures `TextLineBreak.crlf` or hands
  /// `CodeEditor` a fold gutter.
  static int _absoluteOffset(String text, int index, int offset) {
    if (index <= 0) return offset;
    var line = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) != 0x0A) continue;
      line++;
      if (line == index) return i + 1 + offset;
    }
    return text.length;
  }

  static (int, int) _positionFor(String text, int offset) {
    var line = 0;
    var lineStart = 0;
    for (var i = 0; i < offset && i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        line++;
        lineStart = i + 1;
      }
    }
    return (line, offset - lineStart);
  }

  // ---------------------------------------------------------------------------
  // Key feedback
  // ---------------------------------------------------------------------------

  void _afterMotion(String label) {
    _feedback();
    _restartIdleTimer();
    if (!mounted) return;
    setState(() {
      // Only a *different* label needs a new key. Re-keying an identical one
      // makes AnimatedSwitcher cross-fade the text with itself on every
      // auto-repeat tick, which leaves it dim exactly while it is being read.
      if (_motionLabel != label) _statusSeq++;
      _motionLabel = label;
    });
    _labelTimer?.cancel();
    _labelTimer = Timer(_labelDuration, () {
      if (mounted) setState(() => _motionLabel = null);
    });
  }

  void _feedback() {
    final now = DateTime.now();
    final last = _lastHaptic;
    if (last != null &&
        now.difference(last).inMilliseconds < _hapticIntervalMs) {
      return;
    }
    _lastHaptic = now;
    HapticFeedback.selectionClick();
  }

  void _restartIdleTimer() {
    if (_idle && mounted) setState(() => _idle = false);
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleDelay, () {
      if (mounted) setState(() => _idle = true);
    });
  }

  /// Arrows repeat while held. The *rate* accelerates; the unit never does —
  /// silently promoting `char` to `token` mid-hold would contradict the dial
  /// the user just set.
  void _startRepeat(VoidCallback action) {
    _stopRepeat();
    _repeatCancelled = false;
    _heldMs = 0;
    action();
    if (_repeatCancelled) return;
    _scheduleRepeat(action, const Duration(milliseconds: _initialDelayMs));
  }

  void _scheduleRepeat(VoidCallback action, Duration delay) {
    _repeatTimer = Timer(delay, () {
      if (!mounted) return;
      action();
      if (_repeatCancelled) return;
      _heldMs += delay.inMilliseconds;
      _scheduleRepeat(action, _nextPeriod());
    });
  }

  Duration _nextPeriod() {
    final held = (_heldMs - _initialDelayMs).clamp(0, _accelerationMs);
    final t = held / _accelerationMs;
    final ms = (_slowPeriodMs - (_slowPeriodMs - _fastPeriodMs) * t).round();
    return Duration(milliseconds: ms);
  }

  void _stopRepeat() {
    _repeatCancelled = true;
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  Future<void> _toggleSide() async {
    final next = !_onLeft;
    setState(() => _onLeft = next);
    _restartIdleTimer();
    await EditorNavigationSettingsService.setPadOnLeft(next);
  }

  // ---------------------------------------------------------------------------
  // Labels
  // ---------------------------------------------------------------------------

  String _motionLabelFor(AxisDirection direction) {
    final l10n = AppLocalizations.of(context)!;
    final horizontal =
        direction == AxisDirection.left || direction == AxisDirection.right;
    final forward =
        direction == AxisDirection.right || direction == AxisDirection.down;
    switch (_unit) {
      case NavGranularity.char:
        return l10n.navPadUnitChar;
      case NavGranularity.token:
        return horizontal ? l10n.navPadUnitToken : l10n.navPadUnitChar;
      case NavGranularity.line:
        if (!horizontal) return l10n.navPadUnitLine;
        return forward ? l10n.navPadLabelLineEnd : l10n.navPadLabelLineStart;
      case NavGranularity.block:
        if (!horizontal) {
          return forward
              ? l10n.navPadLabelNextBlock
              : l10n.navPadLabelPrevBlock;
        }
        return forward ? l10n.navPadLabelBlockEnd : l10n.navPadLabelBlockStart;
    }
  }

  String _unitLabel(NavGranularity unit) {
    final l10n = AppLocalizations.of(context)!;
    switch (unit) {
      case NavGranularity.char:
        return l10n.navPadUnitChar;
      case NavGranularity.token:
        return l10n.navPadUnitToken;
      case NavGranularity.line:
        return l10n.navPadUnitLine;
      case NavGranularity.block:
        return l10n.navPadUnitBlock;
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Positioned(
      bottom: 16,
      left: _onLeft ? 16 : null,
      right: _onLeft ? null : 16,
      child: CodeEditorTapRegion(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          opacity: _idle ? 0.45 : 1.0,
          child: Listener(
            // Any touch anywhere on the pad wakes it from its idle fade, even
            // one that lands between keys.
            onPointerDown: (_) => _restartIdleTimer(),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: colors.outlineVariant),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildStatusBar(context),
                  const SizedBox(height: 4),
                  _buildRow([
                    _unitKey(NavGranularity.char, 1),
                    _arrowKey(AxisDirection.up, Icons.keyboard_arrow_up),
                    _unitKey(NavGranularity.token, 2),
                  ]),
                  _buildRow([
                    _arrowKey(AxisDirection.left, Icons.keyboard_arrow_left),
                    _buildModeKey(context),
                    _arrowKey(AxisDirection.right, Icons.keyboard_arrow_right),
                  ]),
                  _buildRow([
                    _unitKey(NavGranularity.line, 3),
                    _arrowKey(AxisDirection.down, Icons.keyboard_arrow_down),
                    _unitKey(NavGranularity.block, 4),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(List<Widget> children) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final child in children)
          Padding(padding: const EdgeInsets.all(2), child: child),
      ],
    );
  }

  /// Grid width: three 48dp keys plus the 4dp gaps between and around them.
  static const double _padWidth = 3 * (48 + 4);

  /// The status bar carries both pieces of state at once. The dial is only
  /// affordable because this never goes away — which is why the transient
  /// motion label sits in its own row rather than replacing it.
  ///
  /// It doubles as the pad's grab handle. The drag lives here rather than on
  /// the whole pad because the arrow keys are raw [Listener]s, which never join
  /// the gesture arena: an ancestor drag would fire *in addition to* stepping
  /// the cursor rather than instead of it.
  Widget _buildStatusBar(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final mode = _selectionMode ? l10n.navPadModeSelect : l10n.navPadModeMove;

    return GestureDetector(
      key: EditorNavigationPad.dragHandleKey,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity == 0) return;
        final wantsLeft = velocity < 0;
        if (wantsLeft != _onLeft) _toggleSide();
      },
      child: SizedBox(
        width: _padWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _sideButton(context),
                Expanded(
                  child: Center(
                    child: Text(
                      '$mode · ${_unitLabel(_unit)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ),
                if (widget.onDismiss != null)
                  _iconButton(
                    icon: Icons.close,
                    tooltip: l10n.navPadHide,
                    onTap: widget.onDismiss!,
                  )
                else
                  const SizedBox(width: _chromeTarget),
              ],
            ),
            // A fixed-height slot, so the pad does not change size when a label
            // appears and disappears under the user's thumb.
            SizedBox(
              height: 13,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: _motionLabel == null
                    ? const SizedBox.shrink(key: ValueKey('nav_pad_no_label'))
                    : Text(
                        _motionLabel!,
                        // Keyed by a counter, never by the text: two presses
                        // that produce the same label would otherwise hand the
                        // switcher duplicate keys and throw.
                        key: ValueKey('nav_pad_label_$_statusSeq'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          height: 1.1,
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sideButton(BuildContext context) {
    return _iconButton(
      icon: _onLeft ? Icons.chevron_right : Icons.chevron_left,
      tooltip: AppLocalizations.of(context)!.navPadSwitchSide,
      onTap: _toggleSide,
    );
  }

  /// Chrome, not a key: P5's 48dp floor governs the nine keys. 24dp was too
  /// small to hit reliably though, and the close button is the only way to
  /// dismiss the pad from the pad itself.
  static const double _chromeTarget = 36;

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: _chromeTarget,
          height: _chromeTarget,
          child: Icon(
            icon,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// A corner: one of the four granularities, shown with both a dot count and
  /// a word. Iconography alone would make the lit state guesswork.
  Widget _unitKey(NavGranularity unit, int dots) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selected = _unit == unit;

    return Semantics(
      key: EditorNavigationPad.unitKeyOf(unit),
      button: true,
      selected: selected,
      label: _unitLabel(unit),
      child: Tooltip(
        message: AppLocalizations.of(
          context,
        )!.navPadUnitTooltip(_unitLabel(unit)),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            setState(() => _unit = unit);
            _afterMotion(_unitLabel(unit));
          },
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: selected ? colors.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? colors.primary : colors.outlineVariant,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < dots; i++)
                      Container(
                        width: 3,
                        height: 3,
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected
                              ? colors.onPrimaryContainer
                              : colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _unitLabel(unit),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 9,
                    height: 1.1,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? colors.onPrimaryContainer
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _arrowKey(AxisDirection direction, IconData icon) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      key: EditorNavigationPad.arrowKeyOf(direction),
      button: true,
      label: _arrowSemanticLabel(direction),
      child: Listener(
        onPointerDown: (_) => _startRepeat(() => _move(direction)),
        onPointerUp: (_) => _stopRepeat(),
        onPointerCancel: (_) => _stopRepeat(),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 22, color: colors.onSurface),
        ),
      ),
    );
  }

  String _arrowSemanticLabel(AxisDirection direction) {
    final l10n = AppLocalizations.of(context)!;
    switch (direction) {
      case AxisDirection.up:
        return l10n.navPadMoveUp;
      case AxisDirection.down:
        return l10n.navPadMoveDown;
      case AxisDirection.left:
        return l10n.navPadMoveBackward;
      case AxisDirection.right:
        return l10n.navPadMoveForward;
    }
  }

  /// The centre: tap switches move/select, hold expands the selection one rung,
  /// and a downward drag shrinks it back.
  Widget _buildModeKey(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;

    return Semantics(
      key: EditorNavigationPad.modeKey,
      button: true,
      toggled: _selectionMode,
      label: _selectionMode ? l10n.navPadModeSelect : l10n.navPadModeMove,
      child: Tooltip(
        message: l10n.navPadModeTooltip,
        child: GestureDetector(
          onTap: () {
            setState(() => _selectionMode = !_selectionMode);
            _afterMotion(
              _selectionMode ? l10n.navPadModeSelect : l10n.navPadModeMove,
            );
          },
          onLongPress: _expand,
          onVerticalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) > 0) _shrink();
          },
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _selectionMode
                  ? colors.primaryContainer
                  : colors.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _selectionMode ? colors.primary : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Icon(
              _selectionMode ? Icons.highlight_alt : Icons.my_location,
              size: 20,
              color: _selectionMode
                  ? colors.onPrimaryContainer
                  : colors.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// A zero-copy `List<String>` over re_editor's segmented [CodeLines].
///
/// The block scanner walks every line, and `CodeLines.length` folds over its
/// segments on each call, so the length is read once here rather than per
/// iteration. Building a real list instead would allocate one string reference
/// per line on every auto-repeat tick.
class _CodeLinesView extends ListBase<String> {
  final CodeLines _lines;
  @override
  final int length;

  _CodeLinesView(this._lines) : length = _lines.length;

  @override
  set length(int newLength) => throw UnsupportedError('read-only');

  @override
  String operator [](int index) => _lines[index].text;

  @override
  void operator []=(int index, String value) =>
      throw UnsupportedError('read-only');
}
