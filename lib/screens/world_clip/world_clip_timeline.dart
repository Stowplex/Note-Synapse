import 'dart:typed_data';
import 'package:flutter/material.dart';

/// A horizontal proxy-thumbnail strip. Tapping a thumb toggles its key-frame
/// tag (a tagged thumb is highlighted). Thumbnails load lazily via [thumbnailBuilder].
class WorldClipTimeline extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: timestamps.length,
        itemBuilder: (context, i) {
          final ts = timestamps[i];
          final tagged = taggedTimestamps.contains(ts);
          return GestureDetector(
            key: ValueKey('wc-thumb-$ts'),
            onTap: () => onToggleTag(ts),
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
                future: thumbnailBuilder(ts),
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
