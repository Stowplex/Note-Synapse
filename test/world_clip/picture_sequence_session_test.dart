import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/world_clip/glare_fusion.dart';
import 'package:note_synapse/services/world_clip/picture_sequence_session.dart';

Uint8List _bytes(int tag) => Uint8List.fromList([tag]);

void main() {
  late Directory tmp;
  late List<List<Uint8List>> fuseCalls;
  late PictureSequenceSession session;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('picture_sequence_session_test');
    fuseCalls = [];
    session = PictureSequenceSession(
      fuse: (shots) async {
        fuseCalls.add(shots);
        return Uint8List.fromList([0xFF]); // stand-in "fused" bytes
      },
      writePage: (bytes) async {
        final f = File('${tmp.path}/${DateTime.now().microsecondsSinceEpoch}_${bytes.first}.jpg');
        await f.writeAsBytes(bytes);
        return f;
      },
    );
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('single-shot (non anti-glare) pages', () {
    test('one accepted shot completes the page immediately', () {
      expect(session.acceptShot(_bytes(1)), isTrue);
    });

    test('finishPage does not call fuse for a single-shot page', () async {
      session.acceptShot(_bytes(1));
      final (file, usedFallback) = await session.finishPage();
      expect(fuseCalls, isEmpty);
      expect(usedFallback, isFalse);
      expect(await file.readAsBytes(), _bytes(1));
      expect(session.pages, [file]);
    });
  });

  group('anti-glare pages', () {
    setUp(() => session.setAntiGlare(true));

    test('requires kAntiGlareShotsPerPage shots before completing', () {
      expect(kAntiGlareShotsPerPage, 5);
      expect(kAntiGlareSteps, hasLength(kAntiGlareShotsPerPage));
      expect(session.acceptShot(_bytes(1)), isFalse);
      expect(session.acceptShot(_bytes(2)), isFalse);
      expect(session.acceptShot(_bytes(3)), isFalse);
      expect(session.acceptShot(_bytes(4)), isFalse);
      expect(session.acceptShot(_bytes(5)), isTrue);
    });

    test('finishPage calls fuse with all the accepted shots, in order', () async {
      session.acceptShot(_bytes(1));
      session.acceptShot(_bytes(2));
      session.acceptShot(_bytes(3));
      session.acceptShot(_bytes(4));
      session.acceptShot(_bytes(5));
      await session.finishPage();
      expect(fuseCalls, [
        [_bytes(1), _bytes(2), _bytes(3), _bytes(4), _bytes(5)],
      ]);
    });

    test('liveShotCount reflects shots accepted so far, mid-page', () {
      expect(session.liveShotCount, 0);
      session.acceptShot(_bytes(1));
      expect(session.liveShotCount, 1);
      expect(session.midPage, isTrue);
    });

    test('cannot toggle anti-glare mid-page', () {
      session.acceptShot(_bytes(1));
      expect(session.canToggleAntiGlare, isFalse);
      session.setAntiGlare(false); // no-op: still mid anti-glare page
      expect(session.antiGlare, isTrue);
    });

    test('falls back to the first shot when fuse throws GlareFusionException', () async {
      session = PictureSequenceSession(
        fuse: (_) async => throw GlareFusionException('boom'),
        writePage: (bytes) async {
          final f = File('${tmp.path}/fallback_${bytes.first}.jpg');
          await f.writeAsBytes(bytes);
          return f;
        },
      );
      session.setAntiGlare(true);
      session.acceptShot(_bytes(1));
      session.acceptShot(_bytes(2));
      session.acceptShot(_bytes(3));
      session.acceptShot(_bytes(4));
      session.acceptShot(_bytes(5));
      final (file, usedFallback) = await session.finishPage();
      expect(usedFallback, isTrue);
      expect(await file.readAsBytes(), _bytes(1)); // first shot, unfused
    });
  });

  group('flash', () {
    test('defaults to off', () {
      expect(session.flashOn, isFalse);
    });

    test('setFlashOn is a global toggle, unaffected by page operations', () async {
      session.setFlashOn(true);
      expect(session.flashOn, isTrue);

      // Survives an ordinary page completing...
      session.acceptShot(_bytes(1));
      await session.finishPage();
      expect(session.flashOn, isTrue);

      // ...an anti-glare page's multi-shot sequence...
      session.setAntiGlare(true);
      for (var i = 2; i <= 6; i++) {
        session.acceptShot(_bytes(i));
      }
      await session.finishPage();
      expect(session.flashOn, isTrue);

      // ...and a retake/discard.
      session.retakePage(0);
      for (var i = 7; i <= 11; i++) {
        session.acceptShot(_bytes(i));
      }
      await session.finishPage();
      expect(session.flashOn, isTrue);
      session.discardPage(0);
      expect(session.flashOn, isTrue);
    });

    test('can be turned back off', () {
      session.setFlashOn(true);
      session.setFlashOn(false);
      expect(session.flashOn, isFalse);
    });
  });

  group('retake / discard', () {
    test('discardPage removes a finished page from the sequence', () async {
      session.acceptShot(_bytes(1));
      await session.finishPage();
      session.acceptShot(_bytes(2));
      await session.finishPage();
      expect(session.pages, hasLength(2));

      session.discardPage(0);
      expect(session.pages, hasLength(1));
      expect(await session.pages.single.readAsBytes(), _bytes(2));
    });

    test('retakePage replaces that page in place on the next finishPage', () async {
      session.acceptShot(_bytes(1));
      await session.finishPage();
      session.acceptShot(_bytes(2));
      await session.finishPage();
      final originalSecond = session.pages[1];

      session.retakePage(1);
      expect(session.retakeIndex, 1);
      session.acceptShot(_bytes(9));
      await session.finishPage();

      expect(session.pages, hasLength(2)); // replaced, not appended
      expect(session.pages[1], isNot(same(originalSecond)));
      expect(await session.pages[1].readAsBytes(), _bytes(9));
      expect(session.retakeIndex, isNull); // cleared after finishing
    });

    test('discarding a page before a pending retake target shifts the index down', () async {
      session.acceptShot(_bytes(1));
      await session.finishPage();
      session.acceptShot(_bytes(2));
      await session.finishPage();
      session.acceptShot(_bytes(3));
      await session.finishPage();

      session.retakePage(2); // targeting the third page
      session.discardPage(0); // remove the first — third page shifts to index 1
      expect(session.retakeIndex, 1);

      session.acceptShot(_bytes(9));
      await session.finishPage();
      expect(session.pages, hasLength(2));
      expect(await session.pages[1].readAsBytes(), _bytes(9));
    });

    test('discarding the pending retake target itself clears retakeIndex', () async {
      session.acceptShot(_bytes(1));
      await session.finishPage();
      session.retakePage(0);
      session.discardPage(0);
      expect(session.retakeIndex, isNull);
      expect(session.pages, isEmpty);
    });
  });
}
