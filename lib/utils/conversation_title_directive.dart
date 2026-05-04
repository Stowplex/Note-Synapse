import '../models/conversation.dart';

class ConversationTitleDirectiveResult {
  const ConversationTitleDirectiveResult({
    required this.content,
    required this.title,
    required this.hadDirective,
  });

  final String content;
  final String? title;
  final bool hadDirective;
}

class ConversationTitleDirective {
  static const pendingTitle = 'Forked conversation';

  static const promptInstruction = '''
If this is the first assistant reply in a newly forked conversation, begin your response exactly with:

```conversation-title
short-kebab-case-slug
```

Then add a blank line and write the normal markdown answer.

Slug rules:
- 2-6 concrete topic words
- lowercase ASCII letters/numbers separated by hyphens
- no generic phrases like `in-context`, `follow-up`, or `conversation`
- max 48 characters''';

  static final RegExp _leadingBlock = RegExp(
    r'^\s*```conversation-title[ \t]*\r?\n([\s\S]*?)\r?\n```[ \t]*(?:\r?\n)?',
    caseSensitive: false,
  );

  static bool shouldRequestTitle(Conversation? conversation) =>
      conversation?.title == pendingTitle;

  static ConversationTitleDirectiveResult parseLeading(String content) {
    final match = _leadingBlock.firstMatch(content);
    if (match == null) {
      return ConversationTitleDirectiveResult(
        content: content,
        title: null,
        hadDirective: false,
      );
    }

    final title = normalizeSlug(match.group(1) ?? '');
    final stripped = content
        .substring(match.end)
        .replaceFirst(RegExp(r'^\s*\r?\n'), '');
    return ConversationTitleDirectiveResult(
      content: stripped,
      title: title.isEmpty ? null : title,
      hadDirective: true,
    );
  }

  static String fallbackSlugFromResponse(String content) {
    final parsed = parseLeading(content);
    final text = parsed.content
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
        .replaceAll(RegExp(r'[#*_`>\-\[\]()]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return pendingTitle;

    final words = text
        .split(' ')
        .where((word) => word.trim().isNotEmpty)
        .take(6)
        .join('-');
    final slug = normalizeSlug(words);
    return slug.isEmpty ? pendingTitle : slug;
  }

  static String normalizeSlug(String input) {
    var slug = input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.length > 48) {
      slug = slug.substring(0, 48).replaceAll(RegExp(r'-+$'), '');
    }
    return slug;
  }
}

class ConversationTitleStreamFilter {
  final StringBuffer _buffer = StringBuffer();
  bool _decided = false;

  String addChunk(String chunk) {
    if (_decided) return chunk;

    _buffer.write(chunk);
    final text = _buffer.toString();
    final trimmedLeft = text.trimLeft();

    if (!'```conversation-title'.startsWith(trimmedLeft) &&
        !trimmedLeft.startsWith('```conversation-title')) {
      _decided = true;
      final output = text;
      _buffer.clear();
      return output;
    }

    if (trimmedLeft.startsWith('```conversation-title')) {
      final parsed = ConversationTitleDirective.parseLeading(text);
      if (parsed.hadDirective) {
        _decided = true;
        _buffer.clear();
        return parsed.content;
      }
    }

    return '';
  }
}
