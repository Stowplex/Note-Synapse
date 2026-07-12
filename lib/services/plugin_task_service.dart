import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/generation_context.dart';
import '../providers/app_provider.dart';
import 'ai_tool_service.dart';
import 'database_service.dart';
import 'logger_service.dart';
import 'service_locator.dart';

/// A persisted request to invoke a plugin's own AI tool after a delay.
class ScheduledPluginTask {
  ScheduledPluginTask({
    required this.id,
    required this.appUuid,
    required this.tool,
    required this.params,
    required this.fireAt,
    required this.delaySeconds,
    required this.maxRuns,
    this.runCount = 0,
  });

  final String id;
  final String appUuid;
  final String tool;
  final Map<String, dynamic> params;

  /// Epoch millis when this task should next fire.
  int fireAt;
  final int delaySeconds;
  final int maxRuns;
  int runCount;

  Map<String, dynamic> toJson() => {
        'id': id,
        'appUuid': appUuid,
        'tool': tool,
        'params': params,
        'fireAt': fireAt,
        'delaySeconds': delaySeconds,
        'maxRuns': maxRuns,
        'runCount': runCount,
      };

  factory ScheduledPluginTask.fromJson(Map<String, dynamic> json) {
    return ScheduledPluginTask(
      id: json['id'] as String,
      appUuid: json['appUuid'] as String,
      tool: json['tool'] as String,
      params: (json['params'] as Map?)?.cast<String, dynamic>() ?? const {},
      fireAt: (json['fireAt'] as num).toInt(),
      delaySeconds: (json['delaySeconds'] as num).toInt(),
      maxRuns: (json['maxRuns'] as num?)?.toInt() ?? 1,
      runCount: (json['runCount'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toSummary() => {
        'taskId': id,
        'tool': tool,
        'fireAt': fireAt,
        'runCount': runCount,
        'maxRuns': maxRuns,
      };
}

/// Generic scheduler that re-invokes a plugin's own AI tool after a delay, so
/// multi-minute remote jobs (e.g. polling a NotebookLM studio generation to
/// completion) can finish even after the plugin's UI is closed.
///
/// The scheduler is domain-agnostic: it knows only how to re-run a named tool
/// on a named app; the tool decides what to do (poll, save an artifact,
/// reschedule itself, or stop). Tasks are persisted so they survive an app
/// relaunch ([initialize] re-arms them). Android foreground-service continuation
/// (running while backgrounded) is a later addition; today tasks fire while the
/// app process is alive.
class PluginTaskService {
  PluginTaskService({SharedPreferences? prefs}) : _injectedPrefs = prefs;

  final SharedPreferences? _injectedPrefs;
  static const String _key = 'plugin_scheduled_tasks';
  static const Uuid _uuid = Uuid();

  final Map<String, Timer> _timers = {};
  bool _initialized = false;

  Future<SharedPreferences> get _prefs async =>
      _injectedPrefs ?? await SharedPreferences.getInstance();

  int get _now => DateTime.now().millisecondsSinceEpoch;

  Future<List<ScheduledPluginTask>> _load() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((m) => ScheduledPluginTask.fromJson(m.cast<String, dynamic>()))
            .toList();
      }
    } catch (e) {
      LoggerService.warning('PluginTaskService: corrupt store, resetting: $e');
    }
    return [];
  }

  Future<void> _save(List<ScheduledPluginTask> tasks) async {
    final prefs = await _prefs;
    await prefs.setString(
      _key,
      jsonEncode(tasks.map((t) => t.toJson()).toList()),
    );
  }

  // Serializes read-modify-write sequences so concurrent fires/schedules on the
  // single-item store don't clobber each other (lost updates). Long work like
  // invoking a tool must stay OUTSIDE this lock.
  Future<void> _writeTail = Future.value();
  Future<T> _mutate<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _writeTail = _writeTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  /// Re-arms every persisted task. Call once at startup. Tasks whose fire time
  /// has already passed are fired shortly after launch.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final tasks = await _load();
    for (final task in tasks) {
      _arm(task);
    }
    LoggerService.info('PluginTaskService: re-armed ${tasks.length} task(s)');
  }

  /// Schedules [tool] on the app identified by [appUuid] to run after
  /// [delaySeconds], repeating every [delaySeconds] until [maxRuns] is reached
  /// (default one-shot). Returns the new task id.
  Future<String> schedule({
    required String appUuid,
    required String tool,
    Map<String, dynamic> params = const {},
    required int delaySeconds,
    int maxRuns = 1,
  }) async {
    if (appUuid.isEmpty || tool.isEmpty) {
      throw ArgumentError('appUuid and tool are required');
    }
    final safeDelay = delaySeconds < 1 ? 1 : delaySeconds;
    final task = ScheduledPluginTask(
      id: _uuid.v4(),
      appUuid: appUuid,
      tool: tool,
      params: Map<String, dynamic>.from(params),
      fireAt: _now + safeDelay * 1000,
      delaySeconds: safeDelay,
      maxRuns: maxRuns < 1 ? 1 : maxRuns,
    );
    await _mutate(() async {
      final tasks = await _load()..add(task);
      await _save(tasks);
    });
    _arm(task);
    return task.id;
  }

  /// Cancels a scheduled task by id.
  Future<void> cancel(String taskId) async {
    _timers.remove(taskId)?.cancel();
    await _mutate(() async {
      final tasks = await _load()..removeWhere((t) => t.id == taskId);
      await _save(tasks);
    });
  }

  /// Lists the scheduled tasks for [appUuid] (summary form).
  Future<List<Map<String, dynamic>>> list(String appUuid) async {
    final tasks = await _load();
    return [
      for (final t in tasks)
        if (t.appUuid == appUuid) t.toSummary(),
    ];
  }

  void _arm(ScheduledPluginTask task) {
    _timers.remove(task.id)?.cancel();
    final delayMs = task.fireAt - _now;
    _timers[task.id] = Timer(
      Duration(milliseconds: delayMs < 0 ? 0 : delayMs),
      () => _fire(task.id),
    );
  }

  Future<void> _fire(String taskId) async {
    _timers.remove(taskId);
    // Read current state under the lock so we act on the latest run count.
    final task = await _mutate(() async {
      final tasks = await _load();
      final index = tasks.indexWhere((t) => t.id == taskId);
      return index < 0 ? null : tasks[index];
    });
    if (task == null) return;

    try {
      await _invokeTool(task);
    } catch (e) {
      LoggerService.error(
        'PluginTaskService: task ${task.id} (${task.tool}) failed: $e',
        error: e,
      );
    }

    // Reschedule-or-drop as one atomic read-modify-write, re-reading in case the
    // tool itself cancelled the task during its (unlocked) run.
    ScheduledPluginTask? reArm;
    await _mutate(() async {
      final after = await _load();
      final idx = after.indexWhere((t) => t.id == taskId);
      if (idx < 0) return; // cancelled during invocation
      final current = after[idx];
      current.runCount += 1;
      if (current.runCount < current.maxRuns) {
        current.fireAt = _now + current.delaySeconds * 1000;
        await _save(after);
        reArm = current;
      } else {
        after.removeAt(idx);
        await _save(after);
      }
    });
    if (reArm != null) _arm(reArm!);
  }

  Future<void> _invokeTool(ScheduledPluginTask task) async {
    final db = getIt<DatabaseService>();
    final app = await db.getUserAppByUuid(task.appUuid);
    if (app == null) {
      throw Exception('App not found for scheduled task: ${task.appUuid}');
    }
    final revision = await db.getLatestAppRevision(app.id);
    if (revision == null) {
      throw Exception('No revision for app ${app.name}');
    }
    final bundle = await AiToolService.loadAppBundle(
      app: app,
      revision: revision,
    );
    if (bundle == null) {
      throw Exception('App ${app.name} is not an AI tool bundle');
    }

    final runtime = AiToolRuntime(
      bundle: bundle,
      appProvider: getIt<AppProvider>(),
    );
    try {
      await runtime.invoke(task.tool, task.params, GenerationContext());
    } finally {
      await runtime.dispose();
    }
  }
}
