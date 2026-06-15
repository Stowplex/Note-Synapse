import 'dart:typed_data';
import 'package:flutter/material.dart';

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
  final Map<int, Future<Uint8List>> _thumbnails = {};
  static const _cap = 200; // bound memory on very long timelines

  Future<Uint8List> _thumbnailFor(int ts) {
    final f = _thumbnails[ts] ??= widget.thumbnailBuilder(ts);
    if (_thumbnails.length > _cap && _thumbnails.keys.first != ts) {
      _thumbnails.remove(_thumbnails.keys.first);
    }
    return f;
  }

  @override
  void didUpdateWidget(WorldClipTimeline old) {
    super.didUpdateWidget(old);
    // A new video reuses the same timestamps; drop stale cached thumbnails.
    if (!identical(old.thumbnailBuilder, widget.thumbnailBuilder)) {
      _thumbnails.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ListView.builder(
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
