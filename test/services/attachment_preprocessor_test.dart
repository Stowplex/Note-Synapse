import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/attachment_preprocessor.dart';
import 'package:file_picker/file_picker.dart';

import 'dart:typed_data';

void main() {
  group('AttachmentPreprocessor Tests', () {
    test('detectRequiredCapabilities - Identifies images', () async {
      final attachments = [
        PlatformFile(
          name: 'test.jpg',
          size: 1024,
          path: '/tmp/test.jpg',
          bytes: Uint8List.fromList(List.filled(10, 0)), // Dummy bytes
        ),
      ];

      final caps = await AttachmentPreprocessor.detectRequiredCapabilities(
        attachments,
      );
      // Implementation uses 'images' not 'image'
      expect(caps, contains('images'));
    });

    test('detectRequiredCapabilities - Identifies audio', () async {
      final attachments = [
        PlatformFile(
          name: 'test.mp3',
          size: 1024,
          path: '/tmp/test.mp3',
          bytes: Uint8List.fromList(List.filled(10, 0)),
        ),
      ];
      final caps = await AttachmentPreprocessor.detectRequiredCapabilities(
        attachments,
      );
      expect(caps, contains('audio'));
    });

    test('detectRequiredCapabilities - Identifies video', () async {
      final attachments = [
        PlatformFile(
          name: 'test.mp4',
          size: 1024,
          path: '/tmp/test.mp4',
          bytes: Uint8List.fromList(List.filled(10, 0)),
        ),
      ];
      final caps = await AttachmentPreprocessor.detectRequiredCapabilities(
        attachments,
      );
      expect(caps, contains('video'));
    });

    test('detectRequiredCapabilities - PDF requires documents', () async {
      final attachments = [
        PlatformFile(
          name: 'test.pdf',
          size: 1024,
          path: '/tmp/test.pdf',
          bytes: Uint8List.fromList(List.filled(10, 0)),
        ),
      ];
      final caps = await AttachmentPreprocessor.detectRequiredCapabilities(
        attachments,
      );
      // Implementation uses 'documents' not 'doc_pdf'
      expect(caps, contains('documents'));
    });

    test('detectRequiredCapabilities - Mixed content', () async {
      final attachments = [
        PlatformFile(
          name: 'a.jpg',
          size: 1,
          path: 'a.jpg',
          bytes: Uint8List(1),
        ),
        PlatformFile(
          name: 'b.pdf',
          size: 1,
          path: 'b.pdf',
          bytes: Uint8List(1),
        ),
      ];
      final caps = await AttachmentPreprocessor.detectRequiredCapabilities(
        attachments,
      );
      expect(caps, containsAll(['images', 'documents']));
    });

    test(
      'detectRequiredCapabilities - Text file needs documents (text is document)',
      () async {
        final attachments = [
          PlatformFile(
            name: 'a.txt',
            size: 1,
            path: 'a.txt',
            bytes: Uint8List(1),
          ),
        ];
        final caps = await AttachmentPreprocessor.detectRequiredCapabilities(
          attachments,
        );
        // Implementation checks 'text/' -> 'documents'
        expect(caps, contains('documents'));
      },
    );
  });
}
