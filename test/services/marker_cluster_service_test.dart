import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/in_note_marker.dart';
import 'package:note_synapse/services/marker_cluster_service.dart';

void main() {
  NormalizedRect rect(double x, double y, double w, double h) {
    return NormalizedRect(x: x, y: y, w: w, h: h);
  }

  group('MarkerClusterService', () {
    test('keeps far apart circles as separate placements', () {
      final placements = MarkerClusterService.buildPlacementRects([
        rect(0.10, 0.10, 0.12, 0.12),
        rect(0.68, 0.62, 0.14, 0.14),
      ]);

      expect(placements, hasLength(2));
    });

    test('merges same-line underline fragments into one placement', () {
      final placements = MarkerClusterService.buildPlacementRects([
        rect(0.10, 0.52, 0.18, 0.018),
        rect(0.31, 0.525, 0.20, 0.02),
      ]);

      expect(placements, hasLength(1));
      expect(placements.single.w, greaterThan(0.35));
    });

    test('merges stacked underline fragments into one placement', () {
      final placements = MarkerClusterService.buildPlacementRects([
        rect(0.12, 0.40, 0.42, 0.02),
        rect(0.14, 0.46, 0.40, 0.02),
      ]);

      expect(placements, hasLength(1));
      expect(placements.single.h, greaterThan(0.07));
    });

    test('merges nested circles into one placement', () {
      final placements = MarkerClusterService.buildPlacementRects([
        rect(0.20, 0.20, 0.25, 0.25),
        rect(0.26, 0.26, 0.09, 0.09),
      ]);

      expect(placements, hasLength(1));
      expect(placements.single.w, closeTo(0.25, 0.001));
    });

    test('single mode collapses multiple clusters into one placement', () {
      final placements = MarkerClusterService.buildPlacementRects([
        rect(0.10, 0.10, 0.12, 0.12),
        rect(0.68, 0.62, 0.14, 0.14),
      ], mode: MarkerPlacementMode.single);

      expect(placements, hasLength(1));
      expect(placements.single.w, greaterThan(0.70));
    });

    test('split override is offered only when there are multiple clusters', () {
      expect(
        MarkerClusterService.shouldOfferSplitOverride([
          rect(0.10, 0.10, 0.12, 0.12),
          rect(0.68, 0.62, 0.14, 0.14),
        ]),
        isTrue,
      );
      expect(
        MarkerClusterService.shouldOfferSplitOverride([
          rect(0.10, 0.52, 0.18, 0.018),
          rect(0.31, 0.525, 0.20, 0.02),
        ]),
        isFalse,
      );
    });
  });
}
