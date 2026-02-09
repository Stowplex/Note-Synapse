import 'package:html2md/html2md.dart' as html2md;

class HtmlRules {
  /// A rule that ensures <pre> tags are converted to fenced code blocks.
  ///
  /// By default, html2md might treat <pre> as indented code blocks or just text.
  /// This rule forces a fenced code block style.
  static final html2md.Rule preTagRule = html2md.Rule(
    'pre-fenced',
    filters: ['pre'],
    replacement: (content, node) {
      // If the content is already fenced (e.g. handled by a child <code> tag rule), return as is.
      if (content.trim().startsWith('```')) {
        return content;
      }

      // Attempt to detect language from class attribute (e.g. <pre class="language-dart">)
      var language = '';
      final className = node.className;
      if (className.isNotEmpty) {
        final languageMatch = RegExp(r'language-(\w+)').firstMatch(className);
        if (languageMatch != null) {
          language = languageMatch.group(1) ?? '';
        }
      }

      // If no language found on pre, check if there's a direct code child with language class
      if (language.isEmpty) {
        // We can't easily access children DOM nodes from 'node' (which is html2md Node),
        // but we can try to guess from content if it wasn't processed?
        // Actually, 'content' is the processed string of children.
        // So we rely on the pre tag's attributes or just default to empty.
      }

      return '\n\n```$language\n${content.trim()}\n```\n\n';
    },
  );

  static final List<html2md.Rule> customRules = [preTagRule];
}
