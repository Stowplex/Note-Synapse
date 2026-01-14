// Markdown block tracking utilities for drag-to-edit feature
import 'package:flutter/foundation.dart';

/// Represents a type of markdown block
enum MarkdownBlockType {
  codeBlock,
  image,
  link,
  heading,
  orderedList,
  unorderedList,
  checkbox,
  blockquote,
  horizontalRule,
  paragraph,
  latexBlock,
  table,
}

/// Represents a parsed markdown block with its location in the source
class MarkdownBlock {
  final MarkdownBlockType type;
  final String content;
  final int startOffset;
  final int endOffset;
  final int occurrenceIndex;

  const MarkdownBlock({
    required this.type,
    required this.content,
    required this.startOffset,
    required this.endOffset,
    required this.occurrenceIndex,
  });

  @override
  String toString() =>
      'MarkdownBlock($type, offset: $startOffset-$endOffset, occurrence: $occurrenceIndex)';
}

/// Tracks and identifies markdown blocks within content.
///
/// This utility parses markdown content and identifies block boundaries,
/// enabling accurate mapping between rendered widgets and their source text.
/// It handles edge cases like:
/// - Duplicate blocks with identical content (using occurrence indexing)
/// - Content inside code blocks (code fences escape inner content)
class MarkdownBlockTracker {
  /// Parses markdown content and returns all identified blocks.
  ///
  /// Blocks are returned in document order. Code blocks are parsed first
  /// to prevent their inner content from being misidentified as other blocks.
  List<MarkdownBlock> parseBlocks(String content) {
    final blocks = <MarkdownBlock>[];
    final protectedRanges = <(int, int)>[];

    // Phase 1: Parse code blocks first (they escape inner content)
    _parseCodeBlocks(content, blocks, protectedRanges);

    // Phase 2: Parse LaTeX blocks (also escape inner content)
    _parseLatexBlocks(content, blocks, protectedRanges);

    // Phase 3: Parse all other block types, respecting protected ranges
    _parseHeadings(content, blocks, protectedRanges);
    _parseImages(content, blocks, protectedRanges);
    _parseLinks(content, blocks, protectedRanges);
    _parseBlockquotes(content, blocks, protectedRanges);
    _parseOrderedLists(content, blocks, protectedRanges);
    _parseUnorderedLists(content, blocks, protectedRanges);
    _parseCheckboxes(content, blocks, protectedRanges);
    _parseHorizontalRules(content, blocks, protectedRanges);
    _parseTables(content, blocks, protectedRanges);

    // Phase 4: Parse paragraphs (text between other blocks)
    _parseParagraphs(content, blocks, protectedRanges);

    // Sort blocks by start offset for consistent ordering
    blocks.sort((a, b) => a.startOffset.compareTo(b.startOffset));

    return blocks;
  }

  /// Finds the block at the given character offset.
  MarkdownBlock? findBlockAtOffset(String content, int offset) {
    final blocks = parseBlocks(content);
    for (final block in blocks) {
      if (offset >= block.startOffset && offset < block.endOffset) {
        return block;
      }
    }
    return null;
  }

  /// Finds a block by its content and occurrence index.
  ///
  /// This is the primary method for mapping a rendered widget back to its source.
  /// When a DragTarget receives a drop, it provides the matched text and
  /// which occurrence (0-indexed) this widget represents.
  MarkdownBlock? findBlockByContentAndOccurrence(
    String content,
    String blockContent,
    int occurrenceIndex,
  ) {
    final blocks = parseBlocks(content);
    int currentOccurrence = 0;

    final normalizedSearchContent = _normalizeForMatching(blockContent);

    debugPrint(
      'findBlockByContentAndOccurrence: searching for normalized="${normalizedSearchContent.substring(0, normalizedSearchContent.length > 80 ? 80 : normalizedSearchContent.length)}...", occurrenceIndex=$occurrenceIndex',
    );
    debugPrint(
      'findBlockByContentAndOccurrence: found ${blocks.length} blocks',
    );

    // Debug: print first few image blocks for comparison
    int imageCount = 0;
    for (final block in blocks) {
      if (block.type == MarkdownBlockType.image && imageCount < 3) {
        final normalizedBlock = _normalizeForMatching(block.content);
        debugPrint(
          '  Image block $imageCount: "${normalizedBlock.substring(0, normalizedBlock.length > 80 ? 80 : normalizedBlock.length)}..."',
        );
        imageCount++;
      }
    }

    for (final block in blocks) {
      // Normalize whitespace and prefixes for comparison
      final normalizedBlockContent = _normalizeForMatching(block.content);

      if (normalizedBlockContent == normalizedSearchContent) {
        debugPrint(
          'findBlockByContentAndOccurrence: MATCH at occurrence $currentOccurrence, type=${block.type}',
        );
        if (currentOccurrence == occurrenceIndex) {
          return block;
        }
        currentOccurrence++;
      }
    }
    debugPrint('findBlockByContentAndOccurrence: NO MATCH FOUND');
    return null;
  }

  /// Normalizes block content for matching.
  /// Strips leading list markers (- * +) and whitespace to handle
  /// differences between gpt_markdown component text and parsed content.
  /// Also normalizes code blocks to handle whitespace variations.
  String _normalizeForMatching(String content) {
    var normalized = content.trim();

    // Strip leading whitespace (for indented list items)
    normalized = normalized.replaceFirst(RegExp(r'^[ \t]+'), '');

    // Strip leading list markers: - * + followed by space
    final listPrefixPattern = RegExp(r'^[-*+]\s+');
    normalized = normalized.replaceFirst(listPrefixPattern, '');

    // Normalize image markdown: extract just the URL, ignoring alt text
    // This handles the case where imageBuilder only receives URL but source has alt text
    // Converts ![alt text](url) to ![](url) for matching
    final imagePattern = RegExp(r'^!\[([^\]]*)\]\((.+)\)$');
    final imageMatch = imagePattern.firstMatch(normalized);
    if (imageMatch != null) {
      final url = imageMatch.group(2);
      normalized = '![]($url)';
    }

    // Normalize code blocks: standardize whitespace around fences
    // Handle both ``` and ~~~ fences
    if (normalized.startsWith('```') || normalized.startsWith('~~~')) {
      // Split into lines and normalize each line's trailing whitespace
      final lines = normalized.split('\n');
      final normalizedLines = lines.map((line) => line.trimRight()).toList();

      // Remove empty lines at the end before closing fence
      while (normalizedLines.length > 2 &&
          normalizedLines[normalizedLines.length - 2].isEmpty) {
        normalizedLines.removeAt(normalizedLines.length - 2);
      }

      normalized = normalizedLines.join('\n');
    }

    return normalized;
  }

  /// Replaces a block in the content with new content.
  ///
  /// Returns the modified content string.
  String replaceBlock(
    String content,
    MarkdownBlock block,
    String newBlockContent,
  ) {
    return content.substring(0, block.startOffset) +
        newBlockContent +
        content.substring(block.endOffset);
  }

  /// Deletes a block from the content.
  ///
  /// Also removes surrounding blank lines to prevent excessive whitespace.
  String deleteBlock(String content, MarkdownBlock block) {
    // Find the start of the line containing this block
    int lineStart = block.startOffset;
    while (lineStart > 0 && content[lineStart - 1] != '\n') {
      lineStart--;
    }

    // Find the end of the line containing this block
    int lineEnd = block.endOffset;
    while (lineEnd < content.length && content[lineEnd] != '\n') {
      lineEnd++;
    }

    // Include the trailing newline if present
    if (lineEnd < content.length && content[lineEnd] == '\n') {
      lineEnd++;
    }

    // Remove the line(s)
    String result =
        content.substring(0, lineStart) + content.substring(lineEnd);

    // Clean up excessive blank lines (more than 2 consecutive newlines)
    result = result.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return result;
  }

  // --- Private parsing methods ---

  void _parseCodeBlocks(
    String content,
    List<MarkdownBlock> blocks,
    List<(int, int)> protectedRanges,
  ) {
    // Fenced code blocks (``` or ~~~)
    final fencedPattern = RegExp(
      r'(```|~~~)([^\n]*)\n([\s\S]*?)\1',
      multiLine: true,
    );

    final occurrences = <String, int>{};

    for (final match in fencedPattern.allMatches(content)) {
      final blockContent = match.group(0)!;
      // Use trimmed key for occurrence counting to match BlockOccurrenceTracker
      final occurrenceKey = blockContent.trim();
      final occurrence = occurrences[occurrenceKey] ?? 0;
      occurrences[occurrenceKey] = occurrence + 1;

      blocks.add(
        MarkdownBlock(
          type: MarkdownBlockType.codeBlock,
          content: blockContent,
          startOffset: match.start,
          endOffset: match.end,
          occurrenceIndex: occurrence,
        ),
      );
      protectedRanges.add((match.start, match.end));
    }
  }

  void _parseLatexBlocks(
    String content,
    List<MarkdownBlock> blocks,
    List<(int, int)> protectedRanges,
  ) {
    // Block LaTeX: \[...\] or \begin{...}...\end{...}
    final latexPatterns = [
      RegExp(r'\\\[[\s\S]*?\\\]', multiLine: true),
      RegExp(r'\\begin\{[^}]+\}[\s\S]*?\\end\{[^}]+\}', multiLine: true),
    ];

    final occurrences = <String, int>{};

    for (final pattern in latexPatterns) {
      for (final match in pattern.allMatches(content)) {
        if (_isInProtectedRange(match.start, protectedRanges)) continue;

        final blockContent = match.group(0)!;
        // Use trimmed key for occurrence counting to match BlockOccurrenceTracker
        final occurrenceKey = blockContent.trim();
        final occurrence = occurrences[occurrenceKey] ?? 0;
        occurrences[occurrenceKey] = occurrence + 1;

        blocks.add(
          MarkdownBlock(
            type: MarkdownBlockType.latexBlock,
            content: blockContent,
            startOffset: match.start,
            endOffset: match.end,
            occurrenceIndex: occurrence,
          ),
        );
        protectedRanges.add((match.start, match.end));
      }
    }
  }

  void _parseHeadings(
    String content,
    List<MarkdownBlock> blocks,
    List<(int, int)> protectedRanges,
  ) {
    // ATX headings: # to ######
    final pattern = RegExp(r'^(#{1,6})\s+(.+)$', multiLine: true);
    final occurrences = <String, int>{};

    for (final match in pattern.allMatches(content)) {
      if (_isInProtectedRange(match.start, protectedRanges)) continue;

      final blockContent = match.group(0)!;
      // Use trimmed key for occurrence counting to match BlockOccurrenceTracker
      final occurrenceKey = blockContent.trim();
      final occurrence = occurrences[occurrenceKey] ?? 0;
      occurrences[occurrenceKey] = occurrence + 1;

      blocks.add(
        MarkdownBlock(
          type: MarkdownBlockType.heading,
          content: blockContent,
          startOffset: match.start,
          endOffset: match.end,
          occurrenceIndex: occurrence,
        ),
      );
      protectedRanges.add((match.start, match.end));
    }
  }

  void _parseImages(
    String content,
    List<MarkdownBlock> blocks,
    List<(int, int)> protectedRanges,
  ) {
    // Images: ![alt](url) or ![alt](url "title")
    // Use a regex that handles URLs with parentheses by matching up to the last closing paren
    // or matching balanced parentheses
    final pattern = RegExp(
      r'!\[([^\]]*)\]\((.+?)\)(?=\s|$|[^\(])',
      multiLine: true,
    );
    final occurrences = <String, int>{};

    for (final match in pattern.allMatches(content)) {
      if (_isInProtectedRange(match.start, protectedRanges)) continue;

      final blockContent = match.group(0)!;
      // Use trimmed key for occurrence counting to match BlockOccurrenceTracker
      final occurrenceKey = blockContent.trim();
      final occurrence = occurrences[occurrenceKey] ?? 0;
      occurrences[occurrenceKey] = occurrence + 1;

      blocks.add(
        MarkdownBlock(
          type: MarkdownBlockType.image,
          content: blockContent,
          startOffset: match.start,
          endOffset: match.end,
          occurrenceIndex: occurrence,
        ),
      );
      protectedRanges.add((match.start, match.end));
    }
  }

  void _parseLinks(
    String content,
    List<MarkdownBlock> blocks,
    List<(int, int)> protectedRanges,
  ) {
    // Links: [text](url) - but NOT images which start with !
    // Use negative lookbehind to exclude images
    final pattern = RegExp(r'(?<!!)\[([^\]]+)\]\(([^)]+)\)', multiLine: true);
    final occurrences = <String, int>{};

    for (final match in pattern.allMatches(content)) {
      if (_isInProtectedRange(match.start, protectedRanges)) continue;

      final blockContent = match.group(0)!;
      // Use trimmed key for occurrence counting to match BlockOccurrenceTracker
      final occurrenceKey = blockContent.trim();
      final occurrence = occurrences[occurrenceKey] ?? 0;
      occurrences[occurrenceKey] = occurrence + 1;

      blocks.add(
        MarkdownBlock(
          type: MarkdownBlockType.link,
          content: blockContent,
          startOffset: match.start,
          endOffset: match.end,
          occurrenceIndex: occurrence,
        ),
      );
      // Note: Don't add to protectedRanges as links can be inside other blocks
    }
  }

  void _parseBlockquotes(
    String content,
    List<MarkdownBlock> blocks,
    List<(int, int)> protectedRanges,
  ) {
    // Block quotes: lines starting with >
    // Match consecutive lines starting with >
    final pattern = RegExp(r'^(?:>.*(?:\n|$))+', multiLine: true);
    final occurrences = <String, int>{};

    for (final match in pattern.allMatches(content)) {
      if (_isInProtectedRange(match.start, protectedRanges)) continue;

      final blockContent = match.group(0)!.trimRight();
      // Use trimmed key for occurrence counting to match BlockOccurrenceTracker
      final occurrenceKey = blockContent.trim();
      final occurrence = occurrences[occurrenceKey] ?? 0;
      occurrences[occurrenceKey] = occurrence + 1;

      blocks.add(
        MarkdownBlock(
          type: MarkdownBlockType.blockquote,
          content: blockContent,
          startOffset: match.start,
          endOffset: match.start + blockContent.length,
          occurrenceIndex: occurrence,
        ),
      );
      protectedRanges.add((match.start, match.start + blockContent.length));
    }
  }

  void _parseOrderedLists(
    String content,
    List<MarkdownBlock> blocks,
    List<(int, int)> protectedRanges,
  ) {
    // Ordered list items: 1. item (with optional leading whitespace for indentation)
    final pattern = RegExp(r'^[ \t]*\d+\.\s+.+$', multiLine: true);
    final occurrences = <String, int>{};

    for (final match in pattern.allMatches(content)) {
      if (_isInProtectedRange(match.start, protectedRanges)) continue;

      final blockContent = match.group(0)!;
      // Use trimmed key for occurrence counting to match BlockOccurrenceTracker
      final occurrenceKey = blockContent.trim();
      final occurrence = occurrences[occurrenceKey] ?? 0;
      occurrences[occurrenceKey] = occurrence + 1;

      blocks.add(
        MarkdownBlock(
          type: MarkdownBlockType.orderedList,
          content: blockContent,
          startOffset: match.start,
          endOffset: match.end,
          occurrenceIndex: occurrence,
        ),
      );
      protectedRanges.add((match.start, match.end));
    }
  }

  void _parseUnorderedLists(
    String content,
    List<MarkdownBlock> blocks,
    List<(int, int)> protectedRanges,
  ) {
    // Unordered list items: - item, * item, + item (with optional leading whitespace)
    // But NOT checkboxes (- [ ] or - [x])
    final pattern = RegExp(r'^[ \t]*[-*+]\s+(?!\[[ x]\]).+$', multiLine: true);
    final occurrences = <String, int>{};

    for (final match in pattern.allMatches(content)) {
      if (_isInProtectedRange(match.start, protectedRanges)) continue;

      final blockContent = match.group(0)!;
      // Use trimmed key for occurrence counting to match BlockOccurrenceTracker
      final occurrenceKey = blockContent.trim();
      final occurrence = occurrences[occurrenceKey] ?? 0;
      occurrences[occurrenceKey] = occurrence + 1;

      blocks.add(
        MarkdownBlock(
          type: MarkdownBlockType.unorderedList,
          content: blockContent,
          startOffset: match.start,
          endOffset: match.end,
          occurrenceIndex: occurrence,
        ),
      );
      protectedRanges.add((match.start, match.end));
    }
  }

  void _parseCheckboxes(
    String content,
    List<MarkdownBlock> blocks,
    List<(int, int)> protectedRanges,
  ) {
    // Checkboxes: - [ ] item or - [x] item (with optional leading whitespace for indentation)
    final pattern = RegExp(r'^[ \t]*(?:-\s+)?\[[ x]\]\s+.+$', multiLine: true);
    final occurrences = <String, int>{};

    for (final match in pattern.allMatches(content)) {
      if (_isInProtectedRange(match.start, protectedRanges)) continue;

      final blockContent = match.group(0)!;
      // Use trimmed key for occurrence counting to match BlockOccurrenceTracker
      final occurrenceKey = blockContent.trim();
      final occurrence = occurrences[occurrenceKey] ?? 0;
      occurrences[occurrenceKey] = occurrence + 1;

      blocks.add(
        MarkdownBlock(
          type: MarkdownBlockType.checkbox,
          content: blockContent,
          startOffset: match.start,
          endOffset: match.end,
          occurrenceIndex: occurrence,
        ),
      );
      protectedRanges.add((match.start, match.end));
    }
  }

  void _parseHorizontalRules(
    String content,
    List<MarkdownBlock> blocks,
    List<(int, int)> protectedRanges,
  ) {
    // Horizontal rules: ---, ***, ___ (3 or more)
    final pattern = RegExp(r'^[-*_]{3,}\s*$', multiLine: true);
    final occurrences = <String, int>{};

    for (final match in pattern.allMatches(content)) {
      if (_isInProtectedRange(match.start, protectedRanges)) continue;

      final blockContent = match.group(0)!;
      // Use trimmed key for occurrence counting to match BlockOccurrenceTracker
      final occurrenceKey = blockContent.trim();
      final occurrence = occurrences[occurrenceKey] ?? 0;
      occurrences[occurrenceKey] = occurrence + 1;

      blocks.add(
        MarkdownBlock(
          type: MarkdownBlockType.horizontalRule,
          content: blockContent,
          startOffset: match.start,
          endOffset: match.end,
          occurrenceIndex: occurrence,
        ),
      );
      protectedRanges.add((match.start, match.end));
    }
  }

  void _parseTables(
    String content,
    List<MarkdownBlock> blocks,
    List<(int, int)> protectedRanges,
  ) {
    // Simple table detection: lines with | separators
    // A table has a header row, a separator row (with dashes), and data rows
    final pattern = RegExp(
      r'^\|[^\n]+\|\n\|[-:\s|]+\|\n(?:\|[^\n]+\|\n?)+',
      multiLine: true,
    );
    final occurrences = <String, int>{};

    for (final match in pattern.allMatches(content)) {
      if (_isInProtectedRange(match.start, protectedRanges)) continue;

      final blockContent = match.group(0)!.trimRight();
      // Use trimmed key for occurrence counting to match BlockOccurrenceTracker
      final occurrenceKey = blockContent.trim();
      final occurrence = occurrences[occurrenceKey] ?? 0;
      occurrences[occurrenceKey] = occurrence + 1;

      blocks.add(
        MarkdownBlock(
          type: MarkdownBlockType.table,
          content: blockContent,
          startOffset: match.start,
          endOffset: match.start + blockContent.length,
          occurrenceIndex: occurrence,
        ),
      );
      protectedRanges.add((match.start, match.start + blockContent.length));
    }
  }

  void _parseParagraphs(
    String content,
    List<MarkdownBlock> blocks,
    List<(int, int)> protectedRanges,
  ) {
    // Paragraphs are non-empty lines that aren't part of other block types
    // Split content by blank lines and check each segment
    final lines = content.split('\n');
    final occurrences = <String, int>{};

    int currentOffset = 0;
    String? paragraphBuffer;
    int? paragraphStart;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final lineStart = currentOffset;
      final lineEnd = currentOffset + line.length;

      // Check if this line is in a protected range
      final isProtected = _isInProtectedRange(lineStart, protectedRanges);
      final isBlank = line.trim().isEmpty;

      if (!isProtected && !isBlank) {
        // This line might be part of a paragraph
        if (paragraphBuffer == null) {
          paragraphBuffer = line;
          paragraphStart = lineStart;
        } else {
          paragraphBuffer = '$paragraphBuffer\n$line';
        }
      } else if (paragraphBuffer != null) {
        // End of paragraph
        final trimmed = paragraphBuffer.trim();
        if (trimmed.isNotEmpty) {
          // Check if this paragraph content overlaps with any existing block
          bool overlapsWithBlock = false;
          for (final block in blocks) {
            if (paragraphStart! < block.endOffset &&
                paragraphStart + paragraphBuffer.length > block.startOffset) {
              overlapsWithBlock = true;
              break;
            }
          }

          if (!overlapsWithBlock) {
            final occurrence = occurrences[trimmed] ?? 0;
            occurrences[trimmed] = occurrence + 1;

            blocks.add(
              MarkdownBlock(
                type: MarkdownBlockType.paragraph,
                content: paragraphBuffer,
                startOffset: paragraphStart!,
                endOffset: paragraphStart + paragraphBuffer.length,
                occurrenceIndex: occurrence,
              ),
            );
          }
        }
        paragraphBuffer = null;
        paragraphStart = null;
      }

      currentOffset = lineEnd + 1; // +1 for newline
    }

    // Handle trailing paragraph
    if (paragraphBuffer != null && paragraphBuffer.trim().isNotEmpty) {
      bool overlapsWithBlock = false;
      for (final block in blocks) {
        if (paragraphStart! < block.endOffset &&
            paragraphStart + paragraphBuffer.length > block.startOffset) {
          overlapsWithBlock = true;
          break;
        }
      }

      if (!overlapsWithBlock) {
        final trimmed = paragraphBuffer.trim();
        final occurrence = occurrences[trimmed] ?? 0;
        occurrences[trimmed] = occurrence + 1;

        blocks.add(
          MarkdownBlock(
            type: MarkdownBlockType.paragraph,
            content: paragraphBuffer,
            startOffset: paragraphStart!,
            endOffset: paragraphStart + paragraphBuffer.length,
            occurrenceIndex: occurrence,
          ),
        );
      }
    }
  }

  bool _isInProtectedRange(int offset, List<(int, int)> protectedRanges) {
    for (final (start, end) in protectedRanges) {
      if (offset >= start && offset < end) {
        return true;
      }
    }
    return false;
  }
}

/// Tracks occurrence counts for blocks during rendering.
///
/// This is used by DragTarget wrappers to know which occurrence of a
/// particular block content they represent.
class BlockOccurrenceTracker {
  final Map<String, int> _occurrenceCounts = {};

  /// Normalizes block content for matching.
  /// Strips leading list markers (- * +) and whitespace to handle
  /// differences between gpt_markdown component text and parsed content.
  /// Also normalizes code blocks to handle whitespace variations.
  static String normalizeForMatching(String content) {
    var normalized = content.trim();

    // Strip leading whitespace (for indented list items)
    normalized = normalized.replaceFirst(RegExp(r'^[ \t]+'), '');

    // Strip leading list markers: - * + followed by space
    final listPrefixPattern = RegExp(r'^[-*+]\s+');
    normalized = normalized.replaceFirst(listPrefixPattern, '');

    // Normalize image markdown: extract just the URL, ignoring alt text
    // This handles the case where imageBuilder only receives URL but source has alt text
    // Converts ![alt text](url) to ![](url) for matching
    final imagePattern = RegExp(r'^!\[([^\]]*)\]\((.+)\)$');
    final imageMatch = imagePattern.firstMatch(normalized);
    if (imageMatch != null) {
      final url = imageMatch.group(2);
      normalized = '![]($url)';
    }

    // Normalize code blocks: standardize whitespace around fences
    // Handle both ``` and ~~~ fences
    if (normalized.startsWith('```') || normalized.startsWith('~~~')) {
      // Split into lines and normalize each line's trailing whitespace
      final lines = normalized.split('\n');
      final normalizedLines = lines.map((line) => line.trimRight()).toList();

      // Remove empty lines at the end before closing fence
      while (normalizedLines.length > 2 &&
          normalizedLines[normalizedLines.length - 2].isEmpty) {
        normalizedLines.removeAt(normalizedLines.length - 2);
      }

      normalized = normalizedLines.join('\n');
    }

    return normalized;
  }

  /// Returns the next occurrence index for the given block content
  /// and increments the counter.
  int nextOccurrence(String blockContent) {
    final normalizedContent = normalizeForMatching(blockContent);
    final count = _occurrenceCounts[normalizedContent] ?? 0;
    _occurrenceCounts[normalizedContent] = count + 1;
    return count;
  }

  /// Resets all occurrence counters.
  void reset() => _occurrenceCounts.clear();
}
