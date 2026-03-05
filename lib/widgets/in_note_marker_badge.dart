import 'package:flutter/material.dart';

class InNoteMarkerBadge extends StatefulWidget {
  final int index;
  final VoidCallback onTap;

  const InNoteMarkerBadge({super.key, required this.index, required this.onTap});

  @override
  State<InNoteMarkerBadge> createState() => _InNoteMarkerBadgeState();
}

class _InNoteMarkerBadgeState extends State<InNoteMarkerBadge> {
  double _opacity = 0.6;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        setState(() => _opacity = 1.0);
        widget.onTap();
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) setState(() => _opacity = 0.6);
        });
      },
      child: AnimatedOpacity(
        opacity: _opacity,
        duration: const Duration(milliseconds: 200),
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: Colors.blue,
            shape: BoxShape.circle,
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 3,
                offset: Offset(1, 1),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            '${widget.index}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
