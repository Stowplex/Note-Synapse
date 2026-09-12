// lib/services/user_app_session_service.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../l10n/app_localizations.dart';
import '../models/user_app.dart';
import '../screens/main_screen.dart';
import '../utils/global_keys.dart';
import '../utils/user_app_localization.dart';

/// A single running User App whose route is kept alive on the navigator stack.
///
/// [route] is the `UserAppViewScreen`'s own [ModalRoute]. While the app is
/// backgrounded the route is *covered* (not popped), so its element tree —
/// including the live WebView and all of its JS/DOM state — stays alive.
class UserAppBackgroundSession {
  UserAppBackgroundSession({
    required this.app,
    required this.route,
    this.isForeground = true,
    this.backgrounded = false,
  });

  final UserApp app;
  final Route<dynamic> route;

  /// Whether the app's route is currently the visible one.
  bool isForeground;

  /// Whether the user explicitly sent this app to the background.
  ///
  /// Distinct from `!isForeground`: the app screen pushes sub-routes of its own
  /// (an in-app note link opens `NoteDetailScreen`, the edit button opens
  /// `UserAppEditScreen`), which covers the app route without the user ever
  /// asking to background anything. The pill means "you backgrounded this",
  /// so it keys off this flag; `isForeground` only tracks visibility.
  bool backgrounded;
}

/// Tracks the single User App allowed to keep running while the user navigates
/// elsewhere.
///
/// The mechanism relies on one property of Flutter's [Navigator]: a route that
/// is covered by another route keeps its state, while a popped route is
/// disposed. So "background the app" pushes a fresh [MainScreen] *on top of*
/// the app route, and "resume" pops back down to it.
///
/// All navigation goes through [navigatorKey], the established pattern for
/// navigating from non-UI code.
class UserAppSessionService extends ChangeNotifier {
  /// [homeBuilder] builds the screen pushed on top of the app when
  /// backgrounding. Always Home in the app; injected in tests, where the real
  /// [MainScreen] would drag in the whole service graph.
  UserAppSessionService({WidgetBuilder? homeBuilder})
    : _homeBuilder = homeBuilder ?? _buildHome;

  static Widget _buildHome(BuildContext context) => const MainScreen();

  final WidgetBuilder _homeBuilder;

  UserAppBackgroundSession? _session;

  /// The tracked session, foreground or background, if any.
  UserAppBackgroundSession? get session => _session;

  /// Whether an app was explicitly backgrounded and is still covered — i.e.
  /// the pill should show.
  bool get hasBackgroundApp =>
      _session != null && _session!.backgrounded && !_session!.isForeground;

  NavigatorState? get _navigator => navigatorKey.currentState;

  /// Records [app]/[route] as the tracked session — "this app screen is the one
  /// the user is looking at".
  ///
  /// Called both when an app screen is pushed and when it becomes visible again
  /// (`didPopNext`), so the screen the user is on always owns the session and
  /// its "run in background" button always acts on itself.
  ///
  /// The single-session rule applies to *backgrounded* apps only: if the held
  /// session was explicitly backgrounded, its buried route is disposed with
  /// [NavigatorState.removeRoute] (which works on covered routes without
  /// disturbing anything above them) and the user is told which app was closed.
  /// A session that was merely covered — the user walked forward from app A
  /// through a note into app B — keeps its route: it is an ordinary entry in
  /// the back stack that the user expects to find again on the way back, and
  /// ripping it out with `removeRoute` would silently break the stack.
  void register(UserApp app, Route<dynamic> route) {
    final existing = _session;
    if (existing != null && identical(existing.route, route)) {
      // Same route re-registering: `didChangeDependencies` fired again, or the
      // screen was uncovered and is reclaiming the foreground.
      setForeground(route, true);
      return;
    }

    if (existing != null && existing.backgrounded) {
      _evict(existing);
    }

    // Whether or not anything was evicted, the new screen takes ownership. A
    // non-backgrounded predecessor simply stops being tracked; it stays alive
    // on the stack and re-registers through `didPopNext` if the user backs
    // into it again.
    _session = UserAppBackgroundSession(app: app, route: route);
    notifyListeners();
  }

  void _evict(UserAppBackgroundSession existing) {
    final nav = _navigator;
    if (nav != null && existing.route.isActive) {
      nav.removeRoute(existing.route);
    }
    _session = null;
    _showEvictedMessage(existing.app);
  }

  void _showEvictedMessage(UserApp app) {
    // `register` is called from `UserAppViewScreen.didChangeDependencies`, i.e.
    // inside a build pass, where `showSnackBar` throws. The state transition
    // above must still complete, so only the message is deferred — same guard
    // as `UserAppBackgroundShell._onSessionChanged`.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showEvictedMessage(app),
      );
      return;
    }

    final context = navigatorKey.currentContext;
    if (context == null) return;
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text(l10n.backgroundAppClosed(app.displayName(context)))),
    );
  }

  /// Drops the session if [route] is the one being tracked. Called from
  /// `UserAppViewScreen.dispose`, so a route torn down by any means (back
  /// gesture, `pushReplacement`, an unrelated `popUntil`) leaves no stale pill.
  void unregister(Route<dynamic> route) {
    if (_session == null || !identical(_session!.route, route)) return;
    _session = null;
    notifyListeners();
  }

  /// Updates whether the tracked app is the visible route. Driven by the
  /// `RouteAware` callbacks so the pill also hides when the user returns to the
  /// app with the system back gesture instead of tapping the pill.
  ///
  /// [route] is the calling screen's own route: two app screens can be alive on
  /// the stack at once (app A → note link → app B), and only the one that owns
  /// the session may move it. Without the check, A's `didPushNext` would mark
  /// B's session as hidden and raise or drop the pill for the wrong app.
  void setForeground(Route<dynamic> route, bool value) {
    final session = _session;
    if (session == null) return;
    if (!identical(session.route, route)) return;

    var changed = false;
    if (session.isForeground != value) {
      session.isForeground = value;
      changed = true;
    }
    // Reaching the app again — by the pill or by the system back gesture —
    // ends the explicit background state, so a sub-route pushed afterwards
    // does not bring the pill back.
    if (value && session.backgrounded) {
      session.backgrounded = false;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Pushes a fresh [MainScreen] on top of the running app, leaving the app's
  /// route (and WebView) alive underneath.
  Future<void> moveToBackground() async {
    final session = _session;
    final nav = _navigator;
    if (session == null || nav == null) return;
    if (!session.isForeground) return;

    // The only place `backgrounded` is set: the pill means the user asked for
    // it. `isForeground` is flipped by didPushNext as well, but set it eagerly
    // so the pill appears even if the observer is not wired (e.g. in tests).
    session.backgrounded = true;
    session.isForeground = false;
    notifyListeners();

    // Deliberately not awaited: a push future only completes when that route is
    // popped again, which is not what callers of this method are waiting for.
    unawaited(nav.push(MaterialPageRoute<void>(builder: _homeBuilder)));
  }

  /// Unwinds a modal flow (the share sheet, say) without destroying a live
  /// User App that is sitting further down the stack.
  ///
  /// Flows that end by resetting the navigator — `pushNamedAndRemoveUntil('/main',
  /// (route) => false)` — would take a backgrounded app with them, which is
  /// exactly the app the user went to that flow to come back to: clip a page,
  /// return to the mind map. When a live app route exists this pops only what
  /// the flow itself pushed and returns true. Otherwise it does nothing and
  /// returns false, leaving the caller to reset the stack as it normally would.
  bool unwindPreservingApp(
    NavigatorState navigator,
    ModalRoute<dynamic>? flowRoute,
  ) {
    final session = _session;
    if (session == null || !session.route.isActive || flowRoute == null) {
      return false;
    }
    // `isFirst` is a floor: never pop past the root, even if `flowRoute` has
    // somehow already left the stack.
    navigator.popUntil((route) => identical(route, flowRoute) || route.isFirst);
    if (flowRoute.isCurrent) navigator.pop();
    return true;
  }

  /// Walks back down to the app's route, exactly as if the user pressed back
  /// N times.
  ///
  /// Uses [NavigatorState.maybePop] rather than `popUntil`: `popUntil` ignores
  /// `PopScope`, so a route's own back handler never runs. `maybePop` gives
  /// each screen its own back semantics and makes the transition visible to the
  /// user instead of teleporting them. (It does not protect in-progress edits:
  /// `NoteDetailScreen`'s handler cancels editing and reverts the controllers,
  /// so the same unsaved sliver is dropped either way.) If a route refuses to
  /// pop the loop stops and the user is left there — a second tap completes the
  /// return.
  ///
  /// `maybePop` returns true both when it popped and when the route refused
  /// (`RoutePopDisposition.doNotPop` is "handled"), so refusal is detected by
  /// watching [AppRouteObserver.topRoute] instead: if the top of the stack did
  /// not change, nothing moved and the walk stops.
  Future<void> resume() async {
    final session = _session;
    final nav = _navigator;
    if (session == null || nav == null) return;

    // Hard bound so a navigator we cannot observe can never spin forever.
    var guard = 100;
    while (session.route.isActive && !session.route.isCurrent && guard-- > 0) {
      final before = appRouteObserver.topRoute;
      // A route holding LocalHistoryEntries (an open Drawer, a SearchDelegate)
      // consumes the pop itself: one entry goes, the route stays, and no
      // observer callback fires. That is progress, not a refusal, so keep
      // walking. Each pass consumes exactly one entry and a route has finitely
      // many, so the loop still terminates (and `guard` bounds it regardless).
      final consumesPopInternally =
          before is ModalRoute &&
          before.willHandlePopInternally &&
          before.popDisposition == RoutePopDisposition.pop;
      // Runs the top route's own back semantics, exactly like the back button.
      final handled = await nav.maybePop();
      if (!handled) break;
      if (identical(before, appRouteObserver.topRoute) &&
          !consumesPopInternally) {
        break;
      }
    }

    if (session.route.isCurrent) {
      setForeground(session.route, true);
    }
  }

  /// Closes the session where it stands, without walking the user back to the
  /// app first.
  ///
  /// The single teardown path — used both by the pill's "close app" and by the
  /// app-was-deleted check. Closing must not move the user: they are looking at
  /// whichever screen they reached after backgrounding the app (a clipper, a
  /// note), and returning to the app route only to pop it again would be a
  /// string of page transitions through screens they wanted kept — and would
  /// strand them mid-stack if one of those screens refuses to pop.
  ///
  /// Still uses `maybePop` when the app route happens to be the current one, so
  /// the app's own back semantics run where they matter.
  Future<void> discard() async {
    final session = _session;
    final nav = _navigator;
    if (session == null || nav == null) {
      _session = null;
      notifyListeners();
      return;
    }

    if (!session.route.isActive) {
      // Already gone; dispose() will have unregistered it.
      unregister(session.route);
      return;
    }

    if (session.route.isCurrent) {
      await nav.maybePop();
      // `maybePop` is a no-op if the app screen's own back handler refuses.
      // Without this the route and its WebView would stay alive with no
      // session and no pill left to reach them.
      if (session.route.isActive) nav.removeRoute(session.route);
    } else {
      nav.removeRoute(session.route);
    }
    unregister(session.route);
  }
}
