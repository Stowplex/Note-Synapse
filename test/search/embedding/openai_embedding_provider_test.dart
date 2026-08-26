import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:note_synapse/services/search/embedding/embedding_provider.dart';
import 'package:note_synapse/services/search/embedding/openai_embedding_provider.dart';

class CapturedRequest {
  final Uri url;
  final Map<String, String>? headers;
  final Map<String, dynamic> body;
  CapturedRequest(this.url, this.headers, this.body);
}

void main() {
  const config = EmbeddingProviderConfig(
    type: 'openai',
    endpoint: 'https://api.openai.com',
    modelName: 'text-embedding-3-small',
    displayName: 'OpenAI Text Embedding 3 Small',
    dimensions: 1536,
    sendDimensions: true,
    apiKey: 'sk-test',
  );

  EmbeddingHttpPost fakePost(
    List<CapturedRequest> captured,
    http.Response response,
  ) {
    return (Uri url, {Map<String, String>? headers, Object? body}) async {
      captured.add(
        CapturedRequest(
          url,
          headers,
          jsonDecode(body as String) as Map<String, dynamic>,
        ),
      );
      return response;
    };
  }

  http.Response embeddingsResponse(List<List<double>> vectors) => http.Response(
    jsonEncode({
      'object': 'list',
      'data': [
        for (var i = 0; i < vectors.length; i++)
          {'object': 'embedding', 'index': i, 'embedding': vectors[i]},
      ],
      'model': 'text-embedding-3-small',
    }),
    200,
  );

  group('OpenAIEmbeddingProvider URL building', () {
    Uri uriFor(String endpoint) => OpenAIEmbeddingProvider(
      config.copyWith(endpoint: endpoint),
    ).buildRequestUri();

    test('bare host gets /v1/embeddings appended', () {
      expect(
        uriFor('https://api.openai.com').toString(),
        'https://api.openai.com/v1/embeddings',
      );
    });

    test('endpoint ending in /v1 gets /embeddings appended', () {
      expect(
        uriFor('http://localhost:11434/v1').toString(),
        'http://localhost:11434/v1/embeddings',
      );
    });

    test('full route is used as-is; trailing slash is tolerated', () {
      expect(
        uriFor('https://my-litellm.example/v1/embeddings').toString(),
        'https://my-litellm.example/v1/embeddings',
      );
      expect(
        uriFor('https://api.openai.com/').toString(),
        'https://api.openai.com/v1/embeddings',
      );
    });

    test('all trailing slashes are stripped (no // in path)', () {
      expect(
        uriFor('https://api.openai.com//').toString(),
        'https://api.openai.com/v1/embeddings',
      );
      expect(
        uriFor('http://localhost:11434/v1//').toString(),
        'http://localhost:11434/v1/embeddings',
      );
    });
  });

  group('OpenAIEmbeddingProvider request shape', () {
    test('sends model, input list, dimensions, and Bearer auth', () async {
      final captured = <CapturedRequest>[];
      final provider = OpenAIEmbeddingProvider(
        config,
        httpPost: fakePost(
          captured,
          embeddingsResponse([
            List<double>.filled(1536, 0.1),
            List<double>.filled(1536, 0.2),
          ]),
        ),
      );

      await provider.embedDocuments(const [
        EmbeddingInput.text('a'),
        EmbeddingInput.text('b'),
      ]);

      final request = captured.single;
      expect(request.url.toString(), 'https://api.openai.com/v1/embeddings');
      expect(request.headers?['Authorization'], 'Bearer sk-test');
      expect(request.body['model'], 'text-embedding-3-small');
      expect(request.body['input'], ['a', 'b']);
      expect(request.body['dimensions'], 1536);
    });

    test('keyless config sends no Authorization header', () async {
      final captured = <CapturedRequest>[];
      final keyless = EmbeddingProviderConfig(
        type: 'openai',
        endpoint: 'http://localhost:11434/v1',
        modelName: 'nomic-embed-text',
        displayName: 'Ollama',
        dimensions: 2,
        isCustom: true,
      );
      final provider = OpenAIEmbeddingProvider(
        keyless,
        httpPost: fakePost(
          captured,
          embeddingsResponse([
            [1.0, 0.0],
          ]),
        ),
      );

      await provider.embedQuery('q');

      final request = captured.single;
      expect(request.headers?.containsKey('Authorization'), isFalse);
      // Self-hosted servers may reject unknown params: dimensions is
      // omitted unless sendDimensions is set.
      expect(request.body.containsKey('dimensions'), isFalse);
      expect(await provider.isReady(), isTrue);
    });

    test('more inputs than maxBatchSize throws ArgumentError', () {
      var calls = 0;
      final provider = OpenAIEmbeddingProvider(
        config,
        httpPost: (url, {headers, body}) async {
          calls++;
          return embeddingsResponse([]);
        },
      );
      expect(
        () => provider.embedDocuments([
          for (var i = 0; i < provider.maxBatchSize + 1; i++)
            EmbeddingInput.text('t$i'),
        ]),
        throwsArgumentError,
      );
      expect(calls, 0);
    });

    test('image inputs are rejected (supportsImages is false)', () {
      final provider = OpenAIEmbeddingProvider(config);
      expect(provider.supportsImages, isFalse);
      expect(
        () => provider.embedDocuments([
          EmbeddingInput.image(Uint8List.fromList([1]), 'image/png'),
        ]),
        throwsA(isA<EmbeddingProviderException>()),
      );
    });
  });

  group('OpenAIEmbeddingProvider response parsing', () {
    // Canned vectors in this group are 2-dimensional; the runtime dims
    // guard requires the config to promise the same size.
    final parseConfig = config.copyWith(dimensions: 2);

    test('parses data[].embedding and L2-normalizes', () async {
      final provider = OpenAIEmbeddingProvider(
        parseConfig,
        httpPost: fakePost(
          [],
          embeddingsResponse([
            [3.0, 4.0],
          ]),
        ),
      );

      final vector = await provider.embedQuery('q');

      expect(vector, hasLength(2));
      expect(vector[0], closeTo(0.6, 1e-6));
      expect(vector[1], closeTo(0.8, 1e-6));
      final norm = math.sqrt(vector.fold<double>(0, (s, v) => s + v * v));
      expect(norm, closeTo(1.0, 1e-6));
    });

    test('orders results by index when server shuffles data', () async {
      final response = http.Response(
        jsonEncode({
          'data': [
            {
              'index': 1,
              'embedding': [0.0, 1.0],
            },
            {
              'index': 0,
              'embedding': [1.0, 0.0],
            },
          ],
        }),
        200,
      );
      final provider = OpenAIEmbeddingProvider(
        parseConfig,
        httpPost: (url, {headers, body}) async => response,
      );

      final vectors = await provider.embedDocuments(const [
        EmbeddingInput.text('first'),
        EmbeddingInput.text('second'),
      ]);

      expect(vectors[0][0], closeTo(1.0, 1e-6));
      expect(vectors[1][1], closeTo(1.0, 1e-6));
    });

    test(
      'index-less response preserves server order (no ??0 permutation)',
      () async {
        // Some OpenAI-compatible servers omit `index`; treating missing as 0
        // through a sort could permute results. Server order must be kept.
        final response = http.Response(
          jsonEncode({
            'data': [
              {
                'embedding': [1.0, 0.0],
              },
              {
                'embedding': [0.0, 1.0],
              },
            ],
          }),
          200,
        );
        final provider = OpenAIEmbeddingProvider(
          parseConfig,
          httpPost: (url, {headers, body}) async => response,
        );

        final vectors = await provider.embedDocuments(const [
          EmbeddingInput.text('first'),
          EmbeddingInput.text('second'),
        ]);

        expect(vectors[0][0], closeTo(1.0, 1e-6));
        expect(vectors[0][1], closeTo(0.0, 1e-6));
        expect(vectors[1][0], closeTo(0.0, 1e-6));
        expect(vectors[1][1], closeTo(1.0, 1e-6));
      },
    );

    test('duplicate index values throw a permanent error', () {
      final response = http.Response(
        jsonEncode({
          'data': [
            {
              'index': 0,
              'embedding': [1.0, 0.0],
            },
            {
              'index': 0,
              'embedding': [0.0, 1.0],
            },
          ],
        }),
        200,
      );
      final provider = OpenAIEmbeddingProvider(
        parseConfig,
        httpPost: (url, {headers, body}) async => response,
      );

      expect(
        () => provider.embedDocuments(const [
          EmbeddingInput.text('a'),
          EmbeddingInput.text('b'),
        ]),
        throwsA(
          isA<EmbeddingProviderException>().having(
            (e) => e.isTransient,
            'isTransient',
            isFalse,
          ),
        ),
      );
    });

    test('out-of-range index values throw a permanent error', () {
      final response = http.Response(
        jsonEncode({
          'data': [
            {
              'index': 1,
              'embedding': [1.0, 0.0],
            },
            {
              'index': 2,
              'embedding': [0.0, 1.0],
            },
          ],
        }),
        200,
      );
      final provider = OpenAIEmbeddingProvider(
        parseConfig,
        httpPost: (url, {headers, body}) async => response,
      );

      expect(
        () => provider.embedDocuments(const [
          EmbeddingInput.text('a'),
          EmbeddingInput.text('b'),
        ]),
        throwsA(isA<EmbeddingProviderException>()),
      );
    });

    test('count mismatch throws', () {
      final provider = OpenAIEmbeddingProvider(
        parseConfig,
        httpPost: fakePost(
          [],
          embeddingsResponse([
            [1.0, 0.0],
          ]),
        ),
      );
      expect(
        () => provider.embedDocuments(const [
          EmbeddingInput.text('a'),
          EmbeddingInput.text('b'),
        ]),
        throwsA(isA<EmbeddingProviderException>()),
      );
    });
  });

  group('OpenAIEmbeddingProvider error mapping', () {
    Future<EmbeddingProviderException> errorFor(int statusCode) async {
      final provider = OpenAIEmbeddingProvider(
        config,
        httpPost: (url, {headers, body}) async =>
            http.Response('{"error": {"message": "x"}}', statusCode),
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

    test('429 maps to isTransient', () async {
      final e = await errorFor(429);
      expect(e.isTransient, isTrue);
    });

    test('503 maps to isTransient', () async {
      final e = await errorFor(503);
      expect(e.isTransient, isTrue);
    });

    test('network failure maps to isTransient', () async {
      final provider = OpenAIEmbeddingProvider(
        config,
        httpPost: (url, {headers, body}) =>
            throw http.ClientException('refused'),
      );
      try {
        await provider.embedQuery('q');
        fail('expected EmbeddingProviderException');
      } on EmbeddingProviderException catch (e) {
        expect(e.isTransient, isTrue);
      }
    });
  });

  test('providerKey follows {type}:{model}:{dims}', () {
    final provider = OpenAIEmbeddingProvider(config);
    expect(provider.providerKey, 'openai:text-embedding-3-small:1536');
  });

  group('OpenAIEmbeddingProvider runtime dims guard', () {
    test(
      'off-size vectors throw a permanent mismatch naming both sizes',
      () async {
        // sendDimensions off + server with a different native size: without
        // the guard these vectors would be indexed under a providerKey whose
        // dims component lies.
        final provider = OpenAIEmbeddingProvider(
          config.copyWith(dimensions: 4, sendDimensions: false),
          httpPost: fakePost(
            [],
            embeddingsResponse([
              [1.0, 0.0, 0.0],
            ]),
          ),
        );

        await expectLater(
          provider.embedQuery('q'),
          throwsA(
            isA<EmbeddingProviderException>()
                .having((e) => e.detectedDimensions, 'detectedDimensions', 3)
                .having((e) => e.isAuthError, 'isAuthError', isFalse)
                .having((e) => e.isTransient, 'isTransient', isFalse)
                .having((e) => e.message, 'message', contains('3'))
                .having((e) => e.message, 'message', contains('4')),
          ),
        );
      },
    );

    test('matching vectors pass the guard', () async {
      final provider = OpenAIEmbeddingProvider(
        config.copyWith(dimensions: 3, sendDimensions: false),
        httpPost: fakePost(
          [],
          embeddingsResponse([
            [1.0, 0.0, 0.0],
          ]),
        ),
      );
      final vector = await provider.embedQuery('q');
      expect(vector, hasLength(3));
    });
  });
}
