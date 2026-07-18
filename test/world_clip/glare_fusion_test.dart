import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:note_synapse/services/world_clip/glare_fusion.dart';

Uint8List _encodePng(cv.Mat mat) {
  final (_, png) = cv.imencode('.png', mat);
  return png;
}

/// A field of random-sized, random-toned rectangles gives ORB plenty of
/// stable, non-repeating corner features to match, so alignment succeeds
/// deterministically without needing a real camera. A regular pattern (e.g.
/// a checkerboard) is the wrong fixture here: its translational symmetry
/// makes many keypoints' descriptors ambiguous between equally-good
/// candidate matches, which fails Lowe's ratio test and starves the
/// good-match count. Fixed seed keeps the fixture reproducible.
cv.Mat _texturedPattern({int size = 480, int seed = 7}) {
  final mat = cv.Mat.create(rows: size, cols: size, type: cv.MatType.CV_8UC3);
  final rnd = math.Random(seed);
  for (var i = 0; i < 300; i++) {
    final w = 8 + rnd.nextInt(36);
    final h = 8 + rnd.nextInt(36);
    final x = rnd.nextInt(size - w);
    final y = rnd.nextInt(size - h);
    cv.rectangle(
      mat,
      cv.Rect(x, y, w, h),
      cv.Scalar.all(rnd.nextInt(256).toDouble()),
      thickness: -1,
    );
  }
  return mat;
}

int _blueAt(Uint8List imgBytes, int x, int y) {
  final mat = cv.imdecode(imgBytes, cv.IMREAD_COLOR);
  try {
    return mat.data[(y * mat.cols + x) * mat.channels];
  } finally {
    mat.dispose();
  }
}

(int, int, int) _bgrAt(Uint8List imgBytes, int x, int y) {
  final mat = cv.imdecode(imgBytes, cv.IMREAD_COLOR);
  try {
    final idx = (y * mat.cols + x) * mat.channels;
    return (mat.data[idx], mat.data[idx + 1], mat.data[idx + 2]);
  } finally {
    mat.dispose();
  }
}

void main() {
  group('fuseAntiGlare', () {
    test('throws when given no shots', () {
      expect(() => fuseAntiGlare([]), throwsA(isA<GlareFusionException>()));
    });

    test('returns the single shot unchanged when only one is given', () {
      final page = _texturedPattern();
      final png = _encodePng(page);
      page.dispose();
      expect(fuseAntiGlare([png]), same(png));
    });

    test('throws when the reference shot cannot be decoded', () {
      final garbage = Uint8List.fromList([1, 2, 3, 4]);
      expect(
        () => fuseAntiGlare([garbage, garbage]),
        throwsA(isA<GlareFusionException>()),
      );
    });

    test('drops an undecodable non-reference shot and falls back to the reference', () {
      final page = _texturedPattern();
      final refPng = _encodePng(page);
      page.dispose();
      final result = fuseAntiGlare([refPng, Uint8List.fromList([9, 9, 9])]);
      expect(result, same(refPng));
    });

    test('drops a candidate with genuinely unrelated content (no real feature matches)', () {
      final refMat = _texturedPattern(seed: 7);
      final refPng = _encodePng(refMat);
      refMat.dispose();
      final unrelatedMat = _texturedPattern(seed: 99);
      final unrelatedPng = _encodePng(unrelatedMat);
      unrelatedMat.dispose();

      final result = fuseAntiGlare([refPng, unrelatedPng]);
      expect(result, same(refPng)); // nothing usable to fuse with
    });

    test('aligns a candidate that is scaled and shifted (camera moved closer)', () {
      const size = 480;
      final base = _texturedPattern(size: size);
      final refPng = _encodePng(base);

      // Simulate the camera moving closer: the same content, scaled up ~1.4x
      // and re-cropped to the frame — a pure feature-matching problem a
      // document-quad-corner mapping can't generally solve but ORB +
      // homography should.
      final scaleMat = cv.getRotationMatrix2D(cv.Point2f(size / 2, size / 2), 0, 1.4);
      final scaled = cv.warpAffine(base, scaleMat, (size, size));
      final scaledPng = _encodePng(scaled);
      scaled.dispose();
      base.dispose();

      // Fixed dark spot near the frame center — present in both, at
      // slightly different pixel positions because of the scale change; the
      // alignment must reconcile that before the blend can agree on it.
      final fusedJpg = fuseAntiGlare([refPng, scaledPng]);
      expect(fusedJpg, isNot(same(refPng))); // the candidate DID align and fuse
    });

    test('median-fuses glare spots at different locations out of the result', () {
      const size = 480;
      final base = _texturedPattern(size: size);
      // Fixed, non-overlapping spots — forced to a known dark-ish baseline
      // distinct from the glare (255) so the "glare removed" assertion is
      // unambiguous regardless of the random texture underneath.
      final patch1 = cv.Rect(120, 96, 40, 40);
      final patch2 = cv.Rect(312, 288, 40, 40);
      cv.rectangle(base, patch1, cv.Scalar.all(10), thickness: -1);
      cv.rectangle(base, patch2, cv.Scalar.all(10), thickness: -1);
      final refPng = _encodePng(base);

      cv.Mat glareShot(cv.Rect patch) {
        final m = base.clone();
        cv.rectangle(m, patch, cv.Scalar.all(255), thickness: -1);
        return m;
      }

      final shot1 = glareShot(patch1);
      final shot1Png = _encodePng(shot1);
      shot1.dispose();
      final shot2 = glareShot(patch2);
      final shot2Png = _encodePng(shot2);
      shot2.dispose();
      base.dispose();

      const p1x = 130, p1y = 106;
      const p2x = 320, p2y = 296;

      // Sanity: those spots are genuinely black originally, and genuinely
      // lit up (glare) in their own raw shot.
      expect(_blueAt(refPng, p1x, p1y), lessThanOrEqualTo(10));
      expect(_blueAt(refPng, p2x, p2y), lessThanOrEqualTo(10));
      expect(_blueAt(shot1Png, p1x, p1y), greaterThan(240));
      expect(_blueAt(shot2Png, p2x, p2y), greaterThan(240));

      final fusedJpg = fuseAntiGlare([refPng, shot1Png, shot2Png]);
      expect(fusedJpg, isNot(same(refPng)));

      // Only 1 of 3 shots is bright at each spot — the medoid across the
      // reference + both aligned shots must be close to the ORIGINAL dark
      // baseline, not the injected highlight.
      expect(_blueAt(fusedJpg, p1x, p1y), lessThan(80));
      expect(_blueAt(fusedJpg, p2x, p2y), lessThan(80));
    });

    // Regression: with exactly 2 valid samples at a pixel (the reference plus
    // a single successfully-aligned shot — the common case when a page has
    // only 2 shots, or a 3rd fails to align), there's no majority to vote
    // with, so the fallback must lean toward the darker (non-glare) sample
    // rather than whichever is brighter.
    test('with only 2 usable shots, glare in either one is suppressed toward the dark value', () {
      const size = 480;
      final base = _texturedPattern(size: size);
      final patch = cv.Rect(120, 96, 40, 40);
      cv.rectangle(base, patch, cv.Scalar.all(10), thickness: -1);
      final refPng = _encodePng(base);

      final glared = base.clone();
      cv.rectangle(glared, patch, cv.Scalar.all(255), thickness: -1);
      final glaredPng = _encodePng(glared);
      glared.dispose();
      base.dispose();

      const px = 130, py = 106;
      expect(_blueAt(refPng, px, py), lessThanOrEqualTo(10));
      expect(_blueAt(glaredPng, px, py), greaterThan(240));

      // Glare in the second (non-reference) shot.
      final fused1 = fuseAntiGlare([refPng, glaredPng]);
      expect(_blueAt(fused1, px, py), lessThanOrEqualTo(10));

      // Glare in the reference itself instead — same 2-sample scenario,
      // opposite arrangement, to confirm the fix isn't order-dependent.
      final fused2 = fuseAntiGlare([glaredPng, refPng]);
      expect(_blueAt(fused2, px, py), lessThanOrEqualTo(10));
    });

    test('selects a whole real pixel rather than per-channel-voting into a fabricated color', () {
      const size = 480;
      final base = _texturedPattern(size: size);
      final patch = cv.Rect(120, 96, 40, 40);

      cv.Mat withPatchColor(cv.Scalar bgr) {
        final m = base.clone();
        cv.rectangle(m, patch, bgr, thickness: -1);
        return m;
      }

      // Three shots, otherwise identical, differing only in this patch's
      // color — no misalignment at all, isolating the blend rule itself. A
      // per-channel median of these three would independently pick each
      // channel's own middle value: B from [200,50,50]->50, G from
      // [50,200,50]->50, R from [50,50,200]->50 — i.e. (50,50,50), a gray
      // that appears in NONE of the three shots.
      final pngBlue = _encodePng(withPatchColor(cv.Scalar(200, 50, 50, 0)));
      final pngGreen = _encodePng(withPatchColor(cv.Scalar(50, 200, 50, 0)));
      final pngRed = _encodePng(withPatchColor(cv.Scalar(50, 50, 200, 0)));
      base.dispose();

      final fusedJpg = fuseAntiGlare([pngBlue, pngGreen, pngRed]);
      final (b, g, r) = _bgrAt(fusedJpg, 130, 106);

      // Must land close to a REAL source pixel, not the fabricated (50,50,50)
      // a per-channel vote would have produced.
      final fabricated = (b - 50).abs() < 10 && (g - 50).abs() < 10 && (r - 50).abs() < 10;
      expect(
        fabricated,
        isFalse,
        reason: 'got ($b,$g,$r) — matches the fabricated per-channel-median color',
      );
    });

    // The other headline feature: with several shots, a large occluder
    // present in only a MINORITY of them (a hand pressing the page flat,
    // repositioned between shots) should be voted out just like glare is —
    // recovering the real page content underneath from the shots that don't
    // have it there.
    test('removes a large occluder (e.g. a hand) that only appears in a minority of shots', () {
      const size = 480;
      final base = _texturedPattern(size: size);
      // A patch far larger than a glare highlight — representative of a
      // hand/thumb pressing a corner flat.
      final handSpot = cv.Rect(150, 150, 120, 140);
      cv.rectangle(base, handSpot, cv.Scalar.all(15), thickness: -1);
      final refPng = _encodePng(base); // no hand — "center" shot
      final cleanShot2Png = _encodePng(base.clone()); // no hand either

      // One shot WITH a hand-colored blob (skin-tone-ish, not glare-bright)
      // covering the same spot, simulating the user's hand pressing the
      // page flat in that guided position.
      final handShot = base.clone();
      cv.rectangle(handShot, handSpot, cv.Scalar(90, 130, 190, 0), thickness: -1);
      final handShotPng = _encodePng(handShot);
      handShot.dispose();
      base.dispose();

      const px = 200, py = 200; // inside handSpot

      final fusedJpg = fuseAntiGlare([refPng, cleanShot2Png, handShotPng]);

      // 1 of 3 shots shows the hand there, 2 show the real page — the
      // medoid must side with the (majority-agreeing) real page content,
      // not the hand color.
      final (b, g, r) = _bgrAt(fusedJpg, px, py);
      final looksLikeHand = (b - 90).abs() < 15 && (g - 130).abs() < 15 && (r - 190).abs() < 15;
      expect(looksLikeHand, isFalse, reason: 'got ($b,$g,$r) — the hand was not removed');
      expect(_blueAt(fusedJpg, px, py), lessThan(60));
    });
  });
}
