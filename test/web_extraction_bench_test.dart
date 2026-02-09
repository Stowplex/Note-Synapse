import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/web_content_processor.dart';

void main() {
  test('Benchmark WebContentProcessor', () async {
    // Generate a large HTML string (simulating a long article)
    final StringBuffer htmlBuffer = StringBuffer();
    htmlBuffer.write('<html><body>');
    htmlBuffer.write('<h1>Huge Article</h1>');
    for (int i = 0; i < 5000; i++) {
      htmlBuffer.write(
        '<p>This is paragraph number $i. It has some <b>bold</b> and <i>italic</i> text.</p>',
      );
      htmlBuffer.write('<ul><li>List item 1</li><li>List item 2</li></ul>');
      htmlBuffer.write(
        '<pre class="language-dart">void main() { print("hello world $i"); }</pre>',
      );
      htmlBuffer.write(
        '<img src="https://example.com/image$i.jpg" alt="Image $i" />',
      );
    }
    htmlBuffer.write('</body></html>');

    final htmlContent = htmlBuffer.toString();
    print('HTML size: ${htmlContent.length / 1024} KB');

    final stopwatch = Stopwatch()..start();

    // 1. Process HTML
    // Note: in a unit test environment, compute might run synchronously or need setup.
    // We test the method directly first to ensure logic correctness and measure time.
    final finalContent = WebContentProcessor.processHtml(htmlContent);

    final processTime = stopwatch.elapsedMilliseconds;
    print('Process time: ${processTime}ms');

    expect(finalContent, isNotEmpty);
    expect(finalContent, contains('Huge Article'));
    expect(finalContent, contains('```dart'));

    // 2. Extract Images
    final stopwatchImages = Stopwatch()..start();
    final images = WebContentProcessor.extractImages(finalContent);

    final imageTime = stopwatchImages.elapsedMilliseconds;
    print('Image extraction time: ${imageTime}ms');

    expect(images.length, 5000);
    expect(images.first.url, 'https://example.com/image0.jpg');
  });
}
