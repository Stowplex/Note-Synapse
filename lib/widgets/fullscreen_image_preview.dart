import 'package:flutter/material.dart';

class FullscreenImagePreview extends StatelessWidget {
  const FullscreenImagePreview({super.key, required this.image, this.title});

  final Widget image;
  final String? title;

  static Future<void> show(
    BuildContext context, {
    required Widget image,
    String? title,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) =>
            FullscreenImagePreview(image: image, title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.7),
        foregroundColor: Colors.white,
        elevation: 0,
        title: title != null ? Text(title!) : null,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _ZoomableImagePreview(image: image),
    );
  }
}

class _ZoomableImagePreview extends StatefulWidget {
  const _ZoomableImagePreview({required this.image});

  final Widget image;

  @override
  State<_ZoomableImagePreview> createState() => _ZoomableImagePreviewState();
}

class _ZoomableImagePreviewState extends State<_ZoomableImagePreview> {
  bool _isDarkBackground = false;

  void _toggleBackground() {
    setState(() {
      _isDarkBackground = !_isDarkBackground;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          color: _isDarkBackground
              ? const Color(0xFF1E1E1E)
              : const Color(0xFFFFFFFF),
          child: SizedBox.expand(
            child: InteractiveViewer(
              minScale: 0.1,
              maxScale: 10.0,
              boundaryMargin: const EdgeInsets.all(double.infinity),
              clipBehavior: Clip.none,
              child: Center(child: widget.image),
            ),
          ),
        ),
        Positioned(
          bottom: 32,
          right: 16,
          child: FloatingActionButton(
            mini: true,
            backgroundColor: Colors.white.withValues(alpha: 0.9),
            foregroundColor: Colors.black87,
            onPressed: _toggleBackground,
            child: const Icon(Icons.contrast, size: 20),
          ),
        ),
      ],
    );
  }
}
