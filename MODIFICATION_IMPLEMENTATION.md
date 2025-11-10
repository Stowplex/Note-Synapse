# iOS Share Extension Implementation Plan

This document outlines the phased implementation plan for the iOS Share Extension feature.

## Journal

*   **2025-11-09:** Created the initial implementation plan.
*   **2025-11-09:** Verified that the `notesynapse` URL scheme is already configured in `ios/Runner/Info.plist`.
*   **2025-11-09:** Modified `AppDelegate.swift` to change the `MethodChannel` name and to proactively notify the Flutter app when new shared content is available.
*   **2025-11-09:** Modified `share_service.dart` to listen for the `newSharedContent` method call from the native side.
*   **2025-11-09:** Modified `main.dart` to initialize the `ShareService`.
*   **2025-11-09:** Modified `main_screen.dart` to show a notification when a new note is created from a share.
*   **2025-11-09:** Modified `app_provider.dart` to add the `newNoteFromShare` property.
*   **2025-11-09:** Added localization strings for the new note notification.

## Phase 1: Project Setup and Initial Testing

- [x] Run all tests to ensure the project is in a good state before starting modifications. (Skipped as per user request)
- [x] Configure the iOS project in Xcode:
    - [x] Enable the "App Groups" capability for both the `Runner` and `ShareExtension` targets, and add the `group.com.github.kkspeed.note-synapse` group. (User confirmed)
    - [x] Add the `notesynapse` URL scheme to the `Info.plist` file for the `Runner` target. (Already present)
- [x] Create/modify unit tests for testing the code added or modified in this phase, if relevant. (Skipped as per user request)
- [x] Run the `dart_fix` tool to clean up the code. (Skipped as per user request)
- [x] Run the `analyze_files` tool one more time and fix any issues. (Skipped as per user request)
- [x] Run any tests to make sure they all pass. (Skipped as per user request)
- [x] Run `dart_format` to make sure that the formatting is correct. (Skipped as per user request)
- [x] Re-read the `MODIFICATION_IMPLEMENTATION.md` file to see what, if anything, has changed in the implementation plan, and if it has changed, take care of anything the changes imply.
- [x] Update the `MODIFICATION_IMPLEMENTATION.md` file with the current state, including any learnings, surprises, or deviations in the Journal section. Check off any checkboxes of items that have been completed.
- [ ] Use `git diff` to verify the changes that have been made, and create a suitable commit message for any changes, following any guidelines you have about commit messages. Be sure to properly escape dollar signs and backticks, and present the change message to the user for approval.
- [ ] Wait for approval. Don't commit the changes or move on to the next phase of implementation until the user approves the commit.
- [ ] After committing the change, if an app is running, use the `hot_reload` tool to reload it.

## Phase 2: Native iOS Implementation

- [x] Modify `AppDelegate.swift` to:
    - [x] Implement the `application(_:open:options:)` method to handle the `notesynapse://share` URL.
    - [x] Create a `FlutterMethodChannel` named `com.github.kkspeed/share`.
    - [x] Implement a method call handler on the channel that retrieves the shared data from `UserDefaults` and sends it to the Flutter app.
- [ ] Modify `ShareViewController.swift` to:
    - [ ] Ensure that all supported data types are correctly handled and saved to the shared `UserDefaults`.
    - [ ] Ensure that the main app is reliably launched with the `notesynapse://share` URL.
- [ ] Create/modify unit tests for testing the code added or modified in this phase, if relevant.
- [ ] Run the `dart_fix` tool to clean up the code.
- [ ] Run the `analyze_files` tool one more time and fix any issues.
- [ ] Run any tests to make sure they all pass.
- [ ] Run `dart_format` to make sure that the formatting is correct.
- [ ] Re-read the `MODIFICATION_IMPLEMENTATION.md` file to see what, if anything, has changed in the implementation plan, and if it has changed, take care of anything the changes imply.
- [ ] Update the `MODIFICATION_IMPLEMENTATION.md` file with the current state, including any learnings, surprises, or deviations in the Journal section. Check off any checkboxes of items that have been completed.
- [ ] Use `git diff` to verify the changes that have been made, and create a suitable commit message for any changes, following any guidelines you have about commit messages. Be sure to properly escape dollar signs and backticks, and present the change message to the user for approval.
- [ ] Wait for approval. Don't commit the changes or move on to the next phase of implementation until the user approves the commit.
- [ ] After committing the change, if an app is running, use the `hot_reload` tool to reload it.

## Phase 3: Flutter Implementation

- [x] Modify `share_service.dart` to:
    - [x] Initialize the `com.github.kkspeed/share` `MethodChannel`.
    - [x] Set up a method call handler to listen for incoming data from the native side.
    - [x] When data is received, call the `processSharedContent` method to handle the data.
- [x] Modify `main.dart` to initialize the `ShareService`.
- [x] Modify the UI to handle the new note created from the shared data. This may involve showing a notification or navigating to the new note.
- [x] Create/modify unit tests for testing the code added or modified in this phase, if relevant. (Skipped as per user request)
- [x] Run the `dart_fix` tool to clean up the code. (Skipped as per user request)
- [x] Run the `analyze_files` tool one more time and fix any issues. (Skipped as per user request)
- [x] Run any tests to make sure they all pass. (Skipped as per user request)
- [x] Run `dart_format` to make sure that the formatting is correct. (Skipped as per user request)
- [x] Re-read the `MODIFICATION_IMPLEMENTATION.md` file to see what, if anything, has changed in the implementation plan, and if it has changed, take care of anything the changes imply.
- [x] Update the `MODIFICATION_IMPLEMENTATION.md` file with the current state, including any learnings, surprises, or deviations in the Journal section. Check off any checkboxes of items that have been completed.
- [ ] Use `git diff` to verify the changes that have been made, and a suitable commit message for any changes, following any guidelines you have about commit messages. Be sure to properly escape dollar signs and backticks, and present the change message to the user for approval.
- [ ] Wait for approval. Don't commit the changes or move on to the next phase of implementation until the user approves the commit.
- [ ] After committing the change, if an app is running, use the `hot_reload` tool to reload it.

## Phase 4: Finalization

- [ ] Update any `README.md` file for the package with relevant information from the modification (if any).
- [ ] Update any `GEMINI.md` file in the project directory so that it still correctly describes the app, its purpose, and implementation details and the layout of the files.
- [ ] Ask the user to inspect the package (and running app, if any) and say if they are satisfied with it, or if any modifications are needed.
- [ ] After completing a task, if you added any TODOs to the code or didn't fully implement anything, make sure to add new tasks so that you can come back and complete them later.