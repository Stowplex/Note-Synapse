/// Type of change for a diff line.
enum DiffLineType { unchanged, added, removed }

/// A single line in a diff result.
class DiffLine {
  final String text;
  final DiffLineType type;
  const DiffLine(this.text, this.type);
}

/// Compute a line-based diff using longest common subsequence (LCS).
/// Returns a list of [DiffLine] entries representing the changes.
List<DiffLine> computeLineDiff(String original, String transformed) {
  final oldLines = original.split('\n');
  final newLines = transformed.split('\n');

  // Build LCS table
  final m = oldLines.length;
  final n = newLines.length;
  final lcs = List.generate(m + 1, (_) => List.filled(n + 1, 0));

  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      if (oldLines[i - 1] == newLines[j - 1]) {
        lcs[i][j] = lcs[i - 1][j - 1] + 1;
      } else {
        lcs[i][j] = lcs[i - 1][j] > lcs[i][j - 1]
            ? lcs[i - 1][j]
            : lcs[i][j - 1];
      }
    }
  }

  // Backtrack to build diff
  final diff = <DiffLine>[];
  var i = m, j = n;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1]) {
      diff.add(DiffLine(oldLines[i - 1], DiffLineType.unchanged));
      i--;
      j--;
    } else if (j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j])) {
      diff.add(DiffLine(newLines[j - 1], DiffLineType.added));
      j--;
    } else {
      diff.add(DiffLine(oldLines[i - 1], DiffLineType.removed));
      i--;
    }
  }

  return diff.reversed.toList();
}
