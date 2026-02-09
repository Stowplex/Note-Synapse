import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';

void main() {
  testWidgets('InteractiveCheckboxMarkdown uses Image.file for local images', (
    WidgetTester tester,
  ) async {
    // create a temporary file
    final file = File('test_image.png');
    await file.writeAsBytes([0, 1, 2, 3]); // dummy bytes

    // We can't easily mock file existence in widget tests without IO overrides,
    // but we can check if the widget tree structure attempts to use Image.file
    // when provided with a local file path.
    // However, InteractiveCheckboxMarkdown checks for file existence.
    // In a widget test environment, File('test_image.png').exists() might fail unless we write it.
    // But writing to disk in tests is flaky.

    // Better approach: Check if it parses "file://" or local paths and puts an Image.file in the tree.
    // We might need to mock the file check if possible, or just create a real temp file.

    // Let's try creating a real temp file in the system temp dir.
    final tempDir = Directory.systemTemp.createTempSync();
    final tempFile = File('${tempDir.path}/image.png');
    await tempFile.writeAsBytes([
      // Minimal PNG header to avoid "invalid image" errors if it tries to decode (though we just check widget type)
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ]);

    final content = '![img](${tempFile.path})';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveCheckboxMarkdown(
            originalContent: content,
            noteId: 'test_note', // Required for local file resolution
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify Image.file is used
    // Note: Image.file creates an Image widget with a FileImage provider.
    // We can check for Image widget where image provider is FileImage.
    final imageFinder = find.byWidgetPredicate((widget) {
      if (widget is Image) {
        final image = widget.image;
        if (image is FileImage) {
          return image.file.path == tempFile.path;
        }
      }
      return false;
    });

    expect(
      imageFinder,
      findsOneWidget,
      reason: 'Should use Image.file for local images',
    );

    // Verify Image.memory is NOT used (for this file)
    final memoryImageFinder = find.byWidgetPredicate((widget) {
      if (widget is Image) {
        return widget.image is MemoryImage;
      }
      return false;
    });

    expect(
      memoryImageFinder,
      findsNothing,
      reason: 'Should not use Image.memory for local images',
    );

    // Cleanup
    tempDir.deleteSync(recursive: true);
  });
}
