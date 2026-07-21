import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/sql_query_service.dart';

void main() {
  late DatabaseService db;
  late DataChangeNotifier notifier;
  late SqlQueryService service;
  late List<DataChangeEvent> events;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    await resetForTesting();
    db = DatabaseService.createNew();
    await db.database;
    notifier = DataChangeNotifier();
    events = [];
    notifier.addListener((event) async => events.add(event));
    service = SqlQueryService(db, changeNotifier: notifier);
  });

  tearDown(() async {
    await db.close();
  });

  Future<SqlQueryResult> run(String sql) => service.executeQuery(
        sql,
        requireApprovalForWrites: false,
        allowWriteOperations: true,
      );

  Future<void> insertNoteRow(String id) => run(
        "INSERT INTO notes (id, title, content, type, createdAt, updatedAt) "
        "VALUES ('$id', 'title $id', 'content', 'note', 1, 1)",
      );

  DataChangeEvent merged() =>
      events.fold(const DataChangeEvent(), (a, b) => a.merge(b));

  group('classification', () {
    test('REPLACE INTO is capturable DML', () {
      final type = service.getQueryType(
        "REPLACE INTO notes (id, title, content, type, createdAt, updatedAt) "
        "VALUES ('x', 't', 'c', 'note', 1, 1)",
      );
      expect(service.isCapturableDml(type), isTrue);
    });

    test('PRAGMA read-only vs write forms', () {
      expect(service.isReadOnlyQuery('PRAGMA table_info(notes)'), isTrue);
      expect(service.isReadOnlyQuery('PRAGMA integrity_check'), isTrue);
      expect(service.isReadOnlyQuery('PRAGMA user_version'), isTrue);
      expect(service.isReadOnlyQuery('PRAGMA user_version = 5'), isFalse);
      expect(service.isReadOnlyQuery('PRAGMA journal_mode=WAL'), isFalse);
      // Non-allowlisted call form: conservative write.
      expect(service.isReadOnlyQuery('PRAGMA optimize(0x10002)'), isFalse);
    });

    test('leading comments fall back safely (non-read-only)', () {
      final sql = '-- comment\nDELETE FROM notes';
      // Whether the parser sees through the comment or not, the statement
      // must never be classified read-only.
      expect(service.isReadOnlyQuery(sql), isFalse);
    });
  });

  group('journal capture', () {
    test('INSERT / UPDATE / DELETE on notes publish the affected ids',
        () async {
      await insertNoteRow('n1');
      await run("UPDATE notes SET title = 'renamed' WHERE id = 'n1'");
      await run("DELETE FROM notes WHERE id = 'n1'");
      await notifier.waitForIdle();

      expect(events, hasLength(3));
      for (final event in events) {
        expect(event.noteIds, {'n1'});
        expect(event.bulk, isFalse);
      }
    });

    test('REPLACE INTO notes is captured precisely', () async {
      await insertNoteRow('n1');
      // Drain any pending events from setup statements before clearing, so
      // a late-arriving event cannot leak into the assertion window.
      await notifier.waitForIdle();
      events.clear();
      await run(
        "REPLACE INTO notes (id, title, content, type, createdAt, updatedAt) "
        "VALUES ('n1', 'replaced', 'c', 'note', 1, 1)",
      );
      await notifier.waitForIdle();

      expect(merged().noteIds, {'n1'});
      expect(merged().bulk, isFalse);
    });

    test('child-table writes map to the parent note id', () async {
      await insertNoteRow('n1');
      // Drain any pending events from setup statements before clearing, so
      // a late-arriving event cannot leak into the assertion window.
      await notifier.waitForIdle();
      events.clear();
      await run(
        "INSERT INTO subnotes (id, noteId, name, content, createdAt, isCompleted) "
        "VALUES ('s1', 'n1', 'sub', '', 1, 0)",
      );
      await notifier.waitForIdle();
      expect(merged().noteIds, {'n1'});
    });

    test('association UPDATE captures both old and new note ids', () async {
      await insertNoteRow('n1');
      await insertNoteRow('n2');
      await run(
        "INSERT INTO subnotes (id, noteId, name, content, createdAt, isCompleted) "
        "VALUES ('s1', 'n1', 'sub', '', 1, 0)",
      );
      // Drain any pending events from setup statements before clearing, so
      // a late-arriving event cannot leak into the assertion window.
      await notifier.waitForIdle();
      events.clear();
      await run("UPDATE subnotes SET noteId = 'n2' WHERE id = 's1'");
      await notifier.waitForIdle();
      expect(merged().noteIds, {'n1', 'n2'});
    });

    test('relationships capture both endpoints', () async {
      await insertNoteRow('n1');
      await insertNoteRow('n2');
      // Drain any pending events from setup statements before clearing, so
      // a late-arriving event cannot leak into the assertion window.
      await notifier.waitForIdle();
      events.clear();
      await run(
        "INSERT INTO relationships (id, fromNoteId, toNoteId, type, createdAt) "
        "VALUES ('r1', 'n1', 'n2', 'related', 1)",
      );
      await notifier.waitForIdle();
      expect(merged().relationshipNoteIds, {'n1', 'n2'});
    });

    test('tag rename refreshes the tag list AND every note bearing the tag',
        () async {
      await insertNoteRow('n1');
      await run(
        "INSERT INTO tags (id, name, color, createdAt) "
        "VALUES ('t1', 'old-name', '#fff', 1)",
      );
      await run("INSERT INTO note_tags (noteId, tagId) VALUES ('n1', 't1')");
      // Drain any pending events from setup statements before clearing, so
      // a late-arriving event cannot leak into the assertion window.
      await notifier.waitForIdle();
      events.clear();

      await run("UPDATE tags SET name = 'new-name' WHERE id = 't1'");
      await notifier.waitForIdle();

      expect(merged().tagsChanged, isTrue);
      expect(merged().noteIds, {'n1'});
    });

    test('tag delete captures affected notes before the join rows go away',
        () async {
      await insertNoteRow('n1');
      await run(
        "INSERT INTO tags (id, name, color, createdAt) "
        "VALUES ('t1', 'doomed', '#fff', 1)",
      );
      await run("INSERT INTO note_tags (noteId, tagId) VALUES ('n1', 't1')");
      // Drain any pending events from setup statements before clearing, so
      // a late-arriving event cannot leak into the assertion window.
      await notifier.waitForIdle();
      events.clear();

      await run("DELETE FROM tags WHERE id = 't1'");
      await notifier.waitForIdle();

      expect(merged().tagsChanged, isTrue);
      expect(merged().noteIds, {'n1'});
    });

    test('filter writes publish filtersChanged only', () async {
      await run(
        "INSERT INTO filters (id, name, includeTags, createdAt, updatedAt) "
        "VALUES ('f1', 'filter', '[]', 1, 1)",
      );
      await notifier.waitForIdle();
      expect(merged().filtersChanged, isTrue);
      expect(merged().noteIds, isEmpty);
    });

    test('writes to a plugin-created table publish nothing beyond the DDL '
        'bulk', () async {
      await run('CREATE TABLE plugin_data (id TEXT PRIMARY KEY, value TEXT)');
      await notifier.waitForIdle();
      expect(merged().bulk, isTrue, reason: 'DDL publishes bulk');
      // Drain any pending events from setup statements before clearing, so
      // a late-arriving event cannot leak into the assertion window.
      await notifier.waitForIdle();
      events.clear();

      await run("INSERT INTO plugin_data VALUES ('k', 'v')");
      await notifier.waitForIdle();
      expect(events, isEmpty,
          reason: 'plugin-table DML touches no note domain: no event at all');
    });

    test('a persistent user trigger cascading into notes is captured',
        () async {
      await run('CREATE TABLE plugin_log (id TEXT PRIMARY KEY)');
      await run(
        "CREATE TRIGGER plugin_cascade AFTER INSERT ON plugin_log BEGIN "
        "INSERT INTO notes (id, title, content, type, createdAt, updatedAt) "
        "VALUES ('via-trigger', 't', 'c', 'note', 1, 1); END",
      );
      // Drain any pending events from setup statements before clearing, so
      // a late-arriving event cannot leak into the assertion window.
      await notifier.waitForIdle();
      events.clear();

      await run("INSERT INTO plugin_log VALUES ('x')");
      await notifier.waitForIdle();

      expect(merged().noteIds, {'via-trigger'},
          reason: 'journal observes trigger-cascaded writes');
      expect(merged().bulk, isFalse);
    });
  });

  group('non-transactional statements', () {
    test('VACUUM executes directly and publishes bulk', () async {
      final result = await run('VACUUM');
      await notifier.waitForIdle();
      expect(result.success, isTrue);
      expect(merged().bulk, isTrue);
    });

    test('writable PRAGMA executes directly and publishes bulk', () async {
      final result = await run('PRAGMA user_version = 7');
      await notifier.waitForIdle();
      expect(result.success, isTrue);
      expect(merged().bulk, isTrue);
    });
  });

  group('degraded capture', () {
    test('a dropped monitored table degrades capture to bulk without '
        'failing unrelated writes', () async {
      // Install triggers first so the DROP takes some of them down.
      await insertNoteRow('n0');
      await run('DROP TABLE filters');
      // Drain any pending events from setup statements before clearing, so
      // a late-arriving event cannot leak into the assertion window.
      await notifier.waitForIdle();
      events.clear();

      final result = await run(
        "UPDATE notes SET title = 'still works' WHERE id = 'n0'",
      );
      await notifier.waitForIdle();

      expect(result.success, isTrue,
          reason: 'degraded capture must not fail the write');
      expect(merged().bulk, isTrue,
          reason: 'incomplete trigger set cannot be trusted: bulk fallback');
    });
  });

  group('connection lifecycle', () {
    test('capture works again after close() and reopen', () async {
      await insertNoteRow('n1');
      await notifier.waitForIdle();
      // Drain any pending events from setup statements before clearing, so
      // a late-arriving event cannot leak into the assertion window.
      await notifier.waitForIdle();
      events.clear();

      await db.close();
      await db.database; // reopen

      await insertNoteRow('n2');
      await notifier.waitForIdle();

      expect(merged().noteIds, {'n2'},
          reason: 'TEMP objects must reinstall on the new connection');
      expect(merged().bulk, isFalse);
    });
  });
}
