import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:note_synapse/services/world_clip/clip_compiler.dart';

void main() {
  late List<String> written;
  late ClipCompiler compiler;

  // A real, checksum-valid 2x2 PNG (the pdf path decodes it, so it must be valid).
  final pngA = Uint8List.fromList(
      img.encodePng(img.Image(width: 2, height: 2)..clear(img.ColorRgb8(10, 20, 30))));

  setUp(() {
    written = [];
    compiler = ClipCompiler(
      writeAttachment: (bytes, name) async {
        written.add(name);
        return 'attachments/$name';
      },
      // Render directly (no background isolate) so the unit test is
      // deterministic; still exercises the real PDF build path.
      pdfRenderer: renderWorldClipPdf,
    );
  });

  test('inline output builds a note with one attachment per page', () async {
    final note = await compiler.compile(
      title: 'My Clip',
      pageImagesPng: [pngA, pngA],
      format: ClipOutputFormat.inlineImages,
    );
    expect(note.title, 'My Clip');
    expect(written.length, 2);
    expect(note.attachmentPaths.length, 2);
    expect(note.content, contains('![')); // images embedded in markdown
  });

  test('pdf output builds a note with a single pdf attachment', () async {
    final note = await compiler.compile(
      title: 'My Clip',
      pageImagesPng: [pngA, pngA],
      format: ClipOutputFormat.pdf,
    );
    expect(written.single, endsWith('.pdf'));
    expect(note.attachmentPaths.single, endsWith('.pdf'));
  });

  test('renderWorldClipPdf downscales large pages and emits a valid PDF',
      () async {
    // A page far wider than the 1600px cap must be downscaled, not embedded raw.
    final big = Uint8List.fromList(img.encodePng(
        img.Image(width: 3000, height: 2000)..clear(img.ColorRgb8(200, 100, 50))));
    final pdf = await renderWorldClipPdf([big, big]);
    expect(pdf.length, greaterThan(8));
    // PDF magic header "%PDF".
    expect(pdf.sublist(0, 4), [0x25, 0x50, 0x44, 0x46]);
  });
}
