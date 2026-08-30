// test/user_app_session_service_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/user_app_session_service.dart';
import 'package:note_synapse/utils/global_keys.dart';

UserApp _app(String id, String name) => UserApp(
  id: id,
  uuid: 'uuid-$id',
  name: name,
  description: '',
  steps: const [],
  htmlContent: '',
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
);

/// Minimal host wired exactly like `main.dart`: global navigator key, the
/// global route observer, and localizations (the eviction snackbar needs them).
Widget _host() => MaterialApp(
  navigatorKey: navigatorKey,
  navigatorObservers: [appRouteObserver],
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: const [Locale('en', '')],
  home: const Scaffold(body: Text('HOME')),
);

void main() {
  late UserAppSessionService service;

  setUp(() async {
    await resetForTesting();
    // Both globals outlive a single test; clear the carried-over top route.
    appRouteObserver.resetForTesting();
    service = UserAppSessionService(
      homeBuilder: (_) => const Scaffold(body: Text('HOME_PRIME')),
    );
  });

  /// Pushes a stub "app screen" route and registers it as [app]'s session.
  Future<MaterialPageRoute<void>> pushApp(
    WidgetTester tester,
    UserApp app,
    String label,
  ) async {
    final route = MaterialPageRoute<void>(
      builder: (_) => Scaffold(body: Text(label)),
    );
    unawaitedPush(route);
    await tester.pumpAndSettle();
    service.register(app, route);
    return route;
  }

  /// Pushes a stub app screen wired exactly like `UserAppViewScreen`:
  /// registers itself, tracks the route observer, unregisters on dispose.
  /// Used where the *interaction between two app screens* is what is under
  /// test, so the `RouteAware` ordering is the real one.
  Future<MaterialPageRoute<void>> pushAppScreen(
    WidgetTester tester,
    UserApp app,
    String label,
  ) async {
    final route = MaterialPageRoute<void>(
      builder: (_) => _AppScreenStub(app: app, label: label, service: service),
    );
    unawaitedPush(route);
    await tester.pumpAndSettle();
    return route;
  }

  Future<void> pushPlain(WidgetTester tester, String label) async {
    unawaitedPush(
      MaterialPageRoute<void>(builder: (_) => Scaffold(body: Text(label))),
    );
    await tester.pumpAndSettle();
  }

  group('moveToBackground', () {
    testWidgets('pushes Home on top and keeps the app route alive', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');

      expect(service.hasBackgroundApp, isFalse);

      await service.moveToBackground();
      await tester.pumpAndSettle();

      expect(find.text('HOME_PRIME'), findsOneWidget);
      expect(service.hasBackgroundApp, isTrue);
      // The app route is covered, not popped — its state stays alive.
      expect(appRoute.isActive, isTrue);
      expect(appRoute.isCurrent, isFalse);
    });
  });

  group('resume', () {
    testWidgets('returns to the app route and discards the pushed screen', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');

      await service.moveToBackground();
      await tester.pumpAndSettle();

      await service.resume();
      await tester.pumpAndSettle();

      expect(find.text('APP'), findsOneWidget);
      expect(find.text('HOME_PRIME'), findsNothing);
      expect(appRoute.isCurrent, isTrue);
      expect(service.hasBackgroundApp, isFalse);
    });

    testWidgets('walks back down through several intervening routes', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');

      await service.moveToBackground();
      await tester.pumpAndSettle();
      unawaitedPush(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('CLIP')),
        ),
      );
      await tester.pumpAndSettle();

      await service.resume();
      await tester.pumpAndSettle();

      expect(appRoute.isCurrent, isTrue);
      expect(find.text('CLIP'), findsNothing);
    });

    testWidgets('a route that refuses to pop halts the walk back', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');

      await service.moveToBackground();
      await tester.pumpAndSettle();
      // Stands in for NoteDetailScreen's PopScope(canPop: !_isEditing).
      unawaitedPush(
        MaterialPageRoute<void>(
          builder: (_) => const PopScope(
            canPop: false,
            child: Scaffold(body: Text('EDITING')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await service.resume();
      await tester.pumpAndSettle();

      // The guarded route survives and the user is left on it.
      expect(find.text('EDITING'), findsOneWidget);
      expect(appRoute.isCurrent, isFalse);
      expect(service.hasBackgroundApp, isTrue);
    });

    testWidgets('walks on through a route with local history entries', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');

      await service.moveToBackground();
      await tester.pumpAndSettle();
      // A Drawer / SearchDelegate / anything holding a LocalHistoryEntry:
      // `pop` consumes the entry without removing the route, so the observer
      // sees no change even though the pop *was* handled.
      unawaitedPush(
        MaterialPageRoute<void>(builder: (_) => const _LocalHistoryScreen()),
      );
      await tester.pumpAndSettle();

      await service.resume();
      await tester.pumpAndSettle();

      expect(appRoute.isCurrent, isTrue);
      expect(find.text('LOCAL_HISTORY'), findsNothing);
      expect(service.hasBackgroundApp, isFalse);
    });

    testWidgets('still halts on a guarded route that has local history', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');

      await service.moveToBackground();
      await tester.pumpAndSettle();
      // Both at once: without checking `popDisposition` the "keep walking"
      // branch above would spin until the guard ran out.
      unawaitedPush(
        MaterialPageRoute<void>(
          builder: (_) =>
              const PopScope(canPop: false, child: _LocalHistoryScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await service.resume();
      await tester.pumpAndSettle();

      expect(find.text('LOCAL_HISTORY'), findsOneWidget);
      expect(appRoute.isCurrent, isFalse);
      expect(service.hasBackgroundApp, isTrue);
    });
  });

  group('foreground tracking', () {
    testWidgets('a sub-route pushed above the app does not show the pill', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      await pushApp(tester, _app('1', 'Cartograph'), 'APP');

      // The app screen pushes its own sub-routes (an in-app note link opens
      // NoteDetailScreen). `didPushNext` fires, but the user never asked to
      // background anything, so there must be no pill.
      unawaitedPush(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('NOTE')),
        ),
      );
      await tester.pumpAndSettle();
      service.setForeground(service.session!.route, false);

      expect(service.session, isNotNull);
      expect(service.hasBackgroundApp, isFalse);
    });

    testWidgets('popping a sub-route keeps the very same session', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final appRoute = await pushAppScreen(
        tester,
        _app('1', 'Cartograph'),
        'APP',
      );
      final session = service.session;
      expect(session, isNotNull);

      // An in-app note link, then back out of it. The app screen re-registers
      // on `didPopNext`; that must reuse the session, not build a new one.
      await pushPlain(tester, 'NOTE');
      expect(service.session!.isForeground, isFalse);

      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(identical(service.session, session), isTrue);
      expect(service.session!.isForeground, isTrue);
      expect(appRoute.isCurrent, isTrue);
    });

    testWidgets('returning to the app clears the explicit background state', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      await pushApp(tester, _app('1', 'Cartograph'), 'APP');

      await service.moveToBackground();
      await tester.pumpAndSettle();
      expect(service.hasBackgroundApp, isTrue);

      // The user walks back with the system back gesture: `didPopNext`.
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      service.setForeground(service.session!.route, true);
      expect(service.hasBackgroundApp, isFalse);

      // A sub-route pushed afterwards must not resurrect the pill.
      unawaitedPush(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('NOTE')),
        ),
      );
      await tester.pumpAndSettle();
      service.setForeground(service.session!.route, false);
      expect(service.hasBackgroundApp, isFalse);
    });

    testWidgets('a foreign route cannot move the tracked session', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final routeA = await pushAppScreen(tester, _app('1', 'Cartograph'), 'A');
      await pushAppScreen(tester, _app('2', 'Sheets'), 'B');
      await service.moveToBackground();
      await tester.pumpAndSettle();
      expect(service.hasBackgroundApp, isTrue);
      expect(service.session?.app.id, '2');

      // App A is buried two routes down and does not own the session. A stray
      // `RouteAware` callback from it must not hide B's pill (or, the other
      // way round, raise one for an app nobody backgrounded).
      service.setForeground(routeA, true);
      expect(service.hasBackgroundApp, isTrue);
      expect(service.session?.app.id, '2');

      service.setForeground(routeA, false);
      expect(service.hasBackgroundApp, isTrue);
      expect(service.session?.app.id, '2');
    });

    testWidgets(
      'a covering route removed rather than popped uncovers the app',
      (tester) async {
        await tester.pumpWidget(_host());
        final appRoute = await pushAppScreen(
          tester,
          _app('1', 'Cartograph'),
          'APP',
        );

        await service.moveToBackground();
        await tester.pumpAndSettle();
        expect(service.hasBackgroundApp, isTrue);

        // `removeRoute`, not `pop`: bare `RouteObserver` only forwards
        // `didPush`/`didPop`, so without the observer's own handling the app
        // would come back into view with the pill still floating over it.
        final covering = appRouteObserver.topRoute!;
        navigatorKey.currentState!.removeRoute(covering);
        await tester.pumpAndSettle();

        expect(appRoute.isCurrent, isTrue);
        expect(service.hasBackgroundApp, isFalse);
        expect(service.session?.isForeground, isTrue);
      },
    );
  });

  group('single session', () {
    testWidgets('registering a second app evicts a backgrounded first', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final firstRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP1');

      await service.moveToBackground();
      await tester.pumpAndSettle();

      final secondRoute = await pushApp(tester, _app('2', 'Sheets'), 'APP2');
      await tester.pumpAndSettle();

      expect(firstRoute.isActive, isFalse);
      expect(service.session?.app.id, '2');
      expect(secondRoute.isCurrent, isTrue);
      // The user is told which app was closed.
      expect(find.textContaining('Cartograph'), findsOneWidget);
    });

    testWidgets(
      'opening a second app by ordinary navigation keeps the first on the stack',
      (tester) async {
        await tester.pumpWidget(_host());
        // HOME -> APP_A -> NOTE -> APP_B, with A never backgrounded: the user
        // followed an in-app note link out of app A and launched app B from
        // there. B takes the session, but A is an ordinary back-stack entry.
        final routeA = await pushAppScreen(
          tester,
          _app('1', 'Cartograph'),
          'APP_A',
        );
        await pushPlain(tester, 'NOTE');
        final routeB = await pushAppScreen(
          tester,
          _app('2', 'Sheets'),
          'APP_B',
        );

        expect(routeA.isActive, isTrue, reason: 'A must not be removed');
        expect(service.session?.app.id, '2');
        expect(routeB.isCurrent, isTrue);
        // Nothing was closed, so nothing may claim it was.
        expect(find.textContaining('Closed'), findsNothing);

        // Back, back: exactly the stack the user built.
        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('NOTE'), findsOneWidget);

        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('APP_A'), findsOneWidget);
        expect(routeA.isCurrent, isTrue);

        // A owns the session again, so its own "run in background" button
        // works instead of silently doing nothing.
        expect(service.session?.app.id, '1');
        expect(identical(service.session?.route, routeA), isTrue);

        await service.moveToBackground();
        await tester.pumpAndSettle();
        expect(service.hasBackgroundApp, isTrue);
        expect(service.session?.app.id, '1');
        expect(find.text('HOME_PRIME'), findsOneWidget);
      },
    );

    testWidgets('re-opening the same app through a second route is silent', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final first = await pushAppScreen(
        tester,
        _app('1', 'Cartograph'),
        'APP1',
      );
      final second = await pushAppScreen(
        tester,
        _app('1', 'Cartograph'),
        'APP2',
      );

      expect(first.isActive, isTrue);
      expect(identical(service.session?.route, second), isTrue);
      expect(find.textContaining('Closed'), findsNothing);
    });

    testWidgets('closing the newer app leaves the older one usable', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final routeA = await pushAppScreen(tester, _app('1', 'Cartograph'), 'A');
      final routeB = await pushAppScreen(tester, _app('2', 'Sheets'), 'B');

      // B is backgrounded and then closed from the pill.
      await service.moveToBackground();
      await tester.pumpAndSettle();
      await service.discard();
      await tester.pumpAndSettle();
      expect(routeB.isActive, isFalse);
      expect(service.session, isNull);

      // Backing out of the pushed Home lands on A, which takes over again.
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(routeA.isCurrent, isTrue);
      expect(service.session?.app.id, '1');

      await service.moveToBackground();
      await tester.pumpAndSettle();
      expect(service.hasBackgroundApp, isTrue);
    });
  });

  group('unregister', () {
    testWidgets('clears the session when the app route is disposed', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');

      await service.moveToBackground();
      await tester.pumpAndSettle();
      expect(service.hasBackgroundApp, isTrue);

      service.unregister(appRoute);

      expect(service.session, isNull);
      expect(service.hasBackgroundApp, isFalse);
    });

    testWidgets('ignores a route it is not tracking', (tester) async {
      await tester.pumpWidget(_host());
      await pushApp(tester, _app('1', 'Cartograph'), 'APP');

      service.unregister(
        MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink()),
      );

      expect(service.session?.app.id, '1');
    });
  });

  group('discard (the pill\'s "close app")', () {
    testWidgets('leaves every screen opened since backgrounding intact', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      // HOME -> APPS_LIST -> APP -> HOME'(background) -> CLIPPER.
      await pushPlain(tester, 'APPS_LIST');
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');
      await service.moveToBackground();
      await tester.pumpAndSettle();
      await pushPlain(tester, 'CLIPPER');

      await service.discard();
      await tester.pumpAndSettle();

      expect(appRoute.isActive, isFalse);
      expect(service.session, isNull);
      // The user is still clipping.
      expect(find.text('CLIPPER'), findsOneWidget);

      // And the stack under them is the one they built, minus the app.
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('HOME_PRIME'), findsOneWidget);
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('APPS_LIST'), findsOneWidget);
    });

    testWidgets('never strands the user behind a route that refuses to pop', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');

      await service.moveToBackground();
      await tester.pumpAndSettle();
      unawaitedPush(
        MaterialPageRoute<void>(
          builder: (_) => const PopScope(
            canPop: false,
            child: Scaffold(body: Text('EDITING')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await service.discard();
      await tester.pumpAndSettle();

      expect(appRoute.isActive, isFalse);
      expect(service.session, isNull);
      // The guarded route the user is on is untouched — they are not dragged
      // out of it, and they are not left there with the app half-closed.
      expect(find.text('EDITING'), findsOneWidget);
    });

    testWidgets('never orphans an app route that refuses to pop', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      // The app screen itself guards its back button.
      final appRoute = MaterialPageRoute<void>(
        builder: (_) =>
            const PopScope(canPop: false, child: Scaffold(body: Text('APP'))),
      );
      unawaitedPush(appRoute);
      await tester.pumpAndSettle();
      service.register(_app('1', 'Cartograph'), appRoute);

      await service.discard();
      await tester.pumpAndSettle();

      // No live route + WebView left behind with nothing pointing at it.
      expect(appRoute.isActive, isFalse);
      expect(service.session, isNull);
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('tears the session down without walking the user back', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');

      await service.moveToBackground();
      await tester.pumpAndSettle();
      expect(find.text('HOME_PRIME'), findsOneWidget);

      await service.discard();
      await tester.pumpAndSettle();

      expect(appRoute.isActive, isFalse);
      expect(service.session, isNull);
      // The user stays where they were — no round trip through the app route.
      expect(find.text('HOME_PRIME'), findsOneWidget);
    });

    testWidgets('pops the app route when the user is looking at it', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');

      await service.discard();
      await tester.pumpAndSettle();

      expect(appRoute.isActive, isFalse);
      expect(service.session, isNull);
      expect(find.text('HOME'), findsOneWidget);
    });
  });

  group('unwindPreservingApp', () {
    testWidgets('leaves a backgrounded app alive when a share flow exits', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      // HOME -> APP -> HOME'(background) -> SHARE, the clip-a-page path.
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');
      await service.moveToBackground();
      await tester.pumpAndSettle();

      final shareRoute = MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/share'),
        builder: (_) => const Scaffold(body: Text('SHARE')),
      );
      unawaitedPush(shareRoute);
      await tester.pumpAndSettle();

      final handled = service.unwindPreservingApp(
        navigatorKey.currentState!,
        shareRoute,
      );
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      // The share flow is gone, the user is back where they were...
      expect(shareRoute.isActive, isFalse);
      expect(find.text('HOME_PRIME'), findsOneWidget);
      // ...and the running app survived, still reachable from the pill.
      expect(appRoute.isActive, isTrue);
      expect(service.hasBackgroundApp, isTrue);

      await service.resume();
      await tester.pumpAndSettle();
      expect(find.text('APP'), findsOneWidget);
    });

    testWidgets('pops several routes the flow pushed above itself', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');
      await service.moveToBackground();
      await tester.pumpAndSettle();

      final shareRoute = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('SHARE')),
      );
      unawaitedPush(shareRoute);
      await tester.pumpAndSettle();
      await pushPlain(tester, 'PICKER');

      expect(
        service.unwindPreservingApp(navigatorKey.currentState!, shareRoute),
        isTrue,
      );
      await tester.pumpAndSettle();

      expect(find.text('PICKER'), findsNothing);
      expect(find.text('HOME_PRIME'), findsOneWidget);
      expect(appRoute.isActive, isTrue);
    });

    testWidgets('declines when no app is running, so the caller resets', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      final shareRoute = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('SHARE')),
      );
      unawaitedPush(shareRoute);
      await tester.pumpAndSettle();

      expect(
        service.unwindPreservingApp(navigatorKey.currentState!, shareRoute),
        isFalse,
      );
      // Untouched — the caller still owns the decision.
      expect(find.text('SHARE'), findsOneWidget);
    });

    testWidgets('declines once the app route is gone', (tester) async {
      await tester.pumpWidget(_host());
      final appRoute = await pushApp(tester, _app('1', 'Cartograph'), 'APP');
      await service.moveToBackground();
      await tester.pumpAndSettle();
      navigatorKey.currentState!.removeRoute(appRoute);
      await tester.pumpAndSettle();

      final shareRoute = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('SHARE')),
      );
      unawaitedPush(shareRoute);
      await tester.pumpAndSettle();

      expect(
        service.unwindPreservingApp(navigatorKey.currentState!, shareRoute),
        isFalse,
      );
    });
  });
}

/// Stands in for `UserAppViewScreen`, wired the same way: registers its route
/// on first build, follows the route observer for foreground tracking, and
/// unregisters when disposed. Two of these can be alive on the stack at once,
/// which is what the ownership rules exist for.
class _AppScreenStub extends StatefulWidget {
  const _AppScreenStub({
    required this.app,
    required this.label,
    required this.service,
  });

  final UserApp app;
  final String label;
  final UserAppSessionService service;

  @override
  State<_AppScreenStub> createState() => _AppScreenStubState();
}

class _AppScreenStubState extends State<_AppScreenStub> with RouteAware {
  ModalRoute<void>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    final route = ModalRoute.of(context);
    if (route is! PageRoute<void>) return;
    _route = route;
    appRouteObserver.subscribe(this, route);
    widget.service.register(widget.app, route);
  }

  @override
  void didPushNext() {
    final route = _route;
    if (route != null) widget.service.setForeground(route, false);
  }

  @override
  void didPopNext() {
    final route = _route;
    if (route != null) widget.service.register(widget.app, route);
  }

  @override
  void dispose() {
    final route = _route;
    if (route != null) {
      appRouteObserver.unsubscribe(this);
      widget.service.unregister(route);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: Text(widget.label));
}

/// Stands in for any screen holding a [LocalHistoryEntry] — an open `Drawer`,
/// a `SearchDelegate`, a `DropdownButton` menu. `Navigator.pop` consumes the
/// entry inside the route instead of removing the route.
class _LocalHistoryScreen extends StatefulWidget {
  const _LocalHistoryScreen();

  @override
  State<_LocalHistoryScreen> createState() => _LocalHistoryScreenState();
}

class _LocalHistoryScreenState extends State<_LocalHistoryScreen> {
  bool _added = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_added) return;
    _added = true;
    ModalRoute.of(context)!.addLocalHistoryEntry(LocalHistoryEntry());
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('LOCAL_HISTORY'));
}

/// Pushes without awaiting: a push future only completes when the route is
/// popped, which no test wants to wait for.
void unawaitedPush(Route<void> route) {
  navigatorKey.currentState!.push(route);
}
