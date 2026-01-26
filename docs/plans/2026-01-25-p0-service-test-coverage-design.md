# P0 Service Test Coverage Design

## Overview

Improve test coverage for the five P0 (highest priority) services that power the AI/agent functionality.

**Goal:** Increase coverage from current ~15% average to 50%+ for critical AI services.

**Services in scope:**
| Service | Current Coverage | Target | Status |
|---------|-----------------|--------|--------|
| user_app_service | 0% | 70%+ | No tests exist |
| conversation_ai_engine | 1.7% | 60%+ | No tests exist |
| mcp_service | 0% | 50%+ | Needs refactor first |
| agent_service | 46% | 60%+ | Has tests, improve |
| ai_service | 26% | 40%+ | Has tests, improve |

## Phase 1: UserAppService Tests

**Why first:** Already has `createForTesting()` factory - easiest to test.

### Test Structure

```dart
@GenerateMocks([DatabaseService, AIService])
import 'user_app_service_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late MockAIService mockAi;
  late UserAppService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockAi = MockAIService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<AIService>(mockAi);
    service = UserAppService.createForTesting(mockDb, mockAi);
  });

  tearDown(() async {
    await resetForTesting();
  });
}
```

### Test Categories

**1. CRUD Operations (~8 tests)**
- getAllUserApps returns empty list when no apps
- getAllUserApps returns apps from database
- saveUserApp inserts new app and creates initial revision
- updateUserApp updates existing app
- deleteUserApp removes app and all revisions

**2. State Management (~4 tests)**
- getAppState returns null for non-existent app
- getAppState returns saved state
- saveAppState persists state correctly

**3. Revision Management (~6 tests)**
- getAppRevisions returns revisions for app
- setSelectedRevision updates app's selected revision
- deleteAppRevision removes revision
- createInitialRevision creates revision with code

**4. AI Workflows (~4 tests)**
- createUserApp calls AI and saves result
- createUserApp handles AI error gracefully
- editUserApp generates updated code
- parseAIResponse extracts HTML correctly

### Dependencies to Mock
- `DatabaseService` - all DB operations
- `AIService` - `generateApp()` calls

### Out of Scope (Phase 1)
- `fetchWebPage()` - WebView complexity, defer to integration tests
- Library downloading - network dependency

---

## Phase 2: ConversationAiEngine Tests

**Challenge:** Complex callback-based architecture with tool iteration loops.

### Test Approach

```dart
@GenerateMocks([ModelSelector])
import 'conversation_ai_engine_test.mocks.dart';

void main() {
  late MockModelSelector mockSelector;
  late ConversationAiEngine engine;

  setUp(() async {
    await resetForTesting();
    mockSelector = MockModelSelector();
    getIt.registerSingleton<ModelSelector>(mockSelector);
    engine = ConversationAiEngine();
  });
}
```

### Test Categories

**1. Basic Generation (~4 tests)**
- generate returns text response when no tools
- generate handles empty response
- generate respects cancellation callback

**2. Tool Iteration (~6 tests)**
- executes tool when function_call received
- handles tool error gracefully
- respects max iterations limit
- calls onIterationsExhausted when limit reached
- accumulates parts_history across iterations

**3. Error Handling (~3 tests)**
- handles model error gracefully
- handles unknown function calls
- logs errors appropriately

### Mock Strategy
- Mock `getIt<ModelSelector>()` to return controlled responses
- Inject mock callbacks for `executeTool`, `isCancelled`, `onIterationsExhausted`
- Control iteration count via mock response structure

---

## Phase 3: McpService Refactor + Tests

**Challenge:** Currently all static methods with hard-coded storage - untestable.

### Refactoring Plan

**Before:**
```dart
class McpService {
  static const _storage = FlutterSecureStorage(...);
  static Future<List<McpEndpoint>> getEndpoints() async { ... }
}
```

**After:**
```dart
class McpService {
  final FlutterSecureStorage _storage;

  McpService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(...);

  Future<List<McpEndpoint>> getEndpoints() async { ... }
}
```

### Registration
```dart
// service_locator.dart
getIt.registerLazySingleton<McpService>(() => McpService());
```

### Test Categories

**1. Endpoint Management (~6 tests)**
- getEndpoints returns empty list initially
- addEndpoint persists endpoint
- updateEndpoint modifies existing
- deleteEndpoint removes endpoint
- getBearerToken returns stored token

**2. Tool Operations (~4 tests)**
- getCachedTools returns cached tools
- refreshTools fetches from endpoint (mocked)
- callTool executes tool (mocked)

### Dependencies to Mock
- `FlutterSecureStorage` - inject via constructor
- `SharedPreferences` - use `SharedPreferences.setMockInitialValues()`
- MCP client - mock network responses

---

## Success Criteria

1. All new tests pass
2. No regressions in existing tests
3. Coverage improvements:
   - user_app_service: 0% → 70%+
   - conversation_ai_engine: 1.7% → 60%+
   - mcp_service: 0% → 50%+
4. `flutter test` passes
5. `flutter analyze` has no new errors

## Estimated Effort

| Phase | Service | New Test Lines | Effort |
|-------|---------|---------------|--------|
| 1 | user_app_service | ~400-500 | Medium |
| 2 | conversation_ai_engine | ~300-400 | Medium-High |
| 3 | mcp_service | ~300 + refactor | High |

## Files to Create/Modify

**New files:**
- `test/services/user_app_service_test.dart`
- `test/services/conversation_ai_engine_test.dart`
- `test/services/mcp_service_test.dart`

**Modified files:**
- `lib/services/mcp_service.dart` (refactor to instance-based)
- `lib/services/service_locator.dart` (register McpService)
- Callers of McpService (update to use getIt)
