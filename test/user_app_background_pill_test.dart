// test/user_app_background_pill_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/user_app.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/user_app_session_service.dart';
import 'package:note_synapse/utils/global_keys.dart';
import 'package:note_synapse/widgets/user_app_background_pill.dart';
import 'package:note_synapse/widgets/user_app_background_shell.dart';

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

void main() {
  late UserAppSessionService service;

  setUp(() async {
    await resetForTesting();
    // Both globals outlive a single test; clear the carried-over top route.
    appRouteObserver.resetForTesting();
    service = UserAppSessionService(
      homeBuilder: (_) => const Scaffold(body: Text('HOME_PRIME')),
    );
    getIt.registerSingleton<UserAppSessionService>(service);
  });

  /// Host wired like `main.dart`: the shell sits inside `MaterialApp.builder`,
  /// above the navigator, so the pill outlives screen changes.
  Widget host() => MaterialApp(
    navigatorKey: navigatorKey,
    navigatorObservers: [appRouteObserver],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: const [Locale('en', '')],
    builder: (context, child) =>
        UserAppBackgroundShell(child: child ?? const SizedBox.shrink()),
    home: const Scaffold(body: Text('HOME')),
  );

  /// Pushes a stub app screen, registers it, and backgrounds it.
  Future<MaterialPageRoute<void>> backgroundAnApp(
    WidgetTester tester,
    UserApp app,
  ) async {
    final route = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('APP')),
    );
    navigatorKey.currentState!.push(route);
    await tester.pumpAndSettle();
    service.register(app, route);
    await service.moveToBackground();
    await tester.pumpAndSettle();
    return route;
  }

  /// Lets the pill's "collapse to icon" timer fire so no timer is left pending.
  Future<void> settlePill(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  testWidgets('survives a session registered from within a build pass', (
    tester,
  ) async {
    await tester.pumpWidget(host());

    // UserAppViewScreen registers in didChangeDependencies and unregisters in
    // dispose — both run inside a build pass, with this shell already built.
    final route = MaterialPageRoute<void>(
      builder: (_) => _RegisteringStub(app: _app('1', 'Cartograph')),
    );
    navigatorKey.currentState!.push(route);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(service.session?.app.id, '1');

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(service.session, isNull);
  });

  testWidgets('evicts a previous session from within a build pass', (
    tester,
  ) async {
    await tester.pumpWidget(host());

    final first = MaterialPageRoute<void>(
      builder: (_) => _RegisteringStub(app: _app('1', 'Cartograph')),
    );
    navigatorKey.currentState!.push(first);
    await tester.pumpAndSettle();
    await service.moveToBackground();
    await tester.pumpAndSettle();
    expect(find.byType(UserAppBackgroundPill), findsOneWidget);

    // A second app is launched. Eviction runs inside the new screen's
    // `didChangeDependencies`, i.e. during a build pass.
    final second = MaterialPageRoute<void>(
      builder: (_) => _RegisteringStub(app: _app('2', 'Sheets')),
    );
    navigatorKey.currentState!.push(second);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(first.isActive, isFalse);
    // The new session was actually recorded, and it is in the foreground.
    expect(service.session?.app.id, '2');
    expect(find.byType(UserAppBackgroundPill), findsNothing);
    // The user is told which app was closed.
    expect(find.textContaining('Cartograph'), findsOneWidget);
  });

  testWidgets('stays hidden when the app route is covered by a sub-route', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final route = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('APP')),
    );
    navigatorKey.currentState!.push(route);
    await tester.pumpAndSettle();
    service.register(_app('1', 'Cartograph'), route);

    // An in-app note link pushes NoteDetailScreen on top of the app.
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('NOTE')),
      ),
    );
    await tester.pumpAndSettle();
    service.setForeground(route, false); // what didPushNext does
    await tester.pumpAndSettle();

    expect(find.text('NOTE'), findsOneWidget);
    expect(find.byType(UserAppBackgroundPill), findsNothing);
  });

  testWidgets('rests clear of the bottom navigation bar', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await backgroundAnApp(tester, _app('1', 'Cartograph'));
    await settlePill(tester);

    final pill = find.descendant(
      of: find.byType(UserAppBackgroundPill),
      matching: find.byType(AnimatedContainer),
    );

    // Backgrounding lands the user on MainScreen, whose BottomAppBar (Material
    // 3 default height 80) holds the four primary nav destinations along the
    // bottom edge. The pill lives above the Navigator, so any overlap wins the
    // hit test and eats taps meant for the "Notes" tab.
    const navBarTop = 800.0 - 80.0;
    expect(tester.getBottomRight(pill).dy, lessThanOrEqualTo(navBarTop));
    expect(tester.getTopLeft(pill).dx, closeTo(16, 1));
  });

  testWidgets('stays above a raised soft keyboard', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    // The shell sits inside `MaterialApp.builder`, so its constraints are the
    // whole window: `viewInsets` never shrinks them for us.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await backgroundAnApp(tester, _app('1', 'Cartograph'));
    await settlePill(tester);

    final pill = find.descendant(
      of: find.byType(UserAppBackgroundPill),
      matching: find.byType(AnimatedContainer),
    );
    expect(tester.getBottomRight(pill).dy, lessThanOrEqualTo(800.0 - 300.0));
  });

  testWidgets('keeps its snapped edge when it collapses on a phone width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await backgroundAnApp(tester, _app('1', 'Cartograph'));

    final pill = find.descendant(
      of: find.byType(UserAppBackgroundPill),
      matching: find.byType(AnimatedContainer),
    );

    // Drag it to the right edge while it is still expanded.
    await tester.drag(pill, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(pill).dx, greaterThan(16.0));

    // The collapse timer fires: the pill must stay on the right edge, not
    // teleport back to the left because it is narrower now.
    await settlePill(tester);
    expect(tester.getBottomRight(pill).dx, closeTo(400 - 16, 1));

    // And dragging it back left sticks to the left edge.
    await tester.drag(pill, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(pill).dx, closeTo(16, 1));
  });

  testWidgets('is hidden when nothing is running in the background', (
    tester,
  ) async {
    await tester.pumpWidget(host());

    expect(find.byType(UserAppBackgroundPill), findsNothing);
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('appears with the app name once the app is backgrounded', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await backgroundAnApp(tester, _app('1', 'Cartograph'));

    expect(find.byType(UserAppBackgroundPill), findsOneWidget);
    expect(find.text('Cartograph'), findsOneWidget);

    // Collapses to just the icon after the initial announcement.
    await settlePill(tester);
    expect(find.byType(UserAppBackgroundPill), findsOneWidget);
    expect(find.text('Cartograph'), findsNothing);
    expect(find.text('C'), findsOneWidget);
  });

  testWidgets('hides again while the app is in the foreground', (tester) async {
    await tester.pumpWidget(host());
    await backgroundAnApp(tester, _app('1', 'Cartograph'));
    await settlePill(tester);
    expect(find.byType(UserAppBackgroundPill), findsOneWidget);

    // Reaching the app by any means (here the system back gesture path)
    // must hide the pill.
    service.setForeground(service.session!.route, true);
    await tester.pumpAndSettle();

    expect(find.byType(UserAppBackgroundPill), findsNothing);
  });

  testWidgets('tap resumes the app and hides the pill', (tester) async {
    await tester.pumpWidget(host());
    final route = await backgroundAnApp(tester, _app('1', 'Cartograph'));
    await settlePill(tester);
    expect(find.text('HOME_PRIME'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(UserAppBackgroundPill),
        matching: find.byType(InkWell),
      ),
    );
    await tester.pumpAndSettle();

    expect(route.isCurrent, isTrue);
    expect(find.text('APP'), findsOneWidget);
    expect(find.text('HOME_PRIME'), findsNothing);
    expect(find.byType(UserAppBackgroundPill), findsNothing);
  });

  testWidgets('long-press asks for confirmation before closing', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final route = await backgroundAnApp(tester, _app('1', 'Cartograph'));
    await settlePill(tester);

    await tester.longPress(
      find.descendant(
        of: find.byType(UserAppBackgroundPill),
        matching: find.byType(InkWell),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Close app'), findsWidgets);

    // Cancelling leaves the session alone.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(route.isActive, isTrue);
    expect(service.session, isNotNull);
    expect(find.byType(UserAppBackgroundPill), findsOneWidget);
  });

  testWidgets('confirming the long-press closes the app', (tester) async {
    await tester.pumpWidget(host());
    final route = await backgroundAnApp(tester, _app('1', 'Cartograph'));
    await settlePill(tester);

    await tester.longPress(
      find.descendant(
        of: find.byType(UserAppBackgroundPill),
        matching: find.byType(InkWell),
      ),
    );
    await tester.pumpAndSettle();
    // Title and confirm button share the label; the button is the last one.
    await tester.tap(find.widgetWithText(TextButton, 'Close app'));
    await tester.pumpAndSettle();

    expect(route.isActive, isFalse);
    expect(service.session, isNull);
    expect(find.byType(UserAppBackgroundPill), findsNothing);
    // Closing does not move the user: they stay on the screen they were on,
    // rather than being walked back down to (and out of) the app.
    expect(find.text('HOME_PRIME'), findsOneWidget);
  });

  testWidgets('closing leaves the user on the screen they were using', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    // HOME -> APP -> HOME'(background) -> CLIPPER: the user backgrounded the
    // app, went to Home, and opened the web clipper from there.
    final route = await backgroundAnApp(tester, _app('1', 'Cartograph'));
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('CLIPPER')),
      ),
    );
    await tester.pumpAndSettle();
    await settlePill(tester);

    await tester.longPress(
      find.descendant(
        of: find.byType(UserAppBackgroundPill),
        matching: find.byType(InkWell),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Close app'));
    await tester.pumpAndSettle();

    expect(route.isActive, isFalse);
    expect(service.session, isNull);
    expect(find.byType(UserAppBackgroundPill), findsNothing);
    // Still clipping — not dragged back down through every screen opened
    // since backgrounding the app.
    expect(find.text('CLIPPER'), findsOneWidget);

    // And the stack underneath is intact, minus the app.
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('HOME_PRIME'), findsOneWidget);
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('re-announces the name when a different app takes the pill', (
    tester,
  ) async {
    Widget wrap(UserApp app) => MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en', '')],
      home: Stack(
        fit: StackFit.expand,
        children: [
          UserAppBackgroundPill(
            key: const ValueKey('pill'),
            app: app,
            onResume: () {},
            onClose: () {},
          ),
        ],
      ),
    );

    await tester.pumpWidget(wrap(_app('1', 'Cartograph')));
    expect(find.text('Cartograph'), findsOneWidget);
    await settlePill(tester);
    expect(find.text('Cartograph'), findsNothing);

    // Same widget, different app: the badge must say who it is now.
    await tester.pumpWidget(wrap(_app('2', 'Sheets')));
    await tester.pumpAndSettle();
    expect(find.text('Sheets'), findsOneWidget);
    await settlePill(tester);
    expect(find.text('Sheets'), findsNothing);
    expect(find.text('S'), findsOneWidget);
  });
}

/// Stands in for `UserAppViewScreen`: registers itself with the session service
/// from `didChangeDependencies` and drops the session in `dispose`.
class _RegisteringStub extends StatefulWidget {
  const _RegisteringStub({required this.app});

  final UserApp app;

  @override
  State<_RegisteringStub> createState() => _RegisteringStubState();
}

class _RegisteringStubState extends State<_RegisteringStub> {
  ModalRoute<void>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    final route = ModalRoute.of(context);
    if (route is! PageRoute<void>) return;
    _route = route;
    getIt<UserAppSessionService>().register(widget.app, route);
  }

  @override
  void dispose() {
    final route = _route;
    if (route != null) getIt<UserAppSessionService>().unregister(route);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('APP'));
}
