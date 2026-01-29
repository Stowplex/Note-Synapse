# Dependency Injection Migration - Waves 4-5 Design

## Overview

Continue the DI migration from the original plan, focusing on services with existing tests to improve testability. This design covers Waves 4A, 4B, and 5.

**Goal:** Enable mock-based testing for core services by converting static methods to instance methods with injected dependencies.

## Current State

**Already registered in GetIt (5):**
- DatabaseService
- NoteModificationService
- ContentIngestionService
- ConversationService
- UserAppService

**Using getIt<> internally but not registered (9):**
- agent_service, ai_service, approval_service, fork_service, sql_query_service, starter_service, user_app_library_service, user_app_runtime_bridge, tools/note_tools

## Migration Plan

### Wave 4A: Model Infrastructure

**Dependency order:**
```
ModelStorageService (no deps)
    ↓
ModelPreferenceService (no deps)
    ↓
ModelSelector (depends on above)
    ↓
SqlQueryService (depends on DatabaseService)
```

#### 1. ModelStorageService

**Current:** All static methods using FlutterSecureStorage

**Target:**
```dart
class ModelStorageService {
  final FlutterSecureStorage _storage;

  ModelStorageService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage(...);

  Future<ModelConfig?> getActiveModel() async { ... }
  Future<void> activateModel(String modelId) async { ... }
  // ... convert all static methods to instance methods
}
```

**Registration:**
```dart
getIt.registerLazySingleton<ModelStorageService>(
  () => ModelStorageService(),
);
```

**Caller updates:** ~15 sites
- `ModelStorageService.method()` → `getIt<ModelStorageService>().method()`

#### 2. ModelPreferenceService

**Current:** DIY singleton pattern

**Target:**
```dart
class ModelPreferenceService {
  Future<List<String>> getPreferenceList() async { ... }
  Future<void> setPreferenceList(List<String> modelIds) async { ... }
}
```

**Registration:**
```dart
getIt.registerLazySingleton<ModelPreferenceService>(
  () => ModelPreferenceService(),
);
```

**Caller updates:** ~3 sites
- `ModelPreferenceService.instance.method()` → `getIt<ModelPreferenceService>().method()`

#### 3. ModelSelector

**Current:** DIY singleton with static `_instance` field

**Target:**
```dart
class ModelSelector {
  final ModelStorageService _modelStorage;
  final ModelPreferenceService _modelPreference;

  ModelSelector(this._modelStorage, this._modelPreference);

  // Keep existing instance methods, remove static singleton pattern
}
```

**Registration:**
```dart
getIt.registerLazySingleton<ModelSelector>(
  () => ModelSelector(
    getIt<ModelStorageService>(),
    getIt<ModelPreferenceService>(),
  ),
);
```

**Caller updates:** ~25 sites
- `ModelSelector.instance.method()` → `getIt<ModelSelector>().method()`

#### 4. SqlQueryService

**Current:** Optional injection with getIt fallback

**Target:**
```dart
class SqlQueryService {
  final DatabaseService _databaseService;

  SqlQueryService(this._databaseService);  // Required injection
}
```

**Registration:**
```dart
getIt.registerLazySingleton<SqlQueryService>(
  () => SqlQueryService(getIt<DatabaseService>()),
);
```

**Caller updates:** ~5 sites

---

### Wave 4B: Context Layer

#### ContextManagerService

**Current:** Instance-based but uses static calls

**Target:**
```dart
class ContextManagerService {
  final ModelSelector _modelSelector;

  ContextManagerService(this._modelSelector);

  void someMethod() {
    final config = _modelSelector.currentModelConfig;  // injected
    final threshold = await AgenticSettingsService.getCompactionThreshold();  // keep static
    final response = await AIService.generateWithAttachments(...);  // keep static until Wave 5
  }
}
```

**Registration:**
```dart
getIt.registerLazySingleton<ContextManagerService>(
  () => ContextManagerService(getIt<ModelSelector>()),
);
```

**Caller updates:** ~10 sites

**Note:** AIService injection deferred to Wave 5. AgenticSettingsService kept static (pure settings reader).

---

### Wave 5: Agent Layer

#### 5A: AIService

**Current:** All static methods, uses `getIt<DatabaseService>()` internally

**Target:**
```dart
class AIService {
  final DatabaseService _db;
  final ModelSelector _modelSelector;

  AIService(this._db, this._modelSelector);

  Future<String> generateWithAttachments(...) async { ... }
  Future<String> executePrompt(...) async { ... }
  // ... convert all static methods to instance methods
}
```

**Registration:**
```dart
getIt.registerLazySingleton<AIService>(
  () => AIService(
    getIt<DatabaseService>(),
    getIt<ModelSelector>(),
  ),
);
```

**Caller updates:** ~40 sites
- `AIService.method()` → `getIt<AIService>().method()`

**Post-migration:** Update ContextManagerService to inject AIService.

#### 5B: AgentService

**Current:** Creates ContextManagerService internally, uses static calls

**Target:**
```dart
class AgentService extends ChangeNotifier {
  final ContextManagerService _contextManager;
  final ModelSelector _modelSelector;
  final AIService _aiService;
  final DatabaseService _db;

  AgentService(
    this._contextManager,
    this._modelSelector,
    this._aiService,
    this._db,
  );
}
```

**Registration:**
```dart
getIt.registerLazySingleton<AgentService>(
  () => AgentService(
    getIt<ContextManagerService>(),
    getIt<ModelSelector>(),
    getIt<AIService>(),
    getIt<DatabaseService>(),
  ),
);
```

**Caller updates:** ~5 sites

**Note:** AgentService extends ChangeNotifier. UI accesses via Provider wrapping the GetIt instance.

---

### Wave 6: Deferred

| Service | Reason |
|---------|--------|
| ShareService | Complex UI state management, lower priority |

---

## Services Intentionally Skipped

These are pure utility classes with no meaningful state:

- **AttachmentPreprocessor** - Pure functions for file processing
- **McpToolIntegrationService** - Pure orchestration
- **LoggerService** - Logging utility
- **AgenticSettingsService** - Pure settings reader (SharedPreferences)

---

## Test Pattern

Each migrated service follows this test setup:

```dart
@GenerateMocks([DatabaseService, ModelSelector, ...])
import 'service_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late ServiceUnderTest service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    // ... register other mocks
    service = ServiceUnderTest(getIt<DatabaseService>());
  });

  tearDown(() async {
    await resetForTesting();
  });

  test('example', () async {
    when(mockDb.method()).thenAnswer((_) async => value);
    // test code
    verify(mockDb.method()).called(1);
  });
}
```

---

## Summary

| Wave | Services | Estimated Caller Updates |
|------|----------|-------------------------|
| 4A | ModelStorageService, ModelPreferenceService, ModelSelector, SqlQueryService | ~48 sites |
| 4B | ContextManagerService | ~10 sites |
| 5A | AIService | ~40 sites |
| 5B | AgentService | ~5 sites |
| **Total** | **8 services** | **~103 sites** |

## Verification Checkpoints

After each wave:
1. Run `flutter test` - all tests pass
2. Run `flutter analyze` - no new warnings
3. Manual smoke test of affected features
