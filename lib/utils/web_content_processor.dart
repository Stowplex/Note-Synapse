import 'package:html2md/html2md.dart' as html2md;
import '../utils/html_rules.dart';
import '../utils/markdown_cleaner.dart';
import '../utils/remote_image_utils.dart';

/// specific class for compute-heavy operations to be run in an isolate
class WebContentProcessor {
  /// Processes HTML content to Markdown.
  ///
  /// This method is intended to be run in an isolate via [compute].
  static String processHtml(String htmlContent) {
    // Use custom rules for better extraction and force fenced code blocks
    final markdownContent = html2md.convert(
      htmlContent,
      ignore: ['script', 'style'],
      styleOptions: {'codeBlockStyle': 'fenced'},
      rules: HtmlRules.customRules,
    );

    // Clean up spurious backslashes and other artifacts
    return MarkdownCleaner.clean(markdownContent);
  }

  /// Extracts remote image references from content.
  ///
  /// This method is intended to be run in an isolate via [compute].
  static List<RemoteImageReference> extractImages(String content) {
    return RemoteImageUtils.extractRemoteImages(content);
  }
}
