// Run from the project root with:
// flutter test --no-pub tool/benchmarks/sync_seed_benchmark_test.dart
// Measures local desktop SQLite seeding only, excluding network/blob uploads.
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/device_identity.dart';
import 'package:note_synapse/services/sync/seq_counter.dart';
import 'package:note_synapse/services/sync/hlc.dart';
import 'package:note_synapse/services/sync/seed_scanner.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  for (final count in [1000, 2000]) {
    test('seed local $count existing notes', () async {
      final service = DatabaseService.createNew();
      addTearDown(service.close);
      final db = await service.database;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (var i = 0; i < count; i++) {
          batch.insert('notes', {
            'id': 'benchmark-$i',
            'title': 'Historical note $i',
            'content': 'Existing source text ' * 50,
            'type': 'note',
            'createdAt': 1000 + i,
            'updatedAt': 2000 + i,
          });
        }
        await batch.commit(noResult: true);
        await txn.delete('sync_touch_log');
      });
      final scanner = SeedScanner(
        service,
        DeviceIdentity(service),
        SeqCounter(service),
        HybridLogicalClock(service),
      );
      final watch = Stopwatch()..start();
      var progressCalls = 0;
      final result = await scanner.scan(onProgress: (_) => progressCalls++);
      watch.stop();
      // Local desktop diagnostic; not a network or native phone estimate.
      print(
        'UPGRADE_BENCH notes=$count seedMs=${watch.elapsedMilliseconds} '
        'operations=${result.operationsSeeded} progress=$progressCalls',
      );
      expect(result.completed, isTrue);
      watch.reset();
      watch.start();
      await scanner.scan();
      watch.stop();
      print('UPGRADE_BENCH notes=$count repeatMs=${watch.elapsedMilliseconds}');
    });
  }
}
