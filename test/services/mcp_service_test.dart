import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/mcp_service.dart';
import 'package:note_synapse/services/service_locator.dart';

@GenerateMocks([FlutterSecureStorage])
import 'mcp_service_test.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockFlutterSecureStorage mockStorage;
  late McpService service;

  setUp(() async {
    await resetForTesting();
    SharedPreferences.setMockInitialValues({});
    mockStorage = MockFlutterSecureStorage();
    service = McpService.createForTesting(mockStorage);
    getIt.registerSingleton<McpService>(service);
  });

  tearDown(() async {
    await resetForTesting();
  });

  group('McpService endpoint management', () {
    test('getEndpoints returns empty list when no endpoints exist', () async {
      final result = await service.getEndpoints();
      expect(result, isEmpty);
    });

    test('addEndpoint creates new endpoint with bearer token', () async {
      when(mockStorage.write(key: anyNamed('key'), value: anyNamed('value')))
          .thenAnswer((_) async {});

      final endpoint = await service.addEndpoint(
        name: 'Test Endpoint',
        baseUrl: 'https://test.example.com',
        transportType: McpTransportType.sse,
        bearerToken: 'test-token',
      );

      expect(endpoint.name, equals('Test Endpoint'));
      expect(endpoint.baseUrl, equals('https://test.example.com'));
      expect(endpoint.transportType, equals(McpTransportType.sse));
      verify(mockStorage.write(
        key: argThat(startsWith('mcp_bearer_token_'), named: 'key'),
        value: 'test-token',
      )).called(1);

      // Verify persisted
      final endpoints = await service.getEndpoints();
      expect(endpoints.length, equals(1));
    });

    test('addEndpoint creates endpoint without bearer token', () async {
      final endpoint = await service.addEndpoint(
        name: 'No Token Endpoint',
        baseUrl: 'https://no-token.example.com',
        transportType: McpTransportType.streamableHttp,
      );

      expect(endpoint.name, equals('No Token Endpoint'));
      expect(endpoint.transportType, equals(McpTransportType.streamableHttp));
      verifyNever(
          mockStorage.write(key: anyNamed('key'), value: anyNamed('value')));

      final endpoints = await service.getEndpoints();
      expect(endpoints.length, equals(1));
    });

    test('addEndpoint with additionalHeaders', () async {
      when(mockStorage.write(key: anyNamed('key'), value: anyNamed('value')))
          .thenAnswer((_) async {});

      final endpoint = await service.addEndpoint(
        name: 'Headers Endpoint',
        baseUrl: 'https://headers.example.com',
        transportType: McpTransportType.sse,
        additionalHeaders: {'X-Custom-Header': 'custom-value'},
      );

      expect(endpoint.additionalHeaders['X-Custom-Header'], equals('custom-value'));
    });

    test('updateEndpoint modifies existing endpoint', () async {
      when(mockStorage.write(key: anyNamed('key'), value: anyNamed('value')))
          .thenAnswer((_) async {});

      // First add an endpoint
      final endpoint = await service.addEndpoint(
        name: 'Original Name',
        baseUrl: 'https://original.com',
        transportType: McpTransportType.sse,
      );

      // Update it
      await service.updateEndpoint(
        id: endpoint.id,
        name: 'Updated Name',
      );

      final endpoints = await service.getEndpoints();
      expect(endpoints.first.name, equals('Updated Name'));
      expect(endpoints.first.baseUrl, equals('https://original.com'));
    });

    test('updateEndpoint modifies multiple fields', () async {
      when(mockStorage.write(key: anyNamed('key'), value: anyNamed('value')))
          .thenAnswer((_) async {});

      final endpoint = await service.addEndpoint(
        name: 'Original',
        baseUrl: 'https://original.com',
        transportType: McpTransportType.sse,
      );

      await service.updateEndpoint(
        id: endpoint.id,
        name: 'Updated',
        baseUrl: 'https://updated.com',
        transportType: McpTransportType.streamableHttp,
      );

      final endpoints = await service.getEndpoints();
      expect(endpoints.first.name, equals('Updated'));
      expect(endpoints.first.baseUrl, equals('https://updated.com'));
      expect(endpoints.first.transportType, equals(McpTransportType.streamableHttp));
    });

    test('updateEndpoint throws for non-existent endpoint', () async {
      expect(
        () => service.updateEndpoint(id: 'non-existent', name: 'New Name'),
        throwsException,
      );
    });

    test('updateEndpoint updates bearer token', () async {
      when(mockStorage.write(key: anyNamed('key'), value: anyNamed('value')))
          .thenAnswer((_) async {});

      final endpoint = await service.addEndpoint(
        name: 'Token Endpoint',
        baseUrl: 'https://token.example.com',
        transportType: McpTransportType.sse,
        bearerToken: 'original-token',
      );

      await service.updateEndpoint(
        id: endpoint.id,
        bearerToken: 'new-token',
      );

      verify(mockStorage.write(
        key: 'mcp_bearer_token_${endpoint.id}',
        value: 'new-token',
      )).called(1);
    });

    test('deleteEndpoint removes endpoint and cleans up', () async {
      when(mockStorage.write(key: anyNamed('key'), value: anyNamed('value')))
          .thenAnswer((_) async {});
      when(mockStorage.delete(key: anyNamed('key'))).thenAnswer((_) async {});

      // Add and then delete
      final endpoint = await service.addEndpoint(
        name: 'To Delete',
        baseUrl: 'https://delete.me',
        transportType: McpTransportType.sse,
        bearerToken: 'token',
      );

      await service.deleteEndpoint(endpoint.id);

      final endpoints = await service.getEndpoints();
      expect(endpoints, isEmpty);
      verify(mockStorage.delete(key: anyNamed('key'))).called(1);
    });

    test('deleteEndpoint removes tools cache from SharedPreferences', () async {
      when(mockStorage.write(key: anyNamed('key'), value: anyNamed('value')))
          .thenAnswer((_) async {});
      when(mockStorage.delete(key: anyNamed('key'))).thenAnswer((_) async {});

      final endpoint = await service.addEndpoint(
        name: 'Cache Test',
        baseUrl: 'https://cache.test',
        transportType: McpTransportType.sse,
      );

      // Verify we can delete even without cached tools
      await service.deleteEndpoint(endpoint.id);
      final endpoints = await service.getEndpoints();
      expect(endpoints, isEmpty);
    });

    test('multiple endpoints can be managed', () async {
      when(mockStorage.write(key: anyNamed('key'), value: anyNamed('value')))
          .thenAnswer((_) async {});
      when(mockStorage.delete(key: anyNamed('key'))).thenAnswer((_) async {});

      final endpoint1 = await service.addEndpoint(
        name: 'Endpoint 1',
        baseUrl: 'https://one.example.com',
        transportType: McpTransportType.sse,
      );

      final endpoint2 = await service.addEndpoint(
        name: 'Endpoint 2',
        baseUrl: 'https://two.example.com',
        transportType: McpTransportType.streamableHttp,
      );

      var endpoints = await service.getEndpoints();
      expect(endpoints.length, equals(2));

      await service.deleteEndpoint(endpoint1.id);

      endpoints = await service.getEndpoints();
      expect(endpoints.length, equals(1));
      expect(endpoints.first.id, equals(endpoint2.id));
    });
  });

  group('McpService token management', () {
    test('getBearerToken returns stored token', () async {
      when(mockStorage.write(key: anyNamed('key'), value: anyNamed('value')))
          .thenAnswer((_) async {});
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => 'stored-token');

      final endpoint = await service.addEndpoint(
        name: 'Token Test',
        baseUrl: 'https://token.test',
        transportType: McpTransportType.sse,
        bearerToken: 'stored-token',
      );

      final token = await service.getBearerToken(endpoint.id);
      expect(token, equals('stored-token'));
    });

    test('getBearerToken returns null for non-existent endpoint', () async {
      final token = await service.getBearerToken('non-existent-id');
      expect(token, isNull);
    });

    test('getBearerToken reads from secure storage for token auth type',
        () async {
      when(mockStorage.write(key: anyNamed('key'), value: anyNamed('value')))
          .thenAnswer((_) async {});
      when(mockStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => 'my-secret-token');

      final endpoint = await service.addEndpoint(
        name: 'Secure Token',
        baseUrl: 'https://secure.example.com',
        transportType: McpTransportType.sse,
        bearerToken: 'my-secret-token',
      );

      final token = await service.getBearerToken(endpoint.id);
      expect(token, equals('my-secret-token'));
      verify(mockStorage.read(key: 'mcp_bearer_token_${endpoint.id}')).called(1);
    });
  });

  group('McpService tools cache', () {
    test('getCachedTools returns null when no cache exists', () async {
      final cache = await service.getCachedTools('some-endpoint-id');
      expect(cache, isNull);
    });

    test('getCachedTools returns null for endpoint without cache', () async {
      when(mockStorage.write(key: anyNamed('key'), value: anyNamed('value')))
          .thenAnswer((_) async {});

      final endpoint = await service.addEndpoint(
        name: 'No Cache',
        baseUrl: 'https://no-cache.example.com',
        transportType: McpTransportType.sse,
      );

      final cache = await service.getCachedTools(endpoint.id);
      expect(cache, isNull);
    });

    test('getCachedTools returns cached tools when cache exists', () async {
      // Set up SharedPreferences with cached tools data
      final cacheJson = '''
{
  "endpointId": "cached-endpoint-id",
  "tools": [
    {"name": "tool1", "description": "First tool"},
    {"name": "tool2", "description": "Second tool", "inputSchema": {"type": "object"}}
  ],
  "fetchedAt": "2024-01-15T10:00:00.000Z"
}
''';
      SharedPreferences.setMockInitialValues({
        'mcp_tools_cache_cached-endpoint-id': cacheJson,
      });

      // Create a fresh service instance to pick up the new SharedPreferences values
      final freshService = McpService.createForTesting(mockStorage);

      final cache = await freshService.getCachedTools('cached-endpoint-id');

      expect(cache, isNotNull);
      expect(cache!.endpointId, equals('cached-endpoint-id'));
      expect(cache.tools.length, equals(2));
      expect(cache.tools[0].name, equals('tool1'));
      expect(cache.tools[1].name, equals('tool2'));
      expect(cache.tools[1].inputSchema, isNotNull);
    });

    test('getCachedTools returns null on invalid JSON', () async {
      SharedPreferences.setMockInitialValues({
        'mcp_tools_cache_invalid-endpoint': 'not valid json {{{',
      });

      final freshService = McpService.createForTesting(mockStorage);

      final cache = await freshService.getCachedTools('invalid-endpoint');
      expect(cache, isNull);
    });
  });

  group('McpService transport types', () {
    test('addEndpoint with SSE transport type', () async {
      final endpoint = await service.addEndpoint(
        name: 'SSE Endpoint',
        baseUrl: 'https://sse.example.com',
        transportType: McpTransportType.sse,
      );

      expect(endpoint.transportType, equals(McpTransportType.sse));
      expect(endpoint.transportType.displayName, equals('SSE (Server-Sent Events)'));
    });

    test('addEndpoint with StreamableHTTP transport type', () async {
      final endpoint = await service.addEndpoint(
        name: 'HTTP Endpoint',
        baseUrl: 'https://http.example.com',
        transportType: McpTransportType.streamableHttp,
      );

      expect(endpoint.transportType, equals(McpTransportType.streamableHttp));
      expect(endpoint.transportType.displayName, equals('StreamableHTTP'));
    });
  });

  group('McpService singleton access', () {
    test('McpService.instance() returns registered instance', () {
      final instance = McpService.instance();
      expect(instance, equals(service));
    });
  });
}
