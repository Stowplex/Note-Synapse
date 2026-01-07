import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Service for managing background execution of agent tasks on Android.
/// Uses Android foreground service to keep execution running when app is backgrounded.
class BackgroundAgentService {
  static bool _isInitialized = false;
  static bool _isRunningInBackground = false;
  static String? _pendingConversationId;

  /// Whether agent is currently running in background mode.
  static bool get isRunningInBackground => _isRunningInBackground;

  /// Conversation ID to restore when user returns from notification tap.
  static String? get pendingConversationId => _pendingConversationId;

  /// Initialize foreground task configuration.
  /// Should be called once in main.dart before runApp.
  static Future<void> init() async {
    // Only available on Android
    if (!Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'agent_execution_channel',
        channelName: 'Agent Execution',
        channelDescription: 'Shows progress when agent runs in background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        playSound: false,
        enableVibration: false,
        showWhen: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false, // iOS doesn't support foreground service
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _isInitialized = true;
  }

  /// Start background execution mode.
  /// Called when app goes to background while agent is running.
  static Future<void> startBackgroundExecution({
    required String conversationId,
    required String objective,
  }) async {
    if (!Platform.isAndroid || !_isInitialized) return;

    _pendingConversationId = conversationId;
    _isRunningInBackground = true;

    // Request notification permission on Android 13+
    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    // Start the foreground service
    await FlutterForegroundTask.startService(
      notificationTitle: 'Agent Running',
      notificationText: _truncateObjective(objective),
      notificationIcon: null, // Use default app icon
      notificationInitialRoute: '/',
      callback: _foregroundCallback,
    );
  }

  /// Update notification with current progress.
  /// Called by AgentService.onProgressUpdate callback.
  static void updateProgress(String status) {
    if (!_isRunningInBackground || !Platform.isAndroid) return;

    FlutterForegroundTask.updateService(
      notificationTitle: 'Agent Running',
      notificationText: _truncate(status, 100),
    );
  }

  /// Mark agent as complete and update notification.
  static void markComplete(String summary) {
    if (!_isRunningInBackground || !Platform.isAndroid) return;

    FlutterForegroundTask.updateService(
      notificationTitle: 'Agent Complete',
      notificationText: 'Tap to view results',
    );
  }

  /// Stop foreground service.
  /// Called when user returns to app or agent completes while in foreground.
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;

    _isRunningInBackground = false;
    await FlutterForegroundTask.stopService();
  }

  /// Clear pending state after navigation is handled.
  static void clearPendingState() {
    _pendingConversationId = null;
  }

  /// Check if service was running when app started.
  /// Used to detect launch from notification tap.
  static Future<bool> checkPendingFromNotification() async {
    if (!Platform.isAndroid) return false;
    return await FlutterForegroundTask.isRunningService;
  }

  // Truncate objective for notification display
  static String _truncateObjective(String objective) {
    return _truncate('Working on: $objective', 100);
  }

  static String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength - 3)}...';
  }
}

// This callback is required by flutter_foreground_task but we don't use it
// because our agent logic runs in the main isolate.
@pragma('vm:entry-point')
void _foregroundCallback() {
  // No-op: Agent execution happens in main isolate, not here.
  // This is required for foreground service API but we use it purely
  // for the persistent notification.
}
