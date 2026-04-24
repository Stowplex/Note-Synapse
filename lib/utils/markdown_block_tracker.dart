// Markdown block tracking utilities for drag-to-edit feature

import 'package:markdown/markdown.dart' as md;
import 'package:markdown/src/line.dart'; // Internal import for line tracking

import 'synapse_app_block_syntax.dart';

/// Represents a type of markdown block
enum MarkdownBlockType {
  codeBlock,
  image,
  linkedImage, // Image wrapped in a link: [![alt](url)](url)
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
  html,
  other,
}

/// Represents a parsed markdown block with its location in the source
class MarkdownBlock {
  final MarkdownBlockType type;
  final String content;

  // These offsets refer to indices in the source string.
  final int startOffset;
  final int endOffset;

  const MarkdownBlock({
    required this.type,
    required this.content,
    required this.startOffset,
    required this.endOffset,
  });

  @override
  String toString() => 'MarkdownBlock($type, offset: $startOffset-$endOffset)';
}

/// Tracks and identifies markdown blocks within content.
///
/// This utility parses markdown content and identifies block boundaries,
/// enabling accurate mapping between rendered widgets and their source text.
/// It uses 'package:markdown' internally for robust CommonMark compliance.
class MarkdownBlockTracker {
  /// Parses markdown content and returns all identified blocks.
  List<MarkdownBlock> parseBlocks(String content) {
    if (content.isEmpty) return [];

    final blocks = <MarkdownBlock>[];

    // Split content into Lines, keeping track of their usage
    // Note: 'package:markdown' splits by newline.
    // We need to map Lines back to source offsets.
    // 'content.split' might differ if we don't watch out for newline types,
    // but typically \n is used.

    final sourceLines = content.split('\n');
    final lines = sourceLines.map((e) => Line(e)).toList();

    // Map each Line object to its start offset in the source string.
    final lineOffsets = <Line, int>{};
    int currentOffset = 0;
    for (int i = 0; i < lines.length; i++) {
      lineOffsets[lines[i]] = currentOffset;
      // +1 for the newline character that was split away
      // (Exception: last line might not have newline if content doesn't end with one,
      // but split usually handles that. 'split' gives n strings.
      // If content is "a\nb", length is 3. a(1), \n(1), b(1).
      // split->['a','b'].
      // offset a=0. length 1. next offset = 0+1+1 = 2. b at 2. Correct.)
      // Note: If original content ends with \n, split gives an empty string at end.
      currentOffset += sourceLines[i].length + 1;
    }

    final document = md.Document(
      // We enable common extensions to ensure we catch lists, tables, etc.
      extensionSet: md.ExtensionSet.gitHubFlavored,
      blockSyntaxes: const [LatexBlockSyntax(), SynapseAppBlockSyntax()],
      encodeHtml: false,
    );

    final parser = md.BlockParser(lines, document);

    while (!parser.isDone) {
      final currentLine = parser.current;
      final startLineIndex = lines.indexOf(currentLine);

      // Try to parse using registered syntaxes
      bool matched = false;

      // We iterate document.blockSyntaxes which includes standard + GFM extensions
      for (final syntax in parser.blockSyntaxes) {
        if (syntax.canParse(parser)) {
          final node = syntax.parse(parser);
          // Safety check: If syntax claimed to parse but didn't advance parser,
          // we must force advance to avoid infinite loop.
          if (!parser.isDone &&
              lines.indexOf(parser.current) == startLineIndex) {
            parser.advance();
          }

          int endLineIndex;
          if (parser.isDone) {
            endLineIndex = lines.length; // Exclusive
          } else {
            endLineIndex = lines.indexOf(parser.current);
          }

          // We consumed lines from startLineIndex (inclusive) to endLineIndex (exclusive).
          // Even if node is null (e.g. EmptyBlockSyntax), we must record the block
          // to preserve source mapping offsets.
          _addBlockFromLineRange(
            blocks,
            node,
            lines,
            sourceLines,
            lineOffsets,
            startLineIndex,
            endLineIndex,
            // If node is null, force paragraph (empty lines usually)
            forceType: node == null ? MarkdownBlockType.paragraph : null,
          );

          matched = true;
          break; // Stop after first match as parser state has changed
        }
      }

      if (!matched) {
        // Force advance if no syntax matched (shouldn't happen often as Paragraph catches most)
        // Treated as pure text/paragraph
        parser.advance();
        int endLineIndex;
        if (parser.isDone) {
          endLineIndex = lines.length;
        } else {
          endLineIndex = lines.indexOf(parser.current);
        }

        // Add as paragraph or other
        _addBlockFromLineRange(
          blocks,
          null, // No node type known, assume paragraph
          lines,
          sourceLines,
          lineOffsets,
          startLineIndex,
          endLineIndex,
          forceType: MarkdownBlockType.paragraph,
        );
      }
    }

    // Sort logic not strictly needed as we parse in order, but good for safety
    // blocks.sort((a, b) => a.startOffset.compareTo(b.startOffset)); // Already ordered

    return blocks;
  }

  void _addBlockFromLineRange(
    List<MarkdownBlock> blocks,
    md.Node? node,
    List<Line> lines,
    List<String> sourceLines,
    Map<Line, int> lineOffsets,
    int startIndex,
    int endIndex, {
    MarkdownBlockType? forceType,
  }) {
    if (startIndex >= endIndex) return;

    // Calculate precise start/end offsets from the source
    final startLineObj = lines[startIndex];
    final startOffset = lineOffsets[startLineObj]!;

    // End offset is the end of the last included line.
    // If endIndex is past the last line, we use the end of the last line available.
    final lastIncludedIndex = endIndex - 1;
    final lastLineObj = lines[lastIncludedIndex];
    final lastLineStart = lineOffsets[lastLineObj]!;
    final lastLineLength = sourceLines[lastIncludedIndex].length;

    var endOffset = lastLineStart + lastLineLength;

    // We should also include the newline characters consumed between lines, checking bounds.
    // But 'split' confirms that between line N and N+1 there is a \n.
    // However, does the block include the trailing newline of the last line?
    // Usually blocks in a file are separated by \n.
    // If we want to replace the block cleanly, we should grab the block content.
    // If "Header\n\nNext", Header block is "Header". The \n\n might be whitespace block or part of it?
    // CommonMark spec: block includes its content.
    // BlockParser advances over the lines containing the block.
    // So "Header\n" (setext) or "# Header".
    // If we take indices [startIndex, endIndex), we grab those lines.

    // Reconstruct content from source lines
    // We can't just substring source because there might be gaps? No, we mapped linearly.
    // Actually, simply content.substring(startOffset, endOffset) might miss the newlines *between* lines.

    // Correction:
    // startOffset is start of line S.
    // endOffset calculated as start of line E + len(line E).
    // This range excludes the newlines.
    // We want the newlines too!
    // The previous block ended at some offset.
    // Ideally we capture exactly what lines created.

    // Better strategy for content:
    // Retrieve source substring from startOffset to (endOffset of last line).
    // But wait, what about newlines?
    // The 'lineOffsets' were calculated assuming +1 for newline.
    // So line N starts at X. Line N+1 starts at X + len(N) + 1.
    // So the gap is the newline.
    // So valid content is from startOffset to...
    // Actually, effectively is substring(startOffset, ...).

    // Let's refine endOffset.
    // If we're at the very last line of the file, there may or may not be a newline.

    // Let's rely on retrieving ALL keys from lines [startIndex, endIndex).
    // The end of the block should effectively be the start of the next block
    // OR just the content of these lines.

    // For now, let's include the block's text lines.
    // We will verify if standard parser consumes blank lines after blocks.
    // (Standard BlockParser usually DOES NOT consume trailing blank lines unless PART of the block).

    // So `reconstruct`
    final sb = StringBuffer();
    for (int i = startIndex; i < endIndex; i++) {
      sb.write(sourceLines[i]);
      if (i < endIndex - 1) {
        sb.write('\n'); // Add newline between lines
      }
    }
    String content = sb.toString();

    // But wait, the source might have used \r\n?
    // dart 'split' handles that? 'split(\n)' assumes \n.
    // If file used \r\n, sourceLines elements would end in \r.
    // So appending \n reconstructs to ...\r\n. Roughly correct.
    // This is safer than substring() if we aren't 100% sure of map logic,
    // BUT we need offsets for replacement.
    // So we MUST be sure of offsets.

    // Let's stick to calculated offsets.
    // endOffset currently = end of last line's content.
    // It captures "Line1\nLine2".
    // startOffset=0.
    // L1='Line1'. len=5. lineOffsets[1] = 6.
    // L2='Line2'. len=5.
    // endOffset calculated = 6+5=11.
    // content.substring(0, 11) = "Line1\nLine2".
    // Matches logic.

    final type = forceType ?? _mapNodeType(node);

    blocks.add(
      MarkdownBlock(
        type: type,
        content: content,
        startOffset: startOffset,
        endOffset: endOffset,
      ),
    );
  }

  MarkdownBlockType _mapNodeType(md.Node? node) {
    if (node == null) return MarkdownBlockType.paragraph;
    if (node is md.Element) {
      switch (node.tag) {
        case 'h1':
        case 'h2':
        case 'h3':
        case 'h4':
        case 'h5':
        case 'h6':
          return MarkdownBlockType.heading;
        case 'ul':
          return MarkdownBlockType.unorderedList;
        case 'ol':
          return MarkdownBlockType.orderedList;
        case 'pre':
          return MarkdownBlockType.codeBlock;
        case 'blockquote':
          return MarkdownBlockType.blockquote;
        case 'hr':
          return MarkdownBlockType.horizontalRule;
        case 'table':
          return MarkdownBlockType.table;
        case 'p':
          // Can be paragraph or image (if p contains only img)
          // Checking children is hard here without AST traversal.
          // We'll treat as paragraph generally.
          return MarkdownBlockType.paragraph;
        // Custom or HTML extensions
        case 'latex':
          return MarkdownBlockType.latexBlock;
        case 'synapse-app-embed':
          return MarkdownBlockType.other;
        default:
          return MarkdownBlockType.other;
      }
    }
    return MarkdownBlockType.paragraph;
  }

  // Replaces a block in the content with new content.
  String replaceBlock(
    String content,
    MarkdownBlock block,
    String newBlockContent,
  ) {
    if (block.startOffset < 0 || block.endOffset > content.length) {
      // Safety fallback
      return content;
    }
    return content.substring(0, block.startOffset) +
        newBlockContent +
        content.substring(block.endOffset);
  }

  // Deletes a block from the content.
  String deleteBlock(String content, MarkdownBlock block) {
    var end = block.endOffset;
    // Consume the trailing newline if present to remove the line structure
    if (end < content.length && content[end] == '\n') {
      end++;
    }

    if (block.startOffset < 0 || end > content.length) {
      return content;
    }

    return content.substring(0, block.startOffset) + content.substring(end);
  }

  // Deletes a range of blocks from the content.
  String deleteBlockRange(String content, List<MarkdownBlock> blocks) {
    if (blocks.isEmpty) return content;

    // Find the total range
    int start = blocks.first.startOffset;
    int end = blocks.first.endOffset;

    for (final block in blocks) {
      if (block.startOffset < start) start = block.startOffset;
      if (block.endOffset > end) end = block.endOffset;
    }

    // Consume the trailing newline of the last block (defined by end) if present
    if (end < content.length && content[end] == '\n') {
      end++;
    }

    if (start < 0 || end > content.length) {
      return content;
    }

    return content.substring(0, start) + content.substring(end);
  }

  // Replaces a range of blocks with new content.
  String replaceBlockRange(
    String content,
    List<MarkdownBlock> blocks,
    String newContent,
  ) {
    if (blocks.isEmpty) return content;

    // Find the total range
    int start = blocks.first.startOffset;
    int end = blocks.first.endOffset;

    for (final block in blocks) {
      if (block.startOffset < start) start = block.startOffset;
      if (block.endOffset > end) end = block.endOffset;
    }

    if (start < 0 || end > content.length) {
      return content;
    }

    return content.substring(0, start) + newContent + content.substring(end);
  }
}

/// Syntax for block LaTeX: \[ ... \]
// class LatexBlockSyntax extends md.BlockSyntax {
//   @override
//   RegExp get pattern =>
//       RegExp(r'^\\\[(.+?)\\\]', multiLine: true, dotAll: true);
//
//   const LatexBlockSyntax();
//
//   @override
//   md.Node parse(md.BlockParser parser) {
//     final match = pattern.firstMatch(parser.current.content);
//     if (match != null) {
//       parser.advance();
//       return md.Element.text('latex', match[1]!.trim());
//     }
//
//     // Fallback if regex didn't match (shouldn't happen if pattern matched)
//     parser.advance();
//     return md.Element.text('latex', '');
//   }
// }

/// Syntax for block LaTeX: \[ ... \]
class LatexBlockSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp(r'^\s{0,3}\\\[', multiLine: true);

  const LatexBlockSyntax();

  @override
  md.Node parse(md.BlockParser parser) {
    // The pattern matches against the 'current' line, but for multi-line blocks
    // we need to consume lines until we find the closing tag.
    // However, the provided pattern uses dotAll: true, which implies it expects
    // to match against the whole content?
    // BlockParser operates line-by-line usually.

    // Let's adapt the ShareService logic but robustly for BlockParser.
    // Standard BlockParser checks pattern against parser.current.content.
    // If our pattern expects \[ at start, it works.

    final startLine = parser.current.content;

    // Check if start line initiates a block
    if (!startLine.trim().startsWith(r'\[')) {
      return md.Element.text(
        'latex',
        '',
      ); // Should not happen if canParse matched
    }

    // buffer.writeln(startLine); // Keep delimiters? Or strip them?
    // ShareService strip them matches[1].
    // If we want to support standard editing, maybe we should keep them?
    // For rendering, 'gpt_markdown' might expect them or not?
    // LateXMathMultiLine usually expects raw tex usually...
    // But 'share_screen' extracts the content.

    // Let's capture the raw content for the block including delimiters
    // so the MarkdownBlock represents the whole thing in source.

    // Consume lines until \]
    // We need to advance the parser.

    // Simple robust consumption:
    // 1. Consume start line.
    // 2. Consume subsequent lines until one ends with \] (or contains it?)

    // NOTE: The regex in ShareService is likely used on the WHOLE string, not by block parser.
    // Here we must iterate lines.

    final childLines = <String>[];

    // Check if single line block: \[ ... \]
    if (startLine.trim().endsWith(r'\]') && startLine.trim().length > 2) {
      childLines.add(startLine);
      parser.advance();
    } else {
      // Multi-line
      childLines.add(startLine);
      parser.advance();
      while (!parser.isDone) {
        final line = parser.current.content;
        childLines.add(line);
        parser.advance();
        if (line.trim().endsWith(r'\]')) {
          break;
        }
      }
    }

    // Return a dummy element with type 'latex'
    // The actual content logic is handled by _mapNodeType and source extraction.
    final el = md.Element('latex', [md.Text(childLines.join('\n'))]);
    return el;
  }
}
