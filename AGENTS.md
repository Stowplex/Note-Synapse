# Coding
## Feature Implementation
- Always look into the code base look for code that achieve similar functionality, before rolling out your implementation. Refactor code if necessary to avoid code duplication.
- UI change should consider l10n

## Code Merge
- Remain on the working branch and do not merge other branches unless instructed by user
- Files that should NOT touch (including edit, reset, checkout...) unless instructed:
  + ./ios/Runner.xcodeproj/project.pbxproj

## Testing
- Run `flutter test` and ensure tests all pass

