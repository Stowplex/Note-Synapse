import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:uuid/uuid.dart';
import '../../models/note.dart';
import '../../utils/file_utils.dart';

enum ClipOutputFormat { pdf, inlineImages }

/// Writes bytes to private storage; returns the relative `attachments/...` path.
typedef AttachmentWriter = Future<String> Function(
    Uint8List bytes, String fileName);

/// Compiles ordered, fully-corrected page images into a Note (not persisted).
/// The caller persists via AppProvider.addNote(note).
class ClipCompiler {
  final AttachmentWriter _writeAttachment;

  ClipCompiler({AttachmentWriter? writeAttachment})
      : _writeAttachment = writeAttachment ??
            ((bytes, name) => FileUtils.saveFileToPrivateStorage(bytes, name));

  Future<Note> compile({
    required String title,
    required List<Uint8List> pageImagesPng,
    required ClipOutputFormat format,
  }) async {
    final now = DateTime.now();
    final stamp = now.millisecondsSinceEpoch;

    final List<String> attachmentPaths;
    final String content;

    switch (format) {
      case ClipOutputFormat.inlineImages:
        attachmentPaths = [];
        final buf = StringBuffer();
        for (var i = 0; i < pageImagesPng.length; i++) {
          final path = await _writeAttachment(
              pageImagesPng[i], 'worldclip_${stamp}_$i.png');
          attachmentPaths.add(path);
          buf.writeln('![clip ${i + 1}]($path)');
          buf.writeln();
        }
        content = buf.toString().trimRight();
        break;
      case ClipOutputFormat.pdf:
        final pdfBytes = await _buildPdf(pageImagesPng);
        final path = await _writeAttachment(pdfBytes, 'worldclip_$stamp.pdf');
        attachmentPaths = [path];
        content = '';
        break;
    }

    return Note(
      id: const Uuid().v4(),
      title: title,
      content: content,
      type: NoteType.note,
      createdAt: now,
      updatedAt: now,
      tags: const ['world-clip'],
      attachmentPaths: attachmentPaths,
    );
  }

  Future<Uint8List> _buildPdf(List<Uint8List> pages) async {
    final doc = pw.Document();
    for (final png in pages) {
      final image = pw.MemoryImage(png);
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(12),
        build: (context) =>
            pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
      ));
    }
    return doc.save();
  }
}
