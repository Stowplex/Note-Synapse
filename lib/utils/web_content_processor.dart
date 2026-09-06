import 'package:html2md/html2md.dart' as html2md;
import '../utils/html_rules.dart';
import '../utils/html_url_absolutizer.dart';
import '../utils/markdown_cleaner.dart';
import '../utils/remote_image_utils.dart';

/// A captured page: the HTML to convert plus the base URL its relative
/// references should resolve against (`document.baseURI`).
///
/// [compute] takes exactly one argument, so the base URL has to travel with the
/// HTML. Records are sendable across isolates.
typedef WebContentJob = ({String html, String? baseUrl});

/// specific class for compute-heavy operations to be run in an isolate
class WebContentProcessor {
  /// Processes HTML content to Markdown.
  ///
  /// Relative `src` / `href` / `srcset` values are resolved against
  /// `job.baseUrl` first, so clipped images and links stay usable. That pass is
  /// idempotent, so it runs unconditionally (Readability-processed HTML already
  /// has absolute URLs and is simply left alone).
  ///
  /// This method is intended to be run in an isolate via [compute].
  static String processHtml(WebContentJob job) {
    final htmlContent = absolutizeUrls(job.html, job.baseUrl);

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
