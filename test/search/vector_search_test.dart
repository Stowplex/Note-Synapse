// Unit + integration tests for the vector search layer (plan §2.3):
// float32-LE codec round-trip, VectorMatrix topK vs a brute-force reference,
// incremental patches, the long-lived isolate path over real sqlite, the
// synchronous main-isolate fallback (web), and provider-switch matrix reload.

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/vector_search.dart';

/// Worker that bootstraps normally and then dies on the first real command
/// (errorsAreFatal): stands in for an uncaught error or an OOM kill while
/// the matrix is being materialized.
void dyingWorker(SendPort bootstrap) {
  final commands = ReceivePort();
  bootstrap.send(commands.sendPort);
  commands.listen((message) {
    if (message is SendPort) return; // Reply-port handshake.
    throw StateError('worker died');
  });
}

/// Worker that bootstraps and then never answers anything.
void silentWorker(SendPort bootstrap) {
  final commands = ReceivePort();
  bootstrap.send(commands.sendPort);
  commands.listen((_) {});
}

Float32List _unit(List<double> values) {
  var sum = 0.0;
  for (final v in values) {
    sum += v * v;
  }
  final norm = math.sqrt(sum);
  return Float32List.fromList([for (final v in values) v / norm]);
}

/// Independent reference implementation the isolate/matrix path is checked
/// against (deliberately naive: sort every dot product).
List<int> _bruteForceTopK(
  Map<int, Float32List> corpus,
  Float32List query,
  int k,
) {
  final scored = <(int, double)>[];
  corpus.forEach((chunkId, vector) {
    var dot = 0.0;
    for (var i = 0; i < vector.length; i++) {
      dot += vector[i] * query[i];
    }
    scored.add((chunkId, dot));
  });
  scored.sort((a, b) {
    final byScore = b.$2.compareTo(a.$2);
    if (byScore != 0) return byScore;
    return b.$1.compareTo(a.$1);
  });
  return [for (final entry in scored.take(k)) entry.$1];
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('float32 LE codec', () {
    test('round-trips vectors byte-exactly at float32 precision', () {
      final vector = _unit([0.5, -0.25, 0.125, 3.0]);
      final bytes = encodeVectorFloat32Le(vector);
      expect(bytes.length, vector.length * 4);
      final decoded = decodeVectorFloat32Le(bytes);
      expect(decoded, vector);
    });

    test('decodes from an unaligned buffer view', () {
      final vector = _unit([1.0, 2.0, 3.0, 4.0]);
      final bytes = encodeVectorFloat32Le(vector);
      // Offset by one byte so the Float32List view would be unaligned.
      final padded = Uint8List(bytes.length + 1)
        ..setRange(1, bytes.length + 1, bytes);
      final unaligned = Uint8List.sublistView(padded, 1);
      expect(decodeVectorFloat32Le(unaligned), vector);
    });
  });

  group('VectorMatrix', () {
    test('topK matches a brute-force reference on a random corpus', () {
      final random = math.Random(42);
      final corpus = <int, Float32List>{};
      for (var id = 1; id <= 200; id++) {
        corpus[id] = _unit([
          for (var d = 0; d < 8; d++) random.nextDouble() * 2 - 1,
        ]);
      }
      final matrix = VectorMatrix('test:model:8', 8);
      final packed = Float32List(corpus.length * 8);
      final ids = corpus.keys.toList();
      for (var i = 0; i < ids.length; i++) {
        packed.setRange(i * 8, (i + 1) * 8, corpus[ids[i]]!);
      }
      matrix.loadPacked(ids, packed);
      expect(matrix.length, 200);

      final query = _unit([for (var d = 0; d < 8; d++) random.nextDouble()]);
      final expected = _bruteForceTopK(corpus, query, 10);
      final actual = [for (final hit in matrix.topK(query, 10)) hit.chunkId];
      expect(actual, expected);
    });

    test('scores are cosine similarities (unit vectors → dot product)', () {
      final matrix = VectorMatrix('k', 2)
        ..loadPacked([1, 2], Float32List.fromList([1, 0, 0, 1]));
      final hits = matrix.topK(Float32List.fromList([1, 0]), 2);
      expect(hits.first.chunkId, 1);
      expect(hits.first.score, closeTo(1.0, 1e-6));
      expect(hits.last.score, closeTo(0.0, 1e-6));
    });

    test('upsert adds new rows and replaces existing ones', () {
      final matrix = VectorMatrix('k', 2)
        ..loadPacked([1], Float32List.fromList([1, 0]));
      matrix.upsert(2, Float32List.fromList([0, 1]));
      expect(matrix.length, 2);
      expect(matrix.topK(Float32List.fromList([0, 1]), 1).single.chunkId, 2);

      // Replace chunk 1's vector: it now wins the [0,1] query.
      matrix.upsert(1, Float32List.fromList([0.0, 1.0]));
      final hits = matrix.topK(Float32List.fromList([0, 1]), 2);
      expect(hits.map((h) => h.chunkId).toSet(), {1, 2});
      expect(hits.every((h) => h.score > 0.99), isTrue);
      expect(matrix.length, 2);
    });

    test('upsert ignores off-dimension vectors', () {
      final matrix = VectorMatrix('k', 2)
        ..loadPacked([1], Float32List.fromList([1, 0]));
      matrix.upsert(9, Float32List.fromList([1, 0, 0]));
      expect(matrix.length, 1);
    });

    test('remove deletes rows and keeps the rest queryable', () {
      final matrix = VectorMatrix('k', 2)
        ..loadPacked([1, 2, 3], Float32List.fromList([1, 0, 0, 1, 1, 0]));
      matrix.remove([2, 99]); // 99 unknown: ignored.
      expect(matrix.length, 2);
      final ids = [
        for (final h in matrix.topK(Float32List.fromList([1, 0]), 5)) h.chunkId,
      ];
      expect(ids, [3, 1]);
    });

    test('topK on an empty or dimension-mismatched query returns nothing', () {
      final matrix = VectorMatrix('k', 2);
      expect(matrix.topK(Float32List.fromList([1, 0]), 5), isEmpty);
      matrix.loadPacked([1], Float32List.fromList([1, 0]));
      expect(matrix.topK(Float32List.fromList([1, 0, 0]), 5), isEmpty);
      expect(matrix.topK(Float32List.fromList([1, 0]), 0), isEmpty);
    });
  });

  group('VectorSearch', () {
    late DatabaseService db;

    setUp(() async {
      db = DatabaseService.createNew();
      await db.database;
    });

    tearDown(() async => db.close());

    Future<void> seedChunk(int id, String noteId) async {
      final raw = await db.database;
      await raw.insert('search_chunks', {
        'id': id,
        'chunkKey': '$noteId:note_body:-:$id',
        'noteId': noteId,
        'sourceType': 'note_body',
        'sourceId': null,
        'page': null,
        'seq': id,
        'text': 'chunk $id',
        'meta': null,
        'contentHash': 'h$id',
        'updatedAt': 0,
      });
    }

    Future<void> seedVector(
      int chunkId,
      String providerKey,
      Float32List vector,
    ) async {
      final raw = await db.database;
      await raw.insert('chunk_embeddings', {
        'chunkId': chunkId,
        'providerKey': providerKey,
        'modality': 'text',
        'dims': vector.length,
        'vector': encodeVectorFloat32Le(vector),
        'contentHash': 'h$chunkId',
      });
    }

    test('loads the matrix in a real isolate and answers topK', () async {
      await seedChunk(1, 'n1');
      await seedChunk(2, 'n2');
      await seedVector(1, 'p:m:2', Float32List.fromList([1, 0]));
      await seedVector(2, 'p:m:2', Float32List.fromList([0, 1]));

      final search = VectorSearch(db);
      addTearDown(search.dispose);
      final hits = await search.topK(
        'p:m:2',
        Float32List.fromList([1, 0]),
        k: 5,
      );
      expect(search.usesFallback, isFalse);
      expect([for (final h in hits) h.chunkId], [1, 2]);
      expect(hits.first.score, closeTo(1.0, 1e-6));
    });

    test(
      'falls back to a synchronous main-isolate scan when spawn fails',
      () async {
        await seedChunk(1, 'n1');
        await seedVector(1, 'p:m:2', Float32List.fromList([1, 0]));

        final search = VectorSearch(
          db,
          spawnWorker: (_, _) => throw UnsupportedError('no isolates (web)'),
        );
        addTearDown(search.dispose);
        final hits = await search.topK('p:m:2', Float32List.fromList([1, 0]));
        expect(search.usesFallback, isTrue);
        expect(hits.single.chunkId, 1);
      },
    );

    test(
      'incremental upsert/remove patches are visible without a reload',
      () async {
        await seedChunk(1, 'n1');
        await seedVector(1, 'p:m:2', Float32List.fromList([1, 0]));

        final search = VectorSearch(db);
        addTearDown(search.dispose);
        await search.topK('p:m:2', Float32List.fromList([1, 0])); // Load.

        // Patch in a chunk that was never in the loaded matrix.
        search.upsert('p:m:2', 2, Float32List.fromList([0, 1]));
        var hits = await search.topK('p:m:2', Float32List.fromList([0, 1]));
        expect(hits.first.chunkId, 2);

        search.removeChunks([2]);
        hits = await search.topK('p:m:2', Float32List.fromList([0, 1]));
        expect([for (final h in hits) h.chunkId], [1]);
      },
    );

    test('patches for a non-loaded providerKey are ignored', () async {
      await seedChunk(1, 'n1');
      await seedVector(1, 'p:m:2', Float32List.fromList([1, 0]));

      final search = VectorSearch(db);
      addTearDown(search.dispose);
      await search.topK('p:m:2', Float32List.fromList([1, 0]));
      search.upsert('other:key:2', 7, Float32List.fromList([0, 1]));
      final hits = await search.topK('p:m:2', Float32List.fromList([0, 1]));
      expect([for (final h in hits) h.chunkId], [1]);
    });

    test('provider switch reloads the matrix for the new key', () async {
      await seedChunk(1, 'n1');
      await seedChunk(2, 'n2');
      await seedVector(1, 'a:m:2', Float32List.fromList([1, 0]));
      await seedVector(2, 'b:m:2', Float32List.fromList([0, 1]));

      final search = VectorSearch(db);
      addTearDown(search.dispose);
      var hits = await search.topK('a:m:2', Float32List.fromList([1, 0]));
      expect([for (final h in hits) h.chunkId], [1]);
      expect(search.loadedProviderKey, 'a:m:2');

      hits = await search.topK('b:m:2', Float32List.fromList([0, 1]));
      expect([for (final h in hits) h.chunkId], [2]);
      expect(search.loadedProviderKey, 'b:m:2');

      // And back: the old key's rows are still in SQLite.
      hits = await search.topK('a:m:2', Float32List.fromList([1, 0]));
      expect([for (final h in hits) h.chunkId], [1]);
    });

    test(
      'reset drops the matrix; the next query reloads from sqlite',
      () async {
        await seedChunk(1, 'n1');
        await seedVector(1, 'p:m:2', Float32List.fromList([1, 0]));

        final search = VectorSearch(db);
        addTearDown(search.dispose);
        await search.topK('p:m:2', Float32List.fromList([1, 0]));
        final raw = await db.database;
        await raw.delete('chunk_embeddings');
        search.reset();
        final hits = await search.topK('p:m:2', Float32List.fromList([1, 0]));
        expect(hits, isEmpty);
      },
    );

    test('rows stored under a different dims value are not loaded', () async {
      await seedChunk(1, 'n1');
      await seedVector(1, 'p:m:2', Float32List.fromList([1, 0, 0]));
      final search = VectorSearch(db);
      addTearDown(search.dispose);
      final hits = await search.topK('p:m:2', Float32List.fromList([1, 0]));
      expect(hits, isEmpty);
    });

    // ── Consistency with the worker across resets, patches and deaths ────────

    test(
      'reset() during an in-flight load never marks the matrix loaded',
      () async {
        // deleteStoredEmbeddings racing the very first query: the reset
        // reaches the worker AFTER the load command, so the worker ends up
        // holding nothing. Main must agree, or every later query is empty
        // and every patch is dropped for the rest of the session.
        await seedChunk(1, 'n1');
        await seedVector(1, 'p:m:2', Float32List.fromList([1, 0]));

        final search = VectorSearch(db);
        addTearDown(search.dispose);
        var resetOnce = false;
        search.onLoadWindow = () async {
          if (resetOnce) return;
          resetOnce = true;
          search.reset();
        };

        final hits = await search.topK('p:m:2', Float32List.fromList([1, 0]));
        expect(hits, isEmpty);
        expect(search.loadedProviderKey, isNull);

        // Heals on the next query — no restart, no re-embed.
        final healed = await search.topK('p:m:2', Float32List.fromList([1, 0]));
        expect([for (final h in healed) h.chunkId], [1]);
        expect(search.loadedProviderKey, 'p:m:2');

        // ...and patches land again.
        search.upsert('p:m:2', 2, Float32List.fromList([0, 1]));
        final patched = await search.topK(
          'p:m:2',
          Float32List.fromList([0, 1]),
        );
        expect(patched.first.chunkId, 2);
      },
    );

    test(
      'reset() during an in-flight load is handled the same in the fallback',
      () async {
        await seedChunk(1, 'n1');
        await seedVector(1, 'p:m:2', Float32List.fromList([1, 0]));

        final search = VectorSearch(
          db,
          spawnWorker: (_, _) => throw UnsupportedError('no isolates (web)'),
        );
        addTearDown(search.dispose);
        var resetOnce = false;
        search.onLoadWindow = () async {
          if (resetOnce) return;
          resetOnce = true;
          search.reset();
        };

        final hits = await search.topK('p:m:2', Float32List.fromList([1, 0]));
        expect(search.usesFallback, isTrue);
        expect(hits, isEmpty);
        expect(search.loadedProviderKey, isNull);

        final healed = await search.topK('p:m:2', Float32List.fromList([1, 0]));
        expect([for (final h in healed) h.chunkId], [1]);
      },
    );

    test('patches issued during a load are replayed, not dropped', () async {
      // Chunk 2 is written to SQLite after the load's snapshot; chunk 3 is
      // in the snapshot and deleted during the load window.
      await seedChunk(1, 'n1');
      await seedChunk(3, 'n3');
      await seedVector(1, 'p:m:2', Float32List.fromList([1, 0]));
      await seedVector(3, 'p:m:2', _unit([1, 1]));

      final search = VectorSearch(db);
      addTearDown(search.dispose);
      var patchedOnce = false;
      search.onLoadWindow = () async {
        if (patchedOnce) return;
        patchedOnce = true;
        search.upsert('p:m:2', 2, Float32List.fromList([0, 1]));
        search.removeChunks([3]);
      };

      final hits = await search.topK(
        'p:m:2',
        Float32List.fromList([0, 1]),
        k: 10,
      );
      expect([for (final h in hits) h.chunkId], [2, 1]);
      expect(search.loadedProviderKey, 'p:m:2');
    });

    test(
      'patches for another key issued during a load are still ignored',
      () async {
        await seedChunk(1, 'n1');
        await seedVector(1, 'p:m:2', Float32List.fromList([1, 0]));

        final search = VectorSearch(db);
        addTearDown(search.dispose);
        var patchedOnce = false;
        search.onLoadWindow = () async {
          if (patchedOnce) return;
          patchedOnce = true;
          search.upsert('other:key:2', 7, Float32List.fromList([0, 1]));
        };

        final hits = await search.topK(
          'p:m:2',
          Float32List.fromList([0, 1]),
          k: 10,
        );
        expect([for (final h in hits) h.chunkId], [1]);
      },
    );

    test(
      'a dead worker fails pending requests, respawns, then falls back',
      () async {
        await seedChunk(1, 'n1');
        await seedVector(1, 'p:m:2', Float32List.fromList([1, 0]));

        var spawns = 0;
        final search = VectorSearch(
          db,
          spawnWorker: (_, port) {
            spawns++;
            return Isolate.spawn(dyingWorker, port);
          },
        );
        addTearDown(search.dispose);
        final query = Float32List.fromList([1, 0]);

        // The worker dies while loading: no hang, no "loaded" claim, no
        // leaked completer.
        expect(await search.topK('p:m:2', query), isEmpty);
        expect(search.loadedProviderKey, isNull);
        expect(search.pendingRequests, 0);
        expect(search.workerDeaths, 1);

        // The next query respawns once; that worker dies too.
        expect(await search.topK('p:m:2', query), isEmpty);
        expect(spawns, 2);
        expect(search.workerDeaths, 2);
        expect(search.usesFallback, isTrue);

        // ...and the in-main-isolate matrix takes over: semantic search
        // recovers without an app restart.
        final hits = await search.topK('p:m:2', query);
        expect([for (final h in hits) h.chunkId], [1]);
        expect(spawns, 2);
        expect(search.pendingRequests, 0);
      },
    );

    test('a worker that never replies times out instead of hanging', () async {
      await seedChunk(1, 'n1');
      await seedVector(1, 'p:m:2', Float32List.fromList([1, 0]));

      final search = VectorSearch(
        db,
        spawnWorker: (_, port) => Isolate.spawn(silentWorker, port),
        requestTimeout: const Duration(milliseconds: 60),
      );
      addTearDown(search.dispose);
      final hits = await search
          .topK('p:m:2', Float32List.fromList([1, 0]))
          .timeout(const Duration(seconds: 5));
      expect(hits, isEmpty);
      expect(search.loadedProviderKey, isNull);
      expect(search.pendingRequests, 0);
    });

    test(
      'isolate topK matches the brute-force reference on a larger corpus',
      () async {
        final random = math.Random(7);
        final corpus = <int, Float32List>{};
        for (var id = 1; id <= 120; id++) {
          final vector = _unit([
            for (var d = 0; d < 16; d++) random.nextDouble() * 2 - 1,
          ]);
          corpus[id] = vector;
          await seedChunk(id, 'n$id');
          await seedVector(id, 'p:m:16', vector);
        }
        final search = VectorSearch(db);
        addTearDown(search.dispose);
        final query = _unit([for (var d = 0; d < 16; d++) random.nextDouble()]);
        final hits = await search.topK('p:m:16', query, k: 15);
        expect([
          for (final h in hits) h.chunkId,
        ], _bruteForceTopK(corpus, query, 15));
      },
    );
  });
}
