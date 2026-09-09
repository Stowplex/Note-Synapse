// M2.8 — the permanent sync-scope-exclusion-reasoning audit, § Architecture
// 11.8's own required addition ("added per the M2.7 addendum above"), built
// in the `hard_delete_audit_test.dart` style: a mechanical, checked-in-
// baseline-compared scanner, not a one-off manual review.
//
// ---------------------------------------------------------------------
// Why this exists, and what it is NOT the same thing as.
// ---------------------------------------------------------------------
// `mutation_capture_test.dart`'s "entity-table completeness scan" already
// verifies every real column of every sync-scope entity table is
// *accounted for* — in `syncScopeColumns` (with a live, verified-by-actual-
// mutation `AFTER UPDATE` trigger) or in a hand-maintained `excludedColumns`
// set. That test answers "is every column classified at all?" It
// structurally CANNOT answer the different question M2.7 found a real gap
// in: "for an EXCLUDED column, is the reasoning that excluded it actually
// complete?" M2.7's own finding (`tags.name`/`color`) was excluded on
// reasoning that only ever asked "does this column have a live `UPDATE`
// call site" — true — without separately asking "does this column get a
// real, per-row-varying value at CREATION time that a joining/pulling
// device would otherwise never learn" — also true, and the actual bug.
//
// This file's job: for every entity table's currently-excluded column set,
// mechanically re-derive which FUNCTIONS in `lib/` (excluding `lib/
// services/sync/**` — see below) actually `.insert`/`.update` that TABLE at
// all, and compare that live-scanned set against a checked-in, hand-
// reviewed baseline — symmetric fail on both add and remove, exactly
// `hard_delete_audit_test.dart`'s own design. A baseline drift (a new
// function starts inserting or updating a sync-scope table, or an existing
// one stops) forces a human to look at EVERY excluded column of that table
// again and re-ask both questions M2.7's addendum names — not just the one
// that happens to be locally true — before accepting the new baseline.
// This is exactly the mechanism that would have caught `tags.name`/`color`
// BEFORE it shipped: `insertTag` already existed as a live INSERT site for
// `tags` at the time `name`/`color` were excluded; a baseline requiring an
// explicit, reviewed reason for each excluded column tied to that site
// would have forced the question "does `insertTag` give this column a
// real, varying value?" to be asked and answered, not skipped.
//
// **Scope decision, disclosed**: `lib/services/sync/**` is excluded from
// the function scan. Those files are the sync engine's OWN materialization/
// resolution writers (`materializer.dart` writing an already-resolved
// value back into a real row, `outbox_drainer.dart`/`causal/*.dart` writing
// `sync_field_state`/`sync_set_state`) — the RECEIVING side of already-
// captured data, not an originating local-user-action creation/update call
// site. Counting them would conflate "the sync engine itself writes this
// column when materializing" (true for every synced column, by
// construction, and not informative) with "ordinary application code gives
// this column a real value outside the sync engine's own control" (the
// actual question this audit asks). `test/hard_delete_audit_test.dart`
// makes a comparable scope decision for its own different purpose (guarded-
// table scope mirrors requirement 1, not literally every table in the
// schema) — narrowing scope to what the audit is actually asking about is
// consistent with that precedent, not a departure from it.
//
// This audit runs against every one of the fourteen `syncEntityCaptureScopes`
// entity tables' real, current schema (via `PRAGMA table_info`, the same
// technique `mutation_capture_test.dart` already uses) — not a hand-frozen
// column list — so a brand-new column silently landing in NEITHER
// `syncScopeColumns` NOR this file's baseline fails loudly here too,
// independent of (and in addition to) `mutation_capture_test.dart`'s own
// completeness check.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';

/// One excluded column's checked-in, human-reviewed classification.
/// [reason] is free text (mirrors `syncEntityCaptureScopes`' own per-table
/// doc comments in `database_service.dart` — kept in sync with them
/// deliberately, not independently invented) — this file does not attempt
/// to mechanically verify the ENGLISH is correct (that is exactly the kind
/// of judgment call M2.7's own gap shows still needs a human), only that
/// every excluded column HAS one, and that the mechanical facts backing it
/// (which functions insert/update this table at all) haven't silently
/// drifted out from under it.
class ExcludedColumn {
  const ExcludedColumn(this.column, this.reason);
  final String column;
  final String reason;
}

/// Per-table: the full set of currently-excluded columns (cross-checked
/// against live PRAGMA output below) plus the live-scanned set of
/// functions (anywhere in `lib/`, excluding `lib/services/sync/**`) that
/// `.insert`/`.rawInsert`/`.update`/`.rawUpdate` this table at all.
class TableAudit {
  const TableAudit({
    required this.table,
    required this.idColumn,
    required this.excluded,
    required this.insertSites,
    required this.updateSites,
  });

  final String table;
  final String idColumn;
  final List<ExcludedColumn> excluded;

  /// Checked-in baseline of `(file, function)` sites with a live `.insert`/
  /// `.rawInsert` call against [table].
  final Set<String> insertSites;

  /// Checked-in baseline of `(file, function)` sites with a live `.update`/
  /// `.rawUpdate` call against [table].
  final Set<String> updateSites;

  Set<String> get excludedColumnNames => {for (final e in excluded) e.column};
}

// ===========================================================================
// Checked-in baselines — hand-reviewed against the actual current source
// (both `syncEntityCaptureScopes`' own doc comments in database_service.dart
// AND a direct reading of every insert/update call site named below) as
// part of this milestone's own audit pass. Six real gaps were found and
// fixed this way (relationships.type; conversation_attachments' and
// attachments' filePath/fileName/fileType/isRelativePath; app_revisions'
// revisionNumber/userPrompt/aiResponse/attachmentPaths; user_app_libraries'
// name/usage_instructions; user_app_library_dependencies' original_url/
// local_path) — see `syncEntityCaptureScopes`'s own per-table doc comments
// (`database_service.dart`) for the full finding-by-finding narrative. No
// further gap was found beyond those six plus the already-fixed M2.7
// tags.name/color case.
// ===========================================================================

final List<TableAudit> kTableAudits = [
  TableAudit(
    table: 'notes',
    idColumn: 'id',
    excluded: const [
      ExcludedColumn('id', 'primary key — never changes by definition'),
      ExcludedColumn(
        'createdAt',
        'derived at materialization time from the __exists__ operation\'s own HLC wall-clock '
            '(materializer.dart\'s _createdAtColumnByTable) — not carried as independent field data',
      ),
    ],
    insertSites: {'lib/services/database_service.dart::insertNote'},
    updateSites: {
      'lib/services/database_service.dart::updateNote',
      'lib/services/database_service.dart::updateNoteMetadata',
      'lib/services/database_service.dart::deleteNote',
      'lib/services/note_modification_service.dart::_persistNote',
    },
  ),
  TableAudit(
    table: 'subnotes',
    idColumn: 'id',
    excluded: const [
      ExcludedColumn('id', 'primary key'),
      ExcludedColumn(
        'noteId',
        'owner FK, never reassigned in place — a subnote "move" is delete-and-recreate',
      ),
      ExcludedColumn(
        'createdAt',
        'derived at materialization time from the __exists__ operation\'s own HLC',
      ),
    ],
    insertSites: {
      'lib/services/database_service.dart::insertSubNote',
      'lib/services/database_service.dart::diffAndPersistSubNotes',
    },
    updateSites: {
      'lib/services/database_service.dart::diffAndPersistSubNotes',
      'lib/services/database_service.dart::deleteNote',
    },
  ),
  TableAudit(
    table: 'tags',
    idColumn: 'id',
    excluded: const [
      ExcludedColumn('id', 'primary key'),
      ExcludedColumn(
        'createdAt',
        'derived at materialization time from the __exists__ operation\'s own HLC',
      ),
      ExcludedColumn(
        'usageCount',
        'confirmed dead: every live insert site pins it to the literal constant 0, and no update call site '
            'anywhere ever references it — a per-replica local activity counter would be the wrong shape for a '
            'plain LWW field register regardless (out of this milestone\'s scope even if it were live)',
      ),
    ],
    insertSites: {
      'lib/services/database_service.dart::insertTag',
      'lib/services/database_service.dart::getOrCreateLiveTagId',
      'lib/services/database_service.dart::replaceTag',
      // Migration 47 mints the reserved `all-spaces` tag. Re-examined against
      // every excluded column, as this audit requires: `id` is a *frozen
      // literal* (_allSpacesTagIdV47) precisely so every database mints the
      // same row and recovery's merge-by-name is a no-op — the opposite of a
      // per-row-varying value; `createdAt` is a local wall-clock but stays
      // excluded, so replicas derive their own from the __exists__ HLC as
      // they do for every other tag; `usageCount` is pinned to the literal 0,
      // matching the live insert sites the exclusion reasoning was built on.
      'lib/services/database_service.dart::_migrateToVersion47',
    },
    updateSites: {
      'lib/services/database_service.dart::deleteTag',
      'lib/services/database_service.dart::replaceTag',
    },
  ),
  TableAudit(
    table: 'filters',
    idColumn: 'id',
    excluded: const [
      ExcludedColumn('id', 'primary key'),
      ExcludedColumn(
        'createdAt',
        'derived at materialization time from the __exists__ operation\'s own HLC',
      ),
    ],
    insertSites: {'lib/services/database_service.dart::insertFilter'},
    updateSites: {
      'lib/services/database_service.dart::updateFilter',
      'lib/services/database_service.dart::deleteFilter',
    },
  ),
  TableAudit(
    table: 'relationships',
    idColumn: 'id',
    excluded: const [
      ExcludedColumn('id', 'primary key'),
      ExcludedColumn('fromNoteId', 'endpoint FK, never reassigned in place'),
      ExcludedColumn('toNoteId', 'endpoint FK, never reassigned in place'),
      ExcludedColumn(
        'createdAt',
        'derived at materialization time from the __exists__ operation\'s own HLC',
      ),
    ],
    insertSites: {
      'lib/services/database_service.dart::insertRelationship',
      'lib/services/note_modification_service.dart::_applyLinkModifications',
    },
    updateSites: {
      'lib/services/database_service.dart::deleteRelationship',
      'lib/services/database_service.dart::deleteRelationshipBetween',
      'lib/services/database_service.dart::deleteRelationshipsForNote',
      'lib/services/note_modification_service.dart::_applyLinkModifications',
    },
  ),
  TableAudit(
    table: 'tag_workflow_bindings',
    idColumn: 'pattern',
    excluded: const [
      ExcludedColumn('pattern', 'this table\'s actual primary key (not "id")'),
    ],
    insertSites: {'lib/services/database_service.dart::insertWorkflowBinding'},
    updateSites: {'lib/services/database_service.dart::deleteWorkflowBinding'},
  ),
  TableAudit(
    table: 'conversations',
    idColumn: 'id',
    excluded: const [
      ExcludedColumn('id', 'primary key'),
      ExcludedColumn(
        'createdAt',
        'derived at materialization time from the __exists__ operation\'s own HLC',
      ),
      ExcludedColumn(
        'noteIds',
        'confirmed dead: both the live insert site and the live update site unconditionally pin it to the '
            'literal constant \'[]\' — real membership lives in conversation_note_mapping, an OR-Set table with '
            'its own capture triggers',
      ),
    ],
    insertSites: {'lib/services/database_service.dart::insertConversation'},
    updateSites: {
      'lib/services/database_service.dart::updateConversation',
      'lib/services/database_service.dart::addTagsToConversation',
      'lib/services/database_service.dart::removeTagFromConversation',
      'lib/services/database_service.dart::setConversationTags',
      'lib/services/database_service.dart::deleteConversation',
      'lib/services/database_service.dart::deleteConversationExplicitly',
      'lib/services/database_service.dart::replaceTag',
    },
  ),
  TableAudit(
    table: 'conversation_messages',
    idColumn: 'id',
    excluded: const [
      ExcludedColumn('id', 'primary key'),
      ExcludedColumn(
        'timestamp',
        'this table\'s createdAt-equivalent — derived at materialization time from the __exists__ operation\'s '
            'own HLC (the live update site round-trips the same unchanged value, never actually changing it)',
      ),
    ],
    insertSites: {
      'lib/services/database_service.dart::insertConversationMessage',
    },
    updateSites: {
      'lib/services/database_service.dart::updateConversationMessage',
      'lib/services/database_service.dart::_deleteMessagesBatch',
    },
  ),
  TableAudit(
    table: 'conversation_attachments',
    idColumn: 'id',
    excluded: const [
      ExcludedColumn('id', 'primary key'),
      ExcludedColumn('messageId', 'owner FK, never reassigned in place'),
      ExcludedColumn(
        'createdAt',
        'derived at materialization time from the __exists__ operation\'s own HLC',
      ),
    ],
    insertSites: {
      'lib/services/database_service.dart::insertConversationAttachment',
    },
    updateSites: {
      'lib/services/database_service.dart::deleteConversationAttachment',
      'lib/services/database_service.dart::_deleteMessagesBatch',
      // A pre-sync-engine, one-time local path-normalization migration
      // (v43) that writes filePath/isRelativePath — both now in
      // syncScopeColumns (this file's own fix), so this is fine: any
      // device that still runs this migration will now correctly have
      // its normalized path captured and synced too, a harmless side
      // effect of the fix, not a new concern.
      'lib/services/database_service.dart::_migrateToVersion43',
    },
  ),
  TableAudit(
    table: 'attachments',
    idColumn: 'id',
    excluded: const [
      ExcludedColumn('id', 'primary key'),
      ExcludedColumn('noteId', 'owner FK, never reassigned in place'),
      ExcludedColumn(
        'createdAt',
        'derived at materialization time from the __exists__ operation\'s own HLC',
      ),
    ],
    insertSites: {'lib/services/database_service.dart::_insertAttachmentRow'},
    updateSites: {
      'lib/services/database_service.dart::updateAttachmentAIContext',
      'lib/services/database_service.dart::updateAttachmentMetadata',
      'lib/services/database_service.dart::diffAndPersistAttachments',
      'lib/services/database_service.dart::deleteNote',
      'lib/screens/recovery_screen.dart::_updateAttachmentPathsInCopiedDatabase',
    },
  ),
  TableAudit(
    table: 'user_apps',
    idColumn: 'id',
    excluded: const [
      ExcludedColumn('id', 'primary key'),
      ExcludedColumn(
        'uuid',
        'stable identity column (CLAUDE.md: "user_app.uuid is the effective primary key")',
      ),
      ExcludedColumn(
        'createdAt',
        'derived at materialization time from the __exists__ operation\'s own HLC',
      ),
    ],
    insertSites: {'lib/services/database_service.dart::insertUserApp'},
    updateSites: {
      'lib/services/database_service.dart::updateUserApp',
      'lib/services/database_service.dart::updateUserAppState',
      'lib/services/database_service.dart::deleteUserApp',
    },
  ),
  TableAudit(
    table: 'app_revisions',
    idColumn: 'id',
    excluded: const [
      ExcludedColumn('id', 'primary key'),
      ExcludedColumn('appId', 'owner FK, never reassigned in place'),
      ExcludedColumn(
        'revisionTimestamp',
        'this table\'s createdAt-equivalent — derived from the __exists__ HLC',
      ),
      ExcludedColumn(
        'deletedAt',
        'fallback-selection tie-break bookkeeping (computeAppRevisionVisibility), always written in the same '
            'local transaction as __deleted__ and fully derivable from it plus that operation\'s own HLC — not '
            'independent synced content',
      ),
    ],
    insertSites: {'lib/services/database_service.dart::insertAppRevision'},
    updateSites: {'lib/services/database_service.dart::deleteAppRevision'},
  ),
  TableAudit(
    table: 'user_app_libraries',
    idColumn: 'id',
    excluded: const [
      ExcludedColumn('id', 'primary key (non-portable INTEGER AUTOINCREMENT)'),
      ExcludedColumn('app_uuid', 'owner FK, never reassigned in place'),
      ExcludedColumn('revision_id', 'owner FK, never reassigned in place'),
    ],
    insertSites: {'lib/services/database_service.dart::insertUserAppLibrary'},
    updateSites: {'lib/services/database_service.dart::deleteUserAppLibrary'},
  ),
  TableAudit(
    table: 'user_app_library_dependencies',
    idColumn: 'id',
    excluded: const [
      ExcludedColumn('id', 'primary key (non-portable INTEGER AUTOINCREMENT)'),
      ExcludedColumn('library_id', 'owner FK, never reassigned in place'),
      ExcludedColumn(
        'bytes',
        'the dependency\'s raw file content — a genuinely large-data column (BLOB NOT NULL), the same '
            'content-addressed-blob-sync/M3-deferred reasoning as app_revisions.appCode above',
      ),
    ],
    insertSites: {
      'lib/services/database_service.dart::insertUserAppLibraryDependency',
    },
    updateSites: {
      'lib/services/database_service.dart::deleteUserAppLibraryDependency',
    },
  ),
];

// ===========================================================================
// Mechanical scanner — same regex/enclosing-function technique as
// `hard_delete_audit_test.dart`'s own `scanDirectHardDeleteSites`, retargeted
// at `.insert`/`.rawInsert`/`.update`/`.rawUpdate` instead of `.delete`.
// ===========================================================================

final RegExp _kFunctionStart = RegExp(
  r'^  (?:static\s+)?[A-Za-z_][\w<>,\.\?\s\[\]]*\s(_?[A-Za-z]\w*)\s*\(',
);

final RegExp _kInsertCall = RegExp(r'\b(db|txn)\.(insert|rawInsert)\(');
final RegExp _kUpdateCall = RegExp(r'\b(db|txn)\.(update|rawUpdate)\(');

final RegExp _kInsertTableArg = RegExp(
  r"""\.insert\(\s*\n?\s*'([a-zA-Z_]+)'""",
);
final RegExp _kUpdateTableArg = RegExp(
  r"""\.update\(\s*\n?\s*'([a-zA-Z_]+)'""",
);
final RegExp _kRawInsertTableArg = RegExp(
  r'''\.rawInsert\(\s*\n?\s*['"]INSERT\s+(?:OR\s+\w+\s+)?INTO\s+(\w+)''',
  caseSensitive: false,
);
final RegExp _kRawUpdateTableArg = RegExp(
  r'''\.rawUpdate\(\s*\n?\s*['"]UPDATE\s+(\w+)''',
  caseSensitive: false,
);

/// One `(file::function)` site performing a live `.insert`/`.update` (or raw
/// equivalent) against a table this audit cares about.
Map<String, Set<String>> _scanCallSites({
  required String root,
  required RegExp callPattern,
  required RegExp tableArgPattern,
  required RegExp rawTableArgPattern,
  required Set<String> excludeDirs,
}) {
  final byTable = <String, Set<String>>{};
  final files = Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where(
        (f) => !excludeDirs.any(
          (d) => f.path.replaceAll('\\', '/').contains('/$d/'),
        ),
      );

  for (final file in files) {
    final path = file.path.replaceAll('\\', '/');
    final lines = file.readAsStringSync().split('\n');

    final funcBoundaries = <MapEntry<int, String>>[];
    for (var i = 0; i < lines.length; i++) {
      final m = _kFunctionStart.firstMatch(lines[i]);
      if (m != null) funcBoundaries.add(MapEntry(i, m.group(1)!));
    }
    String enclosingFunction(int lineIdx) {
      var name = '<top-level>';
      for (final entry in funcBoundaries) {
        if (entry.key <= lineIdx) {
          name = entry.value;
        } else {
          break;
        }
      }
      return name;
    }

    for (var i = 0; i < lines.length; i++) {
      if (!callPattern.hasMatch(lines[i])) continue;
      final buf = StringBuffer();
      for (var j = i; j < lines.length && j < i + 8; j++) {
        buf.writeln(lines[j]);
        if (lines[j].contains(';')) break;
      }
      final bufStr = buf.toString();
      final table =
          tableArgPattern.firstMatch(bufStr)?.group(1) ??
          rawTableArgPattern.firstMatch(bufStr)?.group(1);
      if (table == null) continue;
      byTable
          .putIfAbsent(table, () => {})
          .add('$path::${enclosingFunction(i)}');
    }
  }
  return byTable;
}

Map<String, Set<String>> scanInsertSites({String root = 'lib'}) =>
    _scanCallSites(
      root: root,
      callPattern: _kInsertCall,
      tableArgPattern: _kInsertTableArg,
      rawTableArgPattern: _kRawInsertTableArg,
      excludeDirs: const {'sync'},
    );

Map<String, Set<String>> scanUpdateSites({String root = 'lib'}) =>
    _scanCallSites(
      root: root,
      callPattern: _kUpdateCall,
      tableArgPattern: _kUpdateTableArg,
      rawTableArgPattern: _kRawUpdateTableArg,
      excludeDirs: const {'sync'},
    );

String _diffMessage(String label, Set<String> live, Set<String> baseline) {
  final added = live.difference(baseline).toList()..sort();
  final removed = baseline.difference(live).toList()..sort();
  final buf = StringBuffer();
  if (added.isNotEmpty) {
    buf.writeln(
      '$label: found in the live source but NOT in the checked-in baseline — a NEW insert/update site against '
      'this table. Before adding it to the baseline, re-examine EVERY currently-excluded column of this table '
      'against it: does it give any excluded column a real, per-row-varying value this milestone\'s exclusion '
      'reasoning never accounted for (exactly the tags.name/color gap class this audit exists to catch)?',
    );
    for (final a in added) {
      buf.writeln('  + $a');
    }
  }
  if (removed.isNotEmpty) {
    buf.writeln(
      '$label: baseline entries no longer found in the live source (either the code was refactored — remove '
      'deliberately — or the scan regressed and stopped matching; investigate before removing):',
    );
    for (final r in removed) {
      buf.writeln('  - $r');
    }
  }
  return buf.toString();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late DatabaseService databaseService;
  late Database db;

  setUp(() async {
    databaseService = DatabaseService.createNew();
    db = await databaseService.database;
  });

  tearDown(() async {
    await databaseService.close();
  });

  final liveInsertSites = scanInsertSites();
  final liveUpdateSites = scanUpdateSites();

  for (final audit in kTableAudits) {
    group(audit.table, () {
      test(
        'every excluded column exactly matches the checked-in, documented baseline',
        () async {
          final realColumns = (await db.rawQuery(
            "PRAGMA table_info('${audit.table}')",
          )).map((r) => r['name'] as String).toSet();
          final syncScopeColumns = DatabaseService.syncEntityCaptureScopes
              .firstWhere((s) => s.table == audit.table)
              .syncScopeColumns
              .toSet();
          final liveExcluded = realColumns.difference(syncScopeColumns);
          expect(
            liveExcluded,
            audit.excludedColumnNames,
            reason:
                '${audit.table}: live-scanned excluded-column set (real columns minus syncScopeColumns) disagrees '
                'with this file\'s checked-in baseline. A column newly missing from BOTH syncScopeColumns and this '
                'baseline is exactly the class of silent gap this audit exists to prevent — added: '
                '${liveExcluded.difference(audit.excludedColumnNames)}, removed: '
                '${audit.excludedColumnNames.difference(liveExcluded)}',
          );
        },
      );

      test('every excluded column has a non-empty, checked-in reason', () {
        for (final e in audit.excluded) {
          expect(
            e.reason.trim(),
            isNotEmpty,
            reason: '${audit.table}.${e.column} has no documented reason',
          );
        }
      });

      test(
        'live INSERT call sites against this table exactly match the checked-in baseline',
        () {
          final live = liveInsertSites[audit.table] ?? <String>{};
          expect(
            live,
            audit.insertSites,
            reason: _diffMessage(
              '${audit.table} INSERT sites',
              live,
              audit.insertSites,
            ),
          );
        },
      );

      test(
        'live UPDATE call sites against this table exactly match the checked-in baseline',
        () {
          final live = liveUpdateSites[audit.table] ?? <String>{};
          expect(
            live,
            audit.updateSites,
            reason: _diffMessage(
              '${audit.table} UPDATE sites',
              live,
              audit.updateSites,
            ),
          );
        },
      );
    });
  }
}
