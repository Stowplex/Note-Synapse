import '../models/chip_action.dart';

/// Result of parsing an AI message body for ` ```chips ` fenced blocks.
class ChipsParseResult {
  /// Chips extracted from all well-formed blocks in document order.
  final List<ChipAction> chips;

  /// Original markdown with all well-formed `chips` fenced blocks removed.
  /// Malformed blocks (e.g. unterminated fences) stay in place for debug
  /// visibility — better to surface broken AI output than hide it.
  final String strippedMarkdown;

  const ChipsParseResult({
    required this.chips,
    required this.strippedMarkdown,
  });
}

/// Parses fenced ```chips blocks out of an AI message body.
///
/// Block format:
///
///     ```chips
///     ## <label>
///     <prompt body, multi-line>
///     ## <next label>
///     ...
///     ```
///
/// Each chip is one H2 heading followed by its body text. Both label and
/// body must be non-empty (after trim) — defective chips are silently
/// dropped. Multiple chips blocks in one message concatenate in document
/// order. Only fully-terminated fences are stripped from the rendered
/// markdown; unterminated blocks remain visible.
///
/// Note: assumes `\n` line endings (consistent with how AI providers emit).
/// TODO: add `\r\n` normalization if Windows line endings are ever observed
/// in AI provider output.
class ChipsBlockParser {
  /// Matches a fenced ```chips block. The closing ``` must be on its own
  /// line. The body group ([\s\S]*?) is non-greedy so multiple blocks in
  /// the same string are matched independently.
  static final _blockRegex = RegExp(
    r'```chips\s*\n([\s\S]*?)\n```',
    multiLine: true,
  );

  ChipsParseResult parse(String markdown) {
    final matches = _blockRegex.allMatches(markdown).toList();
    if (matches.isEmpty) {
      return ChipsParseResult(chips: const [], strippedMarkdown: markdown);
    }

    final chips = <ChipAction>[];
    for (final m in matches) {
      chips.addAll(_parseBlockBody(m.group(1)!));
    }

    // Strip the matched blocks. For each block, copy the segment before it,
    // then collapse the boundary newlines (the trailing `\n` of the prior
    // segment + the leading newlines of the next segment) so removing a
    // block surrounded by blank lines doesn't leave a 3+ newline run.
    //
    // The collapse is local to the strip seams — content elsewhere in the
    // markdown is preserved verbatim, including legitimate triple-newlines
    // inside code blocks or pre-formatted text.
    final buf = StringBuffer();
    int cursor = 0;
    for (final m in matches) {
      // Trim trailing newlines from the segment ending right before this block.
      final before = markdown
          .substring(cursor, m.start)
          .replaceAll(RegExp(r'\n+$'), '');
      buf.write(before);
      cursor = m.end;
      // Skip leading newlines of the segment that follows the block; we'll
      // emit a single `\n\n` separator below if both before and after are
      // non-empty.
      while (cursor < markdown.length && markdown[cursor] == '\n') {
        cursor++;
      }
      // If both sides have content, separate with a paragraph break.
      if (before.isNotEmpty && cursor < markdown.length) {
        buf.write('\n\n');
      } else if (before.isEmpty && cursor < markdown.length) {
        // Block was at the start; do not emit a leading newline.
      } else if (before.isNotEmpty && cursor >= markdown.length) {
        // Block was at the end; one trailing newline for clean termination.
        buf.write('\n');
      }
    }
    buf.write(markdown.substring(cursor));

    return ChipsParseResult(chips: chips, strippedMarkdown: buf.toString());
  }

  /// Walk the body of a single chips block, splitting on `## ` headings.
  /// Each `## label` line begins a new chip; everything until the next
  /// `## ` is that chip's prompt body.
  List<ChipAction> _parseBlockBody(String body) {
    final lines = body.split('\n');
    final chips = <ChipAction>[];
    String? currentLabel;
    final currentBody = StringBuffer();

    void flush() {
      if (currentLabel != null) {
        final label = currentLabel!.trim();
        final prompt = currentBody.toString().trim();
        if (label.isNotEmpty && prompt.isNotEmpty) {
          chips.add(ChipAction(label: label, prompt: prompt));
        }
      }
      currentLabel = null;
      currentBody.clear();
    }

    for (final line in lines) {
      if (line.startsWith('## ') || line.trimRight() == '##') {
        flush();
        currentLabel = line.length > 3 ? line.substring(3).trim() : '';
      } else {
        if (currentLabel != null) {
          currentBody.writeln(line);
        }
        // Lines before the first ## are silently dropped (they're
        // not part of any chip).
      }
    }
    flush();
    return chips;
  }
}
