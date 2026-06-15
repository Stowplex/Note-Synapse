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
}
