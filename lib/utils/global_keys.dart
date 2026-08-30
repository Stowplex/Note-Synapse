import 'package:flutter/material.dart';

/// Global key for the navigator to allow navigation from non-UI code
/// (e.g. Services) without passing context around or creating circular dependencies.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Route observer for the app's single navigator.
///
/// Screens that need to know when they get covered by another route
/// (`didPushNext`) or uncovered again (`didPopNext`) subscribe to this with a
/// `RouteAware` mixin. Used by `UserAppViewScreen` to track whether a running
/// User App is in the foreground while it is kept alive in the background.
///
/// It also keeps a pointer to the topmost route. The [Navigator] does not
/// expose its stack, and `NavigatorState.maybePop` cannot be used to tell "the
/// route refused to pop" from "the route popped": it returns true for both
/// (`RoutePopDisposition.doNotPop` counts as handled). Watching [topRoute]
/// across a `maybePop` gives that answer — if it did not change, nothing moved.
class AppRouteObserver extends RouteObserver<ModalRoute<void>> {
  Route<dynamic>? _topRoute;

  /// The route currently on top of the stack, as far as observation goes.
  Route<dynamic>? get topRoute => _topRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _topRoute = route;
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(_topRoute, route)) _topRoute = previousRoute;
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final wasTop = identical(_topRoute, route);
    if (wasTop) _topRoute = previousRoute;
    super.didRemove(route, previousRoute);
    if (wasTop) {
      // [RouteObserver] only wires `didPush`/`didPop` through to its
      // `RouteAware` subscribers. A route that is *removed* while on top
      // uncovers the one below it exactly as a pop would, but without this the
      // newly visible screen would never hear `didPopNext` — a backgrounded
      // User App would become visible with the pill still floating over it.
      // Only fire when the removed route was on top: `removeRoute` on a buried
      // route (how a background session is closed) uncovers nobody.
      super.didPop(route, previousRoute);
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (identical(_topRoute, oldRoute)) _topRoute = newRoute;
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  /// Drops the remembered top route. This observer is a process-global, so
  /// without this a widget test would inherit the previous test's stack.
  @visibleForTesting
  void resetForTesting() {
    _topRoute = null;
  }
}

/// Global route observer, wired into `MaterialApp.navigatorObservers`.
final AppRouteObserver appRouteObserver = AppRouteObserver();
