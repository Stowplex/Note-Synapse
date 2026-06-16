import 'dart:typed_data';

/// Memoizes decoded frames (or thumbnails) keyed by timestamp with a bounded
/// LRU cap, so repeatedly requesting the same frame doesn't re-decode it and a
/// long video can't grow memory without bound. Used by the timeline strip, the
/// scrub preview, and the shared thumbnail cache.
class FrameMemoCache {
  final int capacity;
  final Map<int, Future<Uint8List>> _entries = {};

  FrameMemoCache(this.capacity);

  /// Returns the cached future for [key], or [create]s and stores it. The key
  /// is moved to most-recently-used; the least-recently-used is evicted past
  /// [capacity].
  Future<Uint8List> getOrAdd(int key, Future<Uint8List> Function() create) {
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing; // refresh recency
      return existing;
    }
    final future = create();
    _entries[key] = future;
    if (_entries.length > capacity) {
      _entries.remove(_entries.keys.first); // evict least-recently-used
    }
    return future;
  }

  void clear() => _entries.clear();
}
