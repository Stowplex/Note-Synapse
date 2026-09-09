// Tests for the M1.7 "filters + tag_workflow_bindings soft-delete
// conversion" milestone
// (.claude/plans/plan-and-propse-the-glistening-dolphin.md, § Phased
// delivery — the seven dependency-ordered sub-milestones list: "M1.7 —
// `filters` + `tag_workflow_bindings`: independent, single-statement, no
// FK/diff complexity. Validates the M1.4 pattern generalizes outside the
// User-App family before tackling anything harder.").
//
// `filters`/`tag_workflow_bindings` gain a `__deleted__` tombstone column;
// `deleteFilter`/`deleteWorkflowBinding` become ordinary tombstone writes
// instead of real SQL deletes; every list/lookup read path in both tables
// filters on `__deleted__ = 0`. Neither table has a fallback concept the
// way `app_revisions` does, so — unlike M1.4's
// `computeAppRevisionVisibility` — a raw `__deleted__ = 0` filter is
// already the effective one; no derived-visibility helper is needed here.
//
// Five things are verified, matching the milestone's own acceptance bar:
//  1. Fresh-install: a brand-new database already has `__deleted__` on both
//     tables (DatabaseService.createNew() -> _onCreate).
//  2. Migration round-trip (DATABASE_VERSION 50 -> 51): existing rows in
//     both tables survive migration with __deleted__=0, ids/patterns
//     unchanged.
//  3. Soft-delete confirmation: deleteFilter/deleteWorkflowBinding write
//     exactly one __deleted__=1 row update each — the row count in each
//     table is unchanged afterward (a real DELETE would drop the row
//     count by one).
//  4. Read-path filtering: getAllFilters/getFilter and
//     getExactWorkflowBinding/getPrefixWorkflowBindings/
//     getWorkflowBindingByPattern/getAllWorkflowBindings all stop
//     returning tombstoned rows; TagWorkflowService.resolveBindings only
//     ever matches a LIVE binding (both the exact and the prefix path).
//  5. The `tag_workflow_bindings.pattern` PK-reuse-after-tombstone
//     question the task explicitly asked to be investigated: since
//     `pattern` is the primary key and `insertWorkflowBinding` always
//     writes via `ConflictAlgorithm.replace`, re-registering a binding
//     under a previously-tombstoned pattern fully overwrites that row,
//     implicitly resetting `__deleted__` back to 0 (the column's default,
//     since the INSERT never mentions it) — confirmed here to actually
//     work, not just asserted by reading the code. This is a real
//     difference from the `tags.name` collision M1.3 hit (a plain UNIQUE
//     constraint with ordinary, non-REPLACE inserts elsewhere in the
//     codebase), so no design gap exists for this table.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/filter.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/workflow_binding_row.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';

/// The exact pre-M1.7 (DATABASE_VERSION <= 50) shape of `filters`: no
/// `__deleted__` column. Hand-written rather than derived from
/// DatabaseService.getSchema() — as of M1.7, getSchema() already returns
/// the NEW DDL — same approach test/user_app_soft_delete_test.dart
/// established for M1.4.
const _oldFiltersTableDdl = '''
    CREATE TABLE filters(
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      includeText TEXT,
      includeTags TEXT NOT NULL,
      excludeTags TEXT NOT NULL DEFAULT '',
      noteTypes TEXT NOT NULL DEFAULT '',
      includeArchived INTEGER NOT NULL DEFAULT 0,
      isPinned INTEGER NOT NULL DEFAULT 0,
      createdAt INTEGER NOT NULL,
      updatedAt INTEGER NOT NULL
    )
''';

/// The exact pre-M1.7 shape of `tag_workflow_bindings`: no `__deleted__`
/// column.
const _oldTagWorkflowBindingsTableDdl = '''
    CREATE TABLE IF NOT EXISTS tag_workflow_bindings (
      pattern TEXT PRIMARY KEY,
      isPrefix INTEGER NOT NULL DEFAULT 0,
      skillNoteId TEXT NOT NULL,
      prompt TEXT NOT NULL DEFAULT '',
      contentImmutable INTEGER NOT NULL DEFAULT 0
    )
''';

Future<List<Map<String, Object?>>> _tableInfo(Database db, String table) =>
    db.rawQuery("PRAGMA table_info('$table')");

Future<bool> _hasColumn(Database db, String table, String column) async {
  final cols = await _tableInfo(db, table);
  return cols.any((c) => c['name'] == column);
}

Filter _buildFilter({required String id, String name = 'My Filter'}) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  return Filter(
    id: id,
    name: name,
    includeTags: const ['work'],
    noteTypes: const [NoteType.note],
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('M1.7 filters/tag_workflow_bindings soft-delete — fresh install', () {
    late DatabaseService databaseService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test(
      'filters and tag_workflow_bindings both have __deleted__ (NOT NULL, default 0)',
      () async {
        final db = await databaseService.database;

        for (final table in ['filters', 'tag_workflow_bindings']) {
          final cols = await _tableInfo(db, table);
          final deletedCol = cols.firstWhere((c) => c['name'] == '__deleted__');
          expect(deletedCol['notnull'], 1, reason: '$table.__deleted__ should be NOT NULL');
          expect(deletedCol['dflt_value'], '0', reason: '$table.__deleted__ should default to 0');
        }
      },
    );
  });

  group(
    'M1.7 filters/tag_workflow_bindings soft-delete — migration round-trip (v51 -> v52)',
    () {
      late Database preMigrationDb;

      setUp(() async {
        preMigrationDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);

        // Old-shape tables must exist before getSchema()'s own
        // _createIndexes statements run below.
        await preMigrationDb.execute(_oldFiltersTableDdl);
        await preMigrationDb.execute(_oldTagWorkflowBindingsTableDdl);

        for (final statement in DatabaseService.getSchema()) {
          if (statement.contains('CREATE TABLE filters(') ||
              statement.contains(
                'CREATE TABLE IF NOT EXISTS tag_workflow_bindings (',
              )) {
            continue;
          }
          await preMigrationDb.execute(statement);
        }

        await preMigrationDb.execute('''
          CREATE TABLE _schema_version (version INTEGER NOT NULL)
        ''');
        await preMigrationDb.insert('_schema_version', {'version': 50});

        expect(await _hasColumn(preMigrationDb, 'filters', '__deleted__'), isFalse);
        expect(
          await _hasColumn(preMigrationDb, 'tag_workflow_bindings', '__deleted__'),
          isFalse,
        );
      });

      tearDown(() async {
        await preMigrationDb.close();
      });

      test(
        'existing rows in both tables survive migration with __deleted__=0, '
        'ids/patterns unchanged',
        () async {
          await preMigrationDb.insert('filters', {
            'id': 'filter-1',
            'name': 'My Filter',
            'includeTags': 'work',
            'excludeTags': '',
            'noteTypes': 'note',
            'includeArchived': 0,
            'isPinned': 0,
            'createdAt': 100,
            'updatedAt': 100,
          });
          await preMigrationDb.insert('tag_workflow_bindings', {
            'pattern': 'proj/',
            'isPrefix': 1,
            'skillNoteId': 'skill-1',
            'prompt': 'do the thing',
            'contentImmutable': 0,
          });

          final service = DatabaseService.createNew();
          await service.migrateBackupDatabase(preMigrationDb, 51, 52);

          expect(await _hasColumn(preMigrationDb, 'filters', '__deleted__'), isTrue);
          expect(
            await _hasColumn(preMigrationDb, 'tag_workflow_bindings', '__deleted__'),
            isTrue,
          );

          final filters = await preMigrationDb.query('filters');
          expect(filters.single['id'], 'filter-1');
          expect(filters.single['__deleted__'], 0);

          final bindings = await preMigrationDb.query('tag_workflow_bindings');
          expect(bindings.single['pattern'], 'proj/');
          expect(bindings.single['__deleted__'], 0);
        },
      );

      test(
        'running the v51 -> v52 migration twice does not error and leaves '
        'schema/data unchanged the second time',
        () async {
          await preMigrationDb.insert('filters', {
            'id': 'filter-1',
            'name': 'My Filter',
            'includeTags': 'work',
            'excludeTags': '',
            'noteTypes': 'note',
            'includeArchived': 0,
            'isPinned': 0,
            'createdAt': 100,
            'updatedAt': 100,
          });

          final service = DatabaseService.createNew();
          await service.migrateBackupDatabase(preMigrationDb, 51, 52);
          final afterFirst = await preMigrationDb.query('filters', orderBy: 'id');

          await service.migrateBackupDatabase(preMigrationDb, 51, 52);
          final afterSecond = await preMigrationDb.query('filters', orderBy: 'id');

          expect(afterSecond, equals(afterFirst));
        },
      );
    },
  );

  group('M1.7 soft-delete confirmation — tombstone writes, not real deletes', () {
    late DatabaseService databaseService;
    late Database db;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      db = await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test(
      'deleteFilter writes a single __deleted__=1 update; row count unchanged',
      () async {
        await databaseService.insertFilter(_buildFilter(id: 'filter-1'));

        final rowsBefore = await db.query('filters');
        await databaseService.deleteFilter('filter-1');
        final rowsAfter = await db.query('filters');

        expect(rowsAfter.length, rowsBefore.length);
        expect(rowsAfter.single['__deleted__'], 1);
      },
    );

    test(
      'deleteWorkflowBinding writes a single __deleted__=1 update; row count unchanged',
      () async {
        await databaseService.insertWorkflowBinding(
          const WorkflowBindingRow(
            pattern: 'proj/',
            isPrefix: true,
            skillNoteId: 'skill-1',
            prompt: 'p',
            contentImmutable: false,
          ),
        );

        final rowsBefore = await db.query('tag_workflow_bindings');
        await databaseService.deleteWorkflowBinding('proj/');
        final rowsAfter = await db.query('tag_workflow_bindings');

        expect(rowsAfter.length, rowsBefore.length);
        expect(rowsAfter.single['__deleted__'], 1);
      },
    );
  });

  group('M1.7 read-path filtering', () {
    late DatabaseService databaseService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('getAllFilters/getFilter hide a deleted filter', () async {
      await databaseService.insertFilter(_buildFilter(id: 'filter-1'));
      await databaseService.insertFilter(_buildFilter(id: 'filter-2', name: 'Other'));

      await databaseService.deleteFilter('filter-1');

      final all = await databaseService.getAllFilters();
      expect(all.map((f) => f.id), ['filter-2']);
      expect(await databaseService.getFilter('filter-1'), isNull);
      expect(await databaseService.getFilter('filter-2'), isNotNull);
    });

    test(
      'getExactWorkflowBinding/getWorkflowBindingByPattern/getAllWorkflowBindings '
      'hide a deleted exact binding',
      () async {
        await databaseService.insertWorkflowBinding(
          const WorkflowBindingRow(
            pattern: 'exact-tag',
            isPrefix: false,
            skillNoteId: 'skill-1',
            prompt: 'p',
            contentImmutable: false,
          ),
        );
        expect(await databaseService.getExactWorkflowBinding('exact-tag'), isNotNull);

        await databaseService.deleteWorkflowBinding('exact-tag');

        expect(await databaseService.getExactWorkflowBinding('exact-tag'), isNull);
        expect(await databaseService.getWorkflowBindingByPattern('exact-tag'), isNull);
        expect(await databaseService.getAllWorkflowBindings(), isEmpty);
      },
    );

    test('getPrefixWorkflowBindings hides a deleted prefix binding', () async {
      await databaseService.insertWorkflowBinding(
        const WorkflowBindingRow(
          pattern: 'proj/',
          isPrefix: true,
          skillNoteId: 'skill-1',
          prompt: 'p',
          contentImmutable: false,
        ),
      );
      expect(await databaseService.getPrefixWorkflowBindings(), hasLength(1));

      await databaseService.deleteWorkflowBinding('proj/');

      expect(await databaseService.getPrefixWorkflowBindings(), isEmpty);
    });

    test(
      'TagWorkflowService.resolveBindings only ever matches a LIVE binding '
      '(both the exact and the prefix path)',
      () async {
        final service = TagWorkflowService(databaseService);

        await databaseService.insertWorkflowBinding(
          const WorkflowBindingRow(
            pattern: 'exact-tag',
            isPrefix: false,
            skillNoteId: 'exact-skill',
            prompt: 'p',
            contentImmutable: false,
          ),
        );
        await databaseService.insertWorkflowBinding(
          const WorkflowBindingRow(
            pattern: 'proj/',
            isPrefix: true,
            skillNoteId: 'prefix-skill',
            prompt: 'p',
            contentImmutable: false,
          ),
        );

        var resolved = await service.resolveBindings(['exact-tag', 'proj/foo']);
        expect(resolved.map((b) => b.skillNoteId).toSet(), {
          'exact-skill',
          'prefix-skill',
        });

        await databaseService.deleteWorkflowBinding('exact-tag');
        await databaseService.deleteWorkflowBinding('proj/');

        resolved = await service.resolveBindings(['exact-tag', 'proj/foo']);
        expect(
          resolved,
          isEmpty,
          reason: 'both bindings are tombstoned, neither should resolve',
        );
      },
    );
  });

  group(
    'M1.7 tag_workflow_bindings.pattern PK-reuse-after-tombstone (task-flagged '
    'design question, investigated here)',
    () {
      late DatabaseService databaseService;
      late Database db;

      setUp(() async {
        databaseService = DatabaseService.createNew();
        db = await databaseService.database;
      });

      tearDown(() async {
        await databaseService.close();
      });

      test(
        're-registering a binding under a previously-tombstoned pattern fully '
        'overwrites the row and resets __deleted__ to 0 -- no PK collision, '
        'unlike the tags.name gap M1.3 hit',
        () async {
          final service = TagWorkflowService(databaseService);

          await service.registerBinding(
            pattern: 'proj/',
            isPrefix: true,
            skillNoteId: 'old-skill',
            prompt: 'old prompt',
            contentImmutable: false,
          );
          await service.removeBinding('proj/');

          final tombstoned = await db.query('tag_workflow_bindings');
          expect(tombstoned.single['__deleted__'], 1);

          // Re-registering under the exact same pattern must not throw
          // (no UNIQUE/PK violation) and must fully replace the row.
          await service.registerBinding(
            pattern: 'proj/',
            isPrefix: true,
            skillNoteId: 'new-skill',
            prompt: 'new prompt',
            contentImmutable: true,
          );

          final rows = await db.query('tag_workflow_bindings');
          expect(
            rows,
            hasLength(1),
            reason:
                'REPLACE overwrites the existing pattern row in place, it '
                'never leaves a second row behind',
          );
          expect(rows.single['__deleted__'], 0);
          expect(rows.single['skillNoteId'], 'new-skill');
          expect(rows.single['prompt'], 'new prompt');
          expect(rows.single['contentImmutable'], 1);

          // And the resurrected binding is visible again through every
          // read path.
          final live = await databaseService.getWorkflowBindingByPattern('proj/');
          expect(live, isNotNull);
          expect(live!.skillNoteId, 'new-skill');
        },
      );
    },
  );
}
