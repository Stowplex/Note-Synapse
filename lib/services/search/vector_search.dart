// Vector search (plan §2.3): brute-force cosine topK over the stored
// chunk embeddings of one providerKey.
//
// The matrix (≈30 MB at 10k chunks × 768 dims) lives in a LONG-LIVED search
// isolate — never copied per query the way compute() would. The initial load
// crosses the isolate boundary once as TransferableTypedData; afterwards the
// indexer keeps the matrix fresh with incremental patch messages (upsert on
// embed write, remove on chunk delete) instead of reloading from SQLite.
//
// Vectors are L2-normalized on both sides (providers guarantee it), so
// cosine similarity reduces to a dot product.
//
// ## Isolate protocol
//
// Main → worker (one ReceivePort per side, FIFO ordering guaranteed):
// - _LoadCmd(id, providerKey, dims, chunkIds, TransferableTypedData) —
//   REPLACES the held matrix (one matrix at a time, keyed by providerKey);
//   acked so loads can be awaited.
// - _QueryCmd(id, providerKey, query, k) → _QueryReply(id, chunkIds, scores).
//   A providerKey mismatch (stale query racing a switch) returns empty.
// - _UpsertCmd(providerKey, chunkId, vector) — fire-and-forget patch;
//   ignored when the held matrix is for a different key (that key's next
//   load reads the row from SQLite anyway).
// - _RemoveCmd(chunkIds) — fire-and-forget; applies to whatever is loaded.
// - _ResetCmd — drop the matrix (deleteStoredEmbeddings).
//
// If Isolate.spawn fails (web), the same matrix + protocol semantics run
// synchronously in the main isolate ([VectorMatrix] is shared code).
//
// ## Staying consistent with the worker
//
// Three hazards are handled explicitly, because the matrix is refreshed by
// patches (never re-read from SQLite on edits) — a main/worker divergence
// would otherwise persist until the app restarts:
// - reset() racing an in-flight load: every load carries a GENERATION taken
//   before its SQLite snapshot; a load whose generation is stale on ack does
//   not mark itself loaded, so the next query reloads. Same rule in the sync
//   fallback.
// - patches issued DURING a load (between the SQLite snapshot and the ack)
//   are in neither the snapshot nor the matrix: they are buffered and
//   replayed right after the ack (dropped when the load is abandoned — the
//   next load's snapshot is taken after their writes committed).
// - worker death (uncaught error, OOM materializing the matrix): error/exit
//   ports fail every pending request, drop the loaded key and respawn on the
//   next load; a worker that dies twice hands over to the sync fallback.
//   Every request is additionally bounded by [VectorSearch.requestTimeout],
//   so nothing can hang forever (or leak a pending entry) either way.

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../database_service.dart';
import '../logger_service.dart';

/// One topK hit: chunk id + cosine score (dot product of unit vectors).
class VectorHit {
  const VectorHit(this.chunkId, this.score);
  final int chunkId;
  final double score;

  @override
  String toString() => 'VectorHit($chunkId, $score)';
}

// ── float32 LE codec (chunk_embeddings.vector schema) ───────────────────────

/// Encode a vector as float32 little-endian bytes (the `chunk_embeddings.
/// vector` BLOB format). Explicit-endian so the stored bytes are portable
/// even though every shipping target is little-endian.
Uint8List encodeVectorFloat32Le(Float32List vector) {
  final data = ByteData(vector.length * 4);
  for (var i = 0; i < vector.length; i++) {
    data.setFloat32(i * 4, vector[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Decode float32 little-endian bytes into a vector. Alignment-safe
/// (sqflite blobs are not guaranteed 4-byte-aligned views).
Float32List decodeVectorFloat32Le(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final result = Float32List(bytes.length ~/ 4);
  for (var i = 0; i < result.length; i++) {
    result[i] = data.getFloat32(i * 4, Endian.little);
  }
  return result;
}

// ── Matrix (shared by the worker isolate and the sync fallback) ─────────────

/// Dense in-memory matrix of one providerKey's vectors, patchable in place.
/// Pure Dart and synchronous — unit-testable directly.
class VectorMatrix {
  VectorMatrix(this.providerKey, this.dims);

  final String providerKey;
  final int dims;

  final List<Float32List> _rows = [];
  final List<int> _chunkIds = [];
  final Map<int, int> _rowByChunkId = {};

  int get length => _rows.length;

  /// Bulk-load from a packed buffer of [chunkIds].length × [dims] floats.
  void loadPacked(List<int> chunkIds, Float32List packed) {
    _rows.clear();
    _chunkIds.clear();
    _rowByChunkId.clear();
    for (var i = 0; i < chunkIds.length; i++) {
      final row = Float32List.sublistView(packed, i * dims, (i + 1) * dims);
      _rows.add(row);
      _chunkIds.add(chunkIds[i]);
      _rowByChunkId[chunkIds[i]] = i;
    }
  }

  /// Insert or replace one chunk's vector. Off-dims vectors are ignored
  /// (a stale patch racing a dims change must not corrupt the matrix).
  void upsert(int chunkId, Float32List vector) {
    if (vector.length != dims) return;
    final existing = _rowByChunkId[chunkId];
    if (existing != null) {
      _rows[existing] = vector;
      return;
    }
    _rowByChunkId[chunkId] = _rows.length;
    _rows.add(vector);
    _chunkIds.add(chunkId);
  }

  /// Remove chunks (swap-with-last keeps the matrix dense). Unknown ids are
  /// ignored.
  void remove(Iterable<int> chunkIds) {
    for (final chunkId in chunkIds) {
      final row = _rowByChunkId.remove(chunkId);
      if (row == null) continue;
      final last = _rows.length - 1;
      if (row != last) {
        _rows[row] = _rows[last];
        _chunkIds[row] = _chunkIds[last];
        _rowByChunkId[_chunkIds[row]] = row;
      }
      _rows.removeLast();
      _chunkIds.removeLast();
    }
  }

  /// Brute-force dot-product topK. Ties broken by chunkId descending (newer
  /// chunk first — mirrors the lexical docid tiebreak).
  List<VectorHit> topK(Float32List query, int k) {
    if (query.length != dims || _rows.isEmpty || k <= 0) return const [];
    final hits = <VectorHit>[];
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      var dot = 0.0;
      for (var j = 0; j < dims; j++) {
        dot += row[j] * query[j];
      }
      hits.add(VectorHit(_chunkIds[i], dot));
    }
    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return b.chunkId.compareTo(a.chunkId);
    });
    return hits.length <= k ? hits : hits.sublist(0, k);
  }
}

// ── Isolate messages ─────────────────────────────────────────────────────────

class _LoadCmd {
  const _LoadCmd(
    this.id,
    this.providerKey,
    this.dims,
    this.chunkIds,
    this.data,
  );
  final int id;
  final String providerKey;
  final int dims;
  final List<int> chunkIds;
  final TransferableTypedData data;
}

class _QueryCmd {
  const _QueryCmd(this.id, this.providerKey, this.query, this.k);
  final int id;
  final String providerKey;
  final Float32List query;
  final int k;
}

class _UpsertCmd {
  const _UpsertCmd(this.providerKey, this.chunkId, this.vector);
  final String providerKey;
  final int chunkId;
  final Float32List vector;
}

class _RemoveCmd {
  const _RemoveCmd(this.chunkIds);
  final List<int> chunkIds;
}

class _ResetCmd {
  const _ResetCmd();
}

class _AckReply {
  const _AckReply(this.id);
  final int id;
}

class _QueryReply {
  const _QueryReply(this.id, this.chunkIds, this.scores);
  final int id;
  final List<int> chunkIds;
  final Float64List scores;
}

/// Worker entry point: holds one [VectorMatrix] and serves the protocol.
void _vectorWorkerMain(SendPort bootstrap) {
  final commands = ReceivePort();
  bootstrap.send(commands.sendPort);
  VectorMatrix? matrix;
  SendPort? replyTo;
  commands.listen((message) {
    if (message is SendPort) {
      replyTo = message;
    } else if (message is _LoadCmd) {
      final packed = message.data.materialize().asFloat32List();
      matrix = VectorMatrix(message.providerKey, message.dims)
        ..loadPacked(message.chunkIds, packed);
      replyTo?.send(_AckReply(message.id));
    } else if (message is _QueryCmd) {
      final hits = matrix?.providerKey == message.providerKey
          ? matrix!.topK(message.query, message.k)
          : const <VectorHit>[];
      replyTo?.send(
        _QueryReply(message.id, [
          for (final h in hits) h.chunkId,
        ], Float64List.fromList([for (final h in hits) h.score])),
      );
    } else if (message is _UpsertCmd) {
      if (matrix?.providerKey == message.providerKey) {
        matrix!.upsert(message.chunkId, message.vector);
      }
    } else if (message is _RemoveCmd) {
      matrix?.remove(message.chunkIds);
    } else if (message is _ResetCmd) {
      matrix = null;
    } else if (message == null) {
      commands.close();
    }
  });
}

// ── Service ──────────────────────────────────────────────────────────────────

/// Long-lived semantic-search index over `chunk_embeddings`, keyed by
/// providerKey (one matrix at a time — a provider switch loads the new key's
/// matrix on its first query).
class VectorSearch {
  /// [spawnWorker] (tests) overrides isolate spawning; throw from it to
  /// exercise the synchronous in-main-isolate fallback. [requestTimeout]
  /// bounds every worker round-trip (tests shorten it).
  VectorSearch(
    this._db, {
    @visibleForTesting
    Future<Isolate> Function(void Function(SendPort), SendPort)? spawnWorker,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _spawnWorker = spawnWorker ?? Isolate.spawn;

  final DatabaseService _db;
  final Future<Isolate> Function(void Function(SendPort), SendPort)
  _spawnWorker;

  /// Defensive cap on any single worker round-trip. A wedged or dead worker
  /// must never leave a caller awaiting forever, nor leak its [_pending]
  /// entry — semantic search degrades to "no hits", never to a hang.
  final Duration requestTimeout;

  /// How many times a dead worker is respawned before giving up and running
  /// the matrix in the main isolate.
  static const int _maxWorkerRespawns = 1;

  /// Cap on patches buffered during one load; beyond it the load is treated
  /// as unrecoverably behind and the matrix is reloaded instead.
  static const int _maxBufferedPatches = 5000;

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _replies;

  /// Error + exit notifications of the worker isolate.
  ReceivePort? _watchdog;
  bool _workerAlive = false;
  int _workerDeaths = 0;

  /// True once spawning failed (web) or the worker died repeatedly: the
  /// matrix lives on the main isolate.
  bool _useFallback = false;
  VectorMatrix? _fallbackMatrix;

  /// providerKey of the currently loaded matrix (null = nothing loaded).
  String? _loadedKey;

  /// providerKey of the load currently in flight (null = none). Patches
  /// issued in this window are buffered rather than dropped.
  String? _loadingKey;

  /// Bumped whenever the loaded matrix is invalidated out from under an
  /// in-flight load (reset / invalidate / worker death / dispose). A load
  /// whose generation no longer matches must NOT mark itself loaded.
  int _loadGeneration = 0;

  /// Patches ([_UpsertCmd] / [_RemoveCmd]) issued during a load, replayed in
  /// order once it acks.
  final List<Object> _bufferedPatches = [];
  bool _patchOverflow = false;

  /// Serializes load operations so concurrent first queries share one load.
  Future<void> _loadChain = Future.value();

  int _nextRequestId = 0;
  final Map<int, Completer<Object?>> _pending = {};
  bool _disposed = false;

  /// Whether the sync fallback is active (test observability).
  @visibleForTesting
  bool get usesFallback => _useFallback;

  @visibleForTesting
  String? get loadedProviderKey => _loadedKey;

  /// Number of worker isolates that died (test observability).
  @visibleForTesting
  int get workerDeaths => _workerDeaths;

  /// Requests still awaiting a worker reply (test observability: a dead
  /// worker must not leak entries here).
  @visibleForTesting
  int get pendingRequests => _pending.length;

  /// Test seam: awaited inside the LOAD WINDOW — after the SQLite snapshot
  /// (and, on the isolate path, after the load command was sent) and before
  /// the load is applied. Lets tests inject a reset or a patch into exactly
  /// the window the generation guard and the patch buffer exist for.
  @visibleForTesting
  Future<void> Function()? onLoadWindow;

  /// Top-[k] chunks by cosine similarity for [providerKey]. Loads (or
  /// reloads) the matrix from SQLite when [providerKey] differs from the
  /// loaded one. Returns hits sorted by score descending.
  Future<List<VectorHit>> topK(
    String providerKey,
    Float32List query, {
    int k = 200,
  }) async {
    if (_disposed) return const [];
    await _ensureLoaded(providerKey, query.length);
    if (_useFallback) {
      final matrix = _fallbackMatrix;
      if (matrix == null || matrix.providerKey != providerKey) return const [];
      return matrix.topK(query, k);
    }
    if (_commands == null) return const [];
    final id = _nextRequestId++;
    final reply = await _request(id, _QueryCmd(id, providerKey, query, k));
    if (reply is! _QueryReply) return const [];
    return [
      for (var i = 0; i < reply.chunkIds.length; i++)
        VectorHit(reply.chunkIds[i], reply.scores[i]),
    ];
  }

  /// Incremental patch after an embed write. Buffered while [providerKey]'s
  /// matrix is loading (the SQLite snapshot was taken before this write);
  /// ignored (cheaply) when its matrix is neither loaded nor loading — its
  /// next load reads the row from SQLite.
  void upsert(String providerKey, int chunkId, Float32List vector) {
    if (_disposed) return;
    final patch = _UpsertCmd(providerKey, chunkId, vector);
    if (_loadingKey == providerKey) {
      _buffer(patch);
      return;
    }
    _applyUpsert(patch);
  }

  /// Incremental patch after chunk deletion (applies to whatever matrix is
  /// loaded — deleted chunks are gone for every providerKey). Buffered
  /// during ANY load for the same reason as [upsert]: a removal dropped here
  /// would leave a stale id in the matrix, and `search_chunks.id` is a
  /// reused rowid — a later chunk could inherit its score.
  void removeChunks(List<int> chunkIds) {
    if (_disposed || chunkIds.isEmpty) return;
    final patch = _RemoveCmd(List<int>.of(chunkIds));
    if (_loadingKey != null) {
      _buffer(patch);
      return;
    }
    _applyRemove(patch);
  }

  /// Drop the in-memory matrix (deleteStoredEmbeddings / rebuild): the next
  /// query reloads from SQLite. Safe to call during a load — the in-flight
  /// one is abandoned rather than allowed to mark itself loaded.
  void reset() {
    _loadGeneration++;
    _loadedKey = null;
    _bufferedPatches.clear();
    _patchOverflow = false;
    if (_useFallback) {
      _fallbackMatrix = null;
    } else {
      _commands?.send(const _ResetCmd());
    }
  }

  /// Forget the loaded matrix if it holds (or is loading) [providerKey],
  /// forcing the next query for it to reload from SQLite (e.g. after a bulk
  /// write that bypassed patches).
  void invalidate(String providerKey) {
    if (_loadedKey == providerKey || _loadingKey == providerKey) reset();
  }

  void _buffer(Object patch) {
    if (_patchOverflow) return;
    if (_bufferedPatches.length >= _maxBufferedPatches) {
      // Cheaper (and safer) than an unbounded buffer: forget the buffer and
      // reload once the load lands.
      _patchOverflow = true;
      _bufferedPatches.clear();
      return;
    }
    _bufferedPatches.add(patch);
  }

  void _applyUpsert(_UpsertCmd patch) {
    if (_useFallback) {
      final matrix = _fallbackMatrix;
      if (matrix != null && matrix.providerKey == patch.providerKey) {
        matrix.upsert(patch.chunkId, patch.vector);
      }
      return;
    }
    if (_loadedKey == patch.providerKey) _commands?.send(patch);
  }

  void _applyRemove(_RemoveCmd patch) {
    if (_useFallback) {
      _fallbackMatrix?.remove(patch.chunkIds);
      return;
    }
    if (_loadedKey != null) _commands?.send(patch);
  }

  /// Applies the patches issued while the just-acked load was in flight.
  void _replayBufferedPatches() {
    if (_patchOverflow) {
      _patchOverflow = false;
      _bufferedPatches.clear();
      reset(); // Too far behind: the next query reloads from SQLite.
      return;
    }
    if (_bufferedPatches.isEmpty) return;
    final patches = List<Object>.of(_bufferedPatches);
    _bufferedPatches.clear();
    for (final patch in patches) {
      if (patch is _UpsertCmd) {
        _applyUpsert(patch);
      } else if (patch is _RemoveCmd) {
        _applyRemove(patch);
      }
    }
  }

  /// Sends [command] and awaits its reply under [requestTimeout]. On timeout
  /// the pending entry is dropped and null returned (callers treat that as
  /// "no result"), so a wedged worker can neither hang callers nor grow
  /// [_pending] without bound.
  Future<Object?> _request(int id, Object command) {
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands!.send(command);
    return completer.future.timeout(
      requestTimeout,
      onTimeout: () {
        _pending.remove(id);
        LoggerService.warning(
          '[VectorSearch] worker request $id timed out after $requestTimeout',
        );
        return null;
      },
    );
  }

  Future<void> _ensureLoaded(String providerKey, int dims) {
    if (_loadedKey == providerKey) return _loadChain;
    final run = _loadChain.then((_) async {
      if (_disposed || _loadedKey == providerKey) return;
      await _loadMatrix(providerKey, dims);
    });
    // Keep the chain alive on errors; the error still reaches this caller.
    _loadChain = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _loadMatrix(String providerKey, int dims) async {
    // Taken BEFORE the snapshot: anything that invalidates the matrix while
    // this load runs (reset / worker death) bumps it, and this load then
    // declines to mark itself loaded.
    final generation = _loadGeneration;
    _loadingKey = providerKey;
    try {
      final db = await _db.database;
      final rows = await db.query(
        'chunk_embeddings',
        columns: ['chunkId', 'vector'],
        where: 'providerKey = ? AND dims = ?',
        whereArgs: [providerKey, dims],
      );
      final chunkIds = <int>[];
      final packed = Float32List(rows.length * dims);
      var count = 0;
      for (final row in rows) {
        final vector = decodeVectorFloat32Le(row['vector'] as Uint8List);
        if (vector.length != dims) continue; // Corrupt row: skip defensively.
        packed.setRange(count * dims, (count + 1) * dims, vector);
        chunkIds.add(row['chunkId'] as int);
        count++;
      }
      final data = count == rows.length
          ? packed
          : Float32List.sublistView(packed, 0, count * dims);

      if (!_useFallback && _commands == null) {
        await _spawnIfPossible();
      }
      if (_useFallback) {
        await onLoadWindow?.call();
        if (_isStale(generation)) return;
        _fallbackMatrix = VectorMatrix(providerKey, dims)
          ..loadPacked(chunkIds, Float32List.fromList(data));
        _loadedKey = providerKey;
        _replayBufferedPatches();
        return;
      }
      if (_commands == null) return; // Spawn failed into no usable path.
      final id = _nextRequestId++;
      final ack = _request(
        id,
        _LoadCmd(
          id,
          providerKey,
          dims,
          chunkIds,
          TransferableTypedData.fromList([data]),
        ),
      );
      await onLoadWindow?.call();
      // Anything but an ack (worker death, request timeout) means the worker
      // is NOT holding this matrix: leave the key unloaded so the next query
      // retries instead of querying a matrix that does not exist.
      if (await ack is! _AckReply) return;
      if (_isStale(generation)) return;
      _loadedKey = providerKey;
      _replayBufferedPatches();
    } finally {
      if (_loadingKey == providerKey) _loadingKey = null;
      if (_loadedKey != providerKey) {
        // Abandoned load: the buffered patches' writes are already committed,
        // so the next load's snapshot picks them up.
        _bufferedPatches.clear();
        _patchOverflow = false;
      }
    }
  }

  /// Whether the matrix was invalidated (or the service disposed) since a
  /// load captured [generation].
  bool _isStale(int generation) => _disposed || generation != _loadGeneration;

  Future<void> _spawnIfPossible() async {
    final bootstrap = ReceivePort();
    try {
      final commandsPort = Completer<SendPort>();
      bootstrap.listen((message) {
        if (message is SendPort && !commandsPort.isCompleted) {
          commandsPort.complete(message);
        }
      });
      _isolate = await _spawnWorker(_vectorWorkerMain, bootstrap.sendPort);
      _commands = await commandsPort.future.timeout(requestTimeout);
      bootstrap.close();
      _replies = ReceivePort();
      _replies!.listen(_onReply);
      _commands!.send(_replies!.sendPort);
      // A worker killed by an uncaught error (errorsAreFatal) or by the OS
      // would otherwise leave every pending completer — and _loadChain —
      // unresolved forever.
      _watchdog = ReceivePort()..listen((_) => _handleWorkerDeath());
      _isolate!.addErrorListener(_watchdog!.sendPort);
      _isolate!.addOnExitListener(_watchdog!.sendPort);
      _workerAlive = true;
    } catch (e) {
      // No isolate support (web): synchronous main-isolate scan.
      bootstrap.close();
      LoggerService.warning(
        '[VectorSearch] Isolate spawn failed, using in-main-isolate scan: $e',
      );
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _commands = null;
      _watchdog?.close();
      _watchdog = null;
      _replies?.close();
      _replies = null;
      _useFallback = true;
    }
  }

  /// The worker isolate died. Fail everything pending (so callers get "no
  /// hits" instead of hanging), forget the loaded matrix and let the next
  /// load respawn; a worker that dies again hands over to the sync fallback.
  /// Idempotent — errorsAreFatal delivers an error AND an exit.
  void _handleWorkerDeath() {
    if (_disposed || !_workerAlive) return;
    _workerAlive = false;
    _workerDeaths++;
    _loadGeneration++;
    _loadedKey = null;
    _loadingKey = null;
    _bufferedPatches.clear();
    _patchOverflow = false;
    _isolate = null;
    _commands = null;
    _replies?.close();
    _replies = null;
    _watchdog?.close();
    _watchdog = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _pending.clear();
    if (_workerDeaths > _maxWorkerRespawns) {
      _useFallback = true;
    }
    LoggerService.warning(
      '[VectorSearch] worker isolate died (#$_workerDeaths); '
      '${_useFallback ? 'using the in-main-isolate scan' : 'respawning on the next load'}',
    );
  }

  void _onReply(Object? message) {
    if (message is _AckReply) {
      _pending.remove(message.id)?.complete(message);
    } else if (message is _QueryReply) {
      _pending.remove(message.id)?.complete(message);
    }
  }

  void dispose() {
    _disposed = true;
    _loadGeneration++;
    _workerAlive = false;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _pending.clear();
    _bufferedPatches.clear();
    _replies?.close();
    _replies = null;
    _watchdog?.close();
    _watchdog = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
    _fallbackMatrix = null;
    _loadedKey = null;
    _loadingKey = null;
  }
}
