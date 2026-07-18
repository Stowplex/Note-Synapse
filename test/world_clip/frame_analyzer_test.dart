import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:note_synapse/services/world_clip/frame_analyzer.dart';

import 'scroll_document_fixture.dart';

void main() {
  test('recovers a vertical scroll chain with correct sign', () {
    final doc = makeDocument(240, 3000);
    final analyzer = StreamingFrameAnalyzer();
    final offsets = [0, 60, 120, 120, 180]; // down 60/frame with one hold
    final results = [
      for (var i = 0; i < offsets.length; i++)
        analyzer.add(i * 200, frameAt(doc, offsets[i])),
    ];
    analyzer.dispose();
    doc.dispose();

    expect(results[0].shiftKnown, isFalse); // no previous frame
    for (final r in results.skip(1)) {
      expect(r.shiftKnown, isTrue);
    }
    expect(results[1].dyPx, closeTo(60, 2));
    expect(results[1].dxPx.abs(), lessThan(2));
    expect(results[2].dyPx, closeTo(60, 2));
    expect(results[3].dyPx, closeTo(0, 1)); // hold
    expect(results[3].diffFromPrev, lessThanOrEqualTo(kIdenticalDiff));
    expect(results[4].dyPx, closeTo(60, 2));
  });

  test('recovers horizontal pan (bulletin-board case)', () {
    final doc = makeDocument(1200, 500);
    final analyzer = StreamingFrameAnalyzer();
    Uint8List at(int x) {
      final roi = doc.region(cv.Rect(x, 40, 240, 420));
      final view = roi.clone();
      roi.dispose();
      final bgr = cv.cvtColor(view, cv.COLOR_GRAY2BGR);
      view.dispose();
      final (_, png) = cv.imencode('.png', bgr);
      bgr.dispose();
      return png;
    }

    analyzer.add(0, at(0));
    final r = analyzer.add(200, at(50));
    analyzer.dispose();
    doc.dispose();
    expect(r.shiftKnown, isTrue);
    expect(r.dxPx, closeTo(50, 2));
    expect(r.dyPx.abs(), lessThan(2));
  });

  test('content replacement yields an unknown shift', () {
    final docA = makeDocument(240, 500, seed: 1);
    final docB = makeDocument(240, 500, seed: 999);
    final analyzer = StreamingFrameAnalyzer();
    analyzer.add(0, frameAt(docA, 0));
    final r = analyzer.add(200, frameAt(docB, 0));
    analyzer.dispose();
    docA.dispose();
    docB.dispose();
    expect(r.shiftKnown, isFalse);
    expect(r.diffFromPrev, greaterThan(0.08));
  });

  test('fixed chrome bars are reported as static rows', () {
    final doc = makeDocument(240, 3000);
    final analyzer = StreamingFrameAnalyzer();
    for (var i = 0; i < 8; i++) {
      analyzer.add(
        i * 200,
        frameAt(doc, i * 60, chromeTop: 40, chromeBottom: 30),
      );
    }
    final chrome = analyzer.staticChrome();
    analyzer.dispose();
    doc.dispose();
    expect(chrome.topRows, inInclusiveRange(35, 45));
    expect(chrome.bottomRows, inInclusiveRange(25, 35));
  });

  test('chrome does not defeat the shift estimate', () {
    final doc = makeDocument(240, 3000);
    final analyzer = StreamingFrameAnalyzer();
    analyzer.add(0, frameAt(doc, 0, chromeTop: 40, chromeBottom: 30));
    final r = analyzer.add(
      200,
      frameAt(doc, 70, chromeTop: 40, chromeBottom: 30),
    );
    analyzer.dispose();
    doc.dispose();
    expect(r.shiftKnown, isTrue);
    expect(r.dyPx, closeTo(70, 3));
  });

  test('static clip reports no chrome (nothing to distinguish)', () {
    final doc = makeDocument(240, 3000);
    final analyzer = StreamingFrameAnalyzer();
    for (var i = 0; i < 5; i++) {
      analyzer.add(i * 200, frameAt(doc, 0));
    }
    final chrome = analyzer.staticChrome();
    analyzer.dispose();
    doc.dispose();
    expect(chrome.topRows, 0);
    expect(chrome.bottomRows, 0);
  });
}
