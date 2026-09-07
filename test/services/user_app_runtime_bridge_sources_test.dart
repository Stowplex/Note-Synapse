import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/note_source.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/services/block_note_scope_service.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/user_app_runtime_bridge.dart';

// Reuse the mocks generated for the main bridge test.
import 'user_app_runtime_bridge_test.mocks.dart';

/// The `sources` field of `Synapse.Notes`: its JSON shape and how the bridge
/// fills it before the bootstrap script is built.
void main() {
  final full = NoteSource(
    id: 's1',
    url: 'https://example.com/post/123',
    sharedUrl: 'https://example.com/post/123?utm_source=x',
    canonicalUrl: 'https://example.com/post/123',
    title: 'Post title',
    siteName: 'Example',
    byline: 'Jane Doe',
    publishedAt: DateTime.utc(2026, 8, 30, 12),
    clippedAt: DateTime(2026, 9, 6, 17, 4, 11).toUtc(),
    method: NoteSourceMethod.extract,
  );
  final minimal = NoteSource(
    id: 's2',
    url: 'https://www.example.com/x',
    kind: NoteSourceKind.file,
    method: NoteSourceMethod.download,
  );

  Note note(String id) => Note(
    id: id,
    title: 'Note $id',
    content: 'Body',
    type: NoteType.note,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 2),
  );

  final app = UserApp(
    id: 'app',
    uuid: 'app-uuid',
    name: 'App',
    description: '',
    steps: const [],
    htmlContent: '',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  group('sourcesToPluginJson', () {
    test('writes the documented fields and nothing else', () {
      final json = UserAppRuntimeBridge.sourcesToPluginJson([full]);

      expect(json, [
        {
          'id': 's1',
          'url': 'https://example.com/post/123',
          'title': 'Post title',
          'siteName': 'Example',
          'clippedAt': full.clippedAt!.toUtc().toIso8601String(),
          'kind': 'web',
          'method': 'extract',
        },
      ]);
    });

    test('omits optional fields that are unknown', () {
      final json = UserAppRuntimeBridge.sourcesToPluginJson([minimal]);

      expect(json.single.keys, ['id', 'url', 'kind', 'method']);
      expect(json.single['kind'], 'file');
      expect(json.single['method'], 'download');
    });

    test('keeps order and maps an empty list to an empty array', () {
      expect(UserAppRuntimeBridge.sourcesToPluginJson(const []), isEmpty);
      expect(
        UserAppRuntimeBridge.sourcesToPluginJson([
          minimal,
          full,
        ]).map((e) => e['id']),
        ['s2', 's1'],
      );
    });
  });

  group('Synapse.Notes', () {
    late MockAppProvider mockAppProvider;

    setUp(() async {
      await resetForTesting();
      mockAppProvider = MockAppProvider();
    });

    tearDown(() async {
      await resetForTesting();
    });

    String bootstrap(UserAppRuntimeBridge bridge) =>
        bridge.buildBootstrapScript().source;

    test('carries the sources handed to the constructor', () {
      final bridge = UserAppRuntimeBridge(
        app: app,
        appProvider: mockAppProvider,
        revisionNumber: 1,
        isInteractive: true,
        selectedNotes: [note('a'), note('b')],
        selectedNoteSources: {
          'a': [full],
        },
      );

      final source = bootstrap(bridge);

      expect(
        source,
        contains(
          '"sources":[{"id":"s1","url":"https://example.com/post/123",'
          '"title":"Post title","siteName":"Example",'
          '"clippedAt":"${full.clippedAt!.toUtc().toIso8601String()}",'
          '"kind":"web","method":"extract"}]',
        ),
      );
      // Note b has no entry: still a (empty) array, never a missing key.
      expect(source, contains('"id":"b"'));
      expect(source, contains('"sources":[]'));
      verifyNever(mockAppProvider.getNoteSources(any));
    });

    test('loadSelectedNoteSources reads them through the provider', () async {
      when(
        mockAppProvider.getNoteSources('a'),
      ).thenAnswer((_) async => [minimal]);
      when(mockAppProvider.getNoteSources('b')).thenAnswer((_) async => []);
      final bridge = UserAppRuntimeBridge(
        app: app,
        appProvider: mockAppProvider,
        revisionNumber: 1,
        isInteractive: true,
        selectedNotes: [note('a'), note('b')],
      );
      expect(bootstrap(bridge), isNot(contains('"id":"s2"')));

      await bridge.loadSelectedNoteSources();

      final source = bootstrap(bridge);
      expect(
        source,
        contains(
          '"sources":[{"id":"s2","url":"https://www.example.com/x",'
          '"kind":"file","method":"download"}]',
        ),
      );
      expect(source, contains('"sources":[]'));
    });

    /// Registers a [BlockNoteScopeService] and opens a scope over the body of
    /// the note 'parent', whose sources are [full].
    BlockNoteScope openBlockScope() {
      final scopes = BlockNoteScopeService(
        MockDatabaseService(),
        changeNotifier: DataChangeNotifier(),
      );
      getIt.registerSingleton<BlockNoteScopeService>(scopes);
      when(
        mockAppProvider.getNoteSources('parent'),
      ).thenAnswer((_) async => [full]);
      return scopes.open(
        parent: note('parent'),
        spanStart: 0,
        spanEnd: 4,
        text: 'Body',
      );
    }

    test("a transient block note inherits its parent's sources", () async {
      final scope = openBlockScope();
      final bridge = UserAppRuntimeBridge(
        app: app,
        appProvider: mockAppProvider,
        revisionNumber: 1,
        isInteractive: true,
        selectedNotes: [getIt<BlockNoteScopeService>().asNote(scope)],
      );

      await bridge.loadSelectedNoteSources();

      // The lookup goes to the parent, never to the transient id, and the
      // result is keyed by the transient id the entry uses.
      verify(mockAppProvider.getNoteSources('parent')).called(1);
      verifyNever(mockAppProvider.getNoteSources(scope.tempNoteId));
      final source = bootstrap(bridge);
      expect(source, contains('"id":"${scope.tempNoteId}"'));
      expect(source, contains('"isBlockScope":true'));
      expect(source, contains('"parentNoteId":"parent"'));
      expect(
        source,
        contains('"sources":[{"id":"s1","url":"https://example.com/post/123",'),
      );
      expect(source, isNot(contains('"sources":[]')));
    });

    test(
      "exportNotes writes the parent's Source line for a block note",
      () async {
        final scope = openBlockScope();
        final handlers = <String, JavaScriptHandlerCallback>{};
        final controller = MockInAppWebViewController();
        when(
          controller.addJavaScriptHandler(
            handlerName: anyNamed('handlerName'),
            callback: anyNamed('callback'),
          ),
        ).thenAnswer((invocation) {
          handlers[invocation.namedArguments[#handlerName] as String] =
              invocation.namedArguments[#callback] as JavaScriptHandlerCallback;
        });
        final bridge = UserAppRuntimeBridge(
          app: app,
          appProvider: mockAppProvider,
          revisionNumber: 1,
          isInteractive: true,
          selectedNotes: [getIt<BlockNoteScopeService>().asNote(scope)],
        );
        bridge.registerJavaScriptHandlers(controller);

        final result =
            await handlers['exportNotes']!([
                  [scope.tempNoteId],
                  {
                    'includeSubNotesAndLinkedNotes': false,
                    'includeAttachmentList': false,
                  },
                ])
                as Map;

        expect(result['success'], isTrue, reason: '${result['error']}');
        final exported = (result['notes'] as List).single as Map;
        expect(exported['id'], scope.tempNoteId);
        expect(
          exported['markdown'],
          contains('**Source:** [Post title](https://example.com/post/123)'),
        );
        verifyNever(mockAppProvider.getNoteSources(scope.tempNoteId));
      },
    );
  });
}
