import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:uuid/uuid.dart';
import '../../models/note.dart';
import '../../utils/file_utils.dart';

enum ClipOutputFormat { pdf, inlineImages }

/// Writes bytes to private storage; returns the relative `attachments/...` path.
typedef AttachmentWriter = Future<String> Function(
    Uint8List bytes, String fileName);

/// Renders ordered page PNGs into a single PDF byte buffer.
typedef PdfRenderer = Future<Uint8List> Function(List<Uint8List> pageImagesPng);

/// Max width (px) for an embedded PDF page. Full-res frames (often 1080p–4K)
/// rasterize into huge in-memory bitmaps; capping bounds memory so a clip with
/// many pages doesn't OOM the device.
const int _pdfMaxPageWidth = 1600;

/// Builds the PDF on whatever isolate calls it (used via [compute] in
/// production so the heavy decode/rasterize never blocks the UI thread).
/// Each page is downscaled to [_pdfMaxPageWidth] and re-encoded as JPEG to keep
/// peak memory and the output file bounded. Top-level so it is isolate-sendable.
Future<Uint8List> renderWorldClipPdf(List<Uint8List> pages) async {
  final doc = pw.Document();
  for (final png in pages) {
    var bytes = png;
    final decoded = img.decodeImage(png);
    if (decoded != null && decoded.width > _pdfMaxPageWidth) {
      final resized = img.copyResize(decoded, width: _pdfMaxPageWidth);
      bytes = Uint8List.fromList(img.encodeJpg(resized, quality: 85));
    }
    final image = pw.MemoryImage(bytes);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(12),
      build: (context) =>
          pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
    ));
  }
  return doc.save();
}

/// Compiles ordered, fully-corrected page images into a Note (not persisted).
/// The caller persists via AppProvider.addNote(note).
class ClipCompiler {
  final AttachmentWriter _writeAttachment;
  final PdfRenderer _renderPdf;

  ClipCompiler({AttachmentWriter? writeAttachment, PdfRenderer? pdfRenderer})
      : _writeAttachment = writeAttachment ??
            ((bytes, name) => FileUtils.saveFileToPrivateStorage(bytes, name)),
        // Default: render in a background isolate so a large clip's PDF build
        // can't ANR the UI thread.
        _renderPdf = pdfRenderer ?? ((pages) => compute(renderWorldClipPdf, pages));

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
          // The note renderer resolves image links by base name against the
          // attachments dir, so the markdown must NOT include the
          // "attachments/" prefix that saveFileToPrivateStorage returns.
          final fileName = path.split('/').last;
          buf.writeln('![clip ${i + 1}]($fileName)');
          buf.writeln();
        }
        content = buf.toString().trimRight();
        break;
      case ClipOutputFormat.pdf:
        final pdfBytes = await _renderPdf(pageImagesPng);
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
}
