# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Development Commands

```bash
# Get dependencies
flutter pub get

# Generate code (JSON serialization, mocks) - required after adding @JsonSerializable or @GenerateMocks
dart run build_runner build --delete-conflicting-outputs

# Run app
flutter run -d macos    # or ios, android, linux, web

# Run all tests
flutter test

# Run single test file
flutter test test/conversation_service_test.dart

# Analyze code
flutter analyze
```

## Architecture Overview

Note Synapse is a Flutter note-taking app with AI integration (Google Gemini). It uses a hybrid state management approach:

### State Management: GetIt + Provider

```
Screens (UI)
    │
    ├── Provider (ChangeNotifier) → UI state only (AppProvider)
    │
    └── getIt<Service>() → Business logic & data
            │
            └── DatabaseService → SQLite persistence
```

- **Provider**: UI state (loading, selection, etc.)
- **GetIt**: Service singletons with constructor injection

### Service Locator Pattern

Services are registered in `lib/services/service_locator.dart`:

```dart
// Usage in code
final db = getIt<DatabaseService>();
final service = getIt<ConversationService>();

// Service definition with constructor injection
class MyService {
  final DatabaseService _db;
  MyService(this._db);
}
```

### Testing Pattern

```dart
@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;

  setUp(() async {
    await resetForTesting();  // Clear GetIt
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
  });

  test('example', () async {
    when(mockDb.method()).thenAnswer((_) async => value);
    // test code
    verify(mockDb.method()).called(1);
  });
}
```

### Test Coverage

Run `./coverage.sh` to generate a full test coverage report:
- Test output: `coverage/test_output`
- Coverage report: `coverage/test_coverage.csv` (files and uncovered lines)

## Key Directories

- `lib/services/` - Business logic (51 files). `DatabaseService` is the foundation.
- `lib/models/` - Data models with JSON serialization (`*.g.dart` files)
- `lib/screens/` - UI screens
- `lib/providers/` - Provider state classes
- `test/` - Tests using mockito

## Important Constraints

### Files to Never Touch
- `./ios/Runner.xcodeproj/project.pbxproj` - iOS project file

### Database Columns (Large Data)
These columns can be very large and require careful handling:
- `conversation_messages.metadata` - chunked read required
- `app_revisions.appCode`
- `user_app_library_dependencies.bytes`
- `user_apps.appState`
- `notes.content`
- `search_chunks.text` (raw chunk text; derived from notes, rebuildable via the search indexer)

### Database Changes
When modifying tables, update `recovery_screen.dart` to ensure consistency during recovery.

Preserve the published migration numbers and meanings from released `origin/main`.
New cloud-sync and indexing migrations must follow every released migration;
never handle a collision by rewinding or reinterpreting a released version.
Add a forward compatibility step when renumbering migrations used by branch builds.

### User App Notes
- `user_apps.uuid` is the stable package identity; `user_apps.id` is the row key referenced by revisions.
- Current runnable code is in `app_revisions.appCode`; `user_apps.htmlContent` is a legacy field.
- `app_revisions.revisionNumber` is the revision number; `app_revisions.id` identifies the revision row.

### Multi-functions Table
Deliberately excluded from recovery operations.

## Localization

UI text changes must consider l10n. Localizations are in `lib/l10n/` (English and Chinese Simplified).

## Synapse API (Plugin System)

Note Synapse has a plugin mechanism called "User Apps" - HTML/JS applications that can be AI-generated. These apps access the Synapse JavaScript API.

**When adding a new Synapse API method:**

1. **Implement the handler** in `lib/services/user_app_runtime_bridge.dart`:
   - Add JavaScript API in `buildBootstrapScript()` (the `window.Synapse` object)
   - Add Dart handler in `registerJavaScriptHandlers()`

2. **Document the API for AI** in `lib/services/user_app_service.dart`:
   - Update `_buildApiDocumentationSection()` with the new method signature, parameters, and response format
   - This documentation is included in prompts when AI generates user apps

Both steps are required - the implementation enables the functionality, and the prompt documentation teaches AI how to use it when generating plugins.

## Code Style

Before implementing features, search the codebase for similar functionality to avoid duplication. Refactor shared code when appropriate.

## Planning
Your plan files should be stored in project's .claude/plans folder.
