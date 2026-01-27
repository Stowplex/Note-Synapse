import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:note_synapse/services/network_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('NetworkSettingsService - Protocol Preference', () {
    test('getProtocolPreference returns default when not set', () async {
      final result = await NetworkSettingsService.getProtocolPreference();
      expect(result, equals(NetworkProtocolPreference.auto));
    });

    test(
      'setProtocolPreference and getProtocolPreference round-trip',
      () async {
        await NetworkSettingsService.setProtocolPreference(
          NetworkProtocolPreference.http3Only,
        );
        final result = await NetworkSettingsService.getProtocolPreference();
        expect(result, equals(NetworkProtocolPreference.http3Only));
      },
    );

    test('setProtocolPreference http11Only', () async {
      await NetworkSettingsService.setProtocolPreference(
        NetworkProtocolPreference.http11Only,
      );
      final result = await NetworkSettingsService.getProtocolPreference();
      expect(result, equals(NetworkProtocolPreference.http11Only));
    });

    test(
      'getProtocolPreference returns default for invalid stored value',
      () async {
        SharedPreferences.setMockInitialValues({
          'network_protocol_preference': -1,
        });
        final result = await NetworkSettingsService.getProtocolPreference();
        expect(result, equals(NetworkProtocolPreference.auto));
      },
    );

    test(
      'getProtocolPreference returns default for out-of-range value',
      () async {
        SharedPreferences.setMockInitialValues({
          'network_protocol_preference': 999,
        });
        final result = await NetworkSettingsService.getProtocolPreference();
        expect(result, equals(NetworkProtocolPreference.auto));
      },
    );
  });

  group('NetworkSettingsService - Retry Count', () {
    test('getRetryCount returns default when not set', () async {
      final result = await NetworkSettingsService.getRetryCount();
      expect(result, equals(NetworkSettingsService.defaultRetryCount));
      expect(result, equals(3));
    });

    test('setRetryCount and getRetryCount round-trip', () async {
      await NetworkSettingsService.setRetryCount(5);
      final result = await NetworkSettingsService.getRetryCount();
      expect(result, equals(5));
    });

    test('setRetryCount clamps to minimum', () async {
      await NetworkSettingsService.setRetryCount(-10);
      final result = await NetworkSettingsService.getRetryCount();
      expect(result, equals(NetworkSettingsService.minRetryCount));
    });

    test('setRetryCount clamps to maximum', () async {
      await NetworkSettingsService.setRetryCount(100);
      final result = await NetworkSettingsService.getRetryCount();
      expect(result, equals(NetworkSettingsService.maxRetryCount));
    });

    test(
      'getRetryCount returns default for out-of-range stored value',
      () async {
        SharedPreferences.setMockInitialValues({'network_retry_count': -5});
        final result = await NetworkSettingsService.getRetryCount();
        expect(result, equals(NetworkSettingsService.defaultRetryCount));
      },
    );
  });

  group('NetworkSettingsService - Backoff Base', () {
    test('getBackoffBase returns default when not set', () async {
      final result = await NetworkSettingsService.getBackoffBase();
      expect(result, equals(NetworkSettingsService.defaultBackoffBase));
      expect(result, equals(2));
    });

    test('setBackoffBase and getBackoffBase round-trip', () async {
      await NetworkSettingsService.setBackoffBase(5);
      final result = await NetworkSettingsService.getBackoffBase();
      expect(result, equals(5));
    });

    test('setBackoffBase clamps to minimum', () async {
      await NetworkSettingsService.setBackoffBase(0);
      final result = await NetworkSettingsService.getBackoffBase();
      expect(result, equals(NetworkSettingsService.minBackoffBase));
    });

    test('setBackoffBase clamps to maximum', () async {
      await NetworkSettingsService.setBackoffBase(100);
      final result = await NetworkSettingsService.getBackoffBase();
      expect(result, equals(NetworkSettingsService.maxBackoffBase));
    });

    test(
      'getBackoffBase returns default for out-of-range stored value',
      () async {
        SharedPreferences.setMockInitialValues({'network_backoff_base': 0});
        final result = await NetworkSettingsService.getBackoffBase();
        expect(result, equals(NetworkSettingsService.defaultBackoffBase));
      },
    );
  });

  group('NetworkSettingsService - Timeout', () {
    test('getTimeout returns default when not set', () async {
      final result = await NetworkSettingsService.getTimeout();
      expect(result, equals(NetworkSettingsService.defaultTimeout));
      expect(result, equals(600)); // 10 minutes
    });

    test('setTimeout and getTimeout round-trip', () async {
      await NetworkSettingsService.setTimeout(120);
      final result = await NetworkSettingsService.getTimeout();
      expect(result, equals(120));
    });

    test('setTimeout clamps to minimum', () async {
      await NetworkSettingsService.setTimeout(1);
      final result = await NetworkSettingsService.getTimeout();
      expect(result, equals(NetworkSettingsService.minTimeout));
    });

    test('setTimeout clamps to maximum', () async {
      await NetworkSettingsService.setTimeout(9999);
      final result = await NetworkSettingsService.getTimeout();
      expect(result, equals(NetworkSettingsService.maxTimeout));
    });

    test('getTimeout returns default for out-of-range stored value', () async {
      SharedPreferences.setMockInitialValues({'network_timeout': 10});
      final result = await NetworkSettingsService.getTimeout();
      expect(result, equals(NetworkSettingsService.defaultTimeout));
    });
  });

  group('NetworkSettingsService - Connect Timeout', () {
    test('getConnectTimeout returns default when not set', () async {
      final result = await NetworkSettingsService.getConnectTimeout();
      expect(result, equals(NetworkSettingsService.defaultConnectTimeout));
      expect(result, equals(30));
    });

    test('setConnectTimeout and getConnectTimeout round-trip', () async {
      await NetworkSettingsService.setConnectTimeout(60);
      final result = await NetworkSettingsService.getConnectTimeout();
      expect(result, equals(60));
    });

    test('setConnectTimeout clamps to minimum', () async {
      await NetworkSettingsService.setConnectTimeout(1);
      final result = await NetworkSettingsService.getConnectTimeout();
      expect(result, equals(NetworkSettingsService.minConnectTimeout));
    });

    test('setConnectTimeout clamps to maximum', () async {
      await NetworkSettingsService.setConnectTimeout(500);
      final result = await NetworkSettingsService.getConnectTimeout();
      expect(result, equals(NetworkSettingsService.maxConnectTimeout));
    });

    test(
      'getConnectTimeout returns default for out-of-range stored value',
      () async {
        SharedPreferences.setMockInitialValues({'network_connect_timeout': 1});
        final result = await NetworkSettingsService.getConnectTimeout();
        expect(result, equals(NetworkSettingsService.defaultConnectTimeout));
      },
    );
  });

  group('NetworkSettingsService - Constants', () {
    test('constants have expected values', () {
      expect(
        NetworkSettingsService.defaultProtocolPreference,
        equals(NetworkProtocolPreference.auto),
      );
      expect(NetworkSettingsService.defaultRetryCount, equals(3));
      expect(NetworkSettingsService.minRetryCount, equals(0));
      expect(NetworkSettingsService.maxRetryCount, equals(5));
      expect(NetworkSettingsService.defaultBackoffBase, equals(2));
      expect(NetworkSettingsService.minBackoffBase, equals(1));
      expect(NetworkSettingsService.maxBackoffBase, equals(10));
      expect(NetworkSettingsService.defaultTimeout, equals(600));
      expect(NetworkSettingsService.minTimeout, equals(30));
      expect(NetworkSettingsService.maxTimeout, equals(1800));
      expect(NetworkSettingsService.defaultConnectTimeout, equals(30));
      expect(NetworkSettingsService.minConnectTimeout, equals(5));
      expect(NetworkSettingsService.maxConnectTimeout, equals(120));
    });
  });

  group('NetworkProtocolPreference enum', () {
    test('enum has expected values', () {
      expect(NetworkProtocolPreference.values.length, equals(3));
      expect(NetworkProtocolPreference.auto.index, equals(0));
      expect(NetworkProtocolPreference.http3Only.index, equals(1));
      expect(NetworkProtocolPreference.http11Only.index, equals(2));
    });
  });
}
