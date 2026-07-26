import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
import 'package:note_synapse/services/approval_service.dart';
import 'package:note_synapse/services/block_note_scope_service.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/logger_service.dart';
import 'package:note_synapse/services/note_modification_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/sql_query_service.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';
import 'package:note_synapse/services/tts_service.dart';
import 'package:note_synapse/services/user_app_runtime_bridge.dart';
import 'package:note_synapse/services/user_app_service.dart';
import 'package:note_synapse/services/web_session_service.dart';
import 'package:note_synapse/services/app_domain_grant_service.dart';
import 'package:note_synapse/services/crypto_service.dart';
import 'package:note_synapse/services/plugin_task_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'user_app_runtime_bridge_test.mocks.dart';
import 'package:note_synapse/utils/file_utils.dart';

/// In-memory [SessionStorageBackend] so [WebSessionService] is deterministic in
/// tests. Seed [data] with `web_session_<domain>` entries to simulate a login.
class _MemoryStorage implements SessionStorageBackend {
  final Map<String, String> data = {};
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// [CookieGateway] that records restores and returns nothing.
class _NoopCookieGateway implements CookieGateway {
  @override
  Future<List<WebSessionCookie>> getCookies(String url) async => const [];
  @override
  Future<void> setCookie(String url, WebSessionCookie cookie) async {}
  @override
  Future<void> deleteCookies(String url) async {}
}

// Mocks for dependencies
@GenerateNiceMocks([
  MockSpec<AppProvider>(),
  MockSpec<UserAppService>(),
  MockSpec<DatabaseService>(),
  MockSpec<SqlQueryService>(),
  MockSpec<AIService>(),
  MockSpec<InAppWebViewController>(),
  MockSpec<NoteModificationService>(),
])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockAppProvider mockAppProvider;
  late MockUserAppService mockUserAppService;
  late MockDatabaseService mockDatabaseService;
  late MockSqlQueryService mockSqlQueryService;
  late MockAIService mockAIService;
  late MockInAppWebViewController mockWebViewController;
  late MockNoteModificationService mockModificationService;
  late RecordingTtsService fakeTtsService;
  late UserAppRuntimeBridge bridge;
  late _MemoryStorage sessionStorage;
  late AppDomainGrantService grantService;

  // Store registered handlers to simulate JS calls
  final Map<String, JavaScriptHandlerCallback> jsHandlers = {};
  late Directory tempDir;

  setUp(() async {
    getIt.reset();
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp();
    PathProviderPlatform.instance = MockPathProviderPlatform(tempDir.path);
    FileUtils.resetDocumentsPathCache();

    mockAppProvider = MockAppProvider();
    mockUserAppService = MockUserAppService();
    mockDatabaseService = MockDatabaseService();
    mockSqlQueryService = MockSqlQueryService();
    mockSqlQueryService = MockSqlQueryService();
    mockAIService = MockAIService();
    mockWebViewController = MockInAppWebViewController();
    mockModificationService = MockNoteModificationService();
    fakeTtsService = RecordingTtsService();

    getIt.registerSingleton<AppProvider>(mockAppProvider);
    getIt.registerSingleton<UserAppService>(mockUserAppService);
    getIt.registerSingleton<DatabaseService>(mockDatabaseService);
    getIt.registerSingleton<SqlQueryService>(mockSqlQueryService);
    getIt.registerSingleton<AIService>(mockAIService);
    getIt.registerSingleton<NoteModificationService>(mockModificationService);
    getIt.registerSingleton<TtsService>(fakeTtsService);

    sessionStorage = _MemoryStorage();
    getIt.registerSingleton<WebSessionService>(
      WebSessionService(
        cookieGateway: _NoopCookieGateway(),
        storage: sessionStorage,
      ),
    );
    grantService = AppDomainGrantService(
      prefs: await SharedPreferences.getInstance(),
    );
    getIt.registerSingleton<AppDomainGrantService>(grantService);
    getIt.registerSingleton<CryptoService>(CryptoService());
    getIt.registerSingleton<PluginTaskService>(
      PluginTaskService(prefs: await SharedPreferences.getInstance()),
    );

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
      expect(jsHandlers.containsKey('originFetch'), isTrue);
      expect(jsHandlers.containsKey('sessionRequestLogin'), isTrue);
      expect(jsHandlers.containsKey('sessionStatus'), isTrue);
      expect(jsHandlers.containsKey('sessionGetCookies'), isTrue);
      expect(jsHandlers.containsKey('cryptoDigest'), isTrue);
      expect(jsHandlers.containsKey('downloadFile'), isTrue);
      expect(jsHandlers.containsKey('exportNotes'), isTrue);
      expect(jsHandlers.containsKey('pickNotes'), isTrue);
      expect(jsHandlers.containsKey('pickTags'), isTrue);
      expect(jsHandlers.containsKey('tasksSchedule'), isTrue);
      expect(jsHandlers.containsKey('tasksCancel'), isTrue);
      expect(jsHandlers.containsKey('tasksList'), isTrue);
      expect(jsHandlers.containsKey('chatAI'), isTrue);
      expect(jsHandlers.containsKey('log'), isTrue);
      expect(jsHandlers.containsKey('copy-to-clipboard'), isTrue);
      expect(jsHandlers.containsKey('fetchWebPage'), isTrue);
      expect(jsHandlers.containsKey('readAttachment'), isTrue);
      expect(jsHandlers.containsKey('saveTemp'), isTrue);
      expect(jsHandlers.containsKey('saveNotes'), isTrue);
      expect(jsHandlers.containsKey('ttsSpeak'), isTrue);
      expect(jsHandlers.containsKey('ttsStop'), isTrue);
      expect(jsHandlers.containsKey('ttsGetLanguages'), isTrue);
    });

    group('buildBootstrapScript', () {
      test('emits Synapse.Notes and Synapse.Params from the bridge params', () {
        final localBridge = UserAppRuntimeBridge(
          app: UserApp(
            id: 'a',
            uuid: 'u',
            name: 'App',
            description: '',
            steps: const [],
            htmlContent: '',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
          appProvider: mockAppProvider,
          revisionNumber: 1,
          isInteractive: true,
          params: const {
            'zoom': 12,
            'style': 'dark',
            'pins': [
              {'lat': 37.77, 'lng': -122.41},
            ],
          },
        );

        final source = localBridge.buildBootstrapScript().source;
        expect(source, contains('Notes:'));
        expect(source, contains('Params:'));
        expect(source, contains('"zoom":12'));
        expect(source, contains('"style":"dark"'));
        expect(source, contains('"pins":[{"lat":37.77,"lng":-122.41}]'));
      });

      test('emits empty Params object when no params are passed', () {
        final source = bridge.buildBootstrapScript().source;
        expect(source, contains('Params: {}'));
      });
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

      test('surfaces truncation info in the response', () async {
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
        ).thenAnswer(
          (_) async => SqlQueryResult(
            success: true,
            data: List.generate(100, (i) => {'id': '$i'}),
            truncated: true,
            totalRows: 250,
          ),
        );

        final result = await jsHandlers['runQuery']!([sql]);

        expect(result['success'], isTrue);
        expect(result['truncated'], isTrue);
        expect(result['totalRows'], 250);
      });

      test('omits truncation info when results are complete', () async {
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
        ).thenAnswer(
          (_) async => SqlQueryResult(
            success: true,
            data: [
              {'id': '1'},
            ],
          ),
        );

        final result = await jsHandlers['runQuery']!([sql]);

        expect(result['success'], isTrue);
        expect(result.containsKey('truncated'), isFalse);
        expect(result.containsKey('totalRows'), isFalse);
      });
    });

    group('tts handlers', () {
      setUp(() {
        bridge.registerJavaScriptHandlers(mockWebViewController);
      });

      test('ttsSpeak forwards text and options to TtsService', () async {
        final result = await jsHandlers['ttsSpeak']!([
          'Bonjour',
          {'language': 'fr-FR', 'rate': 0.4},
        ]);

        expect(result['success'], isTrue);
        expect(fakeTtsService.speakCalls, [
          {
            'text': 'Bonjour',
            'language': 'fr-FR',
            'rate': 0.4,
            'pitch': null,
            'volume': null,
          },
        ]);
      });

      test('ttsSpeak rejects empty text', () async {
        final result = await jsHandlers['ttsSpeak']!(['   ']);

        expect(result['success'], isFalse);
        expect(fakeTtsService.speakCalls, isEmpty);
      });

      test('ttsStop delegates to TtsService', () async {
        final result = await jsHandlers['ttsStop']!([]);

        expect(result['success'], isTrue);
        expect(fakeTtsService.stopCalls, 1);
      });

      test('ttsGetLanguages returns languages from TtsService', () async {
        fakeTtsService.languages = ['en-US', 'ja-JP'];

        final result = await jsHandlers['ttsGetLanguages']!([]);

        expect(result['success'], isTrue);
        expect(result['data'], ['en-US', 'ja-JP']);
      });
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

      test(
        'session:true without a grant and no approval UI is denied',
        () async {
          // Permission is checked before any network request is made.
          final result = await jsHandlers['proxyFetch']!([
            {'url': 'https://example.com/api', 'session': true},
          ]);
          expect(result['status'], 'error');
          expect(result['error'], 'permission_required');
        },
      );

      test('multipart with a non-ASCII filename does not crash', () async {
        final result = await jsHandlers['proxyFetch']!([
          {
            'url': 'https://example.com/upload',
            'method': 'POST',
            'multipart': [
              {
                'name': 'file',
                'filename': '笔记.pdf',
                'mimeType': 'application/pdf',
                'dataBase64': base64Encode(utf8.encode('hello')),
              },
            ],
          },
        ]);
        // Before the fix, ascii.encode on the filename threw FormatException.
        expect(result['status'], 'success');
      });

      test(
        'downloadFile without a grant and no approval UI is denied',
        () async {
          // Permission is checked before any network request is made.
          final result = await jsHandlers['downloadFile']!([
            {'url': 'https://example.com/file.m4a'},
          ]);
          expect(result['status'], 'error');
          expect(result['error'], 'permission_required');
        },
      );

      test(
        'Set-Cookie is stripped from the response headers exposed to JS',
        () async {
          final result = await jsHandlers['proxyFetch']!([
            {'url': 'https://example.com/api'},
          ]);
          expect(result['status'], 'success');
          final headers = result['headers'] as Map;
          expect(headers.containsKey('x-custom'), isTrue);
          expect(
            headers.keys.map((k) => k.toString().toLowerCase()),
            isNot(contains('set-cookie')),
          );
        },
      );
    });

    group('session handlers', () {
      setUp(() {
        bridge.registerJavaScriptHandlers(mockWebViewController);
      });

      test('status reports loggedIn=false when no session is saved', () async {
        final result = await jsHandlers['sessionStatus']!(['example.com']);
        expect(result['success'], isTrue);
        expect(result['loggedIn'], isFalse);
        expect(result['domain'], 'example.com');
      });

      test('status derives the registrable domain from a URL', () async {
        final result = await jsHandlers['sessionStatus']!([
          'https://a.b.example.com/x',
        ]);
        expect(result['domain'], 'example.com');
      });

      test(
        'getCookies without a grant and no approval UI requires permission',
        () async {
          final result = await jsHandlers['sessionGetCookies']!([
            'example.com',
          ]);
          expect(result['success'], isFalse);
          expect(result['error'], 'permission_required');
        },
      );

      test(
        'getCookies returns no_session once granted but nothing saved',
        () async {
          await grantService.grant('test-uuid', 'example.com');
          final result = await jsHandlers['sessionGetCookies']!([
            'example.com',
          ]);
          // Grant passes; there is simply no stored session in this test.
          expect(result['success'], isFalse);
          expect(result['error'], 'no_session');
        },
      );

      test(
        'requestLogin returns no_ui when no login callback is wired',
        () async {
          final result = await jsHandlers['sessionRequestLogin']!([
            'https://example.com',
          ]);
          expect(result['success'], isFalse);
          expect(result['error'], 'no_ui');
          expect(result['domain'], 'example.com');
        },
      );

      test('pickTags returns no_ui when no picker callback is wired', () async {
        final result = await jsHandlers['pickTags']!([
          {'title': 'Tags'},
        ]);
        expect(result['success'], isFalse);
        expect(result['error'], 'no_ui');
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

    group('Notes Management', () {
      setUp(() {
        bridge.registerJavaScriptHandlers(mockWebViewController);
      });

      test('saveNotes calls _saveNotesFromJavaScript', () async {
        final notesData = [
          {'title': 'Note 1', 'content': 'Content 1'},
          {'title': 'Note 2', 'content': 'Content 2'},
        ];

        when(mockModificationService.buildNote(any)).thenAnswer((
          invocation,
        ) async {
          final data =
              invocation.positionalArguments.first as Map<String, dynamic>;
          return Note(
            id: 'generated-id',
            title: data['title'] ?? 'Untitled',
            content: data['content'] ?? '',
            type: NoteType.note,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
        });
        when(mockAppProvider.addNote(any)).thenAnswer((_) async {});

        final result = await jsHandlers['saveNotes']!([notesData]);

        expect(result['success'], isTrue);
        expect(result['savedCount'], 2);
        verify(mockModificationService.buildNote(any)).called(2);
        verify(mockAppProvider.addNote(any)).called(2);
      });

      test('deleteNotes requires session approval', () async {
        final noteIds = ['id1', 'id2'];

        // Default: deletions not approved, no callback
        final result = await jsHandlers['deleteNotes']!([noteIds]);

        expect(result['success'], isFalse);
        expect(
          result['error'],
          contains('Note deletion requires user approval'),
        );
        verifyNever(mockAppProvider.deleteNote(any));
      });

      test('deleteNotes executes if session approved', () async {
        bridge.approveDeletionsForSession();
        final noteIds = ['id1', 'id2'];
        when(mockAppProvider.deleteNote(any)).thenAnswer((_) async {});

        final result = await jsHandlers['deleteNotes']!([noteIds]);

        expect(result['success'], isTrue);
        expect(result['deletedCount'], 2);
        verify(mockAppProvider.deleteNote('id1')).called(1);
        verify(mockAppProvider.deleteNote('id2')).called(1);
      });

      test('updateNotes merges data for existing note', () async {
        bridge.approveSession(); // Approve modifications
        final noteId = 'existing-id';
        final existingNote = Note(
          id: noteId,
          title: 'Old Title',
          content: 'Old Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        when(
          mockDatabaseService.getNote(noteId),
        ).thenAnswer((_) async => existingNote);
        when(mockAppProvider.updateNote(any)).thenAnswer((_) async {});

        final updates = [
          {'id': noteId, 'title': 'New Title'},
        ];

        final result = await jsHandlers['updateNotes']!([updates]);

        expect(result['success'], isTrue);
        expect(result['updatedCount'], 1);

        final checkCapture = verify(
          mockAppProvider.updateNote(captureAny),
        ).captured;
        final updatedNote = checkCapture.first as Note;
        expect(updatedNote.title, 'New Title');
        expect(updatedNote.content, 'Old Content'); // Should preserve content
      });

      test(
        'updateNotes uses granular modification service if structure matches',
        () async {
          bridge.approveSession();
          final noteId = 'granular-id';
          final existingNote = Note(
            id: noteId,
            title: 'T',
            content: 'C',
            type: NoteType.note,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );

          when(
            mockDatabaseService.getNote(noteId),
          ).thenAnswer((_) async => existingNote);
          // Return the updated Note from applyModifications as expected by the real service signature
          when(
            mockModificationService.applyModifications(any, any),
          ).thenAnswer((_) async => existingNote);

          final updates = [
            {
              'id': noteId,
              'modification': {'type': 'text_insertion', 'content': 'append'},
            },
          ];

          final result = await jsHandlers['updateNotes']!([updates]);

          expect(result['success'], isTrue);
          verify(
            mockModificationService.applyModifications(noteId, any),
          ).called(1);
          // Should NOT call updateNote directly
          verifyNever(mockAppProvider.updateNote(any));
        },
      );
    });

    test('log calls LoggerService', () async {
      bridge.registerJavaScriptHandlers(mockWebViewController);
      final result = await jsHandlers['log']!(['Test message', 'info']);
      expect(result, isNull);
    });

    group('App Actions', () {
      setUp(() {
        bridge.registerJavaScriptHandlers(mockWebViewController);
      });

      test('openNote triggers callback if note exists', () async {
        final noteId = 'note-id';
        final note = Note(
          id: noteId,
          title: 'Title',
          content: 'Content',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        when(mockDatabaseService.getNote(noteId)).thenAnswer((_) async => note);

        bool callbackCalled = false;

        final localBridge = UserAppRuntimeBridge(
          app: bridge.app,
          appProvider: mockAppProvider,
          revisionNumber: 1,
          isInteractive: true,
          onOpenNote: (n, replace) async {
            callbackCalled = true;
            expect(n.id, noteId);
          },
        );
        localBridge.registerJavaScriptHandlers(mockWebViewController);

        // Re-fetch handlers as registerJavaScriptHandlers overwrites the map via mock
        final result = await jsHandlers['openNote']!([noteId]);
        expect(result['success'], isTrue);
        expect(callbackCalled, isTrue);
      });

      test('copy-to-clipboard sets clipboard call', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (
              methodCall,
            ) async {
              if (methodCall.method == 'Clipboard.setData') {
                return null; // successful void return
              }
              return null;
            });

        final result = await jsHandlers['copy-to-clipboard']!(['text']);
        expect(result['success'], isTrue);
      });
    });

    group('runQuery Permissions', () {
      setUp(() {
        bridge.registerJavaScriptHandlers(mockWebViewController);
      });

      test('approves write query if session allows', () async {
        const sql = 'INSERT INTO notes ...';
        bridge.approveSqlWritesForSession();

        when(
          mockSqlQueryService.getQueryType(sql),
        ).thenReturn(SqlQueryType.insert);
        when(mockSqlQueryService.isReadOnlyQuery(sql)).thenReturn(false);
        when(
          mockSqlQueryService.executeQuery(
            any,
            requireApprovalForWrites: anyNamed('requireApprovalForWrites'),
            allowWriteOperations: anyNamed('allowWriteOperations'),
          ),
        ).thenAnswer((_) async => SqlQueryResult(success: true));

        final result = await jsHandlers['runQuery']!([sql]);

        expect(result['success'], isTrue);
        verify(
          mockSqlQueryService.executeQuery(
            sql,
            // requireApprovalForWrites should be false because session approved
            requireApprovalForWrites: false,
            allowWriteOperations: true,
          ),
        ).called(1);
      });
    });
  });

  group('Block scoped notes', () {
    const parentId = 'parent-note';
    const parentContent =
        'Intro.\n\n```mermaid\ngraph TD\nA --> B\n```\n\nOutro.';
    const blockText = '```mermaid\ngraph TD\nA --> B\n```';

    late BlockNoteScopeService scopeService;
    late BlockNoteScope scope;
    late UserAppRuntimeBridge blockBridge;
    late Note storedParent;

    Note buildParent(String content) => Note(
      id: parentId,
      title: 'Parent',
      content: content,
      type: NoteType.note,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      attachmentPaths: const [],
    );

    setUp(() {
      storedParent = buildParent(parentContent);
      if (!getIt.isRegistered<TagWorkflowService>()) {
        getIt.registerSingleton<TagWorkflowService>(
          TagWorkflowService(mockDatabaseService),
        );
      }
      scopeService = BlockNoteScopeService(
        mockDatabaseService,
        changeNotifier: DataChangeNotifier(),
      );
      getIt.registerSingleton<BlockNoteScopeService>(scopeService);

      when(
        mockDatabaseService.getNote(parentId),
      ).thenAnswer((_) async => storedParent);
      when(mockDatabaseService.updateNote(any)).thenAnswer((invocation) async {
        storedParent = invocation.positionalArguments.first as Note;
      });

      final start = parentContent.indexOf(blockText);
      scope = scopeService.open(
        parent: storedParent,
        spanStart: start,
        spanEnd: start + blockText.length,
        text: blockText,
      );

      blockBridge = UserAppRuntimeBridge(
        app: UserApp(
          id: 'test-app',
          uuid: 'test-uuid',
          name: 'Test App',
          description: 'Test Description',
          steps: const ['Step 1'],
          htmlContent: '<html></html>',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        appProvider: mockAppProvider,
        revisionNumber: 1,
        isInteractive: true,
        selectedNotes: [scopeService.asNote(scope)],
      );
      blockBridge.approveSession();
      blockBridge.approveDeletionsForSession();
      blockBridge.registerJavaScriptHandlers(mockWebViewController);
    });

    test('injects isBlockScope and parentNoteId into Synapse.Notes', () {
      final source = blockBridge.buildBootstrapScript().source;

      expect(source, contains('"isBlockScope":true'));
      expect(source, contains('"parentNoteId":"$parentId"'));
      // The plugin sees the block text as the note content.
      expect(source, contains('graph TD'));
    });

    test('full replacement splices the block into the parent', () async {
      final result = await jsHandlers['updateNotes']!([
        [
          {'id': scope.tempNoteId, 'content': 'REPLACED'},
        ],
      ]);

      expect(result['success'], isTrue);
      expect(result['updatedCount'], 1);
      expect(storedParent.content, 'Intro.\n\nREPLACED\n\nOutro.');
      // The parent note itself was never replaced wholesale.
      verifyNever(mockAppProvider.updateNote(any));
    });

    test('granular prepend inserts above the block, keeping it', () async {
      // Use a real saveTemp URI: the host refuses to commit a block that
      // references a temp file it cannot promote, so a made-up URI would (
      // correctly) be rejected.
      final saved = await jsHandlers['saveTemp']!([
        {'text': '<svg xmlns="http://www.w3.org/2000/svg"/>'},
        'image/svg+xml',
      ]);
      final uri = saved['uri'] as String;

      final result = await jsHandlers['updateNotes']!([
        [
          {
            'id': scope.tempNoteId,
            'modification': {
              'content': {'action': 'prepend', 'text': '![mermaid]($uri)'},
            },
          },
        ],
      ]);

      expect(result['success'], isTrue);
      expect(result['updatedCount'], 1);
      expect(
        storedParent.content,
        'Intro.\n\n![mermaid]($uri)\n$blockText\n\nOutro.',
      );

      // The SVG must be promoted to a durable attachment on the PARENT note,
      // named <parentId>_<sha256 of the uri> so the renderer resolves it after
      // the temp cache is purged.
      final hash = sha256.convert(utf8.encode(uri)).toString();
      expect(
        storedParent.attachmentPaths,
        contains('attachments/${parentId}_$hash.svg'),
      );
      expect(
        File(
          p.join(tempDir.path, 'attachments', '${parentId}_$hash.svg'),
        ).existsSync(),
        isTrue,
      );
    });

    test('refuses to commit a block referencing a dead temp file', () async {
      final result = await jsHandlers['updateNotes']!([
        [
          {
            'id': scope.tempNoteId,
            'modification': {
              'content': {
                'action': 'prepend',
                'text': '![gone](synapsetemp:///never-existed.svg)',
              },
            },
          },
        ],
      ]);

      // Committing it would render now and break for good once the OS purges
      // the cache, so nothing is written.
      expect(result['updatedCount'], 0);
      expect(storedParent.content, parentContent);
    });

    test('plugin text cannot attach an arbitrary local file', () async {
      // processContentForAttachments' local-path pass would otherwise copy any
      // readable file into attachments/ and register it on the note, which the
      // plugin could then read back or have uploaded as AI context.
      final secret = File(p.join(tempDir.path, 'secret.db'));
      await secret.writeAsString('sensitive');

      final result = await jsHandlers['updateNotes']!([
        [
          {'id': scope.tempNoteId, 'content': '![x](${secret.path})'},
        ],
      ]);

      expect(result['success'], isTrue);
      expect(storedParent.attachmentPaths, isEmpty);
      // The path is left as written, not turned into an attachment.
      expect(storedParent.content, contains(secret.path));
    });

    test('host-authored refusal messages reach the plugin verbatim', () async {
      // A '/'-based redaction heuristic swallowed exactly this message, because
      // it names "append/prepend/replace" — the most actionable part of it.
      final sectioned = await jsHandlers['updateNotes']!([
        [
          {
            'id': scope.tempNoteId,
            'modification': {
              'content': {
                'action': 'append',
                'text': 'x',
                'section': 'Some Heading',
              },
            },
          },
        ],
      ]);
      expect(
        (sectioned['errors'] as List).single,
        contains('append/prepend/replace'),
      );

      final unsupported = await jsHandlers['updateNotes']!([
        [
          {
            'id': scope.tempNoteId,
            'modification': {
              'content': {'action': 'insertAfter', 'text': 'x'},
            },
          },
        ],
      ]);
      expect(unsupported['updatedCount'], 0);
      expect(
        (unsupported['errors'] as List).single,
        contains('Unsupported content action'),
      );
      // The unknown action must NOT be silently written back unchanged.
      expect(storedParent.content, parentContent);

      final noContent = await jsHandlers['updateNotes']!([
        [
          {'id': scope.tempNoteId, 'tags': ['x']},
        ],
      ]);
      expect(noContent['updatedCount'], 0);
      expect(
        (noContent['errors'] as List).single,
        contains('must include "content"'),
      );
    });

    test('section-scoped content modification is rejected', () async {
      final result = await jsHandlers['updateNotes']!([
        [
          {
            'id': scope.tempNoteId,
            'modification': {
              'content': {
                'action': 'append',
                'text': 'x',
                'section': 'Some Heading',
              },
            },
          },
        ],
      ]);

      // The per-note error is swallowed by the loop, so nothing is written.
      expect(result['success'], isTrue);
      expect(result['updatedCount'], 0);
      expect(storedParent.content, parentContent);
    });

    test('title changes are ignored for a block', () async {
      final result = await jsHandlers['updateNotes']!([
        [
          {'id': scope.tempNoteId, 'title': 'Should Not Apply'},
        ],
      ]);

      expect(result['success'], isTrue);
      expect(storedParent.title, 'Parent');
      expect(storedParent.content, parentContent);
    });

    test(
      'round-tripping the whole note object still applies the content write',
      () async {
        // Regression: `tags`/`attachments` are Lists in full-replacement mode
        // but applyModifications wants the granular object form. Forwarding
        // them threw and silently discarded the content edit. A block scope is
        // content-only now, so the write must land.
        final result = await jsHandlers['updateNotes']!([
          [
            {
              'id': scope.tempNoteId,
              'title': 'Parent',
              'content': 'REPLACED',
              'tags': ['work'],
              'attachments': ['something.png'],
              'pinned': true,
            },
          ],
        ]);

        expect(result['success'], isTrue);
        expect(result['updatedCount'], 1);
        expect(storedParent.content, 'Intro.\n\nREPLACED\n\nOutro.');
        // Note-level fields were ignored, not applied to the parent.
        expect(storedParent.title, 'Parent');
        expect(storedParent.pinned, isFalse);
        verifyNever(mockModificationService.applyModifications(any, any));
      },
    );

    test('note-level fields are never forwarded to the parent', () async {
      await jsHandlers['updateNotes']!([
        [
          {
            'id': scope.tempNoteId,
            'modification': {
              'content': {'action': 'replace', 'text': 'X'},
              'tags': {
                'added': ['sneaky'],
              },
              'link': {
                'added': [
                  {'target': 'other-note'},
                ],
              },
            },
          },
        ],
      ]);

      // The user approved editing a block; retagging/linking the note is not
      // in scope of that consent.
      verifyNever(mockModificationService.applyModifications(any, any));
      expect(storedParent.content, contains('X'));
    });

    test('deleteNotes on a block removes the block, not the note', () async {
      final result = await jsHandlers['deleteNotes']!([
        [scope.tempNoteId],
      ]);

      expect(result['success'], isTrue);
      expect(result['deletedCount'], 1);
      expect(storedParent.content, isNot(contains('mermaid')));
      // Critically: the parent note must not be deleted.
      verifyNever(mockAppProvider.deleteNote(any));
    });

    test(
      'deleting a block asks for a MODIFICATION, not a note deletion',
      () async {
        List<String>? deletionAskedAbout;
        String? modificationNoteId;
        Map<String, dynamic>? modificationData;

        final approvalBridge = UserAppRuntimeBridge(
          app: UserApp(
            id: 'test-app',
            uuid: 'test-uuid',
            name: 'Test App',
            description: 'Test Description',
            steps: const ['Step 1'],
            htmlContent: '<html></html>',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
          appProvider: mockAppProvider,
          revisionNumber: 1,
          isInteractive: true,
          selectedNotes: [scopeService.asNote(scope)],
          onDeletionApprovalRequest: (bridge, ids) async {
            deletionAskedAbout = ids;
            return true;
          },
          onModificationRequest: (bridge, noteId, modification) async {
            modificationNoteId = noteId;
            modificationData = modification;
            return true;
          },
        );
        approvalBridge.registerJavaScriptHandlers(mockWebViewController);

        final result = await jsHandlers['deleteNotes']!([
          [scope.tempNoteId],
        ]);

        expect(result['success'], isTrue);
        // "Allow Note Deletion? ... cannot be undone" naming the whole parent
        // note would misstate what happens: only the block is emptied.
        expect(deletionAskedAbout, isNull);
        expect(modificationNoteId, parentId);
        expect(modificationData?[ApprovalRequest.scopeBlockKey], isTrue);
        expect(storedParent.content, isNot(contains('mermaid')));
      },
    );

    test('a denied block deletion leaves the note untouched', () async {
      final denyBridge = UserAppRuntimeBridge(
        app: UserApp(
          id: 'test-app',
          uuid: 'test-uuid',
          name: 'Test App',
          description: 'Test Description',
          steps: const ['Step 1'],
          htmlContent: '<html></html>',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        appProvider: mockAppProvider,
        revisionNumber: 1,
        isInteractive: true,
        selectedNotes: [scopeService.asNote(scope)],
        onModificationRequest: (bridge, noteId, modification) async => false,
      );
      denyBridge.registerJavaScriptHandlers(mockWebViewController);

      final result = await jsHandlers['deleteNotes']!([
        [scope.tempNoteId],
      ]);

      expect(result['success'], isFalse);
      expect(storedParent.content, parentContent);
    });

    test(
      'whole-note writes in a block session are flagged as note-wide',
      () async {
        String? scopeFlagged;
        final flagBridge = UserAppRuntimeBridge(
          app: UserApp(
            id: 'test-app',
            uuid: 'test-uuid',
            name: 'Test App',
            description: 'Test Description',
            steps: const ['Step 1'],
            htmlContent: '<html></html>',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
          appProvider: mockAppProvider,
          revisionNumber: 1,
          isInteractive: true,
          selectedNotes: [scopeService.asNote(scope)],
          onModificationRequest: (bridge, noteId, modification) async {
            scopeFlagged =
                modification[ApprovalRequest.scopeWholeNoteKey] == true
                ? 'whole-note'
                : modification[ApprovalRequest.scopeBlockKey] == true
                ? 'block'
                : 'none';
            return false;
          },
        );
        flagBridge.registerJavaScriptHandlers(mockWebViewController);

        // A plugin launched on a block targets the parent id it was handed. The
        // dialog must not look identical to the block edit the user asked for.
        await jsHandlers['updateNotes']!([
          [
            {
              'id': parentId,
              'modification': {
                'content': {'action': 'replace', 'text': 'ALL'},
              },
            },
          ],
        ]);

        expect(scopeFlagged, 'whole-note');
      },
    );

    test('a 2-entry batch cannot hide a whole-note write', () async {
      Map<String, dynamic>? seen;
      final batchBridge = UserAppRuntimeBridge(
        app: UserApp(
          id: 'test-app',
          uuid: 'test-uuid',
          name: 'Test App',
          description: 'Test Description',
          steps: const ['Step 1'],
          htmlContent: '<html></html>',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        appProvider: mockAppProvider,
        revisionNumber: 1,
        isInteractive: true,
        selectedNotes: [scopeService.asNote(scope)],
        onModificationRequest: (bridge, noteId, modification) async {
          seen = modification;
          return false;
        },
      );
      batchBridge.registerJavaScriptHandlers(mockWebViewController);

      // Adding one extra entry used to bypass the scope notice entirely,
      // because only the single-entry path attached it.
      await jsHandlers['updateNotes']!([
        [
          {'id': scope.tempNoteId, 'content': 'block edit'},
          {'id': parentId, 'content': 'WHOLE NOTE WIPED'},
        ],
      ]);

      expect(seen?['isBatch'], isTrue);
      expect(seen?[ApprovalRequest.scopeWholeNoteKey], isTrue);
    });

    test('a plugin cannot forge the block-scope reassurance', () async {
      Map<String, dynamic>? seen;
      final spoofBridge = UserAppRuntimeBridge(
        app: UserApp(
          id: 'test-app',
          uuid: 'test-uuid',
          name: 'Test App',
          description: 'Test Description',
          steps: const ['Step 1'],
          htmlContent: '<html></html>',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        appProvider: mockAppProvider,
        revisionNumber: 1,
        isInteractive: true,
        selectedNotes: [scopeService.asNote(scope)],
        onModificationRequest: (bridge, noteId, modification) async {
          seen = modification;
          return false;
        },
      );
      spoofBridge.registerJavaScriptHandlers(mockWebViewController);

      // The plugin tries to label a WHOLE-NOTE rewrite as "block only" by
      // sending the host's own scope key. An attacker-controlled reassurance
      // would be worse than showing no notice at all.
      await jsHandlers['updateNotes']!([
        [
          {
            'id': parentId,
            'content': 'WHOLE NOTE OVERWRITTEN',
            ApprovalRequest.scopeBlockKey: true,
          },
        ],
      ]);

      expect(seen?[ApprovalRequest.scopeBlockKey], isNull);
      expect(seen?[ApprovalRequest.scopeWholeNoteKey], isTrue);
    });

    test(
      'forged scope keys are stripped even outside a block session',
      () async {
        Map<String, dynamic>? seen;
        final plainBridge = UserAppRuntimeBridge(
          app: UserApp(
            id: 'test-app',
            uuid: 'test-uuid',
            name: 'Test App',
            description: 'Test Description',
            steps: const ['Step 1'],
            htmlContent: '<html></html>',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
          appProvider: mockAppProvider,
          revisionNumber: 1,
          isInteractive: true,
          // No block scope at all: the host adds no counter-flag here, so a
          // surviving forged key would go completely unchallenged.
          selectedNotes: const [],
          onModificationRequest: (bridge, noteId, modification) async {
            seen = modification;
            return false;
          },
        );
        plainBridge.registerJavaScriptHandlers(mockWebViewController);

        await jsHandlers['updateNotes']!([
          [
            {
              'id': parentId,
              'content': 'rewritten',
              ApprovalRequest.scopeBlockKey: true,
            },
          ],
        ]);

        expect(seen?[ApprovalRequest.scopeBlockKey], isNull);
        expect(seen?[ApprovalRequest.scopeWholeNoteKey], isNull);
      },
    );

    test('an all-block batch is reported as block scoped', () async {
      Map<String, dynamic>? seen;
      final batchBridge = UserAppRuntimeBridge(
        app: UserApp(
          id: 'test-app',
          uuid: 'test-uuid',
          name: 'Test App',
          description: 'Test Description',
          steps: const ['Step 1'],
          htmlContent: '<html></html>',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        appProvider: mockAppProvider,
        revisionNumber: 1,
        isInteractive: true,
        selectedNotes: [scopeService.asNote(scope)],
        onModificationRequest: (bridge, noteId, modification) async {
          seen = modification;
          return false;
        },
      );
      batchBridge.registerJavaScriptHandlers(mockWebViewController);

      await jsHandlers['updateNotes']!([
        [
          {'id': scope.tempNoteId, 'content': 'a'},
          {'id': scope.tempNoteId, 'content': 'b'},
        ],
      ]);

      expect(seen?[ApprovalRequest.scopeBlockKey], isTrue);
      expect(seen?[ApprovalRequest.scopeWholeNoteKey], isNull);
    });

    test(
      'a refused write reports why instead of looking like success',
      () async {
        // Point the scope at text that is no longer in the note.
        scopeService.close(scope.tempNoteId);
        final staleScope = scopeService.open(
          parent: buildParent('totally different content'),
          spanStart: 0,
          spanEnd: 5,
          text: 'GONE!',
        );

        final result = await jsHandlers['updateNotes']!([
          [
            {'id': staleScope.tempNoteId, 'content': 'nope'},
          ],
        ]);

        expect(result['updatedCount'], 0);
        // Previously this was an unreachable string: the loop swallowed it and
        // the plugin saw success with no explanation.
        expect(result['errors'], isNotNull);
        expect(
          (result['errors'] as List).first,
          contains('could no longer be found'),
        );
        expect(storedParent.content, parentContent);
      },
    );

    test('unused deletion approval path still works for real notes', () async {
      List<String>? askedAbout;
      final approvalBridge = UserAppRuntimeBridge(
        app: UserApp(
          id: 'test-app',
          uuid: 'test-uuid',
          name: 'Test App',
          description: 'Test Description',
          steps: const ['Step 1'],
          htmlContent: '<html></html>',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        appProvider: mockAppProvider,
        revisionNumber: 1,
        isInteractive: true,
        selectedNotes: [scopeService.asNote(scope)],
        onDeletionApprovalRequest: (bridge, ids) async {
          askedAbout = ids;
          return true;
        },
      );
      approvalBridge.registerJavaScriptHandlers(mockWebViewController);

      // An ordinary note id must still go through the note-deletion gate
      // exactly as before, unchanged by the block-scope routing.
      await jsHandlers['deleteNotes']!([
        ['some-real-note'],
      ]);

      expect(askedAbout, ['some-real-note']);
      verify(mockAppProvider.deleteNote('some-real-note')).called(1);
    });

    test('runQuery re-reads a block like a note (the Table Studio save path)', () async {
      // Table Studio (and any careful plugin) re-reads the note's current
      // content with SQL before writing, and ABORTS if it gets no rows, so it
      // never writes stale content. A transient id has no row, so without this
      // the whole save fails with "Could not read the current note content".
      when(
        mockSqlQueryService.getQueryType(any),
      ).thenReturn(SqlQueryType.select);
      when(mockSqlQueryService.isReadOnlyQuery(any)).thenReturn(true);
      when(
        mockSqlQueryService.executeQuery(
          any,
          requireApprovalForWrites: anyNamed('requireApprovalForWrites'),
          allowWriteOperations: anyNamed('allowWriteOperations'),
        ),
      ).thenAnswer(
        (_) async => SqlQueryResult(
          success: true,
          data: [
            {'id': parentId, 'content': storedParent.content},
          ],
        ),
      );

      final result = await jsHandlers['runQuery']!([
        "SELECT content FROM notes WHERE id = '${scope.tempNoteId}' LIMIT 1",
      ]);

      expect(result['success'], isTrue);
      final rows = result['data'] as List;
      expect(rows, hasLength(1));
      // It must see the BLOCK's text, not the whole parent note — otherwise it
      // would write the entire note back into the block's range.
      expect(rows.first['content'], blockText);
      expect(rows.first['id'], scope.tempNoteId);

      // The query the DB actually ran was rewritten to the real note id.
      final ranSql =
          verify(
                mockSqlQueryService.executeQuery(
                  captureAny,
                  requireApprovalForWrites: anyNamed('requireApprovalForWrites'),
                  allowWriteOperations: anyNamed('allowWriteOperations'),
                ),
              ).captured.last
              as String;
      expect(ranSql, contains(parentId));
      expect(ranSql, isNot(contains(scope.tempNoteId)));
    });

    test('SQL writes against a block id are refused with guidance', () async {
      when(
        mockSqlQueryService.getQueryType(any),
      ).thenReturn(SqlQueryType.update);
      when(mockSqlQueryService.isReadOnlyQuery(any)).thenReturn(false);

      final result = await jsHandlers['runQuery']!([
        "UPDATE notes SET content = 'x' WHERE id = '${scope.tempNoteId}'",
      ]);

      // Rewriting this to the parent would write the block's text over the
      // WHOLE note, so it must be refused rather than redirected.
      expect(result['success'], isFalse);
      expect(result['error'], contains('Synapse.updateNotes'));
      verifyNever(
        mockSqlQueryService.executeQuery(
          any,
          requireApprovalForWrites: anyNamed('requireApprovalForWrites'),
          allowWriteOperations: anyNamed('allowWriteOperations'),
        ),
      );
    });

    test('runQuery is untouched when no block scope is open', () async {
      scopeService.close(scope.tempNoteId);
      when(
        mockSqlQueryService.getQueryType(any),
      ).thenReturn(SqlQueryType.select);
      when(mockSqlQueryService.isReadOnlyQuery(any)).thenReturn(true);
      when(
        mockSqlQueryService.executeQuery(
          any,
          requireApprovalForWrites: anyNamed('requireApprovalForWrites'),
          allowWriteOperations: anyNamed('allowWriteOperations'),
        ),
      ).thenAnswer(
        (_) async => SqlQueryResult(
          success: true,
          data: [
            {'id': parentId, 'content': 'untouched'},
          ],
        ),
      );

      const sql = "SELECT content FROM notes WHERE id = 'parent-note'";
      final result = await jsHandlers['runQuery']!([sql]);

      expect((result['data'] as List).first['content'], 'untouched');
      final ranSql =
          verify(
                mockSqlQueryService.executeQuery(
                  captureAny,
                  requireApprovalForWrites: anyNamed('requireApprovalForWrites'),
                  allowWriteOperations: anyNamed('allowWriteOperations'),
                ),
              ).captured.last
              as String;
      expect(ranSql, sql);
    });

    test('openNote on a block navigates to the parent note', () async {
      Note? opened;
      final navBridge = UserAppRuntimeBridge(
        app: UserApp(
          id: 'test-app',
          uuid: 'test-uuid',
          name: 'Test App',
          description: 'Test Description',
          steps: const ['Step 1'],
          htmlContent: '<html></html>',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        appProvider: mockAppProvider,
        revisionNumber: 1,
        isInteractive: true,
        selectedNotes: [scopeService.asNote(scope)],
        onOpenNote: (note, replaceWindow) async => opened = note,
      );
      navBridge.registerJavaScriptHandlers(mockWebViewController);

      final result = await jsHandlers['openNote']!([scope.tempNoteId]);

      expect(result['success'], isTrue);
      expect(opened?.id, parentId);
    });

    test('writes fail cleanly once the scope is closed', () async {
      scopeService.close(scope.tempNoteId);

      final result = await jsHandlers['updateNotes']!([
        [
          {'id': scope.tempNoteId, 'content': 'REPLACED'},
        ],
      ]);

      // Falls through to the ordinary path, finds no such note, writes nothing.
      expect(result['updatedCount'], 0);
      expect(storedParent.content, parentContent);
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
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

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
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  final HttpHeaders headers = MockResponseHeaders();

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

/// Response headers that include a Set-Cookie so the sensitive-header filter can
/// be exercised.
class MockResponseHeaders extends Fake implements HttpHeaders {
  final Map<String, List<String>> _values = {
    'content-type': ['text/plain'],
    'set-cookie': ['sid=secret; HttpOnly'],
    'x-custom': ['ok'],
  };

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  String? value(String name) => _values[name.toLowerCase()]?.join(', ');

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }
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

  @override
  Future<String?> getApplicationDocumentsPath() async {
    return tempPath;
  }
}

/// Hand-written TtsService fake (kept out of build_runner: the platform
/// channel is never exercised in tests, only call recording is needed).
class RecordingTtsService extends TtsService {
  final List<Map<String, dynamic>> speakCalls = [];
  int stopCalls = 0;
  List<String> languages = [];

  @override
  Future<void> speak(
    String text, {
    String? language,
    double? rate,
    double? pitch,
    double? volume,
  }) async {
    speakCalls.add({
      'text': text,
      'language': language,
      'rate': rate,
      'pitch': pitch,
      'volume': volume,
    });
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<List<String>> getLanguages() async => languages;
}
