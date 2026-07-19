import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'frame_memo_cache.dart';

/// A horizontal proxy-thumbnail strip for scrubbing. Tapping a thumb *selects*
/// it (drives the large preview above); key-frame tagging is an explicit button
/// in the parent. The selected thumb is outlined; tagged (key-frame) thumbs get
/// a corner marker + colored border. Thumbnails are memoized per timestamp so
/// selecting one doesn't re-decode the whole strip.
class WorldClipTimeline extends StatefulWidget {
  final List<int> timestamps;
  final Set<int> taggedTimestamps;
  final int? selectedTimestamp;
  final Future<Uint8List> Function(int timestampMs) thumbnailBuilder;
  final void Function(int timestampMs) onSelect;

  const WorldClipTimeline({
    super.key,
    required this.timestamps,
    required this.taggedTimestamps,
    required this.selectedTimestamp,
    required this.thumbnailBuilder,
    required this.onSelect,
  });

  @override
  State<WorldClipTimeline> createState() => _WorldClipTimelineState();
}

class _WorldClipTimelineState extends State<WorldClipTimeline> {
  final _thumbnails = FrameMemoCache(200); // bound memory on long timelines
  final _controller = ScrollController();

  /// Thumb width (80) plus its horizontal margins (4 + 4).
  static const double _itemExtent = 88;

  Future<Uint8List> _thumbnailFor(int ts) =>
      _thumbnails.getOrAdd(ts, () => widget.thumbnailBuilder(ts));

  @override
  void didUpdateWidget(WorldClipTimeline old) {
    super.didUpdateWidget(old);
    // A new video reuses the same timestamps; drop stale cached thumbnails.
    if (!identical(old.thumbnailBuilder, widget.thumbnailBuilder)) {
      _thumbnails.clear();
    }
    final sel = widget.selectedTimestamp;
    if (sel != null && sel != old.selectedTimestamp) {
      _revealSelected(sel);
    }
  }

  /// Scrolls the strip so the selected thumb sits centered (clamped at the
  /// ends) — keeps keyframe navigation from the parent's prev/next buttons
  /// in view even when the target is far off-screen. A thumb that's already
  /// fully visible is left alone, so directly tapping thumbs never yanks the
  /// strip out from under the user's finger.
  void _revealSelected(int ts) {
    final i = widget.timestamps.indexOf(ts);
    if (i < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final pos = _controller.position;
      final itemStart = i * _itemExtent;
      if (itemStart >= pos.pixels &&
          itemStart + _itemExtent <= pos.pixels + pos.viewportDimension) {
        return; // fully in view already
      }
      final target =
          (itemStart - (pos.viewportDimension - _itemExtent) / 2).clamp(
        0.0,
        pos.maxScrollExtent,
      );
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ListView.builder(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        itemCount: widget.timestamps.length,
        itemBuilder: (context, i) {
          final ts = widget.timestamps[i];
          final tagged = widget.taggedTimestamps.contains(ts);
          final selected = widget.selectedTimestamp == ts;
          return GestureDetector(
            key: ValueKey('wc-thumb-$ts'),
            onTap: () => widget.onSelect(ts),
            child: Container(
              width: 80,
              margin: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                border: Border.all(
                  color: selected
                      ? Colors.white
                      : (tagged ? Colors.blue : Colors.transparent),
                  width: selected ? 3 : (tagged ? 3 : 1),
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FutureBuilder<Uint8List>(
                    future: _thumbnailFor(ts),
                    builder: (context, snap) => snap.hasData
                        ? Image.memory(snap.data!, fit: BoxFit.cover)
                        : const Center(child: CircularProgressIndicator()),
                  ),
                  if (tagged)
                    const Positioned(
                      top: 2,
                      right: 2,
                      child: Icon(Icons.key, size: 16, color: Colors.blue),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
