// lib/widgets/user_app_background_pill.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/user_app.dart';
import '../utils/user_app_localization.dart';
import '../utils/global_keys.dart';

/// Floating handle for a User App that is running in the background.
///
/// Expands to show the app's name when it first appears, then collapses to a
/// circular icon. Tap resumes the app, long-press closes it after a confirm.
/// Draggable, snapping to whichever screen edge is nearer.
///
/// Defaults to the bottom-left: the bottom-right belongs to the Notes screen
/// FAB, and the very bottom strip to the workflow mini-player.
class UserAppBackgroundPill extends StatefulWidget {
  const UserAppBackgroundPill({
    super.key,
    required this.app,
    required this.onResume,
    required this.onClose,
  });

  final UserApp app;
  final VoidCallback onResume;
  final VoidCallback onClose;

  @override
  State<UserAppBackgroundPill> createState() => _UserAppBackgroundPillState();
}

class _UserAppBackgroundPillState extends State<UserAppBackgroundPill> {
  static const double _size = 52;
  static const double _margin = 16;
  static const Duration _expandedDuration = Duration(seconds: 3);

  /// Top-left offset of the pill, null until first laid out against the
  /// available size (so we can anchor it to the bottom-left).
  Offset? _position;

  /// Which edge the pill is parked against. Stored as a *side* rather than an
  /// x coordinate: the pill's width changes when it collapses, so a stored x
  /// snapped against the expanded width would be re-snapped against the
  /// collapsed one and jump to the opposite edge — on every phone-sized screen
  /// (any width from 100 to 466 dp).
  bool _snapRight = false;
  bool _expanded = true;
  bool _dragging = false;
  Timer? _collapseTimer;

  @override
  void initState() {
    super.initState();
    _collapseTimer = Timer(_expandedDuration, () {
      if (mounted) setState(() => _expanded = false);
    });
  }

  @override
  void didUpdateWidget(UserAppBackgroundPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different app took over the session — re-announce its name.
    if (oldWidget.app.id != widget.app.id) {
      _collapseTimer?.cancel();
      _expanded = true;
      _collapseTimer = Timer(_expandedDuration, () {
        if (mounted) setState(() => _expanded = false);
      });
    }
  }

  @override
  void dispose() {
    _collapseTimer?.cancel();
    super.dispose();
  }

  String _initial(BuildContext context) {
    final name = widget.app.displayName(context).trim();
    return name.isEmpty ? '?' : name.characters.first.toUpperCase();
  }

  Future<void> _confirmClose() async {
    final l10n = AppLocalizations.of(context)!;
    // This widget lives above the Navigator (it is installed in
    // `MaterialApp.builder`), so its own context has no Navigator to host a
    // dialog. Route through the global key, as WorkflowShell does.
    final navContext = navigatorKey.currentContext;
    if (navContext == null) return;
    final confirmed = await showDialog<bool>(
      context: navContext,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.closeBackgroundApp),
        content: Text(
          l10n.closeBackgroundAppConfirm(widget.app.displayName(context)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.closeBackgroundApp),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

    // This widget is installed in `MaterialApp.builder`, above the Navigator,
    // so its constraints are the whole window: nothing here shrinks for the
    // screen's bottom bar or for a raised soft keyboard. Both have to be
    // subtracted by hand.
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    // `viewPadding`, not `padding`: it keeps reporting the home indicator's
    // height while the keyboard is up, so the resting spot does not jump.
    final safeBottom = media.viewPadding.bottom;

    return LayoutBuilder(
      builder: (context, constraints) {
        final bounds = Size(constraints.maxWidth, constraints.maxHeight);
        // Expanded width is capped so a long app name cannot overflow.
        final expandedWidth = (bounds.width * 0.6).clamp(_size, 280.0);
        final width = _expanded ? expandedWidth : _size;

        final maxX = (bounds.width - width - _margin)
            .clamp(_margin, double.infinity)
            .toDouble();
        final maxY = (bounds.height - keyboard - _size - _margin)
            .clamp(_margin, double.infinity)
            .toDouble();

        // Anchor bottom-left on first layout; re-derive afterwards from the
        // stored side and the *current* width, so a rotation, a keyboard or a
        // collapse cannot strand the pill off screen or flip it across it.
        //
        // Backgrounding an app lands the user on `MainScreen`, whose
        // `BottomAppBar` holds the four primary nav destinations along the
        // bottom edge — and the pill wins the hit test against it, since it
        // lives above the Navigator. So the resting spot clears a bottom bar
        // plus the system's own bottom inset.
        final defaultTop =
            (bounds.height -
                    kBottomNavigationBarHeight -
                    safeBottom -
                    _size -
                    _margin * 2)
                .clamp(_margin, maxY)
                .toDouble();
        final top = (_position?.dy ?? defaultTop)
            .clamp(_margin, maxY)
            .toDouble();
        final left = _dragging
            ? (_position?.dx ?? _margin).clamp(_margin, maxX).toDouble()
            : (_snapRight ? maxX : _margin);
        final position = Offset(left, top);

        return Stack(
          children: [
            Positioned(
              left: position.dx,
              top: position.dy,
              child: GestureDetector(
                onPanStart: (_) => setState(() {
                  _dragging = true;
                  _position = position;
                }),
                onPanUpdate: (details) {
                  setState(() {
                    final next = (_position ?? position) + details.delta;
                    _position = Offset(
                      next.dx.clamp(_margin, maxX).toDouble(),
                      next.dy.clamp(_margin, maxY).toDouble(),
                    );
                  });
                },
                onPanEnd: (_) {
                  setState(() {
                    _dragging = false;
                    final dropped = _position ?? position;
                    // Record the side, not the pixel column.
                    _snapRight = dropped.dx + width / 2 >= bounds.width / 2;
                    _position = Offset(_snapRight ? maxX : _margin, dropped.dy);
                  });
                },
                child: Material(
                  color: Colors.transparent,
                  // Semantics rather than a Tooltip: this widget sits above the
                  // Navigator, so there is no Overlay for a tooltip to use —
                  // and Tooltip's own long-press trigger would fight ours.
                  child: Semantics(
                    button: true,
                    label: l10n.appRunningInBackground(
                      widget.app.displayName(context),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(_size / 2),
                      onTap: widget.onResume,
                      onLongPress: _confirmClose,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        width: width,
                        height: _size,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(_size / 2),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: _dragging ? 0.35 : 0.2,
                              ),
                              blurRadius: _dragging ? 12 : 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              alignment: Alignment.center,
                              child: Text(
                                _initial(context),
                                style: TextStyle(
                                  color: colorScheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                            // Deliberately the bare app name, not the
                            // `appRunningInBackground` phrasing used for the
                            // Semantics label above: the pill is a 52dp-tall
                            // transient badge capped at 280dp wide, and
                            // "… is running" would eat the room the name needs
                            // before ellipsis. Screen-reader users get the full
                            // sentence; sighted users get the identity.
                            if (_expanded)
                              Flexible(
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Text(
                                    widget.app.displayName(context),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: colorScheme.onPrimaryContainer,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
