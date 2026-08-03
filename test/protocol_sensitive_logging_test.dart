import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/logger_service.dart';

void main() {
  test(
    'protocol analysis zone keeps AI payloads out of the global log bucket',
    () async {
      LoggerService.clearAiLogBucket();
      await LoggerService.runWithSensitiveDataRedacted(() async {
        LoggerService.logAiRequest(
          endpoint: 'https://ai.example/v1?key=provider-secret',
          headers: {'Authorization': 'Bearer provider-secret'},
          requestBody: {
            'prompt': 'captured-cookie-value and disclosed-payment-value',
          },
          requestId: 'protocol-1',
        );
        await Future<void>.delayed(Duration.zero);
        LoggerService.logAiResponse(
          statusCode: 200,
          headers: const {},
          responseBody: {'text': 'model repeated disclosed-payment-value'},
          requestId: 'protocol-1',
        );
      });

      final encoded = LoggerService.aiLogBucket
          .map((entry) => entry.toJson().toString())
          .join('\n');
      expect(encoded, isNot(contains('captured-cookie-value')));
      expect(encoded, isNot(contains('disclosed-payment-value')));
      expect(encoded, isNot(contains('provider-secret')));
      expect(encoded, contains('redacted'));
      expect(LoggerService.aiLogBucket.first.endpoint, 'https://ai.example/v1');
    },
  );
}
