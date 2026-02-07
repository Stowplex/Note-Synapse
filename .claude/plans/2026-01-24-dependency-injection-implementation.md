# Dependency Injection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate Note Synapse services to use GetIt dependency injection, enabling testability through constructor injection and mock-friendly architecture.

**Architecture:** GetIt service locator with constructor injection. Services declare dependencies in constructors, GetIt wires them together. Providers continue to manage UI state but get services from GetIt.

**Tech Stack:** GetIt ^7.6.0 for DI, Mockito ^5.6.1 for mocks (already installed), build_runner for mock generation.

---

## Foundation Tasks

### Task 1: Add GetIt Dependency

**Files:**
- Modify: `pubspec.yaml`

**Step 1: Add GetIt to dependencies**

Add after line 71 (after `provider: ^6.1.1`):

```yaml
  # Dependency injection
  get_it: ^7.6.0
```

**Step 2: Run pub get**

Run: `flutter pub get`
Expected: "Got dependencies!" with no errors

**Step 3: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "chore: add get_it dependency for dependency injection"
```

---

### Task 2: Create Service Locator Skeleton

**Files:**
- Create: `lib/services/service_locator.dart`
- Test: `test/services/service_locator_test.dart`

**Step 1: Write the test**

Create `test/services/service_locator_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/database_service.dart';

void main() {
  tearDown(() {
    GetIt.I.reset();
  });

  group('ServiceLocator', () {
    test('setupServiceLocator registers DatabaseService', () {
      setupServiceLocator();

      expect(GetIt.I.isRegistered<DatabaseService>(), isTrue);
    });

    test('resetForTesting clears all registrations', () {
      setupServiceLocator();
      expect(GetIt.I.isRegistered<DatabaseService>(), isTrue);

      resetForTesting();

      expect(GetIt.I.isRegistered<DatabaseService>(), isFalse);
    });

    test('getIt provides access to GetIt instance', () {
      expect(getIt, same(GetIt.I));
    });
  });
}
```

**Step 2: Run test to verify it fails**

Run: `flutter test test/services/service_locator_test.dart`
Expected: FAIL - "Target of URI hasn't been generated: 'package:note_synapse/services/service_locator.dart'"

**Step 3: Create service locator**

Create `lib/services/service_locator.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'database_service.dart';

/// Global GetIt instance for service location.
final GetIt getIt = GetIt.instance;

/// Initialize all services. Call once in main() before runApp().
///
/// ## Testing
///
/// For unit tests, call [resetForTesting] in setUp(), then register mocks:
///
/// ```dart
/// setUp(() {
///   resetForTesting();
///   getIt.registerSingleton<DatabaseService>(MockDatabaseService());
/// });
/// ```
///
/// ## Dependency Graph
///
/// Services are registered in dependency order. See each wave section
/// for which services depend on which.
void setupServiceLocator() {
  // ============================================================
  // WAVE 1: Foundation - No dependencies
  // ============================================================
  if (!getIt.isRegistered<DatabaseService>()) {
    getIt.registerLazySingleton<DatabaseService>(() => DatabaseService());
  }

  // Future waves will be added here as services are migrated
}

/// Reset all registrations. USE ONLY IN TESTS.
///
/// Call this in setUp() before registering mock services:
///
/// ```dart
/// setUp(() {
///   resetForTesting();
///   getIt.registerSingleton<DatabaseService>(MockDatabaseService());
/// });
/// ```
@visibleForTesting
void resetForTesting() {
  getIt.reset();
}
```

**Step 4: Run test to verify it passes**

Run: `flutter test test/services/service_locator_test.dart`
Expected: All tests pass

**Step 5: Commit**

```bash
git add lib/services/service_locator.dart test/services/service_locator_test.dart
git commit -m "feat: add service locator skeleton with DatabaseService registration"
```

---

### Task 3: Integrate Service Locator in main.dart

**Files:**
- Modify: `lib/main.dart`

**Step 1: Add import**

Add after line 17 (after `import 'services/background_agent_service.dart';`):

```dart
import 'services/service_locator.dart';
```

**Step 2: Call setupServiceLocator in main()**

Add after line 35 (after `await GlobalLibraryService().init();`):

```dart
  // Initialize service locator for dependency injection
  setupServiceLocator();
```

**Step 3: Verify app still works**

Run: `flutter run -d macos` (or your preferred device)
Expected: App starts normally, no errors

**Step 4: Run all tests to verify nothing broke**

Run: `flutter test`
Expected: All 418+ tests pass

**Step 5: Commit**

```bash
git add lib/main.dart
git commit -m "feat: integrate service locator in app initialization"
```

---

## Wave 2: Simple Services (Depend only on DatabaseService)

### Task 4: Migrate NoteModificationService

**Files:**
- Modify: `lib/services/note_modification_service.dart`
- Create: `test/services/note_modification_service_test.dart`
- Modify: `lib/services/service_locator.dart`

**Step 1: Write failing test**

Create `test/services/note_modification_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/models/note.dart';

@GenerateMocks([DatabaseService])
import 'note_modification_service_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late NoteModificationService service;

  setUp(() {
    resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = NoteModificationService(getIt<DatabaseService>());
  });

  tearDown(() {
    resetForTesting();
  });

  group('NoteModificationService', () {
    test('applyModifications fetches note from database', () async {
      final note = Note(
        id: 'test-id',
        title: 'Test Note',
        content: 'Original content',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      when(mockDb.getNoteById('test-id')).thenAnswer((_) async => note);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});

      await service.applyModifications('test-id', {});

      verify(mockDb.getNoteById('test-id')).called(1);
    });

    test('applyModifications throws when note not found', () async {
      when(mockDb.getNoteById('missing-id')).thenAnswer((_) async => null);

      expect(
        () => service.applyModifications('missing-id', {}),
        throwsA(isA<Exception>()),
      );
    });

    test('applyModifications appends content when action is append', () async {
      final note = Note(
        id: 'test-id',
        title: 'Test Note',
        content: 'Original',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      when(mockDb.getNoteById('test-id')).thenAnswer((_) async => note);
      when(mockDb.updateNote(any)).thenAnswer((_) async {});

      await service.applyModifications('test-id', {
        'content': {'action': 'append', 'text': ' appended'},
      });

      final captured = verify(mockDb.updateNote(captureAny)).captured.single as Note;
      expect(captured.content, 'Original\n appended');
    });
  });
}
```

**Step 2: Generate mocks**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: Generates `test/services/note_modification_service_test.mocks.dart`

**Step 3: Run test to verify it fails**

Run: `flutter test test/services/note_modification_service_test.dart`
Expected: FAIL - NoteModificationService constructor doesn't accept DatabaseService

**Step 4: Modify NoteModificationService to accept DatabaseService**

In `lib/services/note_modification_service.dart`, change lines 10-12 from:

```dart
class NoteModificationService {
  final DatabaseService _db = DatabaseService();
  final Uuid _uuid = const Uuid();
```

To:

```dart
class NoteModificationService {
  final DatabaseService _db;
  final Uuid _uuid = const Uuid();

  /// Creates a NoteModificationService.
  ///
  /// [db] - The database service for persistence operations.
  NoteModificationService(this._db);
```

**Step 5: Run test to verify it passes**

Run: `flutter test test/services/note_modification_service_test.dart`
Expected: All tests pass

**Step 6: Register in service locator**

In `lib/services/service_locator.dart`, add import at top:

```dart
import 'note_modification_service.dart';
```

Add after DatabaseService registration (around line 28):

```dart
  // ============================================================
  // WAVE 2: Simple services - Depend only on DatabaseService
  // ============================================================
  if (!getIt.isRegistered<NoteModificationService>()) {
    getIt.registerLazySingleton<NoteModificationService>(
      () => NoteModificationService(getIt<DatabaseService>()),
    );
  }
```

**Step 7: Update call sites**

Find all usages of `NoteModificationService()` and replace with `getIt<NoteModificationService>()`.

In `lib/services/content_ingestion_service.dart`, line 164, change:

```dart
          final service = NoteModificationService();
```

To:

```dart
          final service = getIt<NoteModificationService>();
```

Also add import at top of `content_ingestion_service.dart`:

```dart
import 'service_locator.dart';
```

**Step 8: Run all tests**

Run: `flutter test`
Expected: All tests pass (418+)

**Step 9: Commit**

```bash
git add lib/services/note_modification_service.dart \
        lib/services/content_ingestion_service.dart \
        lib/services/service_locator.dart \
        test/services/note_modification_service_test.dart \
        test/services/note_modification_service_test.mocks.dart
git commit -m "refactor: migrate NoteModificationService to dependency injection"
```

---

### Task 5: Migrate ContentIngestionService

**Files:**
- Modify: `lib/services/content_ingestion_service.dart`
- Create: `test/services/content_ingestion_service_test.dart`
- Modify: `lib/services/service_locator.dart`

**Step 1: Write failing test**

Create `test/services/content_ingestion_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/content_ingestion_service.dart';
import 'package:note_synapse/models/note.dart';

@GenerateMocks([DatabaseService])
import 'content_ingestion_service_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late ContentIngestionService service;

  setUp(() {
    resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = ContentIngestionService(getIt<DatabaseService>());
  });

  tearDown(() {
    resetForTesting();
  });

  group('ContentIngestionService', () {
    test('processNote returns early when note has no tags', () async {
      final note = Note(
        id: 'test-id',
        title: 'Test Note',
        content: 'Content',
        tags: [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // Should return without calling database
      await service.processNote(note, MockAppProvider());

      verifyNever(mockDb.getAllTags());
    });

    test('processNote fetches tags from database when note has tags', () async {
      final note = Note(
        id: 'test-id',
        title: 'Test Note',
        content: 'Content',
        tags: ['work'],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      when(mockDb.getAllTags()).thenAnswer((_) async => []);

      await service.processNote(note, MockAppProvider());

      verify(mockDb.getAllTags()).called(1);
    });
  });
}

// Simple mock for AppProvider - just needs to exist for this test
class MockAppProvider {
  // Minimal implementation
}
```

**Step 2: Generate mocks**

Run: `dart run build_runner build --delete-conflicting-outputs`

**Step 3: Run test to verify it fails**

Run: `flutter test test/services/content_ingestion_service_test.dart`
Expected: FAIL - ContentIngestionService constructor doesn't accept DatabaseService

**Step 4: Modify ContentIngestionService**

In `lib/services/content_ingestion_service.dart`, change line 16-17 from:

```dart
class ContentIngestionService {
  final DatabaseService _databaseService = DatabaseService();
```

To:

```dart
class ContentIngestionService {
  final DatabaseService _databaseService;

  /// Creates a ContentIngestionService.
  ///
  /// [databaseService] - The database service for data operations.
  ContentIngestionService(this._databaseService);
```

**Step 5: Run test to verify it passes**

Run: `flutter test test/services/content_ingestion_service_test.dart`
Expected: All tests pass

**Step 6: Register in service locator**

In `lib/services/service_locator.dart`, add import:

```dart
import 'content_ingestion_service.dart';
```

Add after NoteModificationService registration:

```dart
  if (!getIt.isRegistered<ContentIngestionService>()) {
    getIt.registerLazySingleton<ContentIngestionService>(
      () => ContentIngestionService(getIt<DatabaseService>()),
    );
  }
```

**Step 7: Update call sites**

Search for `ContentIngestionService()` in the codebase and replace with `getIt<ContentIngestionService>()`.

**Step 8: Run all tests**

Run: `flutter test`
Expected: All tests pass

**Step 9: Commit**

```bash
git add lib/services/content_ingestion_service.dart \
        lib/services/service_locator.dart \
        test/services/content_ingestion_service_test.dart \
        test/services/content_ingestion_service_test.mocks.dart
git commit -m "refactor: migrate ContentIngestionService to dependency injection"
```

---

### Task 6: Migrate ConversationService

**Files:**
- Modify: `lib/services/conversation_service.dart`
- Modify: `test/conversation_service_test.dart` (existing test file)
- Modify: `lib/services/service_locator.dart`

**Step 1: Review existing test**

The existing test at `test/conversation_service_test.dart` already uses `createForTesting`. We'll update to use GetIt pattern.

**Step 2: Modify ConversationService**

In `lib/services/conversation_service.dart`, change lines 10-30 from:

```dart
class ConversationService {
  // - [x] Batch processing in `ConversationService` <!-- id: 26 -->
  static final ConversationService _instance = ConversationService._internal();
  factory ConversationService() => _instance;
  ConversationService._internal({DatabaseService? databaseService})
    : _databaseService = databaseService ?? DatabaseService();

  final DatabaseService _databaseService;
  final Uuid _uuid = const Uuid();

  // For testing - allow injection of mock database service
  static ConversationService _testInstance = ConversationService._internal();
  static void setTestInstance(ConversationService instance) {
    _testInstance = instance;
  }

  static ConversationService getTestInstance() => _testInstance;

  static ConversationService createForTesting(DatabaseService databaseService) {
    return ConversationService._internal(databaseService: databaseService);
  }
```

To:

```dart
class ConversationService {
  final DatabaseService _databaseService;
  final Uuid _uuid = const Uuid();

  /// Creates a ConversationService.
  ///
  /// [databaseService] - The database service for conversation persistence.
  ConversationService(this._databaseService);

  /// Creates a ConversationService for testing with injected dependencies.
  @visibleForTesting
  static ConversationService createForTesting(DatabaseService databaseService) {
    return ConversationService(databaseService);
  }
```

Add import at top:

```dart
import 'package:flutter/foundation.dart';
```

**Step 3: Update existing tests**

In `test/conversation_service_test.dart`, update to use GetIt:

Add imports:

```dart
import 'package:note_synapse/services/service_locator.dart';
```

Update setUp to use GetIt pattern:

```dart
setUp(() async {
  resetForTesting();
  databaseService = DatabaseService.createNew();
  getIt.registerSingleton<DatabaseService>(databaseService);
  conversationService = ConversationService(getIt<DatabaseService>());
  await databaseService.clearAllData();
});
```

Add tearDown:

```dart
tearDown(() {
  resetForTesting();
});
```

**Step 4: Register in service locator**

In `lib/services/service_locator.dart`, add import:

```dart
import 'conversation_service.dart';
```

Add in Wave 2 section:

```dart
  if (!getIt.isRegistered<ConversationService>()) {
    getIt.registerLazySingleton<ConversationService>(
      () => ConversationService(getIt<DatabaseService>()),
    );
  }
```

**Step 5: Update call sites**

Search for `ConversationService()` throughout codebase and replace with `getIt<ConversationService>()`.

Key files to update:
- `lib/providers/app_provider.dart`
- `lib/screens/conversation_chat_screen.dart`
- `lib/screens/immersive_note_screen.dart`

**Step 6: Run all tests**

Run: `flutter test`
Expected: All tests pass

**Step 7: Commit**

```bash
git add lib/services/conversation_service.dart \
        lib/services/service_locator.dart \
        test/conversation_service_test.dart
git commit -m "refactor: migrate ConversationService to dependency injection"
```

---

## Checkpoint: Verify Foundation Complete

### Task 7: Integration Verification

**Step 1: Run full test suite**

Run: `flutter test`
Expected: All tests pass

**Step 2: Run app and smoke test**

Run: `flutter run -d macos`

Test manually:
- [ ] Create a new note
- [ ] Edit note content
- [ ] Add tags to note
- [ ] Start a conversation
- [ ] Send a message in conversation

**Step 3: Commit checkpoint**

```bash
git add -A
git commit -m "checkpoint: foundation DI migration complete (Wave 1-2)"
```

---

## Continuing Waves (Summary)

The pattern established above repeats for each service. For brevity, here's the order and dependencies for remaining waves:

### Wave 3: AI Infrastructure

| Service | Dependencies | Priority |
|---------|--------------|----------|
| `ContextManagerService` | DatabaseService | High |
| `ModelSelector` | DatabaseService | High |

### Wave 4: Complex AI Services

| Service | Dependencies | Priority |
|---------|--------------|----------|
| `AIService` | DatabaseService, ContextManagerService, ModelSelector | High |
| `AgentService` | DatabaseService, AIService, ContextManagerService | High |

### Wave 5: Remaining Services

| Service | Dependencies | Priority |
|---------|--------------|----------|
| `UserAppService` | DatabaseService | Medium |
| `ShareService` | DatabaseService | Medium |
| `AttachmentPreprocessor` | DatabaseService | Medium |

### Wave 6: UI Integration

| Component | Change | Priority |
|-----------|--------|----------|
| `AppProvider` | Get services from GetIt instead of creating | High |
| Screens | Replace `ServiceName()` with `getIt<ServiceName>()` | Medium |

---

## Verification Checklist

After completing all waves:

- [ ] `flutter test` passes all tests
- [ ] `flutter analyze` shows no errors
- [ ] App starts and basic functionality works
- [ ] New tests can mock any service using GetIt pattern
- [ ] `service_locator.dart` documents full dependency graph

---

## Test Template for Future Services

When migrating a new service, copy this template:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/YOUR_SERVICE.dart';

@GenerateMocks([DatabaseService])  // Add other dependencies as needed
import 'YOUR_SERVICE_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late YourService service;

  setUp(() {
    resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = YourService(getIt<DatabaseService>());
  });

  tearDown(() {
    resetForTesting();
  });

  group('YourService', () {
    test('describe behavior', () async {
      // Arrange
      when(mockDb.someMethod()).thenAnswer((_) async => expectedValue);

      // Act
      final result = await service.methodUnderTest();

      // Assert
      expect(result, expectedValue);
      verify(mockDb.someMethod()).called(1);
    });
  });
}
```
