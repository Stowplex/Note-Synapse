import 'package:flutter/material.dart';

/// A full-screen scrim + spinner (optionally labelled) shown over a stage
/// during a long async op (detect / clone / compile / fuse). Shared by the
/// world-clip flow and picture-sequence screens so the two overlays can't
/// drift. Place inside a Stack.
class ProgressScrim extends StatelessWidget {
  const ProgressScrim({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final label = this.label;
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0x99000000),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              if (label != null && label.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(label, style: const TextStyle(color: Colors.white)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
