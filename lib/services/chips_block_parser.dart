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

    // Strip the matched blocks. Walk forward through the matches and
    // copy non-block segments into a buffer.
    final buf = StringBuffer();
    int cursor = 0;
    for (final m in matches) {
      buf.write(markdown.substring(cursor, m.start));
      cursor = m.end;
    }
    buf.write(markdown.substring(cursor));
    // Collapse 3+ consecutive newlines left by the strip into 2.
    final stripped = buf.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return ChipsParseResult(chips: chips, strippedMarkdown: stripped);
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
