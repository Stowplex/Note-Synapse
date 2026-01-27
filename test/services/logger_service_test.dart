import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/services/logger_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AiLogEntry', () {
    test('constructor creates entry with required properties', () {
      final timestamp = DateTime.now();
      final entry = AiLogEntry(
        id: 'test-id',
        type: 'request',
        endpoint: 'https://api.example.com',
        data: {'key': 'value'},
        timestamp: timestamp,
      );

      expect(entry.id, equals('test-id'));
      expect(entry.type, equals('request'));
      expect(entry.endpoint, equals('https://api.example.com'));
      expect(entry.data, equals({'key': 'value'}));
      expect(entry.timestamp, equals(timestamp));
    });

    test('toJson serializes entry correctly', () {
      final timestamp = DateTime(2024, 1, 15, 10, 30, 0);
      final entry = AiLogEntry(
        id: 'log-123',
        type: 'response',
        endpoint: 'https://api.test.com',
        data: {'status': 200},
        timestamp: timestamp,
      );

      final json = entry.toJson();

      expect(json['id'], equals('log-123'));
      expect(json['type'], equals('response'));
      expect(json['endpoint'], equals('https://api.test.com'));
      expect(json['data'], equals({'status': 200}));
      expect(json['timestamp'], equals('2024-01-15T10:30:00.000'));
    });
  });

  group('LoggerService - Max Log Entries', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      LoggerService.clearAiLogBucket();
    });

    test('defaultMaxLogEntries has expected value', () {
      expect(LoggerService.defaultMaxLogEntries, equals(100));
    });

    test('getMaxLogEntries returns default when not set', () async {
      final result = await LoggerService.getMaxLogEntries();
      expect(result, equals(LoggerService.defaultMaxLogEntries));
    });

    test('setMaxLogEntries and getMaxLogEntries round-trip', () async {
      await LoggerService.setMaxLogEntries(500);
      final result = await LoggerService.getMaxLogEntries();
      expect(result, equals(500));
    });

    test('setMaxLogEntries with -1 for unlimited', () async {
      await LoggerService.setMaxLogEntries(-1);
      final result = await LoggerService.getMaxLogEntries();
      expect(result, equals(-1));
    });

    test('setMaxLogEntries with 0 to disable', () async {
      await LoggerService.setMaxLogEntries(0);
      final result = await LoggerService.getMaxLogEntries();
      expect(result, equals(0));
    });
  });

  group('LoggerService - AI Log Bucket', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      LoggerService.clearAiLogBucket();
    });

    test('aiLogBucket starts empty', () {
      expect(LoggerService.aiLogBucket, isEmpty);
    });

    test('clearAiLogBucket clears all entries', () async {
      // Set up bucket with reasonable limit
      await LoggerService.setMaxLogEntries(100);

      LoggerService.logAiRequest(
        endpoint: 'https://api.test.com',
        headers: {'Content-Type': 'application/json'},
        requestBody: {'prompt': 'test'},
      );

      expect(LoggerService.aiLogBucket, isNotEmpty);

      LoggerService.clearAiLogBucket();

      expect(LoggerService.aiLogBucket, isEmpty);
    });

    test('aiLogBucket is unmodifiable', () {
      final bucket = LoggerService.aiLogBucket;
      expect(
        () => (bucket as List).add(
          AiLogEntry(
            id: 'test',
            type: 'test',
            endpoint: 'test',
            data: {},
            timestamp: DateTime.now(),
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('logAiRequest adds entry to bucket', () async {
      await LoggerService.setMaxLogEntries(100);

      LoggerService.logAiRequest(
        endpoint: 'https://api.example.com/v1/generate',
        headers: {'Authorization': 'Bearer token'},
        requestBody: {'messages': []},
        requestId: 'req-001',
      );

      final bucket = LoggerService.aiLogBucket;
      expect(bucket.length, equals(1));
      expect(bucket.first.id, equals('req-001'));
      expect(bucket.first.type, equals('request'));
      expect(
        bucket.first.endpoint,
        equals('https://api.example.com/v1/generate'),
      );
    });

    test('logAiResponse adds entry to bucket', () async {
      await LoggerService.setMaxLogEntries(100);

      LoggerService.logAiResponse(
        statusCode: 200,
        headers: {'Content-Type': 'application/json'},
        responseBody: {'result': 'success'},
        requestId: 'req-002',
        duration: const Duration(milliseconds: 1500),
      );

      final bucket = LoggerService.aiLogBucket;
      expect(bucket.length, equals(1));
      expect(bucket.first.type, equals('response'));
      expect(bucket.first.data['statusCode'], equals(200));
      expect(bucket.first.data['duration'], equals(1500));
    });

    test('logAiError adds entry to bucket', () async {
      await LoggerService.setMaxLogEntries(100);

      LoggerService.logAiError(
        error: 'Connection timeout',
        endpoint: 'https://api.example.com',
        requestId: 'req-003',
        duration: const Duration(seconds: 30),
      );

      final bucket = LoggerService.aiLogBucket;
      expect(bucket.length, equals(1));
      expect(bucket.first.type, equals('error'));
      expect(bucket.first.data['error'], equals('Connection timeout'));
    });

    test('logAiConsole adds entry to bucket', () async {
      await LoggerService.setMaxLogEntries(100);

      LoggerService.logAiConsole(
        consoleOutput: 'Debug: processing request',
        endpoint: 'local',
        requestId: 'req-004',
      );

      final bucket = LoggerService.aiLogBucket;
      expect(bucket.length, equals(1));
      expect(bucket.first.type, equals('console'));
      expect(
        bucket.first.data['consoleOutput'],
        equals('Debug: processing request'),
      );
    });

    test('bucket respects max entries limit', () async {
      await LoggerService.setMaxLogEntries(3);

      // Add 5 entries
      for (int i = 1; i <= 5; i++) {
        LoggerService.logAiRequest(
          endpoint: 'https://api.example.com',
          headers: {},
          requestBody: {'index': i},
          requestId: 'req-$i',
        );
      }

      final bucket = LoggerService.aiLogBucket;
      expect(bucket.length, equals(3));
      // Should have kept the last 3 entries
      expect(bucket[0].id, equals('req-3'));
      expect(bucket[1].id, equals('req-4'));
      expect(bucket[2].id, equals('req-5'));
    });

    test('setting 0 disables logging and clears bucket', () async {
      await LoggerService.setMaxLogEntries(100);

      LoggerService.logAiRequest(
        endpoint: 'https://api.example.com',
        headers: {},
        requestBody: {},
      );

      expect(LoggerService.aiLogBucket.length, equals(1));

      await LoggerService.setMaxLogEntries(0);

      // Bucket should be cleared
      expect(LoggerService.aiLogBucket, isEmpty);

      // New logs should not be added
      LoggerService.logAiRequest(
        endpoint: 'https://api.example.com',
        headers: {},
        requestBody: {},
      );

      expect(LoggerService.aiLogBucket, isEmpty);
    });
  });

  group('LoggerService - Basic Logging Methods', () {
    // These methods call the logger but we can at least verify they don't throw
    test('debug does not throw', () {
      expect(() => LoggerService.debug('Debug message'), returnsNormally);
    });

    test('info does not throw', () {
      expect(() => LoggerService.info('Info message'), returnsNormally);
    });

    test('warning does not throw', () {
      expect(() => LoggerService.warning('Warning message'), returnsNormally);
    });

    test('error does not throw', () {
      expect(() => LoggerService.error('Error message'), returnsNormally);
    });

    test('verbose does not throw', () {
      expect(() => LoggerService.verbose('Verbose message'), returnsNormally);
    });

    test('debug with error parameter does not throw', () {
      expect(
        () => LoggerService.debug(
          'Debug with error',
          error: Exception('Test'),
          stackTrace: StackTrace.current,
        ),
        returnsNormally,
      );
    });
  });
}
