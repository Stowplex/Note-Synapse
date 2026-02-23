import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';

void main() {
  testWidgets('InteractiveCheckboxMarkdown uses Image.file for local images', (
    WidgetTester tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync();
    final tempFile = File('${tempDir.path}/image.png');
    tempFile.writeAsBytesSync([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

    final content = '![img](${tempFile.path})';
    // Wrap in runAsync to allow real dart:io Futures (like File.exists) to resolve
    // without hanging the FakeAsync zone.
    await tester.runAsync(() async {
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

      // Wait for real async file operations to complete
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    await tester.pump();
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

    // Tear down the widget tree so the InteractiveCheckboxMarkdown is disposed
    // and its periodic timer (_imagePollingTimer) is cancelled. Otherwise,
    // the test runner might hang waiting for background timers to finish.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
