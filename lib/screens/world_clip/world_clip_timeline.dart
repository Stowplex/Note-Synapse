import 'dart:typed_data';
import 'package:flutter/material.dart';

/// A horizontal proxy-thumbnail strip. Tapping a thumb toggles its key-frame
/// tag (a tagged thumb is highlighted). Thumbnails load lazily via
/// [thumbnailBuilder] and are memoized per timestamp, so toggling a tag (which
/// rebuilds the strip) does not re-decode every visible frame.
class WorldClipTimeline extends StatefulWidget {
  final List<int> timestamps;
  final Set<int> taggedTimestamps;
  final Future<Uint8List> Function(int timestampMs) thumbnailBuilder;
  final void Function(int timestampMs) onToggleTag;

  const WorldClipTimeline({
    super.key,
    required this.timestamps,
    required this.taggedTimestamps,
    required this.thumbnailBuilder,
    required this.onToggleTag,
  });

  @override
  State<WorldClipTimeline> createState() => _WorldClipTimelineState();
}

class _WorldClipTimelineState extends State<WorldClipTimeline> {
  final Map<int, Future<Uint8List>> _thumbnails = {};

  Future<Uint8List> _thumbnailFor(int ts) =>
      _thumbnails[ts] ??= widget.thumbnailBuilder(ts);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: widget.timestamps.length,
        itemBuilder: (context, i) {
          final ts = widget.timestamps[i];
          final tagged = widget.taggedTimestamps.contains(ts);
          return GestureDetector(
            key: ValueKey('wc-thumb-$ts'),
            onTap: () => widget.onToggleTag(ts),
            child: Container(
              width: 90,
              margin: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                border: Border.all(
                  color: tagged ? Colors.blue : Colors.transparent,
                  width: 3,
                ),
              ),
              child: FutureBuilder<Uint8List>(
                future: _thumbnailFor(ts),
                builder: (context, snap) => snap.hasData
                    ? Image.memory(snap.data!, fit: BoxFit.cover)
                    : const Center(child: CircularProgressIndicator()),
              ),
            ),
          );
        },
      ),
    );
  }
}
