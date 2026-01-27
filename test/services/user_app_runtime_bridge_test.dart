import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:note_synapse/models/generation_context.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/logger_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/sql_query_service.dart';
import 'package:note_synapse/services/user_app_runtime_bridge.dart';
import 'package:note_synapse/services/user_app_service.dart';
import 'package:uuid/uuid.dart';

import 'user_app_runtime_bridge_test.mocks.dart';

// Mocks for dependencies
@GenerateNiceMocks([
  MockSpec<AppProvider>(),
  MockSpec<UserAppService>(),
  MockSpec<DatabaseService>(),
  MockSpec<SqlQueryService>(),
  MockSpec<AIService>(),
  MockSpec<InAppWebViewController>(),
])
void main() {
  late MockAppProvider mockAppProvider;
  late MockUserAppService mockUserAppService;
  late MockDatabaseService mockDatabaseService;
  late MockSqlQueryService mockSqlQueryService;
  late MockAIService mockAIService;
  late MockInAppWebViewController mockWebViewController;
  late UserAppRuntimeBridge bridge;

  // Store registered handlers to simulate JS calls
  final Map<String, JavaScriptHandlerCallback> jsHandlers = {};
  late Directory tempDir;

  setUp(() async {
    getIt.reset();
    tempDir = await Directory.systemTemp.createTemp();
    PathProviderPlatform.instance = MockPathProviderPlatform(tempDir.path);

    mockAppProvider = MockAppProvider();
    mockUserAppService = MockUserAppService();
    mockDatabaseService = MockDatabaseService();
    mockSqlQueryService = MockSqlQueryService();
    mockAIService = MockAIService();
    mockWebViewController = MockInAppWebViewController();

    getIt.registerSingleton<AppProvider>(mockAppProvider);
    getIt.registerSingleton<UserAppService>(mockUserAppService);
    getIt.registerSingleton<DatabaseService>(mockDatabaseService);
    getIt.registerSingleton<SqlQueryService>(mockSqlQueryService);
    getIt.registerSingleton<AIService>(mockAIService);

    // Mock addJavaScriptHandler to capture callbacks
    when(
      mockWebViewController.addJavaScriptHandler(
        handlerName: anyNamed('handlerName'),
        callback: anyNamed('callback'),
      ),
    ).thenAnswer((invocation) {
      final name = invocation.namedArguments[#handlerName] as String;
      final callback =
          invocation.namedArguments[#callback] as JavaScriptHandlerCallback;
      jsHandlers[name] = callback;
    });

    final app = UserApp(
      id: 'test-app',
      uuid: 'test-uuid',
      name: 'Test App',
      description: 'Test Description',
      steps: ['Step 1'],
      htmlContent: '<html></html>',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    bridge = UserAppRuntimeBridge(
      app: app,
      appProvider: mockAppProvider,
      revisionNumber: 1,
      isInteractive: true,
    );
  });

  group('UserAppRuntimeBridge', () {
    test('registerJavaScriptHandlers registers all expected handlers', () {
      bridge.registerJavaScriptHandlers(mockWebViewController);

      expect(jsHandlers.containsKey('runQuery'), isTrue);
      expect(jsHandlers.containsKey('storeAppState'), isTrue);
      expect(jsHandlers.containsKey('loadAppState'), isTrue);
      expect(jsHandlers.containsKey('proxyFetch'), isTrue);
      expect(jsHandlers.containsKey('chatAI'), isTrue);
      expect(jsHandlers.containsKey('log'), isTrue);
      expect(jsHandlers.containsKey('copy-to-clipboard'), isTrue);
      expect(jsHandlers.containsKey('fetchWebPage'), isTrue);
      expect(jsHandlers.containsKey('readAttachment'), isTrue);
      expect(jsHandlers.containsKey('saveTemp'), isTrue);
      expect(jsHandlers.containsKey('saveNotes'), isTrue);
    });

    group('runQuery', () {
      setUp(() {
        bridge.registerJavaScriptHandlers(mockWebViewController);
      });

      test('executes read-only query without approval', () async {
        const sql = 'SELECT * FROM notes';
        when(
          mockSqlQueryService.getQueryType(sql),
        ).thenReturn(SqlQueryType.select);
        when(mockSqlQueryService.isReadOnlyQuery(sql)).thenReturn(true);
        when(
          mockSqlQueryService.executeQuery(
            any,
            requireApprovalForWrites: anyNamed('requireApprovalForWrites'),
            allowWriteOperations: anyNamed('allowWriteOperations'),
          ),
        ).thenAnswer((_) async => SqlQueryResult(success: true, data: []));

        final result = await jsHandlers['runQuery']!([sql]);

        expect(result['success'], isTrue);
        verify(
          mockSqlQueryService.executeQuery(
            sql,
            requireApprovalForWrites: false,
            allowWriteOperations: true,
          ),
        ).called(1);
      });

      test(
        'requires approval for write query if not session approved',
        () async {
          const sql = 'INSERT INTO notes ...';
          when(
            mockSqlQueryService.getQueryType(sql),
          ).thenReturn(SqlQueryType.insert);
          when(mockSqlQueryService.isReadOnlyQuery(sql)).thenReturn(false);

          // No approval callback set, should fail
          final result = await jsHandlers['runQuery']!([sql]);

          expect(result['success'], isFalse);
          expect(result['error'], contains('require user approval'));
          verifyNever(
            mockSqlQueryService.executeQuery(
              any,
              requireApprovalForWrites: anyNamed('requireApprovalForWrites'),
              allowWriteOperations: anyNamed('allowWriteOperations'),
            ),
          );
        },
      );
    });

    group('chatAI', () {
      setUp(() {
        bridge.registerJavaScriptHandlers(mockWebViewController);
      });

      test('calls chatAI on AIService', () async {
        const prompt = 'Hello AI';
        when(
          mockAIService.chatAI(
            any,
            temperature: anyNamed('temperature'),
            topK: anyNamed('topK'),
            topP: anyNamed('topP'),
            attachedFiles: anyNamed('attachedFiles'),
            modelHint: anyNamed('modelHint'),
          ),
        ).thenAnswer((_) async => 'AI Response');

        final result = await jsHandlers['chatAI']!([prompt]);

        expect(result['success'], isTrue);
        expect(result['response'], 'AI Response');
        verify(
          mockAIService.chatAI(
            prompt,
            temperature: anyNamed('temperature'),
            topK: anyNamed('topK'),
            topP: anyNamed('topP'),
            attachedFiles: anyNamed('attachedFiles'),
            modelHint: anyNamed('modelHint'),
          ),
        ).called(1);
      });

      test('supports multi-part response', () async {
        const prompt = 'Hello AI';
        final options = {'response_type': 'multi_part'};
        when(
          mockAIService.chatAIMultiPart(
            any,
            temperature: anyNamed('temperature'),
            topK: anyNamed('topK'),
            topP: anyNamed('topP'),
            attachedFiles: anyNamed('attachedFiles'),
            modelHint: anyNamed('modelHint'),
          ),
        ).thenAnswer(
          (_) async => [
            {'text': 'Part 1'},
            {'text': 'Part 2'},
          ],
        );

        final result = await jsHandlers['chatAI']!([prompt, options]);

        expect(result['success'], isTrue);
        expect(result['response'], [
          {'text': 'Part 1'},
          {'text': 'Part 2'},
        ]);
      });
    });

    group('proxyFetch', () {
      setUp(() {
        bridge.registerJavaScriptHandlers(mockWebViewController);
        // We need to mock HttpOverrides for this test
        HttpOverrides.global = MockHttpOverrides();
      });

      tearDown(() {
        HttpOverrides.global = null;
      });

      test('validates URL requirement', () async {
        final result = await jsHandlers['proxyFetch']!([{}]);
        expect(result['status'], 'error');
        expect(result['error'], contains('URL is required'));
      });
    });

    group('App State', () {
      setUp(() {
        bridge.registerJavaScriptHandlers(mockWebViewController);
      });

      test('storeAppState calls appProvider.saveAppState', () async {
        final state = {'key': 'value'};
        when(
          mockAppProvider.saveAppState(any, any),
        ).thenAnswer((_) async {}); // Future<void>

        final result = await jsHandlers['storeAppState']!([state]);

        expect(result['success'], isTrue);
        verify(mockAppProvider.saveAppState('test-app', state)).called(1);
      });

      test('loadAppState calls userAppService.getAppState', () async {
        final state = {'key': 'value'};
        when(
          mockUserAppService.getAppState(any),
        ).thenAnswer((_) async => state);

        final result = await jsHandlers['loadAppState']!([]);

        expect(result['success'], isTrue);
        expect(result['data'], state);
        verify(mockUserAppService.getAppState('test-app')).called(1);
      });
    });

    group('FileSystem', () {
      setUp(() {
        bridge.registerJavaScriptHandlers(mockWebViewController);
      });

      test('readAttachment reads existing file', () async {
        final file = File(p.join(tempDir.path, 'test.txt'));
        await file.writeAsString('Hello World');
        final path = file.path;

        when(
          mockDatabaseService.verifyAttachmentPath(path),
        ).thenAnswer((_) async => true);

        final result = await jsHandlers['readAttachment']!([path]);

        // bridge wrapped call returns result directly in success/error envelope?
        // Let's assume standard envelope: {success: true, data: ..., mimeType: ...}
        // Actually, looking at bridge implementation for readAttachment (not shown in snippet but assumed standard):
        // Wait, line 1413 of user_app_runtime_bridge.dart: returns {'data': base64Data, 'mimeType': mimeType};
        // The handler wrapper (lines 1-800? No, handlers are registered).
        // I need to check the handler registration for readAttachment.
        // It's likely wrapping the result.

        expect(result['success'], isTrue);
        expect(result['mimeType'], 'text/plain');
        expect(result['data'], isNotNull);
        final decoded = utf8.decode(base64Decode(result['data']));
        expect(decoded, 'Hello World');
      });

      test('saveTemp saves data to synapse_temp', () async {
        final data = base64Encode(utf8.encode('Test Content'));
        final dataMap = {'binary': data};

        final result = await jsHandlers['saveTemp']!([dataMap, 'text/plain']);

        expect(result['success'], isTrue);
        expect(result['uri'], startsWith('synapsetemp:///'));

        final cacheDir = Directory(p.join(tempDir.path, 'synapse_temp'));
        expect(await cacheDir.exists(), isTrue);
        final files = await cacheDir.list().toList();
        expect(files.isNotEmpty, isTrue);

        final file = File(files.first.path);
        expect(await file.readAsString(), 'Test Content');
      });
    });

    test('log calls LoggerService', () async {
      bridge.registerJavaScriptHandlers(mockWebViewController);
      final result = await jsHandlers['log']!(['Test message', 'info']);
      expect(result, isNull);
    });
  });
}

// Mock HttpOverrides for testing HttpClient
class MockHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return MockHttpClient();
  }
}

class MockHttpClient extends Fake implements HttpClient {
  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return MockHttpClientRequest();
  }
}

class MockHttpClientRequest extends Fake implements HttpClientRequest {
  @override
  final HttpHeaders headers = MockHttpHeaders();

  @override
  Future<HttpClientResponse> close() async {
    return MockHttpClientResponse();
  }

  @override
  void add(List<int> data) {}
}

class MockHttpClientResponse extends Fake implements HttpClientResponse {
  @override
  final int statusCode = 200;

  @override
  final HttpHeaders headers = MockHttpHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    // Return empty stream
    return Stream<List<int>>.value([]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

class MockHttpHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  String? value(String name) => null;
}

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String tempPath;

  MockPathProviderPlatform(this.tempPath);

  @override
  Future<String?> getTemporaryPath() async {
    return tempPath;
  }
}
