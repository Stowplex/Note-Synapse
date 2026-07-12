import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/plugin_task_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PluginTaskService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    service = PluginTaskService(prefs: prefs);
  });

  test('schedule persists a task and returns an id', () async {
    final id = await service.schedule(
      appUuid: 'app1',
      tool: 'poll',
      params: {'artifactId': 'a1'},
      delaySeconds: 3600, // far future so it never fires during the test
      maxRuns: 3,
    );

    expect(id, isNotEmpty);
    final tasks = await service.list('app1');
    expect(tasks, hasLength(1));
    expect(tasks.single['tool'], 'poll');
    expect(tasks.single['maxRuns'], 3);
    expect(tasks.single['runCount'], 0);
  });

  test('list is scoped per app', () async {
    await service.schedule(
      appUuid: 'app1',
      tool: 'poll',
      delaySeconds: 3600,
    );
    await service.schedule(
      appUuid: 'app2',
      tool: 'sync',
      delaySeconds: 3600,
    );

    expect(await service.list('app1'), hasLength(1));
    expect(await service.list('app2'), hasLength(1));
    expect((await service.list('app1')).single['tool'], 'poll');
  });

  test('cancel removes a scheduled task', () async {
    final id = await service.schedule(
      appUuid: 'app1',
      tool: 'poll',
      delaySeconds: 3600,
    );

    await service.cancel(id);
    expect(await service.list('app1'), isEmpty);
  });

  test('rejects empty app uuid or tool', () async {
    expect(
      () => service.schedule(appUuid: '', tool: 'poll', delaySeconds: 60),
      throwsArgumentError,
    );
    expect(
      () => service.schedule(appUuid: 'app1', tool: '', delaySeconds: 60),
      throwsArgumentError,
    );
  });

  test('persisted tasks survive a new service instance', () async {
    await service.schedule(
      appUuid: 'app1',
      tool: 'poll',
      delaySeconds: 3600,
    );

    final prefs = await SharedPreferences.getInstance();
    final reloaded = PluginTaskService(prefs: prefs);
    expect(await reloaded.list('app1'), hasLength(1));
  });
}
