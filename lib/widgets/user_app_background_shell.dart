// lib/widgets/user_app_background_shell.dart
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/service_locator.dart';
import '../services/user_app_session_service.dart';
import 'user_app_background_pill.dart';

/// Root-level host that floats a [UserAppBackgroundPill] over every screen
/// while a User App is running in the background.
///
/// Lives above navigation (in `MaterialApp.builder`), so the pill survives
/// screen changes — that is the whole point of it. Mirrors the `WorkflowShell`
/// pattern; the two compose, with this one inside so the pill floats over page
/// content rather than fighting the mini-player for the bottom edge.
class UserAppBackgroundShell extends StatefulWidget {
  const UserAppBackgroundShell({super.key, required this.child});

  final Widget child;

  @override
  State<UserAppBackgroundShell> createState() => _UserAppBackgroundShellState();
}

class _UserAppBackgroundShellState extends State<UserAppBackgroundShell> {
  UserAppSessionService? _service;

  @override
  void initState() {
    super.initState();
    if (getIt.isRegistered<UserAppSessionService>()) {
      _service = getIt<UserAppSessionService>();
      _service!.addListener(_onSessionChanged);
    }
  }

  @override
  void dispose() {
    _service?.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    // Sessions are registered from `UserAppViewScreen.didChangeDependencies`
    // and dropped from its `dispose` — both inside a build pass. This shell is
    // an ancestor that has already built by then, so marking it dirty now would
    // assert; defer to the end of the frame instead.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    final session = service?.session;
    final showPill = service != null && service.hasBackgroundApp;

    return Stack(
      // Expand so the pill's LayoutBuilder measures the full available area
      // rather than sizing itself to the pill.
      fit: StackFit.expand,
      children: [
        widget.child,
        if (showPill && session != null)
          UserAppBackgroundPill(
            app: session.app,
            onResume: service.resume,
            // `discard`, not a walk back to the app and out again: the user
            // asked to close the app, not to be taken on a tour of every
            // screen they opened since backgrounding it.
            onClose: service.discard,
          ),
      ],
    );
  }
}
