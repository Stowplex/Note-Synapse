/// Model for structured task results with TOC support for lazy-loading.
///
/// Instead of including full task results in context (which wastes tokens),
/// this model allows:
/// 1. Generating a TOC (table of contents) from markdown headers
/// 2. Checking if results are short enough to inline
/// 3. Providing section-based retrieval via breadcrumb paths

import '../services/agentic_settings_service.dart';
import '../utils/token_estimator.dart';

/// Represents a section within a task result, identified by its header.
class ResultSection {
  /// Breadcrumb path to this section (e.g., "# Section 1 > ## Subsection A")
  final String breadcrumb;

  /// The header title text
  final String title;

  /// Character offset where this section starts in the full result
  final int startOffset;

  /// Character offset where this section ends in the full result
  final int endOffset;

  ResultSection({
    required this.breadcrumb,
    required this.title,
    required this.startOffset,
    required this.endOffset,
  });

  /// Extracts the content of this section from the full result string.
  String getContent(String fullResult) {
    if (startOffset >= fullResult.length) return '';
    final end = endOffset > fullResult.length ? fullResult.length : endOffset;
    return fullResult.substring(startOffset, end);
  }

  Map<String, dynamic> toJson() => {
    'breadcrumb': breadcrumb,
    'title': title,
    'startOffset': startOffset,
    'endOffset': endOffset,
  };

  factory ResultSection.fromJson(Map<String, dynamic> json) => ResultSection(
    breadcrumb: json['breadcrumb'] as String,
    title: json['title'] as String,
    startOffset: json['startOffset'] as int,
    endOffset: json['endOffset'] as int,
  );
}

/// Stores a task's result with structural metadata for lazy-loading.
class TaskResultStorage {
  /// ID of the task this result belongs to
  final String taskId;

  /// Goal/objective of the task
  final String goal;

  /// The complete result text
  final String fullResult;

  /// Parsed sections from the result
  final List<ResultSection> sections;

  TaskResultStorage({
    required this.taskId,
    required this.goal,
    required this.fullResult,
    required this.sections,
  });

  /// Generate TOC from sections (headers only)
  String get toc {
    if (sections.isEmpty) {
      // No headers found, return a summary-style TOC
      final preview = fullResult.length > 200
          ? '${fullResult.substring(0, 200)}...'
          : fullResult;
      return 'No headers found. Preview: $preview';
    }
    return sections.map((s) => '${s.breadcrumb}').join('\n');
  }

  /// Estimated token count of the full result.
  /// Uses token estimation for accuracy with CJK text.
  int get tokenCount => TokenEstimator.estimateTokens(fullResult);

  /// Check if result is short enough to inline (uses configurable token threshold)
  Future<bool> isShort() async {
    final threshold = await AgenticSettingsService.getTocInlineThreshold();
    return tokenCount < threshold;
  }

  /// Synchronous short check with a default token threshold (for contexts where async isn't possible)
  bool isShortSync({int threshold = 1000}) {
    return tokenCount < threshold;
  }

  /// Find a section by its breadcrumb path
  ResultSection? findSection(String breadcrumb) {
    return sections.cast<ResultSection?>().firstWhere(
      (s) => s?.breadcrumb == breadcrumb,
      orElse: () => null,
    );
  }

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'goal': goal,
    'fullResult': fullResult,
    'sections': sections.map((s) => s.toJson()).toList(),
  };

  factory TaskResultStorage.fromJson(Map<String, dynamic> json) =>
      TaskResultStorage(
        taskId: json['taskId'] as String,
        goal: json['goal'] as String,
        fullResult: json['fullResult'] as String,
        sections: (json['sections'] as List)
            .map((s) => ResultSection.fromJson(s as Map<String, dynamic>))
            .toList(),
      );

  // Note: Word counting removed in favor of TokenEstimator.estimateTokens()
  // which provides more accurate estimation for CJK text.
}
