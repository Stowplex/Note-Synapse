import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

// TODO(stuck-selection): remove this workaround once we ship on a Flutter
// stable that contains flutter/flutter#185292 (merged to master 2026-04-29,
// commit 823b47d, no `cp: stable` filed). Expected stable arrival ~Q3 2026
// on Flutter's quarterly cadence. Re-evaluate this guard and the lifecycle
// observer in main.dart at the next SDK bump after 2026-09-01: if our
// pinned Flutter version includes #185292 AND macOS #167090 is also fixed,
// delete this helper and the four `onTap: guardStuckSelection(...)` call
// sites. If only Android is fixed, keep the guard for desktop coverage.
void guardStuckSelection(TextEditingController controller) {
  final hk = HardwareKeyboard.instance;
  final physicalShiftHeld =
      hk.physicalKeysPressed.contains(PhysicalKeyboardKey.shiftLeft) ||
      hk.physicalKeysPressed.contains(PhysicalKeyboardKey.shiftRight);
  if (hk.isShiftPressed && !physicalShiftHeld) {
    hk.clearState();
    final sel = controller.selection;
    if (!sel.isCollapsed) {
      controller.selection = TextSelection.collapsed(offset: sel.extentOffset);
    }
  }
}
