// Unit tests for the extracted search-result presentation logic (plan §1.6):
// source-provenance badge derivation and first-run index banner visibility.

import 'package:flutter_test/flutter_test.dart';

import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:note_synapse/utils/search_result_presentation.dart';

void main() {
  group('deriveSearchBadge', () {
    test('note_body has no badge', () {
      expect(
        deriveSearchBadge(sourceType: 'note_body'),
        const SearchSourceBadge(SearchBadgeKind.none),
      );
    });

    test('meta maps to the Tag badge', () {
      expect(
        deriveSearchBadge(sourceType: 'meta'),
        const SearchSourceBadge(SearchBadgeKind.tag),
      );
    });

    test('subnote and annotation map to their badges', () {
      expect(
        deriveSearchBadge(sourceType: 'subnote'),
        const SearchSourceBadge(SearchBadgeKind.subnote),
      );
      expect(
        deriveSearchBadge(sourceType: 'annotation'),
        const SearchSourceBadge(SearchBadgeKind.annotation),
      );
    });

    test('attachment_text with a page is a PDF page badge (1-based)', () {
      expect(
        deriveSearchBadge(sourceType: 'attachment_text', page: 4),
        const SearchSourceBadge(SearchBadgeKind.pdfPage, page: 4),
      );
    });

    test('attachment_text without a page degrades to Attachment', () {
      expect(
        deriveSearchBadge(sourceType: 'attachment_text'),
        const SearchSourceBadge(SearchBadgeKind.attachment),
      );
    });

    test('attachment_ocr: paged is PDF page, page-less is Image', () {
      expect(
        deriveSearchBadge(sourceType: 'attachment_ocr', page: 7),
        const SearchSourceBadge(SearchBadgeKind.pdfPage, page: 7),
      );
      expect(
        deriveSearchBadge(sourceType: 'attachment_ocr'),
        const SearchSourceBadge(SearchBadgeKind.image),
      );
    });

    test('figure is Image', () {
      expect(
        deriveSearchBadge(sourceType: 'figure', page: 2),
        const SearchSourceBadge(SearchBadgeKind.image),
      );
    });

    test('unknown sourceType degrades to no badge', () {
      expect(
        deriveSearchBadge(sourceType: 'something_new', page: 3),
        const SearchSourceBadge(SearchBadgeKind.none),
      );
    });
  });

  group('shouldShowIndexBanner', () {
    const running = IndexProgress(
      done: 3,
      total: 10,
      stage: NoteIndexService.stageChunks,
      running: true,
    );
    const finished = IndexProgress(
      done: 10,
      total: 10,
      stage: NoteIndexService.stageChunks,
      running: false,
    );

    test('visible while running and not dismissed', () {
      expect(
        shouldShowIndexBanner(progress: running, dismissed: false),
        isTrue,
      );
    });

    test('hidden when dismissed, even while running', () {
      expect(
        shouldShowIndexBanner(progress: running, dismissed: true),
        isFalse,
      );
    });

    test('auto-hides at completion', () {
      expect(
        shouldShowIndexBanner(progress: finished, dismissed: false),
        isFalse,
      );
    });

    test('hidden while idle (backfill never started or already complete)', () {
      expect(
        shouldShowIndexBanner(progress: IndexProgress.idle, dismissed: false),
        isFalse,
      );
    });

    test('hidden while the dismissal flag is still unknown (null)', () {
      // The persisted flag is read asynchronously on mount; until it lands the
      // banner must not render, or an already-dismissed banner flashes.
      expect(
        shouldShowIndexBanner(progress: running, dismissed: null),
        isFalse,
      );
      expect(
        shouldShowIndexBanner(progress: finished, dismissed: null),
        isFalse,
      );
    });

    test('appears once the read resolves to "not dismissed"', () {
      expect(
        shouldShowIndexBanner(progress: running, dismissed: null),
        isFalse,
      );
      expect(
        shouldShowIndexBanner(progress: running, dismissed: false),
        isTrue,
      );
    });

    test('stays hidden once the read resolves to "dismissed"', () {
      expect(
        shouldShowIndexBanner(progress: running, dismissed: null),
        isFalse,
      );
      expect(
        shouldShowIndexBanner(progress: running, dismissed: true),
        isFalse,
      );
    });
  });

  group('indexProgressPercent', () {
    test('0 when total unknown', () {
      expect(indexProgressPercent(IndexProgress.idle), 0);
    });

    test('whole-number percent of done/total', () {
      const p = IndexProgress(
        done: 62,
        total: 100,
        stage: NoteIndexService.stageChunks,
        running: true,
      );
      expect(indexProgressPercent(p), 62);
      const third = IndexProgress(
        done: 1,
        total: 3,
        stage: NoteIndexService.stageChunks,
        running: true,
      );
      expect(indexProgressPercent(third), 33);
    });

    test('clamped to 100 when done overshoots total', () {
      const p = IndexProgress(
        done: 12,
        total: 10,
        stage: NoteIndexService.stageChunks,
        running: true,
      );
      expect(indexProgressPercent(p), 100);
    });
  });
}
