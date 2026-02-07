import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/services/agentic_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AgenticSettingsService - Compaction Threshold', () {
    test('getCompactionThreshold returns default when not set', () async {
      final result = await AgenticSettingsService.getCompactionThreshold();
      expect(result, equals(AgenticSettingsService.defaultCompactionThreshold));
      expect(result, equals(100000));
    });

    test(
      'setCompactionThreshold and getCompactionThreshold round-trip',
      () async {
        await AgenticSettingsService.setCompactionThreshold(50000);
        final result = await AgenticSettingsService.getCompactionThreshold();
        expect(result, equals(50000));
      },
    );

    test('setCompactionThreshold clamps to minimum', () async {
      await AgenticSettingsService.setCompactionThreshold(100);
      final result = await AgenticSettingsService.getCompactionThreshold();
      expect(result, equals(AgenticSettingsService.minCompactionThreshold));
    });

    test('setCompactionThreshold clamps to maximum', () async {
      await AgenticSettingsService.setCompactionThreshold(1000000);
      final result = await AgenticSettingsService.getCompactionThreshold();
      expect(result, equals(AgenticSettingsService.maxCompactionThreshold));
    });

    test('getCompactionThreshold clamps stored value to range', () async {
      SharedPreferences.setMockInitialValues({
        'agentic_compaction_threshold': 5000,
      });
      final result = await AgenticSettingsService.getCompactionThreshold();
      expect(result, equals(AgenticSettingsService.minCompactionThreshold));
    });
  });

  group('AgenticSettingsService - Finding Limit', () {
    test('getFindingLimit returns default when not set', () async {
      final result = await AgenticSettingsService.getFindingLimit();
      expect(result, equals(AgenticSettingsService.defaultFindingLimit));
      expect(result, equals(10));
    });

    test('setFindingLimit and getFindingLimit round-trip', () async {
      await AgenticSettingsService.setFindingLimit(25);
      final result = await AgenticSettingsService.getFindingLimit();
      expect(result, equals(25));
    });

    test('setFindingLimit clamps to minimum', () async {
      await AgenticSettingsService.setFindingLimit(0);
      final result = await AgenticSettingsService.getFindingLimit();
      expect(result, equals(AgenticSettingsService.minFindingLimit));
    });

    test('setFindingLimit clamps to maximum', () async {
      await AgenticSettingsService.setFindingLimit(100);
      final result = await AgenticSettingsService.getFindingLimit();
      expect(result, equals(AgenticSettingsService.maxFindingLimit));
    });
  });

  group('AgenticSettingsService - Finding Max Words', () {
    test('getFindingMaxWords returns default when not set', () async {
      final result = await AgenticSettingsService.getFindingMaxWords();
      expect(result, equals(AgenticSettingsService.defaultFindingMaxWords));
      expect(result, equals(500));
    });

    test('setFindingMaxWords and getFindingMaxWords round-trip', () async {
      await AgenticSettingsService.setFindingMaxWords(1000);
      final result = await AgenticSettingsService.getFindingMaxWords();
      expect(result, equals(1000));
    });

    test('setFindingMaxWords clamps to minimum', () async {
      await AgenticSettingsService.setFindingMaxWords(10);
      final result = await AgenticSettingsService.getFindingMaxWords();
      expect(result, equals(AgenticSettingsService.minFindingMaxWords));
    });

    test('setFindingMaxWords clamps to maximum', () async {
      await AgenticSettingsService.setFindingMaxWords(5000);
      final result = await AgenticSettingsService.getFindingMaxWords();
      expect(result, equals(AgenticSettingsService.maxFindingMaxWords));
    });
  });

  group('AgenticSettingsService - Max Turns', () {
    test('getMaxTurns returns default when not set', () async {
      final result = await AgenticSettingsService.getMaxTurns();
      expect(result, equals(AgenticSettingsService.defaultMaxTurns));
      expect(result, equals(10));
    });

    test('setMaxTurns and getMaxTurns round-trip', () async {
      await AgenticSettingsService.setMaxTurns(50);
      final result = await AgenticSettingsService.getMaxTurns();
      expect(result, equals(50));
    });

    test('setMaxTurns clamps to minimum', () async {
      await AgenticSettingsService.setMaxTurns(0);
      final result = await AgenticSettingsService.getMaxTurns();
      expect(result, equals(AgenticSettingsService.minMaxTurns));
    });

    test('setMaxTurns clamps to maximum', () async {
      await AgenticSettingsService.setMaxTurns(500);
      final result = await AgenticSettingsService.getMaxTurns();
      expect(result, equals(AgenticSettingsService.maxMaxTurns));
    });
  });

  group('AgenticSettingsService - Turn Increment', () {
    test('getTurnIncrement returns default when not set', () async {
      final result = await AgenticSettingsService.getTurnIncrement();
      expect(result, equals(AgenticSettingsService.defaultTurnIncrement));
      expect(result, equals(10));
    });

    test('setTurnIncrement and getTurnIncrement round-trip', () async {
      await AgenticSettingsService.setTurnIncrement(15);
      final result = await AgenticSettingsService.getTurnIncrement();
      expect(result, equals(15));
    });

    test('setTurnIncrement clamps to minimum', () async {
      await AgenticSettingsService.setTurnIncrement(2);
      final result = await AgenticSettingsService.getTurnIncrement();
      expect(result, equals(AgenticSettingsService.minTurnIncrement));
    });

    test('setTurnIncrement clamps to maximum', () async {
      await AgenticSettingsService.setTurnIncrement(100);
      final result = await AgenticSettingsService.getTurnIncrement();
      expect(result, equals(AgenticSettingsService.maxTurnIncrement));
    });
  });

  group('AgenticSettingsService - TOC Inline Threshold', () {
    test('getTocInlineThreshold returns default when not set', () async {
      final result = await AgenticSettingsService.getTocInlineThreshold();
      expect(result, equals(AgenticSettingsService.defaultTocInlineThreshold));
      expect(result, equals(1000));
    });

    test(
      'setTocInlineThreshold and getTocInlineThreshold round-trip',
      () async {
        await AgenticSettingsService.setTocInlineThreshold(2500);
        final result = await AgenticSettingsService.getTocInlineThreshold();
        expect(result, equals(2500));
      },
    );

    test('setTocInlineThreshold clamps to minimum', () async {
      await AgenticSettingsService.setTocInlineThreshold(50);
      final result = await AgenticSettingsService.getTocInlineThreshold();
      expect(result, equals(AgenticSettingsService.minTocInlineThreshold));
    });

    test('setTocInlineThreshold clamps to maximum', () async {
      await AgenticSettingsService.setTocInlineThreshold(10000);
      final result = await AgenticSettingsService.getTocInlineThreshold();
      expect(result, equals(AgenticSettingsService.maxTocInlineThreshold));
    });
  });

  group('AgenticSettingsService - Max Subtask Depth', () {
    test('getMaxSubtaskDepth returns default when not set', () async {
      final result = await AgenticSettingsService.getMaxSubtaskDepth();
      expect(result, equals(AgenticSettingsService.defaultMaxSubtaskDepth));
      expect(result, equals(2));
    });

    test('setMaxSubtaskDepth and getMaxSubtaskDepth round-trip', () async {
      await AgenticSettingsService.setMaxSubtaskDepth(4);
      final result = await AgenticSettingsService.getMaxSubtaskDepth();
      expect(result, equals(4));
    });

    test('setMaxSubtaskDepth clamps to minimum (allows 0)', () async {
      await AgenticSettingsService.setMaxSubtaskDepth(-5);
      final result = await AgenticSettingsService.getMaxSubtaskDepth();
      expect(result, equals(AgenticSettingsService.minMaxSubtaskDepth));
      expect(result, equals(0)); // 0 is valid - disables subtasks
    });

    test('setMaxSubtaskDepth clamps to maximum', () async {
      await AgenticSettingsService.setMaxSubtaskDepth(10);
      final result = await AgenticSettingsService.getMaxSubtaskDepth();
      expect(result, equals(AgenticSettingsService.maxMaxSubtaskDepth));
    });

    test('setMaxSubtaskDepth accepts zero', () async {
      await AgenticSettingsService.setMaxSubtaskDepth(0);
      final result = await AgenticSettingsService.getMaxSubtaskDepth();
      expect(result, equals(0));
    });
  });

  group('AgenticSettingsService - Constants', () {
    test('constants have expected values', () {
      expect(AgenticSettingsService.defaultCompactionThreshold, equals(100000));
      expect(AgenticSettingsService.minCompactionThreshold, equals(10000));
      expect(AgenticSettingsService.maxCompactionThreshold, equals(500000));

      expect(AgenticSettingsService.defaultFindingLimit, equals(10));
      expect(AgenticSettingsService.minFindingLimit, equals(1));
      expect(AgenticSettingsService.maxFindingLimit, equals(50));

      expect(AgenticSettingsService.defaultFindingMaxWords, equals(500));
      expect(AgenticSettingsService.minFindingMaxWords, equals(100));
      expect(AgenticSettingsService.maxFindingMaxWords, equals(2000));

      expect(AgenticSettingsService.defaultMaxTurns, equals(10));
      expect(AgenticSettingsService.minMaxTurns, equals(1));
      expect(AgenticSettingsService.maxMaxTurns, equals(100));

      expect(AgenticSettingsService.defaultTurnIncrement, equals(10));
      expect(AgenticSettingsService.minTurnIncrement, equals(5));
      expect(AgenticSettingsService.maxTurnIncrement, equals(30));

      expect(AgenticSettingsService.defaultTocInlineThreshold, equals(1000));
      expect(AgenticSettingsService.minTocInlineThreshold, equals(100));
      expect(AgenticSettingsService.maxTocInlineThreshold, equals(5000));

      expect(AgenticSettingsService.defaultMaxSubtaskDepth, equals(2));
      expect(AgenticSettingsService.minMaxSubtaskDepth, equals(0));
      expect(AgenticSettingsService.maxMaxSubtaskDepth, equals(5));
    });
  });
}
