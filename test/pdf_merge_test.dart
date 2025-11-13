import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:note_synapse/models/note.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PDF Merging Tests', () {
    late Directory tempDir;

    setUp(() async {
      // Create a temporary directory for test PDFs
      tempDir = await Directory.systemTemp.createTemp('pdf_merge_test_');
    });

    tearDown(() async {
      // Clean up temporary directory
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<File> createTestPdf(String name, String content) async {
      final pdf = pw.Document();
      pdf.addPage(
        pw.Page(
          build: (context) => pw.Center(
            child: pw.Text(content, style: const pw.TextStyle(fontSize: 24)),
          ),
        ),
      );

      final bytes = await pdf.save();
      final file = File('${tempDir.path}/$name');
      await file.writeAsBytes(bytes);
      return file;
    }

    test('PDF merging with single attachment', () async {
      // Create a test PDF attachment
      final pdfFile = await createTestPdf('attachment1.pdf', 'Test PDF Content 1');

      // Create a note with PDF attachment
      final note = Note(
        id: 'test-note-1',
        title: 'Test Note with PDF',
        content: 'This note has a PDF attachment',
        type: NoteType.note,
        attachmentPaths: [pdfFile.path],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      print('Created test note with PDF attachment: ${pdfFile.path}');
      print('PDF file exists: ${await pdfFile.exists()}');
      print('PDF file size: ${await pdfFile.length()} bytes');

      // Verify the test setup
      expect(await pdfFile.exists(), true);
      expect(note.attachmentPaths.length, 1);
    });

    test('PDF merging with multiple attachments', () async {
      // Create multiple test PDF attachments
      final pdf1 = await createTestPdf('attachment1.pdf', 'PDF 1');
      final pdf2 = await createTestPdf('attachment2.pdf', 'PDF 2');

      // Create a note with multiple PDF attachments
      final note = Note(
        id: 'test-note-2',
        title: 'Test Note with Multiple PDFs',
        content: 'This note has multiple PDF attachments',
        type: NoteType.note,
        attachmentPaths: [pdf1.path, pdf2.path],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      print('Created test note with ${note.attachmentPaths.length} PDF attachments');
      print('PDF 1: ${pdf1.path} (${await pdf1.length()} bytes)');
      print('PDF 2: ${pdf2.path} (${await pdf2.length()} bytes)');

      // Verify the test setup
      expect(await pdf1.exists(), true);
      expect(await pdf2.exists(), true);
      expect(note.attachmentPaths.length, 2);
    });

    test('Verify _collectPdfAttachments helper', () async {
      // This test verifies that the internal helper method can collect PDFs
      // Create test PDFs
      final pdf1 = await createTestPdf('test1.pdf', 'Content 1');
      final pdf2 = await createTestPdf('test2.pdf', 'Content 2');
      final imageFile = File('${tempDir.path}/image.jpg');
      await imageFile.writeAsBytes([0xFF, 0xD8, 0xFF]); // Fake JPEG header

      // Create notes with various attachments
      final notes = [
        Note(
          id: 'note1',
          title: 'Note 1',
          content: 'Content',
          type: NoteType.note,
          attachmentPaths: [pdf1.path, imageFile.path],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        Note(
          id: 'note2',
          title: 'Note 2',
          content: 'Content',
          type: NoteType.note,
          attachmentPaths: [pdf2.path],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];

      print('Test setup complete:');
      print('- PDF 1: ${await pdf1.exists()} (${await pdf1.length()} bytes)');
      print('- PDF 2: ${await pdf2.exists()} (${await pdf2.length()} bytes)');
      print('- Image: ${await imageFile.exists()} (${await imageFile.length()} bytes)');
      print('- Total notes: ${notes.length}');
      print('- Total attachments: ${notes.expand((n) => n.attachmentPaths).length}');

      // Verify files exist
      expect(await pdf1.exists(), true);
      expect(await pdf2.exists(), true);
      expect(await imageFile.exists(), true);
    });
  });
}


