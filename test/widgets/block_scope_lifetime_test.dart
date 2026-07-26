import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/screens/note_action_app_selection_screen.dart';
import 'package:note_synapse/services/block_note_scope_service.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:provider/provider.dart';

import 'block_scope_lifetime_test.mocks.dart';

/// Regression test for the block-scope lifetime contract.
///
/// [NoteActionAppSelectionScreen] launches the plugin with
/// `Navigator.pushReplacement`, which COMPLETES the replaced route's future
/// immediately. Tying scope cleanup to `await Navigator.push(...)` therefore
/// closed the scope before the plugin screen was even built, and every plugin
/// write silently became a no-op. Scope lifetime must belong to the screen that
/// opened it (its `dispose`), never to a route future.
@GenerateNiceMocks([MockSpec<AppProvider>(), MockSpec<DatabaseService>()])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _assertProductionWiring();

  late MockAppProvider mockAppProvider;
  late MockDatabaseService mockDb;
  late BlockNoteScopeService scopeService;

  final note = Note(
    id: 'parent-1',
    title: 'Parent',
    content: 'Intro\n\nBLOCK\n\nOutro',
    type: NoteType.note,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  setUp(() {
    getIt.reset();
    mockDb = MockDatabaseService();
    mockAppProvider = MockAppProvider();
    when(mockAppProvider.isLoading).thenReturn(false);
    when(mockAppProvider.userApps).thenReturn([
      UserApp(
        id: 'app-1',
        uuid: 'app-uuid-1',
        name: 'Test Note Action App',
        description: 'does things',
        steps: const [],
        htmlContent: '<html></html>',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        type: UserAppType.noteAction,
      ),
    ]);

    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<DataChangeNotifier>(DataChangeNotifier());
    scopeService = BlockNoteScopeService(mockDb);
    getIt.registerSingleton<BlockNoteScopeService>(scopeService);
  });

  testWidgets(
    'scope outlives the picker route being replaced by the plugin screen',
    (tester) async {
      final events = <String>[];
      late BlockNoteScope scope;

      await tester.pumpWidget(
        ChangeNotifierProvider<AppProvider>.value(
          value: mockAppProvider,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: _HostScreen(
              onOpen: (context) async {
                scope = scopeService.open(
                  parent: note,
                  spanStart: 7,
                  spanEnd: 12,
                  text: 'BLOCK',
                );
                events.add('scope-open');
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => NoteActionAppSelectionScreen(
                      selectedNotes: [scopeService.asNote(scope)],
                    ),
                  ),
                );
                events.add('push-future-resolved');
              },
              onDisposeScope: () {
                events.add('scope-close');
                scopeService.close(scope.tempNoteId);
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(scopeService.lookup(scope.tempNoteId), isNotNull);

      // Pick the app: the picker pushReplacement's to the plugin screen, which
      // resolves the future the host is awaiting.
      await tester.tap(find.text('Test Note Action App'));
      await tester.pumpAndSettle();

      expect(
        events,
        contains('push-future-resolved'),
        reason:
            'pushReplacement completes the replaced route future - this is '
            'exactly why cleanup must not hang off that future',
      );
      expect(
        events,
        isNot(contains('scope-close')),
        reason:
            'the scope must still be open while the plugin runs, otherwise '
            'every plugin write silently no-ops',
      );
      expect(
        scopeService.lookup(scope.tempNoteId),
        isNotNull,
        reason: 'the plugin resolves its transient note id through this lookup',
      );
    },
  );

  testWidgets('scope is released when the owning screen is disposed', (
    tester,
  ) async {
    late BlockNoteScope scope;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: mockAppProvider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: _HostScreen(
            onOpen: (context) async {
              scope = scopeService.open(
                parent: note,
                spanStart: 7,
                spanEnd: 12,
                text: 'BLOCK',
              );
            },
            onDisposeScope: () => scopeService.close(scope.tempNoteId),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(scopeService.hasOpenScopes, isTrue);

    // Tear the owning screen down.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(
      scopeService.hasOpenScopes,
      isFalse,
      reason: 'a scope must never outlive the screen that owns it',
    );
  });
}

/// The tests above prove the PATTERN with a stand-in host, because pumping the
/// real NoteDetailScreen is impractical (it pulls in most of the service
/// graph). This pins the production WIRING so the pattern cannot silently be
/// unhooked: the catastrophic version of this bug was a scope that was closed
/// too early, and nothing else in the suite would notice if the release moved
/// back onto a route future.
void _assertProductionWiring() {
  final source = File('lib/screens/note_detail_screen.dart').readAsStringSync();

  test('NoteDetailScreen releases the block scope from dispose', () {
    final dispose = source.substring(
      source.indexOf('  void dispose() {'),
      source.indexOf('  void _setupAudioListeners()'),
    );
    expect(
      dispose,
      contains('_releaseBlockScope()'),
      reason: 'the scope must be released when the owning screen goes away',
    );
  });

  test('NoteDetailScreen does not close the scope on a route future', () {
    // NoteActionAppSelectionScreen uses pushReplacement, which completes the
    // pushing future immediately — so a finally around the push would close the
    // scope before the plugin has even loaded.
    final handler = source.substring(
      source.indexOf('Future<void> _handleNoteActionAppSelection()'),
      source.indexOf('void _releaseBlockScope()'),
    );
    expect(
      handler,
      isNot(contains('finally')),
      reason:
          'closing the scope when the pushed route completes is the '
          'original bug: pushReplacement resolves that future early',
    );
  });
}

/// Stands in for NoteDetailScreen: opens a scope, pushes the real picker, and
/// releases the scope in dispose (the production ownership model).
class _HostScreen extends StatefulWidget {
  const _HostScreen({required this.onOpen, required this.onDisposeScope});

  final Future<void> Function(BuildContext context) onOpen;
  final VoidCallback onDisposeScope;

  @override
  State<_HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<_HostScreen> {
  @override
  void dispose() {
    widget.onDisposeScope();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => widget.onOpen(context),
          child: const Text('open'),
        ),
      ),
    );
  }
}
