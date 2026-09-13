import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/services/prompts/prompt_template_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/space_scope_service.dart';
import 'package:note_synapse/services/user_app_runtime_bridge.dart';
import 'package:note_synapse/services/user_app_service.dart';

import 'synapse_space_api_test.mocks.dart';

/// The JavaScript value assigned after [marker] — `space: ` in the bootstrap
/// script, `var space = ` in the change script.
///
/// Scanned with a brace/string walker rather than matched with a regex: the
/// property under test is that the payload is well-formed JSON *whatever* the
/// user called their Space, and a regex would have to assume the very thing
/// the code is supposed to guarantee. A payload broken by naive interpolation
/// either fails this scan or fails to decode — both are the failure we want.
String spaceLiteral(String source, [String marker = 'space: ']) {
  final start = source.indexOf(marker);
  expect(start, isNot(-1), reason: 'no `$marker` payload in the script');
  var i = start + marker.length;
  if (source.startsWith('null', i)) return 'null';

  var depth = 0;
  var inString = false;
  var escaped = false;
  final from = i;
  for (; i < source.length; i++) {
    final c = source[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return source.substring(from, i + 1);
    }
  }
  fail('the `$marker` literal is never closed — the script is broken');
}

/// M7: `Synapse.space` — the value plugins read, the event they react to, and
/// the prompt documentation that teaches the AI both (CLAUDE.md requires the
/// implementation *and* the documentation).
@GenerateNiceMocks([
  MockSpec<AppProvider>(),
  MockSpec<InAppWebViewController>(),
])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockAppProvider appProvider;
  late MockInAppWebViewController controller;
  late SpaceScopeService scope;

  UserApp buildApp() => UserApp(
    id: 'app-1',
    uuid: 'uuid-1',
    name: 'Plugin',
    description: '',
    steps: const [],
    htmlContent: '<html></html>',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  UserAppRuntimeBridge buildBridge() => UserAppRuntimeBridge(
    app: buildApp(),
    appProvider: appProvider,
    revisionNumber: 1,
    isInteractive: true,
  );

  setUp(() async {
    await resetForTesting();
    appProvider = MockAppProvider();
    when(appProvider.locale).thenReturn(const Locale('en', 'US'));
    controller = MockInAppWebViewController();
    scope = SpaceScopeService();
    getIt.registerSingleton<SpaceScopeService>(scope);
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('Synapse.space in the bootstrap script', () {
    test('is null when no Space is active', () {
      final source = buildBridge().buildBootstrapScript().source;
      expect(spaceLiteral(source), 'null');
    });

    test('carries the active Space id, name and tags', () {
      scope.setActive('space-1', const ['thesis', '2026'], name: 'Thesis');

      final source = buildBridge().buildBootstrapScript().source;
      expect(jsonDecode(spaceLiteral(source)), {
        'id': 'space-1',
        'name': 'Thesis',
        'tags': ['thesis', '2026'],
      });
    });

    test('is null while an id is resolved but its tags are not known yet', () {
      // `load()` adopts a persisted id before AppProvider resolves it against
      // the filter list. Publishing `{tags: []}` there would read to a plugin
      // as "a Space that contains nothing".
      scope.setActive('space-1', const []);

      final source = buildBridge().buildBootstrapScript().source;
      expect(spaceLiteral(source), 'null');
    });

    test('a Space name containing a quote, a backslash and a newline stays '
        'valid JSON', () {
      // The name is arbitrary user text. Interpolated field by field it would
      // close the JavaScript string early and take the whole window.Synapse
      // object — every API, not just this one — down with it.
      const hostile = 'He said "hi"\\ then\nleft';
      scope.setActive('space-1', const ['x'], name: hostile);

      final literal = spaceLiteral(buildBridge().buildBootstrapScript().source);
      expect(
        literal,
        contains(r'\"'),
        reason: 'the quote in the name was never escaped',
      );
      expect(jsonDecode(literal)['name'], hostile);
    });

    test('a Space tag containing a quote is escaped too', () {
      scope.setActive('space-1', const [r'quote"tag'], name: 'S');

      final literal = spaceLiteral(buildBridge().buildBootstrapScript().source);
      expect(jsonDecode(literal)['tags'], [r'quote"tag']);
    });

    test('the rest of the Synapse namespace still follows the space entry', () {
      scope.setActive('space-1', const ['x'], name: 'He said "hi"');

      final source = buildBridge().buildBootstrapScript().source;
      final after = source.substring(
        source.indexOf('space: ') + spaceLiteral(source).length,
      );
      expect(after, contains('window.Synapse.tool.invoke'));
    });
  });

  group('synapse:spacechanged', () {
    test('reaches the live WebView with the new Space as its detail', () async {
      final bridge = buildBridge();
      bridge.buildBootstrapScript();
      bridge.registerJavaScriptHandlers(controller);
      await bridge.pageDidFinishLoading();
      scope.setActive('space-1', const ['thesis'], name: 'Thesis');

      await bridge.notifySpaceChanged();

      final source =
          verify(
                controller.evaluateJavascript(
                  source: captureAnyNamed('source'),
                ),
              ).captured.single
              as String;
      expect(source, contains("'synapse:spacechanged'"));
      expect(source, contains('window.dispatchEvent'));
      expect(source, contains('window.Synapse.space = nextSpace'));
      expect(jsonDecode(spaceLiteral(source, 'var nextSpace = ')), {
        'id': 'space-1',
        'name': 'Thesis',
        'tags': ['thesis'],
      });
    });

    test('carries a null payload on leave', () async {
      scope.setActive('space-1', const ['thesis'], name: 'Thesis');
      final bridge = buildBridge();
      bridge.buildBootstrapScript();
      bridge.registerJavaScriptHandlers(controller);
      await bridge.pageDidFinishLoading();
      scope.setActive(null, const []);

      await bridge.notifySpaceChanged();

      final source =
          verify(
                controller.evaluateJavascript(
                  source: captureAnyNamed('source'),
                ),
              ).captured.single
              as String;
      expect(source, contains('var nextSpace = null;'));
      expect(source, contains("'synapse:spacechanged'"));
    });

    test('is a no-op for a bridge with no WebView attached', () async {
      final bridge = buildBridge();
      scope.setActive('space-1', const ['thesis'], name: 'Thesis');

      await bridge.notifySpaceChanged();

      verifyNever(controller.evaluateJavascript(source: anyNamed('source')));
    });

    test('survives a WebView that has already gone away', () async {
      final bridge = buildBridge();
      bridge.buildBootstrapScript();
      bridge.registerJavaScriptHandlers(controller);
      await bridge.pageDidFinishLoading();
      scope.setActive('space-1', const ['thesis'], name: 'Thesis');
      when(
        controller.evaluateJavascript(source: anyNamed('source')),
      ).thenThrow(StateError('webview disposed'));

      await expectLater(bridge.notifySpaceChanged(), completes);
    });

    test('the payload the host compares is the published value', () {
      // The web view only dispatches when `buildSpaceJson()` changes, so the
      // two must be the same string — otherwise a rename either never reaches
      // the page or fires on every unrelated notifyListeners().
      final bridge = buildBridge();
      scope.setActive('space-1', const ['thesis'], name: 'Thesis');
      expect(
        bridge.buildSpaceChangedScript(),
        contains('var space = ${bridge.buildSpaceJson()};'),
      );
    });

    test('a rename changes the published payload', () {
      final bridge = buildBridge();
      scope.setActive('space-1', const ['thesis'], name: 'Thesis');
      final before = bridge.buildSpaceJson();
      scope.setActive('space-1', const ['thesis'], name: 'Dissertation');
      expect(bridge.buildSpaceJson(), isNot(before));
    });
  });

  group('prompt documentation (CLAUDE.md: implement AND document)', () {
    setUpAll(() async {
      // Minimal asset manifest: PromptTemplateService enumerates
      // assets/prompts/**.md through it, then reads each file from disk.
      final manifest = <String, List<String>>{
        'assets/prompts/user_app/api_documentation.md': [
          'assets/prompts/user_app/api_documentation.md',
        ],
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', (message) async {
            final key = utf8.decode(message!.buffer.asUint8List());
            if (key == 'AssetManifest.bin') {
              return const StandardMessageCodec().encodeMessage(manifest);
            }
            if (key == 'AssetManifest.json') {
              return ByteData.view(
                Uint8List.fromList(utf8.encode(json.encode(manifest))).buffer,
              );
            }
            final file = File(key);
            if (await file.exists()) {
              return ByteData.view(
                Uint8List.fromList(await file.readAsBytes()).buffer,
              );
            }
            return null;
          });
    });

    tearDownAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', null);
    });

    Future<String> renderDocs() async {
      if (getIt.isRegistered<PromptTemplateService>()) {
        await getIt.unregister<PromptTemplateService>();
      }
      final service = PromptTemplateService();
      await service.preloadAll();
      getIt.registerSingleton<PromptTemplateService>(service);
      return UserAppService.testBuildApiDocumentationSection();
    }

    test('documents Synapse.space and its shape', () async {
      final docs = await renderDocs();
      expect(docs, contains('Synapse.space'));
      expect(docs, contains('{ id: string, name: string, tags: string[] }'));
      expect(docs, contains('null when none is active'));
    });

    test('documents the synapse:spacechanged event', () async {
      final docs = await renderDocs();
      expect(docs, contains('synapse:spacechanged'));
      expect(docs, contains('addEventListener'));
      expect(docs, contains('detail'));
    });

    test('advises scoping runQuery with the Space tags', () async {
      final docs = await renderDocs();
      final scoping = docs.substring(docs.indexOf('Synapse.space'));
      expect(scoping, contains('runQuery'));
      expect(scoping, contains('space.tags'));
      expect(scoping, contains(SpaceScopeService.allSpacesTag));
    });

    test(
      'the cross-Space OR is documented around the Space tag group only',
      () async {
        // The in-app query carries this warning; the doc used to say "around the
        // whole conjunction", which is correct only for the snippet above it
        // (the conjunction is the Space's tags alone). A plugin that also
        // requires a tag of its own follows it literally into
        // `(myTag AND spaceTags) OR all-spaces`, and since migration v47 every
        // agent-skill note carries the reserved tag — so that predicate returns
        // the whole skill library.
        final docs = await renderDocs();
        final scoping = docs.substring(docs.indexOf('Synapse.space'));
        // Whitespace-normalised: this is prose, so a phrase may wrap across
        // lines. Asserting the raw text makes the test fail on a re-wrap that
        // changes nothing about what the AI is taught.
        final clause = scoping
            .substring(scoping.indexOf(SpaceScopeService.allSpacesTag))
            .replaceAll(RegExp(r'\s+'), ' ');

        expect(clause, contains('Space tag group only'));
        expect(
          clause,
          isNot(contains('around the whole conjunction')),
          reason: 'that phrasing teaches the M5 blocker shape',
        );
        // And the counter-example is spelled out, not left implied.
        expect(clause, contains('ANDed outside'));
        expect(clause, contains('Never'));
      },
    );
  });
}
