class WorkflowBindingRow {
  final String pattern;
  final bool isPrefix;
  final String skillNoteId;
  final String prompt;
  final bool contentImmutable;

  const WorkflowBindingRow({
    required this.pattern,
    required this.isPrefix,
    required this.skillNoteId,
    required this.prompt,
    required this.contentImmutable,
  });

  factory WorkflowBindingRow.fromRow(Map<String, dynamic> row) =>
      WorkflowBindingRow(
        pattern: row['pattern'] as String,
        isPrefix: (row['isPrefix'] as int) == 1,
        skillNoteId: row['skillNoteId'] as String,
        prompt: row['prompt'] as String,
        contentImmutable: (row['contentImmutable'] as int) == 1,
      );

  Map<String, dynamic> toMap() => {
    'pattern': pattern,
    'isPrefix': isPrefix ? 1 : 0,
    'skillNoteId': skillNoteId,
    'prompt': prompt,
    'contentImmutable': contentImmutable ? 1 : 0,
  };
}
