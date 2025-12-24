import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/share_service.dart';

void main() {
  group('ShareService URL Extraction', () {
    // Helper to access the private static method via reflection or just copy logic for unit testing
    // Since _extractUrl is private, we'll need to make it public or @visibleForTesting
    // For now, let's assume we will modify ShareService to make it testable or accessible.
    // Given I cannot easily change visibility without modifying the file first,
    // and I want to write the test first (TDD), I will rely on `ShareService.processSharedContent`
    // which calls `_extractUrl` internally when `type` is text.

    Future<String?> detectUrlViaProcessSharedContent(String text) async {
      // We can Mock the platform channel if needed, but processSharedContent is static.
      // It seems processSharedContent uses _extractUrl when action is SEND...
      // and type is 'text/plain'.

      final result = await ShareService.processSharedContent({
        'action': 'SEND',
        'type': 'text/plain',
        'text': text,
      });

      if (result['success'] == true && result['contentType'] == 'url') {
        return result['url'] as String?;
      }
      return null;
    }

    test('detects strict URL', () async {
      expect(
        await detectUrlViaProcessSharedContent('https://example.com'),
        'https://example.com',
      );
      expect(
        await detectUrlViaProcessSharedContent('http://google.com'),
        'http://google.com',
      );
    });

    test('detects URL with whitespace', () async {
      // Current implementation trims, so this should pass if it trims.
      // The new implementation should definitely handle this.
      expect(
        await detectUrlViaProcessSharedContent('  https://example.com  '),
        'https://example.com',
      );
    });

    test('detects URL in short text (ratio > 1/5)', () async {
      // Text length: 11 + 19 + 4 = 34. URL length: 19. Ratio: 19/34 > 1/5.
      // Current implementation: Should FAIL (returns null)
      // New implementation: Should PASS
      final text = 'Check this https://example.com out';
      expect(
        await detectUrlViaProcessSharedContent(text),
        'https://example.com',
      );
    });

    test('detects URL in medium text (ratio > 1/5)', () async {
      // URL: https://example.com (19 chars)
      // Prefix: "Here is a link " (15 chars)
      // Suffix: " for you" (8 chars)
      // Total: 15 + 19 + 8 = 42.
      // Ratio: 19/42 = 0.45 > 0.2
      final text = 'Here is a link https://example.com for you';
      expect(
        await detectUrlViaProcessSharedContent(text),
        'https://example.com',
      );
    });

    test('ignores URL in long text (ratio <= 1/5)', () async {
      // URL: https://a.com (13 chars)
      // We need total length >= 13 * 5 = 65 chars for it to be ignored.
      // Text: 60 chars of filler + URL = 73 chars.
      final text =
          'This is a very long text that basically just rambles on and on and on and contains a small link https://a.com inside it.';
      expect(await detectUrlViaProcessSharedContent(text), isNull);
    });

    test('ignores invalid URLs', () async {
      expect(
        await detectUrlViaProcessSharedContent('htt://example.com'),
        isNull,
      );
      expect(
        await detectUrlViaProcessSharedContent('example.com'),
        isNull,
      ); // missing scheme
    });

    test('handles multiple URLs by picking the first valid one', () async {
      // "Link1: https://one.com Link2: https://two.com"
      // Total: 7 + 15 + 8 + 15 = 45.
      // URL1: 15/45 = 1/3 > 1/5.
      expect(
        await detectUrlViaProcessSharedContent(
          'Link1: https://one.com Link2: https://two.com',
        ),
        'https://one.com',
      );
    });
  });
}
