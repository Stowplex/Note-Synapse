import 'package:flutter/widgets.dart';

import '../utils/global_keys.dart';

/// Calls [onResumed] when the route hosting [child] becomes the top route
/// again after a full screen ([PageRoute]) was opened anywhere above it,
/// including through a dialog (app, dialog, page, pop, pop).
///
/// Closing only a dialog or other popup does not count: it covers the screen
/// but is not a navigation away. Subscribes to [observer], which defaults to the
/// app-wide [appRouteObserver].
class RouteResumeListener extends StatefulWidget {
  const RouteResumeListener({
    super.key,
    required this.onResumed,
    required this.child,
    this.observer,
  });

  final VoidCallback onResumed;
  final Widget child;

  /// The observer to subscribe to; [appRouteObserver] when null.
  final AppRouteObserver? observer;

  @override
  State<RouteResumeListener> createState() => _RouteResumeListenerState();
}

class _RouteResumeListenerState extends State<RouteResumeListener>
    with RouteAware {
  ModalRoute<void>? _route;

  /// [AppRouteObserver.pagePushes] before the route that covered ours.
  int? _pagePushesBeforeCover;

  AppRouteObserver get _observer => widget.observer ?? appRouteObserver;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == null || identical(route, _route)) return;
    if (_route != null) _observer.unsubscribe(this);
    _route = route;
    _observer.subscribe(this, route);
  }

  @override
  void didPushNext() {
    // The observer counts the covering route before notifying subscribers.
    final covering = _observer.topRoute is PageRoute ? 1 : 0;
    _pagePushesBeforeCover = _observer.pagePushes - covering;
  }

  @override
  void didPopNext() {
    final before = _pagePushesBeforeCover;
    _pagePushesBeforeCover = null;
    if (before == null || _observer.pagePushes <= before) return;
    widget.onResumed();
  }

  @override
  void dispose() {
    if (_route != null) _observer.unsubscribe(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
