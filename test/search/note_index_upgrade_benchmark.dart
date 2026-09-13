// Manual diagnostic, deliberately outside the automatic *_test.dart suite:
// flutter test --no-pub test/search/note_index_upgrade_benchmark.dart
//
// Uses the application's desktop SQLite factory and a real temporary DB.
// Timings include lexical indexing and the unchanged attachment sweeps;
// native PDF/OCR processing, embedding API calls, and cloud transfers are
// excluded. These debug desktop measurements are not phone release timings.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/attachment_text_extractor.dart';
import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'ocr_test_stubs.dart';

void main() {
  for (final count in [1000, 2000]) {
    test(
      'index $count populated legacy notes',
      () async {
        final service = DatabaseService.createNew();
        final db = await service.database;
        final dbPath = db.path;
        final body =
            'Historical note content with searchable context.\n\n' * 80;
        final subnote = 'Imported supporting detail for this note.\n\n' * 30;
        final annotation =
            'Saved annotation about a historical document.\n\n' * 20;
        await db.transaction((txn) async {
          for (var start = 0; start < count; start += 100) {
            final batch = txn.batch();
            for (var i = start; i < start + 100 && i < count; i++) {
              final id = 'legacy-$i';
              batch.insert('notes', {
                'id': id,
                'title': 'Historical note $i',
                'content': '$body\nlastbodytoken$i',
                'type': 'note',
                'createdAt': 1000 + i,
                'updatedAt': 2000 + i,
              });
              for (var child = 0; child < 2; child++) {
                batch.insert('subnotes', {
                  'id': 'sub-$i-$child',
                  'noteId': id,
                  'name': 'Transcript $child',
                  'content': subnote,
                  'createdAt': 1000 + child,
                  'isCompleted': 0,
                });
                batch.insert('attachments', {
                  'id': 'attachment-$i-$child',
                  'noteId': id,
                  'fileName': 'document-$child.txt',
                  'filePath': '/benchmark/document-$i-$child.txt',
                  'fileType': 'txt',
                  'isRelativePath': 0,
                  'createdAt': 1000 + child,
                });
              }
              batch.insert('note_annotations', {
                'id': 'annotation-$i',
                'attachment_id': 'attachment-$i-0',
                'content': annotation,
                'attachment_paths': '[]',
                'created_at': '2026-01-01T00:00:00.000',
              });
            }
            await batch.commit(noResult: true);
          }
        });
        final indexer = NoteIndexService(
          service,
          changeNotifier: DataChangeNotifier(),
          extractor: AttachmentTextExtractor(
            service,
            pageCapLoader: () async => 100,
          ),
          ocrExtractor: stubOcrExtractor(service),
          figureExtractor: stubFigureExtractor(),
          figuresEnabledLoader: () async => false,
        );
        addTearDown(() async {
          await indexer.pause();
          indexer.dispose();
          await service.close();
          await deleteDatabase(dbPath);
        });

        final watch = Stopwatch()..start();
        await indexer.backfillAll();
        final initialMs = watch.elapsedMilliseconds;
        expect(indexer.debugBackfillNotesChunked, count);
        final chunkCount =
            (await db.rawQuery(
                  'SELECT COUNT(*) AS count FROM search_chunks',
                )).single['count']
                as int;
        expect(await indexer.isBackfillComplete(), isTrue);

        indexer.debugBackfillNotesChunked = 0;
        watch.reset();
        await indexer.backfillAll();
        final repeatMs = watch.elapsedMilliseconds;
        watch.stop();
        expect(indexer.debugBackfillNotesChunked, 0);
        final metrics = {
          'notes': count,
          'subnotes': count * 2,
          'attachments': count * 2,
          'annotations': count,
          'sourceCharactersApprox':
              count * (body.length + 2 * subnote.length + annotation.length),
          'chunks': chunkCount,
          'initialMs': initialMs,
          'unchangedSweepMs': repeatMs,
          'unchangedNotesRechunked': indexer.debugBackfillNotesChunked,
          'largestBatchBytes': indexer.debugBackfillLargestBatchBytes,
        };
        // ignore: avoid_print -- manual benchmark emits machine-readable data.
        print('INDEX_UPGRADE_BENCH ${jsonEncode(metrics)}');
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}
