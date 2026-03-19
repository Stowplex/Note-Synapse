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
      var codeNode = node.firstChild;
      if (codeNode?.nodeName != 'code') {
        codeNode = null;
      }

      // Attempt to detect language from class attributes on either <pre> or <code>.
      var language = '';
      final classNames = [node.className, if (codeNode != null) codeNode.className];
      for (final className in classNames) {
        final languageMatch = RegExp(r'language-([A-Za-z0-9_+-]+)').firstMatch(
          className,
        );
        if (languageMatch != null) {
          language = languageMatch.group(1) ?? '';
          break;
        }
      }

      // Use raw DOM text to preserve multiline formatting inside code blocks.
      var codeText = (codeNode ?? node).textContent;
      codeText = codeText.replaceFirst(RegExp(r'^\n'), '');
      codeText = codeText.replaceFirst(RegExp(r'\n$'), '');

      return '\n\n```$language\n$codeText\n```\n\n';
    },
  );

  static final List<html2md.Rule> customRules = [preTagRule];
}
