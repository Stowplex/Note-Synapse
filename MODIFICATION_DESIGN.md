# Modification Design: iOS Keyboard Fix for Immersive Chat

## 1. Overview

This document outlines the design for a fix to a critical bug on the iOS platform. In the app's immersive view, the chat text field becomes unusable because the on-screen keyboard is immediately dismissed after it appears.

The root cause is the default Flutter `Scaffold` behavior, which resizes its body to accommodate the keyboard. This resizing event causes the complex, dynamically positioned chat panel widget to be rebuilt, leading to the `TextField` losing focus.

The proposed solution is to disable the automatic resizing and instead manually adjust the position of the chat panel to keep it visible above the keyboard.

## 2. Analysis of the Problem

- **Screen:** `lib/screens/immersive_note_screen.dart`
- **Widgets Involved:** `Scaffold`, `LayoutBuilder`, `Stack`, `Positioned`, `GestureDetector`, `TextField`.
- **Behavior:**
    1. The user taps the `TextField` within the AI chat handle.
    2. The iOS keyboard begins to animate upwards.
    3. The `Scaffold`'s `resizeToAvoidBottomInset` property is `true` by default, so it resizes its `body` (the `SafeArea`).
    4. The `LayoutBuilder` within the `body` gets new, smaller constraints.
    5. The entire `Stack` and its `Positioned` children are rebuilt based on the new constraints.
    6. This rapid rebuild causes the `TextField` to lose focus.
    7. With focus lost, the keyboard is dismissed.

This creates a loop where the keyboard can never stay open, rendering the chat feature unusable on iOS.

## 3. Alternatives Considered

### Alternative 1: Wrap the UI in a `SingleChildScrollView`

- **Description:** The most common "Flutter-idiomatic" solution for keyboard overlap issues is to wrap the main content in a `SingleChildScrollView` and keep `resizeToAvoidBottomInset: true`.
- **Pros:** The framework would automatically handle scrolling the focused `TextField` into view.
- **Cons:** The UI in `immersive_note_screen.dart` is not a simple, static layout. It features a draggable handle whose position is calculated with a `GestureDetector` and a fractional value (`_aiHandleFraction`). Integrating a `SingleChildScrollView` would require a significant and risky refactoring of this complex layout and positioning logic. It's a high-risk change for a targeted bug fix.

### Alternative 2: Disable Resizing and Manually Adjust (Chosen)

- **Description:** Set `resizeToAvoidBottomInset: false` on the `Scaffold`. This prevents the resize event that causes the focus loss. Then, use `MediaQuery` to detect the keyboard's presence and height, and manually adjust the chat panel's position to keep it visible.
- **Pros:**
    - **Targeted Fix:** Directly addresses the root cause (the resize) without altering the existing layout structure.
    - **Low Risk:** It's a much less invasive change, requiring modifications only to the `Scaffold` and the layout logic for the AI handle.
    - **Preserves UI:** The existing draggable behavior and complex layout are preserved.
- **Cons:** Requires manual calculation and state management to adjust the UI when the keyboard appears and disappears.

The second alternative is strongly preferred as it is a safer, more localized, and less complex solution for the given problem.

## 4. Detailed Design

The implementation will be done in `lib/screens/immersive_note_screen.dart`.

### Step 1: Disable Scaffold Resizing

In the `build` method of `_ImmersiveNoteScreenState`, locate the `Scaffold` widget and set its `resizeToAvoidBottomInset` property to `false`.

```dart
// In _ImmersiveNoteScreenState.build()

return Scaffold(
  resizeToAvoidBottomInset: false, // This is the key change
  appBar: AppBar(...),
  body: SafeArea(...),
);
```

### Step 2: Adjust Layout for Keyboard

With the resizing disabled, the keyboard will now overlay the content. We need to adjust the position of the AI chat handle when the keyboard is visible. The layout logic is primarily in the `_buildVerticalAiOverlays` method.

We will use `MediaQuery.of(context).viewInsets.bottom` to get the height of the keyboard. This value is non-zero only when the keyboard is visible.

The plan is to treat the area obscured by the keyboard as "off-limits" for the bottom of the screen. We will subtract the keyboard's height from the total available height when calculating the handle's position.

The modification will be in `_buildVerticalAiOverlays`:

```dart
// In _ImmersiveNoteScreenState._buildVerticalAiOverlays()

List<Widget> _buildVerticalAiOverlays(Size size, AppLocalizations l10n) {
  // Get the keyboard height
  final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

  final overlays = <Widget>[];
  // The total height is now the canvas size. We will use keyboardHeight to offset.
  final totalHeight = size.height;
  final handleHeight = _currentHandleHeight();
  final panelHeight = _computePanelExtent(totalHeight, handleHeight);
  final effectiveSide = _effectivePanelSide(false);

  // Adjust the maximum top position to account for the keyboard
  final minHandleTop = _aiHandleMargin;
  final maxHandleTop = max(
    _aiHandleMargin,
    // Subtract keyboardHeight from the total height for positioning
    totalHeight - handleHeight - _aiHandleMargin - keyboardHeight,
  );

  double handleTop;

  if (_isAiPanelExpanded && panelHeight > 0) {
    // ... (logic for expanded panel)
    // This part also needs to be checked to ensure it respects the keyboard.
    // The current logic positions from top or bottom. When positioned from the bottom,
    // it should be offset by the keyboard height.
    if (effectiveSide == _AiPanelSide.top) {
      // ...
    } else { // Bottom
      overlays.add(
        Positioned(
          // Add keyboardHeight to the bottom offset
          bottom: keyboardHeight,
          left: _aiHandleMargin,
          right: _aiHandleMargin,
          height: panelHeight,
          child: _buildAiPanelContent(l10n),
        ),
      );
      handleTop = totalHeight - panelHeight - handleHeight - _aiHandleMargin - keyboardHeight;
    }
  } else {
    // Adjust the track height for the handle's draggable area
    final trackHeight = max(0.0, totalHeight - handleHeight - keyboardHeight);
    handleTop = trackHeight <= 0
        ? _aiHandleMargin
        : _aiHandleFraction * trackHeight;
  }

  final clampedHandleTop = _clampToRange(
    handleTop,
    minHandleTop,
    maxHandleTop,
  );

  // ... rest of the method remains the same
}
```

The core idea is to subtract `keyboardHeight` from any calculation that assumes the bottom of the screen is at `size.height`. This will ensure the handle and the expanded panel are always rendered above the keyboard.

A similar adjustment will be needed for `_buildHorizontalAiOverlays` to ensure the landscape view is also correct, although the primary issue is with the vertical (portrait) layout. In landscape, the keyboard takes up less vertical space, but the principle is the same.

### Step 3: Mermaid Diagram

This diagram illustrates the "before" and "after" layout behavior when the keyboard appears.

```mermaid
graph TD
    subgraph Before (resizeToAvoidBottomInset: true)
        A[Screen] --> B{Scaffold};
        B --> C[Body (Resized)];
        C --> D[Stack];
        D --> E[TextField];
        E -- "Focus" --> F((Keyboard Appears));
        F -- "Resizes Body" --> C;
        C -- "Rebuilds Stack" --> D;
        D -- "Causes Focus Loss" --> E;
    end

    subgraph After (resizeToAvoidBottomInset: false)
        A2[Screen] --> B2{Scaffold};
        B2 --> C2[Body (Not Resized)];
        C2 --> D2[Stack];
        D2 --> E2[TextField];
        E2 -- "Focus" --> F2((Keyboard Appears));
        F2 -- "Overlays Body" --> C2;
        subgraph Manual Adjustment
            G[MediaQuery] -- "Provides Keyboard Height" --> H{Layout Logic};
            H -- "Adjusts Position" --> I[Chat Handle];
        end
        F2 --> G;
    end
```

## 5. Summary of Design

1.  **Prevent Resizing:** Set `resizeToAvoidBottomInset: false` on the `Scaffold` in `immersive_note_screen.dart`.
2.  **Detect Keyboard:** Use `MediaQuery.of(context).viewInsets.bottom` to get the keyboard's height.
3.  **Adjust Layout:** Modify the `_buildVerticalAiOverlays` and `_buildHorizontalAiOverlays` methods to subtract the keyboard's height from their vertical layout calculations, ensuring the chat handle and panel are always positioned above the keyboard.

This design provides a targeted, low-risk fix that resolves the iOS keyboard bug while preserving the existing UI structure and behavior.

## 6. Research

- Flutter `Scaffold` `resizeToAvoidBottomInset` property: [https://api.flutter.dev/flutter/material/Scaffold/resizeToAvoidBottomInset.html](https://api.flutter.dev/flutter/material/Scaffold/resizeToAvoidBottomInset.html)
- Flutter `MediaQuery` `viewInsets` property: [https://api.flutter.dev/flutter/widgets/MediaQueryData/viewInsets.html](https://api.flutter.dev/flutter/widgets/MediaQueryData/viewInsets.html)
- General discussion on Flutter keyboard and `TextField` focus issues.
