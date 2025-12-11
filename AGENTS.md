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

# Notes
- Multi functions table is deliberately left out during recovery
- conversation\_messages metadata column can be very large and requires chunked read
- user_app should look at the uuid field and treat it as if it's primary key
- user_app_revision's code should be treated as big column
- user_app's html column should NOT be used
- User_app_revision's revision number is the revision. ID is timestamp_{revision} which is not useful.
- user_app_libraries code could be large.
- note's content should be treated as big column
