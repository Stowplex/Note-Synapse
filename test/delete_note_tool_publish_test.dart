import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/approval_service.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/tools/note_tools.dart';

import 'delete_note_tool_publish_test.mocks.dart';

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late DataChangeNotifier notifier;
  late List<DataChangeEvent> events;

  Note stubNote(String id) => Note(
        id: id,
        title: id,
        content: '',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    notifier = DataChangeNotifier();
    getIt.registerSingleton<DataChangeNotifier>(notifier);
    events = [];
    notifier.addListener((event) async => events.add(event));
    ApprovalService.sessionApprovedNoteDeletions = true;
  });

  tearDown(() {
    ApprovalService.sessionApprovedNoteDeletions = false;
  });

  test('publishes exactly the successfully deleted ids', () async {
    when(mockDb.getNote('ok')).thenAnswer((_) async => stubNote('ok'));
    when(mockDb.getNote('broken')).thenAnswer((_) async => stubNote('broken'));
    when(mockDb.getNote('missing')).thenAnswer((_) async => null);
    when(mockDb.deleteNote('ok')).thenAnswer((_) async {});
    when(mockDb.deleteNote('broken')).thenThrow(Exception('locked'));

    final result = await DeleteNoteTool().execute({
      'note_ids': ['ok', 'broken', 'missing'],
    });
    await notifier.waitForIdle();

    expect(result['deleted_count'], 1);
    expect(events, hasLength(1));
    expect(events.single.noteIds, {'ok'},
        reason: 'failed and missing ids must not be published');
  });

  test('publishes nothing when no deletion succeeded', () async {
    when(mockDb.getNote('missing')).thenAnswer((_) async => null);

    await DeleteNoteTool().execute({
      'note_ids': ['missing'],
    });
    await notifier.waitForIdle();

    expect(events, isEmpty);
  });
}
