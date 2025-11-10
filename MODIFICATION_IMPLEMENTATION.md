# Modification Implementation Plan: iOS Keyboard Fix

This document outlines the step-by-step plan to fix the iOS keyboard issue in the immersive chat view.

## Journal

*   **Sunday, November 9, 2025** - Plan created. Initial tests skipped as per user instruction.
*   **Sunday, November 9, 2025** - Phase 2 code modifications completed. `dart_fix` and `dart_format` run. `analyze_files` run.

## Phase 1: Project Health Check

- [x] Run all existing tests to ensure the project is in a stable state before making changes. (Skipped as per user instruction)

## Phase 2: Implement the Keyboard Fix

The following changes will be made in `lib/screens/immersive_note_screen.dart`.

- [x] In the `build` method, find the `Scaffold` widget and set its `resizeToAvoidBottomInset` property to `false`.
- [x] In the `_buildVerticalAiOverlays` method:
    - [x] At the beginning of the method, get the keyboard height: `final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;`.
    - [x] Update the `maxHandleTop` calculation to subtract `keyboardHeight`: `totalHeight - handleHeight - _aiHandleMargin - keyboardHeight`.
    - [x] When the AI panel is expanded (`_isAiPanelExpanded` is true) and positioned at the bottom, update the `Positioned` widget to include the `keyboardHeight` in its `bottom` offset. Also, update the `handleTop` calculation for this case to subtract `keyboardHeight`.
    - [x] When the AI panel is collapsed, update the `trackHeight` calculation to subtract `keyboardHeight`.
- [x] In the `_buildHorizontalAiOverlays` method:
    - [x] At the beginning of the method, get the keyboard height: `final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;`.
    - [x] Update the `maxHandleTop` calculation to subtract `keyboardHeight`.
    - [x] Update the `trackHeight` calculation to subtract `keyboardHeight`.

### Post-Phase 2 Verification

- [ ] Create/modify unit tests for testing the code added or modified in this phase, if relevant. (Note: This is a visual fix, so manual testing is the primary verification method. No new unit tests are anticipated.)
- [x] Run the `dart_fix` tool to clean up the code.
- [x] Run the `analyze_files` tool and fix any new issues that may have been introduced.
- [ ] Run all tests to make sure they all pass. (Skipped as per user instruction)
- [x] Run `dart_format` to ensure correct formatting.
- [ ] Re-read this `MODIFICATION_IMPLEMENTATION.md` file to check for any changes or missed steps.
- [x] Update the "Journal" section in this file with a summary of actions taken, any learnings, or deviations from the plan. Check off completed tasks.
- [ ] Use `git diff` to verify the changes made, and then prepare a commit message for user approval.
- [ ] Wait for user approval of the commit message.
- [ ] After approval, commit the changes.
- [ ] If the app is running, use the `hot_reload` tool to apply the changes.

## Phase 3: Final Review

- [ ] Update the `README.md` file if any of the changes require documentation updates (not expected for this fix).
- [ ] Update the `GEMINI.md` file if the project's overall description or file layout has changed (not expected for this fix).
- [ ] Ask the user to inspect the running application on an iOS device or simulator to confirm that the keyboard issue is resolved and that no new issues have been introduced.
- [ ] Await user confirmation of satisfaction.

---
After completing a task, if you added any TODOs to the code or didn't fully implement anything, make sure to add new tasks so that you can come back and complete them later.
