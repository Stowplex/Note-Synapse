import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/services/conversation_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ConversationSettingsService - Max Tool Iterations', () {
    test('getMaxToolIterations returns default when not set', () async {
      final result = await ConversationSettingsService.getMaxToolIterations();
      expect(
        result,
        equals(ConversationSettingsService.defaultMaxToolIterations),
      );
      expect(result, equals(10));
    });

    test('setMaxToolIterations and getMaxToolIterations round-trip', () async {
      await ConversationSettingsService.setMaxToolIterations(25);
      final result = await ConversationSettingsService.getMaxToolIterations();
      expect(result, equals(25));
    });

    test('setMaxToolIterations clamps to minimum', () async {
      await ConversationSettingsService.setMaxToolIterations(0);
      final result = await ConversationSettingsService.getMaxToolIterations();
      expect(result, equals(ConversationSettingsService.minToolIterations));
      expect(result, equals(1));
    });

    test('setMaxToolIterations clamps to maximum', () async {
      await ConversationSettingsService.setMaxToolIterations(1000);
      final result = await ConversationSettingsService.getMaxToolIterations();
      expect(result, equals(ConversationSettingsService.maxToolIterationsCap));
      expect(result, equals(50));
    });

    test('getMaxToolIterations clamps retrieved value to range', () async {
      // Simulate corrupted stored value above max
      SharedPreferences.setMockInitialValues({
        'conversation_max_tool_iterations': 100,
      });
      final result = await ConversationSettingsService.getMaxToolIterations();
      expect(result, equals(50)); // Clamped to max
    });

    test(
      'getMaxToolIterations clamps retrieved value below min to min',
      () async {
        // Simulate corrupted stored value below min
        SharedPreferences.setMockInitialValues({
          'conversation_max_tool_iterations': 0,
        });
        final result = await ConversationSettingsService.getMaxToolIterations();
        expect(result, equals(1)); // Clamped to min
      },
    );

    test('setMaxToolIterations with minimum boundary value', () async {
      await ConversationSettingsService.setMaxToolIterations(1);
      final result = await ConversationSettingsService.getMaxToolIterations();
      expect(result, equals(1));
    });

    test('setMaxToolIterations with maximum boundary value', () async {
      await ConversationSettingsService.setMaxToolIterations(50);
      final result = await ConversationSettingsService.getMaxToolIterations();
      expect(result, equals(50));
    });

    test('setMaxToolIterations with mid-range value', () async {
      await ConversationSettingsService.setMaxToolIterations(30);
      final result = await ConversationSettingsService.getMaxToolIterations();
      expect(result, equals(30));
    });
  });

  group('ConversationSettingsService - Constants', () {
    test('constants have expected values', () {
      expect(ConversationSettingsService.defaultMaxToolIterations, equals(10));
      expect(ConversationSettingsService.minToolIterations, equals(1));
      expect(ConversationSettingsService.maxToolIterationsCap, equals(50));
    });
  });
}
