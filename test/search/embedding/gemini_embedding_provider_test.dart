import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:note_synapse/services/search/embedding/embedding_provider.dart';
import 'package:note_synapse/services/search/embedding/gemini_embedding_provider.dart';

class CapturedRequest {
  final Uri url;
  final Map<String, String>? headers;
  final Map<String, dynamic> body;
  CapturedRequest(this.url, this.headers, this.body);
}

void main() {
  const config = EmbeddingProviderConfig(
    type: 'gemini',
    endpoint: 'https://generativelanguage.googleapis.com/v1beta',
    modelName: 'gemini-embedding-001',
    displayName: 'Gemini Embedding',
    dimensions: 768,
    supportsBatch: true,
    apiKey: 'test-key',
  );

  List<double> unitVector(int dims) {
    final v = List<double>.filled(dims, 0);
    v[0] = 1.0;
    return v;
  }

  /// Fake post returning [responses] in order and capturing every request.
  EmbeddingHttpPost fakePost(
    List<CapturedRequest> captured,
    List<http.Response> responses,
  ) {
    var call = 0;
    return (Uri url, {Map<String, String>? headers, Object? body}) async {
      captured.add(
        CapturedRequest(
          url,
          headers,
          jsonDecode(body as String) as Map<String, dynamic>,
        ),
      );
      return responses[math.min(call++, responses.length - 1)];
    };
  }

  http.Response batchResponse(List<List<double>> vectors) => http.Response(
    jsonEncode({
      'embeddings': [
        for (final v in vectors) {'values': v},
      ],
    }),
    200,
  );

  http.Response singleResponse(List<double> vector) => http.Response(
    jsonEncode({
      'embedding': {'values': vector},
    }),
    200,
  );

  group('GeminiEmbeddingProvider request shape', () {
    test('embedDocuments uses batchEmbedContents with RETRIEVAL_DOCUMENT '
        'and outputDimensionality', () async {
      final captured = <CapturedRequest>[];
      final provider = GeminiEmbeddingProvider(
        config,
        httpPost: fakePost(captured, [
          batchResponse([unitVector(768), unitVector(768)]),
        ]),
      );

      await provider.embedDocuments(const [
        EmbeddingInput.text('hello'),
        EmbeddingInput.text('world'),
      ]);

      expect(captured, hasLength(1));
      final request = captured.single;
      expect(
        request.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-embedding-001:batchEmbedContents',
      );
      expect(request.headers?['x-goog-api-key'], 'test-key');
      expect(request.headers?['Content-Type'], 'application/json');

      final requests = request.body['requests'] as List;
      expect(requests, hasLength(2));
      final first = requests[0] as Map<String, dynamic>;
      expect(first['model'], 'models/gemini-embedding-001');
      expect(first['taskType'], 'RETRIEVAL_DOCUMENT');
      expect(first['outputDimensionality'], 768);
      expect(first['content']['parts'][0]['text'], 'hello');
      expect((requests[1] as Map)['content']['parts'][0]['text'], 'world');
    });

    test('embedQuery uses embedContent with RETRIEVAL_QUERY', () async {
      final captured = <CapturedRequest>[];
      final provider = GeminiEmbeddingProvider(
        config,
        httpPost: fakePost(captured, [singleResponse(unitVector(768))]),
      );

      await provider.embedQuery('find me');

      final request = captured.single;
      expect(request.url.path, endsWith(':embedContent'));
      expect(request.body['taskType'], 'RETRIEVAL_QUERY');
      expect(request.body['outputDimensionality'], 768);
      expect(request.body['content']['parts'][0]['text'], 'find me');
    });

    test('omits outputDimensionality at native 3072 dims', () async {
      final captured = <CapturedRequest>[];
      final provider = GeminiEmbeddingProvider(
        config.copyWith(dimensions: 3072),
        httpPost: fakePost(captured, [singleResponse(unitVector(3072))]),
      );

      await provider.embedQuery('q');

      expect(captured.single.body.containsKey('outputDimensionality'), isFalse);
    });

    test('supportsBatch=false falls back to per-item embedContent', () async {
      final captured = <CapturedRequest>[];
      final provider = GeminiEmbeddingProvider(
        config.copyWith(supportsBatch: false),
        httpPost: fakePost(captured, [
          singleResponse(unitVector(768)),
          singleResponse(unitVector(768)),
        ]),
      );

      // maxBatchSize is 1 here, so callers chunk to single-input calls.
      expect(provider.maxBatchSize, 1);
      final vectors = [
        ...await provider.embedDocuments(const [EmbeddingInput.text('a')]),
        ...await provider.embedDocuments(const [EmbeddingInput.text('b')]),
      ];

      expect(vectors, hasLength(2));
      expect(captured, hasLength(2));
      for (final request in captured) {
        expect(request.url.path, endsWith(':embedContent'));
        expect(request.body['taskType'], 'RETRIEVAL_DOCUMENT');
      }
    });

    test('more inputs than maxBatchSize throws ArgumentError', () async {
      var calls = 0;
      EmbeddingHttpPost countingPost(http.Response response) {
        return (url, {headers, body}) async {
          calls++;
          return response;
        };
      }

      // Batch mode: cap is 100.
      final batchProvider = GeminiEmbeddingProvider(
        config,
        httpPost: countingPost(batchResponse([unitVector(768)])),
      );
      expect(
        () => batchProvider.embedDocuments([
          for (var i = 0; i < batchProvider.maxBatchSize + 1; i++)
            EmbeddingInput.text('t$i'),
        ]),
        throwsArgumentError,
      );

      // Per-item mode: cap is 1, so even two inputs are the caller's bug.
      final singleProvider = GeminiEmbeddingProvider(
        config.copyWith(supportsBatch: false),
        httpPost: countingPost(singleResponse(unitVector(768))),
      );
      expect(
        () => singleProvider.embedDocuments(const [
          EmbeddingInput.text('a'),
          EmbeddingInput.text('b'),
        ]),
        throwsArgumentError,
      );
      expect(calls, 0);
    });

    test(
      'endpoint trailing slashes never produce // in the URL path',
      () async {
        for (final endpoint in [
          'https://generativelanguage.googleapis.com/v1beta/',
          'https://generativelanguage.googleapis.com/v1beta//',
        ]) {
          final captured = <CapturedRequest>[];
          final provider = GeminiEmbeddingProvider(
            config.copyWith(endpoint: endpoint),
            httpPost: fakePost(captured, [singleResponse(unitVector(768))]),
          );

          await provider.embedQuery('q');

          expect(
            captured.single.url.toString(),
            'https://generativelanguage.googleapis.com/v1beta/models/'
            'gemini-embedding-001:embedContent',
          );
          expect(captured.single.url.path.contains('//'), isFalse);
        }
      },
    );

    test('multimodal image input sends inline_data and no taskType', () async {
      final captured = <CapturedRequest>[];
      final multimodal = config.copyWith(
        modelName: 'gemini-embedding-2',
        supportsImages: true,
        supportsBatch: false,
      );
      final provider = GeminiEmbeddingProvider(
        multimodal,
        httpPost: fakePost(captured, [singleResponse(unitVector(768))]),
      );

      final bytes = Uint8List.fromList([1, 2, 3]);
      await provider.embedDocuments([EmbeddingInput.image(bytes, 'image/png')]);

      final body = captured.single.body;
      final part = body['content']['parts'][0] as Map<String, dynamic>;
      expect(part['inline_data']['mime_type'], 'image/png');
      expect(part['inline_data']['data'], base64Encode(bytes));
      expect(body.containsKey('taskType'), isFalse);
    });

    test('image input on a text-only model throws', () async {
      final provider = GeminiEmbeddingProvider(
        config,
        httpPost: fakePost([], [singleResponse(unitVector(768))]),
      );
      expect(
        () => provider.embedDocuments([
          EmbeddingInput.image(Uint8List.fromList([1]), 'image/png'),
        ]),
        throwsA(isA<EmbeddingProviderException>()),
      );
    });
  });

  group('GeminiEmbeddingProvider normalization', () {
    // Canned vectors here are 2-dimensional; the runtime dims guard
    // requires the config to promise the same size.
    final dims2Config = config.copyWith(dimensions: 2);

    test('re-normalizes truncated (non-unit) vectors to L2 norm 1', () async {
      // A Matryoshka-truncated vector is no longer unit length: [3, 4]
      // has norm 5 and must come back as [0.6, 0.8].
      final provider = GeminiEmbeddingProvider(
        dims2Config,
        httpPost: fakePost([], [
          singleResponse([3.0, 4.0]),
        ]),
      );

      final vector = await provider.embedQuery('q');

      expect(vector[0], closeTo(0.6, 1e-6));
      expect(vector[1], closeTo(0.8, 1e-6));
      final norm = math.sqrt(vector.fold<double>(0, (s, v) => s + v * v));
      expect(norm, closeTo(1.0, 1e-6));
    });

    test('already-normalized vectors pass through unchanged', () async {
      final provider = GeminiEmbeddingProvider(
        dims2Config,
        httpPost: fakePost([], [
          batchResponse([
            [0.6, 0.8],
          ]),
        ]),
      );

      final vectors = await provider.embedDocuments(const [
        EmbeddingInput.text('a'),
      ]);

      expect(vectors.single[0], closeTo(0.6, 1e-6));
      expect(vectors.single[1], closeTo(0.8, 1e-6));
    });
  });

  group('GeminiEmbeddingProvider runtime dims guard', () {
    test(
      'off-size vectors throw a permanent mismatch naming both sizes',
      () async {
        // The server ignoring/mishandling outputDimensionality must fail
        // loudly instead of silently indexing off-size vectors.
        final provider = GeminiEmbeddingProvider(
          config,
          httpPost: fakePost([], [singleResponse(unitVector(3072))]),
        );

        await expectLater(
          provider.embedQuery('q'),
          throwsA(
            isA<EmbeddingProviderException>()
                .having((e) => e.detectedDimensions, 'detectedDimensions', 3072)
                .having((e) => e.isAuthError, 'isAuthError', isFalse)
                .having((e) => e.isTransient, 'isTransient', isFalse)
                .having((e) => e.message, 'message', contains('3072'))
                .having((e) => e.message, 'message', contains('768')),
          ),
        );
      },
    );

    test('batch responses are guarded too', () async {
      final provider = GeminiEmbeddingProvider(
        config,
        httpPost: fakePost([], [
          batchResponse([unitVector(512), unitVector(512)]),
        ]),
      );

      await expectLater(
        provider.embedDocuments(const [
          EmbeddingInput.text('a'),
          EmbeddingInput.text('b'),
        ]),
        throwsA(
          isA<EmbeddingProviderException>().having(
            (e) => e.detectedDimensions,
            'detectedDimensions',
            512,
          ),
        ),
      );
    });
  });

  group('GeminiEmbeddingProvider error mapping', () {
    Future<EmbeddingProviderException> errorFor(int statusCode) async {
      final provider = GeminiEmbeddingProvider(
        config,
        httpPost: fakePost([], [http.Response('{"error": "x"}', statusCode)]),
      );
      try {
        await provider.embedQuery('q');
        fail('expected EmbeddingProviderException');
      } on EmbeddingProviderException catch (e) {
        return e;
      }
    }

    test('401 maps to isAuthError', () async {
      final e = await errorFor(401);
      expect(e.isAuthError, isTrue);
      expect(e.isTransient, isFalse);
    });

    test('403 maps to isAuthError', () async {
      final e = await errorFor(403);
      expect(e.isAuthError, isTrue);
    });

    test('429 maps to isTransient', () async {
      final e = await errorFor(429);
      expect(e.isTransient, isTrue);
      expect(e.isAuthError, isFalse);
    });

    test('500 maps to isTransient', () async {
      final e = await errorFor(500);
      expect(e.isTransient, isTrue);
    });

    test('400 is neither auth nor transient', () async {
      final e = await errorFor(400);
      expect(e.isAuthError, isFalse);
      expect(e.isTransient, isFalse);
    });

    test('network failure maps to isTransient', () async {
      final provider = GeminiEmbeddingProvider(
        config,
        httpPost: (url, {headers, body}) =>
            throw http.ClientException('connection refused'),
      );
      try {
        await provider.embedQuery('q');
        fail('expected EmbeddingProviderException');
      } on EmbeddingProviderException catch (e) {
        expect(e.isTransient, isTrue);
        expect(e.isAuthError, isFalse);
      }
    });

    test('missing API key throws auth error without any request', () async {
      var calls = 0;
      final provider = GeminiEmbeddingProvider(
        config.copyWith(apiKey: ''),
        httpPost: (url, {headers, body}) async {
          calls++;
          return http.Response('{}', 200);
        },
      );
      // copyWith('') keeps the empty string only if it overrides; ensure
      // the provider treats an empty key as unconfigured.
      try {
        await provider.embedQuery('q');
        fail('expected EmbeddingProviderException');
      } on EmbeddingProviderException catch (e) {
        expect(e.isAuthError, isTrue);
      }
      expect(calls, 0);
      expect(await provider.isReady(), isFalse);
    });
  });

  test('providerKey follows {type}:{model}:{dims}', () {
    final provider = GeminiEmbeddingProvider(config);
    expect(provider.providerKey, 'gemini:gemini-embedding-001:768');
    expect(provider.dimensions, 768);
    expect(provider.supportsImages, isFalse);
  });
}
