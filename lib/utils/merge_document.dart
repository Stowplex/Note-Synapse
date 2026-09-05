import '../models/note.dart';
import '../services/chips_block_parser.dart';
import 'markdown_block_tracker.dart';

/// One note that the user is pulling blocks out of.
///
/// [blocks] is exactly what `BlockMarkdownBody` produces for the same note
/// (parsed against the chips-stripped markdown), so a block index here is the
/// same index the source tab reports on tap.
class MergeSource {
  MergeSource({
    required this.note,
    required this.colorIndex,
    required this.blocks,
  });

  final Note note;

  /// Position in the source colour palette. Monotonic per document, so a
  /// source keeps its colour when an earlier one is removed.
  final int colorIndex;

  List<MarkdownBlock> blocks;

  String get id => note.id;

  /// Blank lines parse as zero-width blocks; those are never selectable.
  bool isSelectable(int index) =>
      index >= 0 &&
      index < blocks.length &&
      blocks[index].content.trim().isNotEmpty;

  Iterable<int> get selectableIndices sync* {
    for (var i = 0; i < blocks.length; i++) {
      if (isSelectable(i)) yield i;
    }
  }

  int get selectableCount => selectableIndices.length;

  /// Parses [content] the same way `BlockMarkdownBody` does.
  static List<MarkdownBlock> parseBlocks(String content) {
    final stripped = ChipsBlockParser().parse(content).strippedMarkdown;
    return MarkdownBlockTracker().parseBlocks(stripped);
  }
}

/// One block of the merged note. [source] is null for text the user typed or
/// pasted, or for a block whose source note was removed from the merge.
class MergeSegment {
  MergeSegment({required this.text, this.source, this.sourceBlockIndex});

  String text;
  MergeSource? source;
  int? sourceBlockIndex;

  bool get hasProvenance => source != null && sourceBlockIndex != null;
}

/// What a source tab shows next to a block.
enum MergeBlockStatus {
  /// Not in the merged note.
  none,

  /// In the merged note, verbatim.
  added,

  /// Was added, but its text no longer appears verbatim in the merged note
  /// (edited or deleted in the Edit view).
  edited,
}

/// The in-memory state of one merge session. Pure Dart; nothing here touches
/// the database.
class MergeDocument {
  MergeDocument();

  final List<MergeSource> sources = [];
  final List<MergeSegment> segments = [];

  /// Where the next added block goes. `null` means append at the end.
  int? insertionIndex;

  /// Blocks that were added at some point and not explicitly removed. Used to
  /// tell "edited" from "never added" after the text was changed by hand.
  final Set<String> _taken = {};

  int _nextColor = 0;

  static String _key(MergeSource source, int blockIndex) =>
      '${source.id}#$blockIndex';

  // ---------------------------------------------------------------- sources

  MergeSource? sourceFor(String noteId) {
    for (final s in sources) {
      if (s.id == noteId) return s;
    }
    return null;
  }

  /// Adds [note] as a source. Returns the existing source if the note is
  /// already part of the merge.
  MergeSource addSource(Note note) {
    final existing = sourceFor(note.id);
    if (existing != null) return existing;
    final source = MergeSource(
      note: note,
      colorIndex: _nextColor++,
      blocks: MergeSource.parseBlocks(note.content),
    );
    sources.add(source);
    return source;
  }

  /// Drops [source] from the merge. Segments taken from it keep their text
  /// but lose their provenance; the note itself is untouched.
  void removeSource(MergeSource source) {
    for (final segment in segments) {
      if (segment.source == source) {
        segment.source = null;
        segment.sourceBlockIndex = null;
      }
    }
    _taken.removeWhere((k) => k.startsWith('${source.id}#'));
    sources.remove(source);
  }

  /// Replaces [source]'s block list with what the renderer actually parsed,
  /// if it differs. Provenance indices are only meaningful while the two
  /// agree, so a mismatch also re-derives provenance from text.
  void syncBlocks(MergeSource source, List<MarkdownBlock> blocks) {
    if (_sameBlocks(source.blocks, blocks)) return;
    source.blocks = List.of(blocks);
    _recoverProvenance();
  }

  static bool _sameBlocks(List<MarkdownBlock> a, List<MarkdownBlock> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].content != b[i].content) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------- queries

  bool contains(MergeSource source, int blockIndex) => segments.any(
    (s) => s.source == source && s.sourceBlockIndex == blockIndex,
  );

  MergeBlockStatus statusOf(MergeSource source, int blockIndex) {
    if (contains(source, blockIndex)) return MergeBlockStatus.added;
    if (_taken.contains(_key(source, blockIndex))) {
      return MergeBlockStatus.edited;
    }
    return MergeBlockStatus.none;
  }

  int addedCount(MergeSource source) =>
      source.selectableIndices.where((i) => contains(source, i)).length;

  /// 1-based position of the block in the merged note (first copy), or null.
  int? positionOf(MergeSource source, int blockIndex) {
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      if (s.source == source && s.sourceBlockIndex == blockIndex) return i + 1;
    }
    return null;
  }

  bool get isEmpty => segments.isEmpty;

  int get blockCount => segments.length;

  // ------------------------------------------------------------- mutations

  /// Adds one block. Returns false if it is not selectable or already in.
  bool add(MergeSource source, int blockIndex) {
    if (!source.isSelectable(blockIndex)) return false;
    if (contains(source, blockIndex)) return false;
    _insert(
      MergeSegment(
        text: tidy(source.blocks[blockIndex].content),
        source: source,
        sourceBlockIndex: blockIndex,
      ),
    );
    _taken.add(_key(source, blockIndex));
    return true;
  }

  /// Adds the block again even though it was taken before (the "edited"
  /// case). Returns false if the block is not selectable.
  bool addCopy(MergeSource source, int blockIndex) {
    if (!source.isSelectable(blockIndex)) return false;
    _insert(
      MergeSegment(
        text: tidy(source.blocks[blockIndex].content),
        source: source,
        sourceBlockIndex: blockIndex,
      ),
    );
    _taken.add(_key(source, blockIndex));
    return true;
  }

  /// Removes every copy of the block. Returns how many segments were removed.
  int remove(MergeSource source, int blockIndex) {
    final before = segments.length;
    _removeWhere(
      (s) => s.source == source && s.sourceBlockIndex == blockIndex,
    );
    _taken.remove(_key(source, blockIndex));
    return before - segments.length;
  }

  /// Clears the "edited" mark without adding anything.
  void forget(MergeSource source, int blockIndex) {
    _taken.remove(_key(source, blockIndex));
  }

  /// Adds [headingIndex] and every block after it until the next heading of
  /// the same or higher level. Returns the number of blocks added.
  int addSection(MergeSource source, int headingIndex) {
    final level = headingLevel(source.blocks[headingIndex].content);
    if (level == null) return add(source, headingIndex) ? 1 : 0;
    var added = 0;
    for (var i = headingIndex; i < source.blocks.length; i++) {
      if (i > headingIndex) {
        final l = headingLevel(source.blocks[i].content);
        if (l != null && l <= level) break;
      }
      if (add(source, i)) added++;
    }
    return added;
  }

  /// Every block after [headingIndex] that [addSection] would take.
  List<int> sectionIndices(MergeSource source, int headingIndex) {
    final level = headingLevel(source.blocks[headingIndex].content);
    if (level == null) return [headingIndex];
    final out = <int>[];
    for (var i = headingIndex; i < source.blocks.length; i++) {
      if (i > headingIndex) {
        final l = headingLevel(source.blocks[i].content);
        if (l != null && l <= level) break;
      }
      if (source.isSelectable(i)) out.add(i);
    }
    return out;
  }

  int addAll(MergeSource source) {
    var added = 0;
    for (final i in source.selectableIndices) {
      if (add(source, i)) added++;
    }
    return added;
  }

  int removeAll(MergeSource source) {
    final before = segments.length;
    _removeWhere((s) => s.source == source);
    _taken.removeWhere((k) => k.startsWith('${source.id}#'));
    return before - segments.length;
  }

  /// Moves the segment at [from] so that it ends up at index [to] in the
  /// resulting list (i.e. [to] is already adjusted for the removal, the way
  /// `ReorderableListView.onReorderItem` reports it).
  void move(int from, int to) {
    if (from < 0 || from >= segments.length) return;
    if (to < 0 || to >= segments.length) return;
    if (from == to) return;
    final segment = segments.removeAt(from);
    final target = to;
    segments.insert(target, segment);
    if (insertionIndex != null) {
      // Keep the marker on the same gap it was on, relative to its neighbours.
      final ins = insertionIndex!;
      if (from < ins && target >= ins) {
        insertionIndex = ins - 1;
      } else if (from >= ins && target < ins) {
        insertionIndex = ins + 1;
      }
    }
  }

  void removeAt(int index) {
    if (index < 0 || index >= segments.length) return;
    final segment = segments[index];
    segments.removeAt(index);
    if (segment.hasProvenance &&
        !contains(segment.source!, segment.sourceBlockIndex!)) {
      _taken.remove(_key(segment.source!, segment.sourceBlockIndex!));
    }
    if (insertionIndex != null && insertionIndex! > index) {
      insertionIndex = insertionIndex! - 1;
    }
  }

  /// The merged note as markdown. Block text is never altered; two adjacent
  /// bullet lists therefore read back as one list, which
  /// [replaceFromText] undoes by decomposition.
  String flatten() =>
      segments.map((s) => tidy(s.text)).where((t) => t.isNotEmpty).join('\n\n');

  static final RegExp _leadingBlankLines = RegExp(r'^(?:[ \t]*\n)+');

  /// Normalises line endings and strips leading blank lines and trailing
  /// whitespace only, so an indented code block keeps the indentation of its
  /// first line.
  static String tidy(String text) => text
      .replaceAll('\r\n', '\n')
      .replaceFirst(_leadingBlankLines, '')
      .trimRight();

  /// Rebuilds [segments] from free-form [text] (after the user edited the
  /// merged note by hand). Provenance is recovered by exact text match against
  /// the sources' blocks; anything else becomes a plain segment.
  void replaceFromText(String text) {
    final blocks = MergeSource.parseBlocks(text);
    segments
      ..clear()
      ..addAll([
        for (final b in blocks)
          if (b.content.trim().isNotEmpty) MergeSegment(text: tidy(b.content)),
      ]);
    insertionIndex = null;
    _recoverProvenance();
  }

  // ---------------------------------------------------------------- helpers

  void _insert(MergeSegment segment) {
    final at = insertionIndex;
    if (at == null || at >= segments.length) {
      segments.add(segment);
      if (at != null) insertionIndex = segments.length;
    } else {
      segments.insert(at, segment);
      insertionIndex = at + 1;
    }
  }

  void _removeWhere(bool Function(MergeSegment) test) {
    for (var i = segments.length - 1; i >= 0; i--) {
      if (test(segments[i])) {
        segments.removeAt(i);
        if (insertionIndex != null && insertionIndex! > i) {
          insertionIndex = insertionIndex! - 1;
        }
      }
    }
  }

  /// Key used to match a segment back to a source block.
  static String matchKey(String text) => tidy(text);

  /// Re-derives every segment's provenance from its text. A segment that
  /// matches no source block but reads as several consecutive source blocks
  /// joined by single newlines (two bullet lists fused by the markdown
  /// parser) is split back into those blocks.
  void _recoverProvenance() {
    final index = <String, (MergeSource, int)>{};
    for (final source in sources) {
      for (final i in source.selectableIndices) {
        index.putIfAbsent(matchKey(source.blocks[i].content), () => (source, i));
      }
    }
    final rebuilt = <MergeSegment>[];
    for (final segment in segments) {
      final hit = index[matchKey(segment.text)];
      if (hit != null) {
        segment.source = hit.$1;
        segment.sourceBlockIndex = hit.$2;
        rebuilt.add(segment);
        continue;
      }
      final parts = _decompose(matchKey(segment.text), index);
      if (parts == null) {
        segment.source = null;
        segment.sourceBlockIndex = null;
        rebuilt.add(segment);
      } else {
        for (final part in parts) {
          rebuilt.add(
            MergeSegment(
              text: part.$1,
              source: part.$2.$1,
              sourceBlockIndex: part.$2.$2,
            ),
          );
        }
      }
    }
    segments
      ..clear()
      ..addAll(rebuilt);
  }

  /// Greedy, longest-first split of [text] into whole source blocks. Returns
  /// null unless the entire text is covered by at least two blocks.
  static List<(String, (MergeSource, int))>? _decompose(
    String text,
    Map<String, (MergeSource, int)> index,
  ) {
    final lines = text.split('\n');
    final out = <(String, (MergeSource, int))>[];
    var at = 0;
    while (at < lines.length) {
      // A loose list keeps the blank line between the two original blocks.
      if (lines[at].trim().isEmpty) {
        at++;
        continue;
      }
      var matched = false;
      for (var end = lines.length; end > at; end--) {
        final candidate = lines.sublist(at, end).join('\n');
        final hit = index[candidate];
        if (hit != null) {
          out.add((candidate, hit));
          at = end;
          matched = true;
          break;
        }
      }
      if (!matched) return null;
    }
    return out.length >= 2 ? out : null;
  }

  static final RegExp _atxHeading = RegExp(r'^(#{1,6})\s');

  /// 1..6 for an ATX heading block, null otherwise.
  static int? headingLevel(String blockContent) {
    final m = _atxHeading.firstMatch(blockContent.trimLeft());
    return m?.group(1)!.length;
  }
}
