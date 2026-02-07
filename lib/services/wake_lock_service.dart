import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'logger_service.dart';

const String _wakeLockKey = 'keep_screen_on';

/// Service to manage wake lock state for keeping the screen on.
/// Default is disabled (screen can turn off automatically).

Future<void> initializeWakeLock() async {
  final enabled = await isWakeLockEnabled();
  if (enabled) {
    await enableWakeLock();
  }
}

Future<bool> isWakeLockEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_wakeLockKey) ?? false;
}

Future<void> enableWakeLock() async {
  try {
    await WakelockPlus.enable();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_wakeLockKey, true);
    LoggerService.info('Wake lock enabled');
  } catch (e) {
    LoggerService.error('Failed to enable wake lock: $e');
  }
}

Future<void> disableWakeLock() async {
  try {
    await WakelockPlus.disable();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_wakeLockKey, false);
    LoggerService.info('Wake lock disabled');
  } catch (e) {
    LoggerService.error('Failed to disable wake lock: $e');
  }
}

Future<void> setWakeLock(bool enabled) async {
  if (enabled) {
    await enableWakeLock();
  } else {
    await disableWakeLock();
  }
}
