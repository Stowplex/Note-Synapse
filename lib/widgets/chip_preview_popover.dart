import 'package:flutter/material.dart';
import '../models/chip_action.dart';

/// Renders a chip's full prompt as an overlay anchored above the tapped
/// chip. Static API: caller invokes [show] to insert the overlay and
/// receives an [OverlayEntry] which it must remove on dismissal
/// (mouse-leave, scroll, tap-elsewhere, or after a timeout).
///
/// Used by ChipsFooter's long-press handler (Task 11) and ChatPanel's
/// hover wiring (Task 17).
class ChipPreviewPopover {
  static const double _maxWidth = 360.0;
  static const double _maxHeight = 240.0;
  static const double _gap = 8.0;
  static const double _approxHeightForOffset = 200.0;

  /// Inserts a popover overlay anchored above [anchorRect] showing
  /// the [chip]'s full prompt text. Returns the [OverlayEntry] —
  /// caller owns removal.
  ///
  /// Horizontal position is clamped so the popover stays within the
  /// screen with an 8px margin. Vertical position attempts to render
  /// above the anchor; if that would clip off the top, the caller can
  /// reposition by re-calling show with a different anchor.
  static OverlayEntry show({
    required BuildContext context,
    required Rect anchorRect,
    required ChipAction chip,
  }) {
    final overlay = Overlay.of(context);
    final mediaSize = MediaQuery.of(context).size;
    final left = (anchorRect.center.dx - _maxWidth / 2)
        .clamp(_gap, mediaSize.width - _maxWidth - _gap);
    final top = (anchorRect.top - _gap - _approxHeightForOffset).clamp(
      _gap,
      mediaSize.height - _approxHeightForOffset - _gap,
    );

    final entry = OverlayEntry(
      builder: (ctx) => Positioned(
        left: left,
        top: top,
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: _maxWidth,
              maxHeight: _maxHeight,
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                child: Text(
                  chip.prompt,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    return entry;
  }
}
