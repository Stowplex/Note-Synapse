# Dependency Injection Refactoring Design

## Overview

Refactor the Note Synapse codebase to use proper dependency injection, enabling testability and reducing coupling between services.

**Goal:** Make services testable in isolation with mocked dependencies.

**Approach:** GetIt service locator with constructor injection, incremental TDD migration.

## Current Problems

| Problem | Evidence |
|---------|----------|
| No DI framework | 30+ direct `DatabaseService()` instantiations |
| Hard to test | Services create their own dependencies internally |
| Circular coupling | AppProvider ↔ Services (AIService, ModelSelector, ShareService) |
| Low test coverage | 36% services tested, 3% screens tested |
| God classes | `DatabaseService` = 4,661 lines, 143+ methods |

## Architecture Decision

### Hybrid Approach

- **GetIt** for services/repositories (business logic, data access)
- **Provider** for UI state (ChangeNotifiers that screens observe)

```
┌─────────────────────────────────────────────────────────┐
│                      Screens                             │
│  - Use Provider for UI state                            │
│  - Use getIt<Service> for business logic                │
└─────────────────────┬───────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────┐
│                    Providers                             │
│  - AppProvider holds UI state only                      │
│  - Gets services from GetIt in constructor              │
└─────────────────────┬───────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────┐
│                    Services                              │
│  - Registered in GetIt                                  │
│  - Accept dependencies via constructor                  │
│  - No direct instantiation of other services            │
└─────────────────────┬───────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────┐
│                  DatabaseService                         │
│  - Foundation layer                                     │
│  - Future: Split into repositories                      │
└─────────────────────────────────────────────────────────┘
```

## Service Locator Setup

### File: `lib/services/service_locator.dart`

```dart
import 'package:get_it/get_it.dart';
import 'package:flutter/foundation.dart';

final getIt = GetIt.instance;

/// Initialize all services. Call once in main().
///
/// FOR TESTING: Call [resetForTesting] then register mocks before each test.
///
/// Example test setup:
/// ```dart
/// setUp(() {
///   resetForTesting();
///   getIt.registerSingleton<DatabaseService>(MockDatabaseService());
/// });
/// ```
void setupServiceLocator() {
  // ============================================================
  // WAVE 1: Foundation
  // ============================================================
  getIt.registerLazySingleton<DatabaseService>(
    () => DatabaseService(),
  );

  // ============================================================
  // WAVE 2: Simple services (depend only on DatabaseService)
  // ============================================================
  getIt.registerLazySingleton<TagService>(
    () => TagService(getIt<DatabaseService>()),
  );
  getIt.registerLazySingleton<NoteModificationService>(
    () => NoteModificationService(getIt<DatabaseService>()),
  );
  getIt.registerLazySingleton<RelationshipService>(
    () => RelationshipService(getIt<DatabaseService>()),
  );

  // ============================================================
  // WAVE 3: Services used by AI layer
  // ============================================================
  getIt.registerLazySingleton<ConversationService>(
    () => ConversationService(getIt<DatabaseService>()),
  );
  getIt.registerLazySingleton<AttachmentService>(
    () => AttachmentService(getIt<DatabaseService>()),
  );

  // ============================================================
  // WAVE 4: AI infrastructure
  // ============================================================
  getIt.registerLazySingleton<ContextManagerService>(
    () => ContextManagerService(getIt<DatabaseService>()),
  );
  getIt.registerLazySingleton<ModelSelector>(
    () => ModelSelector(getIt<DatabaseService>()),
  );

  // ============================================================
  // WAVE 5: Complex AI services
  // ============================================================
  getIt.registerLazySingleton<AIService>(
    () => AIService(
      getIt<DatabaseService>(),
      getIt<ContextManagerService>(),
      getIt<ModelSelector>(),
    ),
  );
  getIt.registerLazySingleton<AgentService>(
    () => AgentService(
      getIt<DatabaseService>(),
      getIt<AIService>(),
      getIt<ContextManagerService>(),
    ),
  );

  // ============================================================
  // WAVE 6: Less frequently changed services
  // ============================================================
  getIt.registerLazySingleton<UserAppService>(
    () => UserAppService(getIt<DatabaseService>()),
  );
  getIt.registerLazySingleton<ShareService>(
    () => ShareService(getIt<DatabaseService>()),
  );
}

/// Reset all registrations. USE ONLY IN TESTS.
///
/// Call this in setUp() before registering mock services.
@visibleForTesting
void resetForTesting() {
  getIt.reset();
}
```

## Test Injection Pattern

### Standard Test Setup

```dart
// test/services/example_service_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:get_it/get_it.dart';
import 'package:note_synapse/services/service_locator.dart';

@GenerateMocks([DatabaseService])
import 'example_service_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late ExampleService service;

  setUp(() {
    // Step 1: Reset GetIt (clears all registrations)
    resetForTesting();

    // Step 2: Register mocks
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);

    // Step 3: Create service under test with injected mock
    service = ExampleService(getIt<DatabaseService>());
  });

  tearDown(() {
    resetForTesting();
  });

  test('example test with mock', () async {
    // Arrange
    when(mockDb.getAllNotes()).thenAnswer((_) async => []);

    // Act
    final result = await service.loadNotes();

    // Assert
    expect(result, isEmpty);
    verify(mockDb.getAllNotes()).called(1);
  });
}
```

### Generating Mocks

Run after adding `@GenerateMocks` annotation:

```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

## TDD Migration Template

For each service, follow these steps:

### Step 1: Write Test First

```dart
// test/services/{service_name}_test.dart

@GenerateMocks([DatabaseService])
import '{service_name}_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late ServiceName service;

  setUp(() {
    resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = ServiceName(getIt<DatabaseService>());
  });

  group('methodName', () {
    test('should do expected behavior', () async {
      // Arrange
      when(mockDb.someMethod()).thenAnswer((_) async => expectedValue);

      // Act
      final result = await service.methodName();

      // Assert
      expect(result, expectedValue);
    });
  });
}
```

### Step 2: Refactor Service

```dart
// lib/services/{service_name}.dart

class ServiceName {
  final DatabaseService _db;

  // Constructor injection
  ServiceName(this._db);

  // REMOVE: final DatabaseService _db = DatabaseService();

  Future<Result> methodName() async {
    return await _db.someMethod();
  }
}
```

### Step 3: Register in Service Locator

```dart
// lib/services/service_locator.dart

getIt.registerLazySingleton<ServiceName>(
  () => ServiceName(getIt<DatabaseService>()),
);
```

### Step 4: Update Call Sites

```dart
// Before
final service = ServiceName();

// After
final service = getIt<ServiceName>();
```

### Step 5: Verify

```bash
# Run tests
flutter test

# Run app and verify functionality
flutter run
```

## Migration Order

### Foundation (Do First)

| Task ID | Description | Files |
|---------|-------------|-------|
| F1 | Add GetIt + Mockito to pubspec.yaml | `pubspec.yaml` |
| F2 | Create service_locator.dart skeleton | `lib/services/service_locator.dart` |
| F3 | Register DatabaseService in GetIt | `lib/services/service_locator.dart` |
| F4 | Update main.dart to call setupServiceLocator() | `lib/main.dart` |

### Wave 1: DatabaseService

| Task ID | Description |
|---------|-------------|
| W1-1 | Write DatabaseService integration tests (existing behavior) |
| W1-2 | Verify app works with GetIt-provided DatabaseService |

### Wave 2: Simple Services

| Task ID | Service | Dependencies |
|---------|---------|--------------|
| W2-1 | TagService | DatabaseService |
| W2-2 | NoteModificationService | DatabaseService |
| W2-3 | RelationshipService | DatabaseService |

### Wave 3: Conversation/Attachment

| Task ID | Service | Dependencies |
|---------|---------|--------------|
| W3-1 | ConversationService | DatabaseService |
| W3-2 | AttachmentService | DatabaseService |

### Wave 4: AI Infrastructure

| Task ID | Service | Dependencies |
|---------|---------|--------------|
| W4-1 | ContextManagerService | DatabaseService |
| W4-2 | ModelSelector | DatabaseService |

### Wave 5: Complex AI Services

| Task ID | Service | Dependencies |
|---------|---------|--------------|
| W5-1 | AIService | DatabaseService, ContextManagerService, ModelSelector |
| W5-2 | AgentService | DatabaseService, AIService, ContextManagerService |

### Wave 6: Remaining Services

| Task ID | Service | Dependencies |
|---------|---------|--------------|
| W6-1 | UserAppService | DatabaseService |
| W6-2 | ShareService | DatabaseService |

## UI Migration

After service layer migration is complete.

### Phase B: Screen Migration

For each screen, replace direct service instantiation:

```dart
// Before
class _MyScreenState extends State<MyScreen> {
  final _db = DatabaseService();
}

// After
class _MyScreenState extends State<MyScreen> {
  late final DatabaseService _db;

  @override
  void initState() {
    super.initState();
    _db = getIt<DatabaseService>();
  }
}
```

### Phase C: Simplify AppProvider

Remove service references from AppProvider, keep only UI state:

```dart
// After: AppProvider holds only UI state
class AppProvider extends ChangeNotifier {
  List<Note> _notes = [];
  List<Tag> _tags = [];
  bool _isLoading = false;

  // Load data using services from GetIt
  Future<void> loadData() async {
    final db = getIt<DatabaseService>();
    _notes = await db.getAllNotes();
    notifyListeners();
  }
}
```

### Phase D: Optional Facades

For complex screens with many dependencies, consider facade services:

```dart
// lib/services/facades/immersive_note_facade.dart
class ImmersiveNoteFacade {
  final DatabaseService _db;
  final ConversationService _conversations;
  final AIService _ai;

  ImmersiveNoteFacade(this._db, this._conversations, this._ai);

  // High-level operations the screen needs
}
```

## Verification

After each migration step:

1. **Run all tests:** `flutter test`
2. **Run the app:** `flutter run`
3. **Smoke test affected functionality:**
   - For database services: Create, edit, delete a note
   - For conversation services: Start a conversation, send messages
   - For AI services: Trigger AI summarization or analysis

## Future Work

This plan focuses on dependency injection. Follow-up plans:

1. **Screen Architecture (MVVM):** Extract ViewModels from screens, separate business logic from UI
2. **DatabaseService Decomposition:** Split into NoteRepository, TagRepository, ConversationRepository, etc.

## Dependencies

Add to `pubspec.yaml`:

```yaml
dependencies:
  get_it: ^7.6.0

dev_dependencies:
  mockito: ^5.4.0
  build_runner: ^2.4.0
```

## Task Summary

| Phase | Tasks |
|-------|-------|
| Foundation | 4 |
| Waves 1-6 (Services) | ~60 |
| Phase B (Screens) | ~35 |
| Phase C (AppProvider) | ~5 |
| **Total** | **~104** |
