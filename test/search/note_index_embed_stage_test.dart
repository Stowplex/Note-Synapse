// Integration tests for the NoteIndexService embedding stage (plan §2.3):
// consent gate, gap scan + batching, includeInAIContext / per-attachment
// policy skips, auth-halt / transient-retry / permanent-continue paths, the
// wifi-only gating seam, vector-index patching, and the provider-switch
// lifecycle (A serves until B completes, revoke → lexical, None keeps
// vectors, GC, deleteStoredEmbeddings). Real sqlite via sqflite_common_ffi,
// scripted fake providers via the registry's providerBuilder seam.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/search/embedding/embedding_provider.dart';
import 'package:note_synapse/services/search/embedding/embedding_provider_registry.dart';
import 'package:note_synapse/services/search/note_index_service.dart';
import 'package:note_synapse/services/search/vector_search.dart';

import 'ocr_test_stubs.dart';

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      Directory.systemTemp.path;
}

/// Scripted embedding provider: records batch sizes, can fail the next N
/// calls with a chosen exception, and produces deterministic unit vectors.
class FakeEmbeddingProvider implements EmbeddingProvider {
  FakeEmbeddingProvider({
    required this.providerKey,
    this.dimensions = 4,
    this.maxBatchSize = 3,
  });

  @override
  final String providerKey;
  @override
  final int dimensions;
  @override
  final int maxBatchSize;

  @override
  String get displayName => providerKey;
  @override
  bool get supportsImages => false;
  @override
  Future<bool> isReady() async => true;

  /// Inputs-per-call sizes, in order.
  final List<int> batchSizes = [];
  final List<String> embeddedTexts = [];
  int documentCalls = 0;
  int queryCalls = 0;

  /// Errors popped (in order) before each embedDocuments call; null entries
  /// mean "succeed".
  final List<EmbeddingProviderException?> scriptedErrors = [];

  /// Runs at the start of each embedDocuments call: lets a test change the
  /// world (e.g. switch providers) WHILE a pass is in flight.
  Future<void> Function()? beforeEmbed;

  @override
  Future<List<Float32List>> embedDocuments(List<EmbeddingInput> inputs) async {
    documentCalls++;
    await beforeEmbed?.call();
    if (inputs.length > maxBatchSize) {
      throw ArgumentError('batch of ${inputs.length} exceeds $maxBatchSize');
    }
    if (scriptedErrors.isNotEmpty) {
      final error = scriptedErrors.removeAt(0);
      if (error != null) throw error;
    }
    batchSizes.add(inputs.length);
    for (final input in inputs) {
      embeddedTexts.add(input.text ?? '');
    }
    return [for (final input in inputs) _vectorFor(input.text ?? '')];
  }

  @override
  Future<Float32List> embedQuery(String query) async {
    queryCalls++;
    return _vectorFor(query);
  }

  Float32List _vectorFor(String text) {
    final vector = Float32List(dimensions);
    vector[text.hashCode.abs() % dimensions] = 1.0;
    return vector;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;
  late DataChangeNotifier notifier;
  late NoteIndexService indexer;
  late VectorSearch vectorSearch;
  var indexerBuilt = false;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    db = DatabaseService.createNew();
    await db.database;
    notifier = DataChangeNotifier();
    indexerBuilt = false;
  });

  tearDown(() async {
    // Some tests never build an indexer (pure label assertions).
    if (indexerBuilt) {
      indexer.dispose();
      vectorSearch.dispose();
    }
    await db.close();
  });

  const configA = EmbeddingProviderConfig(
    type: 'fakeA',
    modelName: 'm',
    displayName: 'Provider A',
    dimensions: 4,
  );
  const configB = EmbeddingProviderConfig(
    type: 'fakeB',
    modelName: 'm',
    displayName: 'Provider B',
    dimensions: 4,
  );
  const configC = EmbeddingProviderConfig(
    type: 'fakeC',
    modelName: 'm',
    displayName: 'Provider C',
    dimensions: 4,
  );

  final providers = <String, FakeEmbeddingProvider>{};

  FakeEmbeddingProvider providerFor(EmbeddingProviderConfig config) {
    return providers.putIfAbsent(
      config.providerKey,
      () => FakeEmbeddingProvider(providerKey: config.providerKey),
    );
  }

  EmbeddingProviderRegistry buildRegistry() {
    providers.clear();
    return EmbeddingProviderRegistry(providerBuilder: providerFor);
  }

  /// Builds the indexer under test with the embed stage wired. Call it
  /// AFTER seeding notes: the constructor installs the DatabaseService write
  /// hooks, so notes inserted earlier carry no pending debounced reindex
  /// (which backfillAll would defer around).
  /// providerKeys whose consent was withdrawn by the indexer.
  final revokedConsent = <String>[];

  NoteIndexService buildIndexer(
    EmbeddingProviderRegistry registry, {
    Set<String> consented = const {},
    Future<bool> Function()? networkAllowed,
    int? scanPageSize,
  }) {
    revokedConsent.clear();
    vectorSearch = VectorSearch(db);
    indexerBuilt = true;
    indexer = NoteIndexService(
      db,
      changeNotifier: notifier,
      debounceDelay: const Duration(milliseconds: 20),
      ocrExtractor: stubOcrExtractor(db),
      figureExtractor: stubFigureExtractor(),
      embeddingRegistry: registry,
      vectorSearch: vectorSearch,
      embedConsentCheck: (key) async =>
          consented.contains(key) && !revokedConsent.contains(key),
      embedConsentRevoke: (key) async => revokedConsent.add(key),
      embedNetworkAllowed: networkAllowed,
      embedRetryBaseDelay: const Duration(milliseconds: 1),
      embedScanPageSize: scanPageSize ?? 1000,
    );
    return indexer;
  }

  Note buildNote(String id, {String? content}) => Note(
    id: id,
    title: 'Note $id',
    content: content ?? 'Body of note $id.',
    type: NoteType.note,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );

  /// Raw attachments insert (the embed stage only reads columns, and the
  /// extraction stages are stubbed out in these tests).
  Future<void> insertAttachmentRow(
    DatabaseExecutor raw, {
    required String id,
    String noteId = 'n1',
    bool includeInAIContext = true,
    Map<String, dynamic>? metadata,
  }) async {
    await raw.insert('attachments', {
      'id': id,
      'noteId': noteId,
      'filePath': '/tmp/$id.pdf',
      'fileName': '$id.pdf',
      'fileType': 'pdf',
      'isRelativePath': 0,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'includeInAIContext': includeInAIContext ? 1 : 0,
      'metadata': metadata == null ? null : jsonEncode(metadata),
    });
  }

  Future<List<Map<String, Object?>>> embeddingRows([
    String? providerKey,
  ]) async {
    final raw = await db.database;
    return raw.query(
      'chunk_embeddings',
      where: providerKey == null ? null : 'providerKey = ?',
      whereArgs: providerKey == null ? null : [providerKey],
      orderBy: 'chunkId',
    );
  }

  Future<Map<String, Object?>?> embedGlobalState(String providerKey) async {
    final raw = await db.database;
    final rows = await raw.query(
      'search_index_state',
      where: "scopeType = 'global' AND scopeId = 'all' AND stage = ?",
      whereArgs: [NoteIndexService.stageEmbed(providerKey)],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> chunkErrorStates(
    String providerKey,
  ) async {
    final raw = await db.database;
    return raw.query(
      'search_index_state',
      where: "scopeType = 'chunk' AND stage = ?",
      whereArgs: [NoteIndexService.stageEmbed(providerKey)],
      orderBy: 'scopeId',
    );
  }

  // ── Consent gate ───────────────────────────────────────────────────────────

  test('no consent recorded: the embed stage no-ops entirely', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    // No consent for A is recorded.
    await db.insertNote(buildNote('n1'));
    buildIndexer(registry);
    await indexer.backfillAll();

    expect(await embeddingRows(), isEmpty);
    expect(await embedGlobalState(configA.providerKey), isNull);
    expect(providers[configA.providerKey]?.documentCalls ?? 0, 0);
    // Nothing serves: semantic stays off until consent + backfill.
    expect(registry.servingProviderKey, isNull);
  });

  test('consent granted: chunks embed and the global row turns done', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1'));
    buildIndexer(registry, consented: {configA.providerKey});
    await indexer.backfillAll();

    final rows = await embeddingRows();
    expect(rows, isNotEmpty);
    expect(rows.first['providerKey'], configA.providerKey);
    expect(rows.first['modality'], 'text');
    expect(rows.first['dims'], 4);
    expect((await embedGlobalState(configA.providerKey))!['status'], 'done');
  });

  test('stage label is namespaced per providerKey', () {
    expect(NoteIndexService.stageEmbed('x:y:1'), 'embed:x:y:1');
  });

  // ── Gap scan + batching ────────────────────────────────────────────────────

  test('gap scan re-embeds only missing/stale chunks and batches at '
      'maxBatchSize', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    // 7 chunks total (each note yields a meta + body chunk); batch cap 3.
    for (var i = 0; i < 4; i++) {
      await db.insertNote(buildNote('n$i'));
    }
    buildIndexer(registry, consented: {configA.providerKey});
    await indexer.backfillAll();

    final provider = providers[configA.providerKey]!;
    expect(provider.batchSizes.every((size) => size <= 3), isTrue);
    final embedded = (await embeddingRows()).length;
    expect(provider.batchSizes.reduce((a, b) => a + b), embedded);

    // Second pass: every chunk already has a current vector → no calls.
    final callsBefore = provider.documentCalls;
    await indexer.backfillAll();
    expect(provider.documentCalls, callsBefore);

    // Edit one note: only ITS changed chunks re-embed.
    final raw = await db.database;
    final beforeIds = {
      for (final row in await embeddingRows()) row['chunkId'] as int,
    };
    await db.updateNote(
      buildNote('n1', content: 'completely different body text'),
    );
    await indexer.flushPending();
    expect(provider.documentCalls, greaterThan(callsBefore));
    final afterRows = await embeddingRows();
    expect(afterRows.length, greaterThanOrEqualTo(beforeIds.length - 1));
    // Chunk rows for untouched notes kept their vectors (same contentHash).
    final untouched = await raw.rawQuery(
      "SELECT c.id FROM search_chunks c WHERE c.noteId = 'n0'",
    );
    for (final row in untouched) {
      expect(
        afterRows.any((e) => e['chunkId'] == row['id']),
        isTrue,
        reason: 'untouched chunk ${row['id']} must keep its vector',
      );
    }
  });

  test('a chunk whose content changed has its stale vector dropped and '
      're-embedded', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1', content: 'first body'));
    buildIndexer(registry, consented: {configA.providerKey});
    await indexer.backfillAll();
    final before = await embeddingRows();
    expect(before, isNotEmpty);

    await db.updateNote(buildNote('n1', content: 'second body entirely'));
    await indexer.flushPending();
    final after = await embeddingRows();
    final raw = await db.database;
    final chunks = await raw.query(
      'search_chunks',
      columns: ['id', 'contentHash'],
    );
    // Every stored vector matches its chunk's CURRENT contentHash.
    for (final row in after) {
      final chunk = chunks.firstWhere((c) => c['id'] == row['chunkId']);
      expect(row['contentHash'], chunk['contentHash']);
    }
  });

  // ── Policy skips ───────────────────────────────────────────────────────────

  test(
    'chunks of an includeInAIContext=false attachment are never embedded',
    () async {
      final registry = buildRegistry();
      await registry.setActiveConfig(configA);
      await db.insertNote(buildNote('n1'));
      final raw = await db.database;
      await insertAttachmentRow(raw, id: 'a1', includeInAIContext: false);
      await insertAttachmentRow(raw, id: 'a2');
      // Attachment-derived chunks written directly (extraction is stubbed).
      for (final entry in [
        ('a1', 'secret contents'),
        ('a2', 'public contents'),
      ]) {
        await raw.insert('search_chunks', {
          'chunkKey': 'n1:attachment_text:${entry.$1}:1',
          'noteId': 'n1',
          'sourceType': 'attachment_text',
          'sourceId': entry.$1,
          'page': 1,
          'seq': 1,
          'text': entry.$2,
          'meta': null,
          'contentHash': 'h_${entry.$1}',
          'updatedAt': 0,
        });
      }
      buildIndexer(registry, consented: {configA.providerKey});
      await indexer.backfillAll();

      final provider = providers[configA.providerKey]!;
      expect(provider.embeddedTexts, contains('public contents'));
      expect(provider.embeddedTexts, isNot(contains('secret contents')));
      // The stage still completes: policy skips are not gaps.
      expect((await embedGlobalState(configA.providerKey))!['status'], 'done');
    },
  );

  test(
    'per-attachment metadata.searchIndex.embed=false skips its chunks',
    () async {
      final registry = buildRegistry();
      await registry.setActiveConfig(configA);
      await db.insertNote(buildNote('n1'));
      final raw = await db.database;
      await insertAttachmentRow(
        raw,
        id: 'a1',
        metadata: const {
          'searchIndex': {'text': 'auto', 'ocr': true, 'embed': false},
        },
      );
      await raw.insert('search_chunks', {
        'chunkKey': 'n1:attachment_text:a1:1',
        'noteId': 'n1',
        'sourceType': 'attachment_text',
        'sourceId': 'a1',
        'page': 1,
        'seq': 1,
        'text': 'opted out of embedding',
        'meta': null,
        'contentHash': 'h_a1',
        'updatedAt': 0,
      });
      buildIndexer(registry, consented: {configA.providerKey});
      await indexer.backfillAll();

      final provider = providers[configA.providerKey]!;
      expect(provider.embeddedTexts, isNot(contains('opted out of embedding')));
    },
  );

  // ── Policy purge ───────────────────────────────────────────────────────────
  //
  // The scans above are FILTERS: they stop new uploads. These pin the other
  // half of plan §1.3 — a flag flipped off deletes what was ALREADY stored,
  // and patches it out of the in-memory matrix, or the attachment keeps
  // surfacing in semantic results after the user opted out.

  /// Seeds n1 with two attachment-derived chunks (a1, a2) and embeds them,
  /// with the matrix loaded so later patches are what change it.
  Future<({int a1, int a2, Float32List a1Vector})> seedTwoEmbedded(
    EmbeddingProviderRegistry registry,
  ) async {
    await db.insertNote(buildNote('n1'));
    final raw = await db.database;
    await insertAttachmentRow(raw, id: 'a1');
    await insertAttachmentRow(raw, id: 'a2');
    for (final entry in [('a1', 'opted out later'), ('a2', 'stays indexed')]) {
      await raw.insert('search_chunks', {
        'chunkKey': 'n1:attachment_text:${entry.$1}:1',
        'noteId': 'n1',
        'sourceType': 'attachment_text',
        'sourceId': entry.$1,
        'page': 1,
        'seq': 1,
        'text': entry.$2,
        'meta': null,
        'contentHash': 'h_${entry.$1}',
        'updatedAt': 0,
      });
    }
    buildIndexer(registry, consented: {configA.providerKey});
    // Load the (empty) matrix FIRST: everything it serves from here on got
    // there by patch, never by a reload from sqlite.
    await vectorSearch.topK(configA.providerKey, Float32List(4)..[0] = 1);
    await indexer.backfillAll();

    Future<int> chunkIdOf(String attachmentId) async {
      final rows = await raw.query(
        'search_chunks',
        columns: ['id'],
        where: 'sourceId = ?',
        whereArgs: [attachmentId],
      );
      return rows.single['id'] as int;
    }

    final a1 = await chunkIdOf('a1');
    final a2 = await chunkIdOf('a2');
    final stored = await embeddingRows(configA.providerKey);
    expect(stored.map((row) => row['chunkId']), containsAll([a1, a2]));
    final a1Row = stored.firstWhere((row) => row['chunkId'] == a1);
    return (
      a1: a1,
      a2: a2,
      a1Vector: decodeVectorFloat32Le(a1Row['vector'] as Uint8List),
    );
  }

  /// chunkIds the loaded matrix still serves for [probe].
  Future<Set<int>> reachable(Float32List probe) async {
    final hits = await vectorSearch.topK(configA.providerKey, probe, k: 50);
    return {for (final hit in hits) hit.chunkId};
  }

  test('turning searchIndex.embed off deletes the vectors already stored '
      'and patches them out of the matrix', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    final seeded = await seedTwoEmbedded(registry);
    expect(await reachable(seeded.a1Vector), contains(seeded.a1));

    // Exactly what the Step-21 dialog writes.
    await db.updateAttachmentMetadata('a1', {
      'searchIndex': {'text': 'auto', 'ocr': true, 'embed': false},
    });
    await indexer.flushPending();
    await Future<void>.delayed(Duration.zero);

    final after = await embeddingRows();
    expect(
      after.map((row) => row['chunkId']),
      isNot(contains(seeded.a1)),
      reason: 'the opted-out attachment keeps no stored vector',
    );
    expect(after.map((row) => row['chunkId']), contains(seeded.a2));
    expect(
      await reachable(seeded.a1Vector),
      isNot(contains(seeded.a1)),
      reason: 'the matrix is patched incrementally, not left to a reload',
    );

    // Only the VECTORS go: the chunk stays lexically searchable, because the
    // flag says "do not send this to the provider", not "do not index it".
    final raw = await db.database;
    final chunks = await raw.query(
      'search_chunks',
      where: 'id = ?',
      whereArgs: [seeded.a1],
    );
    expect(chunks, hasLength(1));

    // And it stays deleted: the next pass must not re-upload it.
    final callsBefore = providers[configA.providerKey]!.documentCalls;
    await indexer.backfillAll();
    expect(providers[configA.providerKey]!.documentCalls, callsBefore);
    expect(
      (await embeddingRows()).map((row) => row['chunkId']),
      isNot(contains(seeded.a1)),
    );
  });

  test(
    'withdrawing includeInAIContext deletes what was already uploaded',
    () async {
      final registry = buildRegistry();
      await registry.setActiveConfig(configA);
      final seeded = await seedTwoEmbedded(registry);
      expect(await reachable(seeded.a1Vector), contains(seeded.a1));

      // The app's established privacy control, flipped from the attachment menu.
      await db.updateAttachmentAIContext('n1', '/tmp/a1.pdf', false);
      await indexer.flushPending();
      await Future<void>.delayed(Duration.zero);

      final ids = (await embeddingRows()).map((row) => row['chunkId']);
      expect(ids, isNot(contains(seeded.a1)));
      expect(ids, contains(seeded.a2), reason: 'only the excluded one goes');
      expect(await reachable(seeded.a1Vector), isNot(contains(seeded.a1)));
    },
  );

  test('the purge is a sweep: it repairs an external write with consent '
      'withdrawn', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    final seeded = await seedTwoEmbedded(registry);

    // No indexer hook fires for this write (a restore, another process, a
    // build predating the purge) and the stage is off entirely — deletion is
    // local, so neither may keep the vectors alive.
    final raw = await db.database;
    await raw.update(
      'attachments',
      {
        'metadata': jsonEncode({
          'searchIndex': {'embed': false},
        }),
      },
      where: 'id = ?',
      whereArgs: ['a1'],
    );
    revokedConsent.add(configA.providerKey);
    await indexer.backfillAll();
    await Future<void>.delayed(Duration.zero);

    final ids = (await embeddingRows()).map((row) => row['chunkId']);
    expect(ids, isNot(contains(seeded.a1)));
    expect(ids, contains(seeded.a2));
    expect(await reachable(seeded.a1Vector), isNot(contains(seeded.a1)));
  });

  test('note-born chunks are never touched by the purge', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1', content: 'plain note body'));
    buildIndexer(registry, consented: {configA.providerKey});
    await indexer.backfillAll();
    final before = await embeddingRows();
    expect(before, isNotEmpty);

    await indexer.backfillAll();
    expect(
      (await embeddingRows()).length,
      before.length,
      reason: 'the policy only applies to attachment-derived chunks',
    );
  });

  // ── Error paths ────────────────────────────────────────────────────────────

  test(
    'auth error halts the whole pass and records a visible error state',
    () async {
      final registry = buildRegistry();
      await registry.setActiveConfig(configA);
      for (var i = 0; i < 4; i++) {
        await db.insertNote(buildNote('n$i'));
      }
      final provider = providerFor(configA);
      provider.scriptedErrors.add(
        const EmbeddingProviderException(
          'Embedding request failed: 401 - bad key',
          statusCode: 401,
          isAuthError: true,
        ),
      );
      buildIndexer(registry, consented: {configA.providerKey});
      await indexer.backfillAll();

      final state = await embedGlobalState(configA.providerKey);
      expect(state!['status'], 'error');
      expect(state['errorMessage'], contains('401'));
      // Halted before any further batch: no quota burn.
      expect(provider.documentCalls, 1);
      expect(await embeddingRows(), isEmpty);
      // Sticky: a later sweep does not retry.
      await indexer.backfillAll();
      expect(provider.documentCalls, 1);
      // Serving key untouched — semantic stays lexical-only.
      expect(registry.servingProviderKey, isNull);
    },
  );

  test('retryEmbedIndexing clears the halt and re-runs the pass', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1'));
    final provider = providerFor(configA);
    provider.scriptedErrors.add(
      const EmbeddingProviderException(
        '403',
        statusCode: 403,
        isAuthError: true,
      ),
    );
    buildIndexer(registry, consented: {configA.providerKey});
    await indexer.backfillAll();
    expect((await embedGlobalState(configA.providerKey))!['status'], 'error');

    await indexer.retryEmbedIndexing();
    expect((await embedGlobalState(configA.providerKey))!['status'], 'done');
    expect(await embeddingRows(), isNotEmpty);
  });

  test('retryEmbedIndexing clears per-chunk failures and re-embeds those '
      'chunks', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    for (var i = 0; i < 3; i++) {
      await db.insertNote(buildNote('n$i'));
    }
    final provider = providerFor(configA);
    // First batch fails permanently → per-chunk error rows; the rest embed.
    provider.scriptedErrors.add(
      const EmbeddingProviderException('unsupported input'),
    );
    buildIndexer(registry, consented: {configA.providerKey});
    await indexer.backfillAll();

    final failedRows = await chunkErrorStates(configA.providerKey);
    expect(failedRows, isNotEmpty);
    final failedChunkIds = {
      for (final row in failedRows) row['scopeId'] as String,
    };
    expect(
      (await indexer.embedStageState(configA.providerKey)).failedChunks,
      failedChunkIds.length,
    );
    // Sweeps never revisit them (the error row is keyed to the contentHash),
    // which is exactly why Retry has to clear them.
    await indexer.backfillAll();
    expect(
      await chunkErrorStates(configA.providerKey),
      hasLength(failedChunkIds.length),
    );

    await indexer.retryEmbedIndexing();

    expect(await chunkErrorStates(configA.providerKey), isEmpty);
    final embeddedChunkIds = {
      for (final row in await embeddingRows(configA.providerKey))
        '${row['chunkId']}',
    };
    expect(
      embeddedChunkIds,
      containsAll(failedChunkIds),
      reason:
          'Retry must actually re-embed the failed chunks, not just '
          'delete the rows that made settings show the error tile',
    );
    // The red "N chunks could not be embedded" tile clears with them.
    final state = await indexer.embedStageState(configA.providerKey);
    expect(state.failedChunks, 0);
    expect(state.status, 'done');
  });

  test('transient errors retry with backoff, then succeed', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1'));
    final provider = providerFor(configA);
    provider.scriptedErrors.addAll([
      const EmbeddingProviderException(
        '429',
        statusCode: 429,
        isTransient: true,
      ),
      const EmbeddingProviderException(
        '503',
        statusCode: 503,
        isTransient: true,
      ),
    ]);
    buildIndexer(registry, consented: {configA.providerKey});
    await indexer.backfillAll();

    expect(provider.documentCalls, 3); // 2 failures + 1 success.
    expect(await embeddingRows(), isNotEmpty);
    expect((await embedGlobalState(configA.providerKey))!['status'], 'done');
  });

  test('exhausted transient retries defer the pass (no state written), and '
      'the next sweep retries', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1'));
    final provider = providerFor(configA);
    // maxRetries defaults to 3 → 4 attempts, all transient failures.
    for (var i = 0; i < 4; i++) {
      provider.scriptedErrors.add(
        const EmbeddingProviderException(
          '503',
          statusCode: 503,
          isTransient: true,
        ),
      );
    }
    buildIndexer(registry, consented: {configA.providerKey});
    await indexer.backfillAll();

    expect(await embedGlobalState(configA.providerKey), isNull);
    expect(await embeddingRows(), isEmpty);

    // Next sweep: no scripted errors left → it completes.
    await indexer.backfillAll();
    expect((await embedGlobalState(configA.providerKey))!['status'], 'done');
    expect(await embeddingRows(), isNotEmpty);
  });

  test('permanent per-batch errors record chunk states and the pass '
      'continues', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    for (var i = 0; i < 3; i++) {
      await db.insertNote(buildNote('n$i'));
    }
    final provider = providerFor(configA);
    // First batch permanently fails; the rest succeed.
    provider.scriptedErrors.add(
      const EmbeddingProviderException('unsupported input'),
    );
    buildIndexer(registry, consented: {configA.providerKey});
    await indexer.backfillAll();

    final errors = await chunkErrorStates(configA.providerKey);
    expect(errors, isNotEmpty);
    expect(errors.first['errorMessage'], contains('unsupported input'));
    // Later batches still stored vectors, and the stage completed.
    expect(await embeddingRows(), isNotEmpty);
    expect((await embedGlobalState(configA.providerKey))!['status'], 'done');

    // The failed chunks are not retried on the next sweep (error state is
    // keyed to their contentHash).
    final callsBefore = provider.documentCalls;
    await indexer.backfillAll();
    expect(provider.documentCalls, callsBefore);
  });

  // ── wifi-only gate ─────────────────────────────────────────────────────────

  test('network gate false defers the pass; allowing it lets the next sweep '
      'complete', () async {
    var allowed = false;
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1'));
    buildIndexer(
      registry,
      consented: {configA.providerKey},
      networkAllowed: () async => allowed,
    );
    await indexer.backfillAll();

    expect(await embeddingRows(), isEmpty);
    expect(await embedGlobalState(configA.providerKey), isNull);
    expect(providers[configA.providerKey]?.documentCalls ?? 0, 0);

    allowed = true;
    await indexer.backfillAll();
    expect(await embeddingRows(), isNotEmpty);
    expect((await embedGlobalState(configA.providerKey))!['status'], 'done');
  });

  // ── Vector index patching ──────────────────────────────────────────────────

  test(
    'embed writes patch the in-memory vector index; deletes remove rows',
    () async {
      final registry = buildRegistry();
      await registry.setActiveConfig(configA);
      await db.insertNote(buildNote('n1', content: 'alpha beta gamma'));
      // Load the (empty) matrix first so patches are what populate it.
      final probe = Float32List(4)..[0] = 1;
      await vectorSearch.topK(configA.providerKey, probe);
      buildIndexer(registry, consented: {configA.providerKey});
      await indexer.backfillAll();

      final stored = await embeddingRows();
      expect(stored, isNotEmpty);
      // Every stored chunk is reachable through the vector index without any
      // reload from sqlite.
      final reachable = <int>{};
      for (final row in stored) {
        final vector = decodeVectorFloat32Le(row['vector'] as Uint8List);
        final hits = await vectorSearch.topK(
          configA.providerKey,
          vector,
          k: 50,
        );
        reachable.addAll([for (final hit in hits) hit.chunkId]);
      }
      expect(
        reachable,
        containsAll([for (final row in stored) row['chunkId'] as int]),
      );

      // Deleting the note purges rows and patches them out.
      await indexer.removeNote('n1');
      await Future<void>.delayed(Duration.zero);
      final hits = await vectorSearch.topK(configA.providerKey, probe, k: 50);
      expect(hits, isEmpty);
      expect(await embeddingRows(), isEmpty);
    },
  );

  // ── Provider-switch lifecycle ──────────────────────────────────────────────

  test('A serves until B completes, then the serving key switches and A is '
      'GCd', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1'));
    buildIndexer(
      registry,
      consented: {configA.providerKey, configB.providerKey},
    );
    await indexer.backfillAll();
    expect(registry.servingProviderKey, configA.providerKey);
    expect(await embeddingRows(configA.providerKey), isNotEmpty);

    // Switch to B: A KEEPS SERVING until B's backfill completes.
    await registry.setActiveConfig(configB);
    expect(registry.servingProviderKey, configA.providerKey);
    expect(registry.activeConfig!.providerKey, configB.providerKey);
    expect(registry.transitionState.inTransition, isTrue);

    await indexer.backfillAll();
    expect(registry.servingProviderKey, configB.providerKey);
    expect(registry.transitionState.inTransition, isFalse);
    // Lazy GC of A's rows.
    expect(await embeddingRows(configA.providerKey), isEmpty);
    expect(await embeddingRows(configB.providerKey), isNotEmpty);
    expect(await embedGlobalState(configA.providerKey), isNull);
  });

  test('revoking the serving provider degrades to lexical immediately, and B '
      'takes over when done', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1'));
    buildIndexer(
      registry,
      consented: {configA.providerKey, configB.providerKey},
    );
    await indexer.backfillAll();
    expect(registry.servingProviderKey, configA.providerKey);

    await registry.setActiveConfig(configB);
    await registry.revokeServing(); // "Stop using A now".
    expect(registry.servingProviderKey, isNull);
    expect(registry.servingProvider, isNull);

    await indexer.backfillAll();
    expect(registry.servingProviderKey, configB.providerKey);
  });

  test('a switch DURING B\'s pass never promotes the newest key or GCs the '
      'serving one', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1'));
    buildIndexer(
      registry,
      consented: {
        configA.providerKey,
        configB.providerKey,
        configC.providerKey,
      },
    );
    await indexer.backfillAll();
    expect(registry.servingProviderKey, configA.providerKey);

    // Switch to B and start its (slow) pass; while it runs the user switches
    // again to C. B's pass must not promote C — C has no vectors at all —
    // and must not GC A's rows, which are still the ones being served.
    await registry.setActiveConfig(configB);
    final providerB = providerFor(configB);
    providerB.beforeEmbed = () async {
      providerB.beforeEmbed = null;
      await registry.setActiveConfig(configC);
    };
    await indexer.backfillAll();

    expect(registry.servingProviderKey, configA.providerKey);
    expect(await embeddingRows(configA.providerKey), isNotEmpty);
    expect(await embeddingRows(configB.providerKey), isNotEmpty);
    expect(await embeddingRows(configC.providerKey), isEmpty);

    // C's own pass then promotes normally and GCs both superseded keys.
    await indexer.backfillAll();
    expect(registry.servingProviderKey, configC.providerKey);
    expect(await embeddingRows(configC.providerKey), isNotEmpty);
    expect(await embeddingRows(configA.providerKey), isEmpty);
    expect(await embeddingRows(configB.providerKey), isEmpty);
  });

  test(
    'revoking while A is still active survives sweeps and restarts',
    () async {
      final registry = buildRegistry();
      await registry.setActiveConfig(configA);
      await db.insertNote(buildNote('n1'));
      buildIndexer(registry, consented: {configA.providerKey});
      await indexer.backfillAll();
      expect(registry.servingProviderKey, configA.providerKey);

      // "Stop using A now" with A STILL the configured provider: its vectors
      // are complete, so a completeness sweep must not quietly re-promote it.
      await registry.revokeServing();
      expect(registry.servingProviderKey, isNull);

      await indexer.ensureBackfilled();
      expect(registry.servingProviderKey, isNull);
      await indexer.backfillAll();
      expect(registry.servingProviderKey, isNull);
      await indexer.retryEmbedIndexing();
      expect(registry.servingProviderKey, isNull);
      // Stored vectors are untouched — re-enabling stays free.
      expect(await embeddingRows(configA.providerKey), isNotEmpty);

      // Restart: a fresh registry reads the persisted revocation.
      final restarted = EmbeddingProviderRegistry(providerBuilder: providerFor);
      await restarted.initialize();
      expect(restarted.activeConfig!.providerKey, configA.providerKey);
      expect(restarted.servingProviderKey, isNull);
      indexer.dispose();
      vectorSearch.dispose();
      buildIndexer(restarted, consented: {configA.providerKey});
      await indexer.ensureBackfilled();
      expect(restarted.servingProviderKey, isNull);

      // Picking A again in settings is the explicit re-enable: the next sweep
      // promotes it without re-embedding anything.
      await restarted.setActiveConfig(configA);
      final calls = providers[configA.providerKey]!.documentCalls;
      await indexer.ensureBackfilled();
      expect(restarted.servingProviderKey, configA.providerKey);
      expect(providers[configA.providerKey]!.documentCalls, calls);
    },
  );

  test(
    'switching to None clears the serving key but KEEPS stored vectors',
    () async {
      final registry = buildRegistry();
      await registry.setActiveConfig(configA);
      await db.insertNote(buildNote('n1'));
      buildIndexer(registry, consented: {configA.providerKey});
      await indexer.backfillAll();
      final before = await embeddingRows(configA.providerKey);
      expect(before, isNotEmpty);

      await registry.clearActiveConfig();
      expect(registry.servingProviderKey, isNull);
      expect(registry.active, isNull);
      expect(
        await embeddingRows(configA.providerKey),
        hasLength(before.length),
      );

      // Re-enabling the same key needs no re-embed: the stage is already done
      // and the serving key is restored by the completeness check.
      await registry.setActiveConfig(configA);
      final provider = providers[configA.providerKey]!;
      final callsBefore = provider.documentCalls;
      await indexer.ensureBackfilled();
      expect(provider.documentCalls, callsBefore);
      expect(registry.servingProviderKey, configA.providerKey);
    },
  );

  test(
    'deleteStoredEmbeddings removes every vector and embed state row',
    () async {
      final registry = buildRegistry();
      await registry.setActiveConfig(configA);
      await db.insertNote(buildNote('n1'));
      buildIndexer(registry, consented: {configA.providerKey});
      await indexer.backfillAll();
      expect(await embeddingRows(), isNotEmpty);

      await indexer.deleteStoredEmbeddings();
      expect(await embeddingRows(), isEmpty);
      expect(await embedGlobalState(configA.providerKey), isNull);
      final probe = Float32List(4)..[0] = 1;
      expect(await vectorSearch.topK(configA.providerKey, probe), isEmpty);
    },
  );

  test('deleteStoredEmbeddings turns the provider off instead of silently '
      're-uploading everything', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1'));
    buildIndexer(registry, consented: {configA.providerKey});
    await indexer.backfillAll();
    final provider = providers[configA.providerKey]!;
    final callsBefore = provider.documentCalls;
    expect(callsBefore, greaterThan(0));

    await indexer.deleteStoredEmbeddings();

    // Semantic search is off: no serving provider (so no query embedding is
    // billed against an empty matrix) and no backfill target.
    expect(registry.servingProviderKey, isNull);
    expect(registry.activeConfig, isNull);
    expect(revokedConsent, contains(configA.providerKey));

    // The next sweeps must NOT re-upload the corpus.
    await indexer.ensureBackfilled();
    await indexer.backfillAll();
    expect(provider.documentCalls, callsBefore);
    expect(await embeddingRows(), isEmpty);

    // Only an explicit re-enable (with fresh consent) starts a new pass.
    revokedConsent.remove(configA.providerKey);
    await registry.setActiveConfig(configA);
    await indexer.backfillAll();
    expect(provider.documentCalls, greaterThan(callsBefore));
    expect(await embeddingRows(configA.providerKey), isNotEmpty);
    expect(registry.servingProviderKey, configA.providerKey);
  });

  test('a rolled-back chunk write does not evict live vectors from the '
      'in-memory index', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1', content: 'first body'));
    buildIndexer(registry, consented: {configA.providerKey});
    // Load the (empty) matrix so the backfill's patches populate it.
    final probe = Float32List(4)..[0] = 1;
    await vectorSearch.topK(configA.providerKey, probe);
    await indexer.backfillAll();

    final stored = await embeddingRows(configA.providerKey);
    expect(stored, isNotEmpty);
    Future<Set<int>> reachableChunkIds() async {
      final ids = <int>{};
      for (final row in stored) {
        final vector = decodeVectorFloat32Le(row['vector'] as Uint8List);
        final hits = await vectorSearch.topK(
          configA.providerKey,
          vector,
          k: 50,
        );
        ids.addAll([for (final hit in hits) hit.chunkId]);
      }
      return ids;
    }

    final before = await reachableChunkIds();
    expect(before, isNotEmpty);

    // Break the FTS table so the next chunk write throws mid-transaction
    // (after its embeddings delete) and rolls back.
    final raw = await db.database;
    await raw.execute('DROP TABLE chunks_fts');
    await db.updateNote(buildNote('n1', content: 'second body entirely'));
    var threw = false;
    try {
      await indexer.reindexNote('n1');
    } catch (_) {
      threw = true;
    }
    expect(threw, isTrue, reason: 'the chunk write must have failed');
    try {
      await indexer.flushPending(); // Drain the queued follow-up stages.
    } catch (_) {
      // Those stages fail on the dropped table too; irrelevant here.
    }

    // The rollback kept the rows: the vector index must still hold them.
    expect(
      await embeddingRows(configA.providerKey),
      hasLength(stored.length),
      reason: 'the failed transaction must have rolled back',
    );
    expect(await reachableChunkIds(), before);
  });

  test('the gap scan pages without skipping or duplicating chunks', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1'));
    final raw = await db.database;
    // 7 extra chunks + one policy-skipped one, across pages of 2.
    await insertAttachmentRow(raw, id: 'a1', includeInAIContext: false);
    await insertAttachmentRow(raw, id: 'a2');
    for (var i = 0; i < 7; i++) {
      await raw.insert('search_chunks', {
        'chunkKey': 'n1:attachment_text:a2:$i',
        'noteId': 'n1',
        'sourceType': 'attachment_text',
        'sourceId': 'a2',
        'page': i + 1,
        'seq': 1,
        'text': 'extra chunk $i',
        'meta': null,
        'contentHash': 'hx$i',
        'updatedAt': 0,
      });
    }
    await raw.insert('search_chunks', {
      'chunkKey': 'n1:attachment_text:a1:1',
      'noteId': 'n1',
      'sourceType': 'attachment_text',
      'sourceId': 'a1',
      'page': 1,
      'seq': 1,
      'text': 'private attachment text',
      'meta': null,
      'contentHash': 'hprivate',
      'updatedAt': 0,
    });
    buildIndexer(registry, consented: {configA.providerKey}, scanPageSize: 2);
    await indexer.backfillAll();

    final provider = providers[configA.providerKey]!;
    expect(provider.embeddedTexts, isNot(contains('private attachment text')));
    for (var i = 0; i < 7; i++) {
      expect(
        provider.embeddedTexts.where((t) => t == 'extra chunk $i'),
        hasLength(1),
        reason: 'every gap embeds exactly once across page boundaries',
      );
    }
    final rows = await embeddingRows(configA.providerKey);
    final chunkRows = await raw.query('search_chunks', columns: ['id']);
    // Every chunk except the policy-skipped one has a vector.
    expect(rows, hasLength(chunkRows.length - 1));
    expect((await embedGlobalState(configA.providerKey))!['status'], 'done');
  });

  test('embedCoverage reports the re-indexed fraction for the settings '
      'subtitle', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1'));
    buildIndexer(registry, consented: {configA.providerKey});
    var coverage = await indexer.embedCoverage(configA.providerKey);
    expect(coverage.embedded, 0);

    await indexer.backfillAll();
    coverage = await indexer.embedCoverage(configA.providerKey);
    expect(coverage.total, greaterThan(0));
    expect(coverage.embedded, coverage.total);
  });

  test('embedStageState surfaces the halt message and failed-chunk count '
      'for settings', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1'));
    buildIndexer(registry, consented: {configA.providerKey});
    var state = await indexer.embedStageState(configA.providerKey);
    expect(state.status, isNull);
    expect(state.failedChunks, 0);

    providerFor(configA).scriptedErrors.add(
      const EmbeddingProviderException(
        'Embedding request failed: 401 - bad key',
        statusCode: 401,
        isAuthError: true,
      ),
    );
    await indexer.backfillAll();
    state = await indexer.embedStageState(configA.providerKey);
    expect(state.status, 'error');
    expect(state.errorMessage, contains('401'));

    await indexer.retryEmbedIndexing();
    state = await indexer.embedStageState(configA.providerKey);
    expect(state.status, 'done');
    expect(state.errorMessage, isNull);
  });

  // ── Halt-kind encoding (settings reads the kind, not the prose) ────────────

  final haltScenarios =
      <({String kind, EmbeddingProviderException error, String prose})>[
        (
          kind: NoteIndexService.embedHaltAuth,
          error: const EmbeddingProviderException(
            'Embedding request failed: 401 - bad key',
            statusCode: 401,
            isAuthError: true,
          ),
          prose: 'Embedding request failed: 401 - bad key',
        ),
        (
          kind: NoteIndexService.embedHaltNotInstalled,
          // The real local-provider message: it matches NONE of the prose
          // patterns the settings screen used to classify with, so before the
          // prefix it surfaced as a generic halt with an inert Retry instead
          // of a "Download model" action.
          error: const EmbeddingProviderException(
            'EmbeddingGemma is missing its model/tokenizer download URLs',
            isNotInstalled: true,
          ),
          prose: 'EmbeddingGemma is missing its model/tokenizer download URLs',
        ),
        (
          kind: NoteIndexService.embedHaltDims,
          error: EmbeddingProviderException.dimensionMismatch(
            modelName: 'm',
            expected: 4,
            actual: 8,
          ),
          prose: EmbeddingProviderException.dimensionMismatch(
            modelName: 'm',
            expected: 4,
            actual: 8,
          ).message,
        ),
      ];

  for (final scenario in haltScenarios) {
    test('an embed halt persists the "${scenario.kind}" kind as a prefix on '
        'errorMessage', () async {
      final registry = buildRegistry();
      await registry.setActiveConfig(configA);
      await db.insertNote(buildNote('n1'));
      providerFor(configA).scriptedErrors.add(scenario.error);
      buildIndexer(registry, consented: {configA.providerKey});
      await indexer.backfillAll();

      final stored =
          (await embedGlobalState(configA.providerKey))!['errorMessage']
              as String?;
      expect(stored, '${scenario.kind}|${scenario.prose}');

      // embedStageState hands the RAW value through; the UI parses it.
      final state = await indexer.embedStageState(configA.providerKey);
      expect(state.status, 'error');
      final halt = NoteIndexService.parseEmbedHalt(state.errorMessage);
      expect(halt.kind, scenario.kind);
      expect(
        halt.message,
        scenario.prose,
        reason: 'the displayed prose must not keep the machine prefix',
      );
    });
  }

  test('parseEmbedHalt leaves unprefixed and unknown-prefix messages '
      'untouched', () {
    // Permanent per-chunk errors and pre-prefix rows carry bare prose.
    var halt = NoteIndexService.parseEmbedHalt('unsupported input');
    expect(halt.kind, isNull);
    expect(halt.message, 'unsupported input');

    // A '|' in the prose is not a kind.
    halt = NoteIndexService.parseEmbedHalt('failed: a|b');
    expect(halt.kind, isNull);
    expect(halt.message, 'failed: a|b');

    halt = NoteIndexService.parseEmbedHalt(null);
    expect(halt.kind, isNull);
    expect(halt.message, isEmpty);

    // A kind-less halt (no typed reason) is stored unprefixed.
    expect(
      NoteIndexService.encodeEmbedHalt(
        const EmbeddingProviderException('something else'),
      ),
      'something else',
    );
  });

  test('a forced rebuild clears halts and per-chunk errors but does not '
      're-embed current chunks', () async {
    final registry = buildRegistry();
    await registry.setActiveConfig(configA);
    await db.insertNote(buildNote('n1'));
    buildIndexer(registry, consented: {configA.providerKey});
    await indexer.backfillAll();
    final provider = providers[configA.providerKey]!;
    final callsBefore = provider.documentCalls;

    await indexer.backfillAll(force: true);
    expect(provider.documentCalls, callsBefore);
    expect((await embedGlobalState(configA.providerKey))!['status'], 'done');
  });
}
