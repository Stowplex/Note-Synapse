// Tests for the M1.9 "tags family completion" milestone
// (.claude/plans/plan-and-propse-the-glistening-dolphin.md, § Phased
// delivery — the seven dependency-ordered sub-milestones list: "M1.9 —
// `tags` family completion: `deleteTag`/`replaceTag`'s remaining
// `tags`-row deletes become tombstone writes, reusing M1.3's existing
// `__deleted__`/`redirectTarget`/`idx_tags_name_live`/`findLiveTagByName`/
// `getOrCreateLiveTagId` machinery ...; plus the `tag_images`/
// `tag_ai_configs` read-side derive-from-owning-tag visibility join.").
//
// `tags` already gained `__deleted__`/`redirectTarget` and
// `idx_tags_name_live` in M1.3 (test/tags_identity_schema_test.dart) — no
// schema migration is needed this milestone, only behavior changes:
//
//  1. `deleteTag`/`replaceTag` now write `__deleted__ = 1` on the `tags`
//     row instead of deleting it. Both (plus `removeTagFromConversation`,
//     a third divergent unguarded `WHERE name = ?` lookup found while
//     auditing every tags read path) now resolve the tag to act on via
//     the shared `DatabaseService.findLiveTagByName` lookup, not a bare
//     name match — necessary now that a tombstoned row can share a name
//     with a live one instead of being physically gone.
//  2. Every tags read path (`getAllTags`, the note/conversation tag-join
//     paths feeding `getNoteById`/`getAllNotes`/`getNotesByTag`/
//     `searchNotesFTS`/`getConversationTags`/`getAllConversations`) now
//     filters `__deleted__ = 0`.
//  3. `tag_images`/`tag_ai_configs` have no independent identity/tombstone
//     of their own (`tagId` is their actual primary key) — per design doc
//     § Architecture 10 they derive visibility from the owning tag's
//     `__deleted__` state via a JOIN (`getAllTagImages`/`getTagImage`/
//     `getTagExtractionPrompt`), since the `ON DELETE CASCADE` from
//     `tags` no longer fires once `deleteTag`/`replaceTag` stop issuing a
//     real `DELETE FROM tags`. The row is verified to still physically
//     exist afterward, not deleted — visibility is derived, not enforced
//     by removing the row.
//  4. M1.3's `findLiveTagByName`/`idx_tags_name_live` continue to work
//     correctly against tombstoned rows this milestone starts actually
//     producing through ordinary usage: a new tag can reuse a
//     `deleteTag`-tombstoned tag's old name.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/database_service.dart';

Note _buildNote(String id, {List<String> tags = const []}) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  return Note(
    id: id,
    title: 'Note $id',
    content: 'content',
    type: NoteType.note,
    createdAt: now,
    updatedAt: now,
    tags: tags,
  );
}

Conversation _buildConversation(String id) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  return Conversation(id: id, title: 'Conv $id', createdAt: now, updatedAt: now);
}

/// Directly seeds a `tags` row, bypassing DatabaseService, for scenarios
/// that need to construct a specific liveness state precisely (a
/// pre-existing tombstoned row under a name, or a membership row left
/// dangling onto a tombstoned tag) rather than one reachable by driving
/// the service's own public API.
Future<void> _seedTag(
  Database db, {
  required String id,
  required String name,
  int deleted = 0,
}) {
  return db.insert('tags', {
    'id': id,
    'name': name,
    'color': '#000000',
    'createdAt': 1,
    'usageCount': 0,
    '__deleted__': deleted,
    'redirectTarget': null,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('M1.9 deleteTag/replaceTag tombstone instead of delete', () {
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
      'deleteTag writes a single __deleted__=1 update; row count unchanged; '
      'note_tags membership row is still really deleted',
      () async {
        await databaseService.insertNote(_buildNote('note-1', tags: ['urgent']));
        final tagId = (await databaseService.getAllTags()).single.id;

        final rowsBefore = await db.query('tags');
        await databaseService.deleteTag('urgent');
        final rowsAfter = await db.query('tags');

        expect(rowsAfter.length, rowsBefore.length, reason: 'tombstone, not delete');
        expect(rowsAfter.single['id'], tagId);
        expect(rowsAfter.single['__deleted__'], 1);

        final noteTags = await db.query(
          'note_tags',
          where: 'tagId = ?',
          whereArgs: [tagId],
        );
        expect(
          noteTags,
          isEmpty,
          reason: 'membership row is an OR-Set real delete, unaffected by this milestone',
        );
      },
    );

    test(
      'deleteTag resolves the LIVE tag via findLiveTagByName, not a stale '
      'tombstoned row sharing the same name',
      () async {
        // A pre-existing tombstoned row under the name the live tag below
        // will also use -- exactly the "old-name row and new-name row
        // coexist" state a bare `WHERE name = ?` lookup could pick wrong.
        await _seedTag(db, id: 'old-dead', name: 'urgent', deleted: 1);
        await databaseService.insertNote(_buildNote('note-1', tags: ['urgent']));

        final liveTag = await DatabaseService.findLiveTagByName(db, 'urgent');
        final liveTagId = liveTag!['id'] as String;
        expect(liveTagId, isNot('old-dead'));

        await databaseService.deleteTag('urgent');

        final oldDead = await db.query(
          'tags',
          where: 'id = ?',
          whereArgs: ['old-dead'],
        );
        expect(
          oldDead.single['__deleted__'],
          1,
          reason: 'untouched -- was already tombstoned',
        );
        final live = await db.query(
          'tags',
          where: 'id = ?',
          whereArgs: [liveTagId],
        );
        expect(
          live.single['__deleted__'],
          1,
          reason: 'the actually-live tag must now be tombstoned',
        );
      },
    );

    test(
      'deleteTag on an already-tombstoned-only name is a no-op',
      () async {
        await _seedTag(db, id: 'dead', name: 'urgent', deleted: 1);

        await databaseService.deleteTag('urgent');

        final rows = await db.query('tags');
        expect(rows.single['id'], 'dead');
        expect(rows.single['__deleted__'], 1);
      },
    );

    test(
      'replaceTag tombstones the OLD tag row instead of deleting it; new '
      'tag row is inserted live',
      () async {
        await databaseService.insertNote(_buildNote('note-1', tags: ['old-name']));
        final oldTagId = (await databaseService.getAllTags()).single.id;

        await databaseService.replaceTag('old-name', 'new-name');

        final rows = await db.query('tags', orderBy: 'createdAt');
        expect(
          rows.length,
          2,
          reason: 'old tag tombstoned in place, new tag inserted -- neither ever deleted',
        );
        final oldRow = rows.firstWhere((r) => r['id'] == oldTagId);
        expect(oldRow['__deleted__'], 1);
        expect(oldRow['name'], 'old-name');

        final liveTags = await databaseService.getAllTags();
        expect(liveTags.map((t) => t.name), ['new-name']);
      },
    );

    test(
      'replaceTag M2.4 fix: a REAL MERGE into an already-live target tag '
      'populates redirectTarget on the losing tag, not just __deleted__',
      () async {
        // Two independently-created, already-live tags — 'new-name' is not
        // created by this call, it already exists (the `newTag != null`
        // branch replaceTag's own doc comment calls a genuine merge, as
        // opposed to a plain rename that mints a brand-new tag row).
        await databaseService.insertNote(_buildNote('note-1', tags: ['old-name']));
        await databaseService.insertNote(_buildNote('note-2', tags: ['new-name']));
        final tagsBefore = await databaseService.getAllTags();
        final oldTagId = tagsBefore.firstWhere((t) => t.name == 'old-name').id;
        final winnerTagId = tagsBefore.firstWhere((t) => t.name == 'new-name').id;

        await databaseService.replaceTag('old-name', 'new-name');

        final rows = await db.query('tags', orderBy: 'createdAt');
        expect(
          rows.length,
          2,
          reason: 'a real merge must not mint a third tag row — the '
              'pre-existing winner absorbs the loser',
        );
        final oldRow = rows.firstWhere((r) => r['id'] == oldTagId);
        expect(oldRow['__deleted__'], 1);
        expect(
          oldRow['redirectTarget'],
          winnerTagId,
          reason: 'the losing tag must redirect to the pre-existing winner '
              'it was merged into — this is the M2.4 fix (design doc '
              '§ Architecture 11.3\'s own named follow-up): previously '
              'redirectTarget stayed NULL forever for every replaceTag call, '
              'merge or rename alike',
        );

        // The winner row itself is untouched (still live, no redirect of
        // its own, same id).
        final winnerRow = rows.firstWhere((r) => r['id'] == winnerTagId);
        expect(winnerRow['__deleted__'], 0);
        expect(winnerRow['redirectTarget'], isNull);

        final liveTags = await databaseService.getAllTags();
        expect(liveTags.map((t) => t.name), ['new-name']);
      },
    );

    test(
      'replaceTag plain RENAME (target name not yet live) leaves '
      'redirectTarget NULL — only a real merge into a pre-existing live '
      'tag populates it (M2.4\'s own explicit scope boundary)',
      () async {
        await databaseService.insertNote(_buildNote('note-1', tags: ['old-name']));
        final oldTagId = (await databaseService.getAllTags()).single.id;

        await databaseService.replaceTag('old-name', 'brand-new-name');

        final oldRow = (await db.query(
          'tags',
          where: 'id = ?',
          whereArgs: [oldTagId],
        )).single;
        expect(oldRow['__deleted__'], 1);
        expect(
          oldRow['redirectTarget'],
          isNull,
          reason: 'a plain rename mints a fresh tag row under a new id — '
              'the old row is not "the same tag, redirected", so '
              'redirectTarget must stay NULL, matching M2.4\'s explicit '
              'scope boundary (only the manual merge path is fixed here; '
              'the full auto-merge/collision-detection mechanism is M2.7\'s '
              'job)',
        );
      },
    );

    test(
      'removeTagFromConversation resolves via the live-tag lookup too '
      '(a third divergent WHERE name = ? lookup found auditing this milestone)',
      () async {
        await _seedTag(db, id: 'old-dead', name: 'urgent', deleted: 1);
        await databaseService.insertConversation(_buildConversation('conv-1'));
        await databaseService.setConversationTags('conv-1', ['urgent']);

        await databaseService.removeTagFromConversation('conv-1', 'urgent');

        expect(await databaseService.getConversationTags('conv-1'), isEmpty);
      },
    );
  });

  group('M1.9 read-path filtering -- tombstoned tag hidden', () {
    late DatabaseService databaseService;
    late Database db;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      db = await databaseService.database;
    });

    tearDown(() async {
      await databaseService.close();
    });

    test('getAllTags hides a tombstoned tag', () async {
      await databaseService.insertNote(_buildNote('note-1', tags: ['urgent']));
      expect(await databaseService.getAllTags(), hasLength(1));

      await databaseService.deleteTag('urgent');

      expect(await databaseService.getAllTags(), isEmpty);
    });

    test(
      'getNoteById/getAllNotes ignore a note_tags row dangling onto a '
      'tombstoned tag (defense-in-depth: deleteTag/replaceTag always purge '
      'note_tags in the same operation, so this is simulated directly to '
      'verify the JOIN filter itself, independent of that invariant)',
      () async {
        await databaseService.insertNote(_buildNote('note-1', tags: ['urgent']));
        final tagId = (await databaseService.getAllTags()).single.id;
        await db.update(
          'tags',
          {'__deleted__': 1},
          where: 'id = ?',
          whereArgs: [tagId],
        );

        final note = await databaseService.getNoteById('note-1');
        expect(note!.tags, isEmpty);

        final all = await databaseService.getAllNotes();
        expect(all.single.tags, isEmpty);

        // The dangling membership row itself was not touched by this test
        // -- confirms the filtering happens at the read-side JOIN, not by
        // relying on the membership row being absent.
        final noteTags = await db.query(
          'note_tags',
          where: 'tagId = ?',
          whereArgs: [tagId],
        );
        expect(noteTags, isNotEmpty);
      },
    );

    test(
      'getNotesByTag no longer finds notes once the tag is tombstoned',
      () async {
        await databaseService.insertNote(_buildNote('note-1', tags: ['urgent']));
        expect(await databaseService.getNotesByTag('urgent'), hasLength(1));

        await databaseService.deleteTag('urgent');

        expect(await databaseService.getNotesByTag('urgent'), isEmpty);
      },
    );

    test(
      'searchNotesFTS tag filter excludes a note whose tag is tombstoned',
      () async {
        await databaseService.insertNote(
          _buildNote('note-1', tags: ['urgent'])
              .copyWith(title: 'find-me-please'),
        );
        expect(
          await databaseService.searchNotesFTS('find-me-please', tags: ['urgent']),
          hasLength(1),
        );

        await databaseService.deleteTag('urgent');

        expect(
          await databaseService.searchNotesFTS('find-me-please', tags: ['urgent']),
          isEmpty,
        );
      },
    );

    test(
      'getConversationTags hides a tag dangling on conversation_tags once '
      'tombstoned',
      () async {
        await databaseService.insertConversation(_buildConversation('conv-1'));
        await databaseService.setConversationTags('conv-1', ['urgent']);
        final tagId = (await databaseService.getConversationTags('conv-1')).single.id;

        await db.update(
          'tags',
          {'__deleted__': 1},
          where: 'id = ?',
          whereArgs: [tagId],
        );

        expect(await databaseService.getConversationTags('conv-1'), isEmpty);

        // The row itself is untouched -- filtering happens at the JOIN.
        final rows = await db.query(
          'conversation_tags',
          where: 'tagId = ?',
          whereArgs: [tagId],
        );
        expect(rows, isNotEmpty);
      },
    );

    test(
      'getAllConversations(tagNames: ...) excludes a match against a '
      'tombstoned tag',
      () async {
        await databaseService.insertConversation(_buildConversation('conv-1'));
        await databaseService.setConversationTags('conv-1', ['urgent']);
        final tagId = (await databaseService.getConversationTags('conv-1')).single.id;

        expect(
          await databaseService.getAllConversations(tagNames: ['urgent']),
          hasLength(1),
        );

        await db.update(
          'tags',
          {'__deleted__': 1},
          where: 'id = ?',
          whereArgs: [tagId],
        );

        expect(
          await databaseService.getAllConversations(tagNames: ['urgent']),
          isEmpty,
        );
      },
    );
  });

  group('M1.9 tag_images/tag_ai_configs derive visibility from owning tag', () {
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
      'getAllTagImages/getTagImage hide a tombstoned tag\'s image; the row '
      'still physically exists (no more DELETE CASCADE once deleteTag stops '
      'issuing a real DELETE FROM tags)',
      () async {
        await databaseService.insertNote(_buildNote('note-1', tags: ['urgent']));
        final tagId = (await databaseService.getAllTags()).single.id;
        await databaseService.setTagImage(tagId, 'builtin:tech-ai');

        expect(await databaseService.getTagImage(tagId), 'builtin:tech-ai');
        expect(await databaseService.getAllTagImages(), {tagId: 'builtin:tech-ai'});

        await databaseService.deleteTag('urgent');

        expect(
          await databaseService.getTagImage(tagId),
          isNull,
          reason: 'owning tag is tombstoned -- must become invisible',
        );
        expect(await databaseService.getAllTagImages(), isEmpty);

        final rawRows = await db.query(
          'tag_images',
          where: 'tagId = ?',
          whereArgs: [tagId],
        );
        expect(
          rawRows,
          isNotEmpty,
          reason: 'visibility is derived, the row itself must not be deleted',
        );
        expect(rawRows.single['imagePath'], 'builtin:tech-ai');
      },
    );

    test(
      'getTagExtractionPrompt hides a tombstoned tag\'s prompt; the row '
      'still physically exists',
      () async {
        await databaseService.insertNote(_buildNote('note-1', tags: ['urgent']));
        final tagId = (await databaseService.getAllTags()).single.id;
        await databaseService.updateTagExtractionPrompt(tagId, 'extract dates');

        expect(await databaseService.getTagExtractionPrompt(tagId), 'extract dates');

        await databaseService.deleteTag('urgent');

        expect(
          await databaseService.getTagExtractionPrompt(tagId),
          isNull,
          reason: 'owning tag is tombstoned -- must become invisible',
        );

        final rawRows = await db.query(
          'tag_ai_configs',
          where: 'tagId = ?',
          whereArgs: [tagId],
        );
        expect(rawRows, isNotEmpty);
        expect(rawRows.single['extractionPrompt'], 'extract dates');
      },
    );

    test(
      'replaceTag leaves the old tag\'s tag_images row physically intact '
      'but invisible',
      () async {
        await databaseService.insertNote(_buildNote('note-1', tags: ['old-name']));
        final oldTagId = (await databaseService.getAllTags()).single.id;
        await databaseService.setTagImage(oldTagId, 'builtin:tech-ai');

        await databaseService.replaceTag('old-name', 'new-name');

        expect(await databaseService.getTagImage(oldTagId), isNull);
        final rawRows = await db.query(
          'tag_images',
          where: 'tagId = ?',
          whereArgs: [oldTagId],
        );
        expect(rawRows, isNotEmpty, reason: 'not cascaded away, just invisible');
      },
    );
  });

  group(
    'M1.9 findLiveTagByName/idx_tags_name_live -- name reuse after tombstoning',
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
        'a new tag can reuse a deleteTag-tombstoned tag\'s old name',
        () async {
          await databaseService.insertNote(_buildNote('note-1', tags: ['urgent']));
          final oldTagId = (await databaseService.getAllTags()).single.id;
          await databaseService.deleteTag('urgent');

          // getOrCreateLiveTagId (via insertNote -> _linkNoteToTag) must
          // create a fresh row, not resurrect the tombstoned one.
          await databaseService.insertNote(_buildNote('note-2', tags: ['urgent']));

          final liveTags = await databaseService.getAllTags();
          expect(liveTags.map((t) => t.name), ['urgent']);
          expect(liveTags.single.id, isNot(oldTagId));

          final oldRow = await db.query(
            'tags',
            where: 'id = ?',
            whereArgs: [oldTagId],
          );
          expect(
            oldRow.single['__deleted__'],
            1,
            reason: 'old tombstoned row is untouched, not resurrected',
          );

          final allRows = await db.query('tags');
          expect(
            allRows.length,
            2,
            reason: 'both rows physically coexist -- one live, one tombstoned',
          );
        },
      );

      test(
        'idx_tags_name_live still rejects two LIVE rows sharing a name '
        '(getOrCreateLiveTagId is idempotent for an already-live name)',
        () async {
          await databaseService.insertNote(_buildNote('note-1', tags: ['urgent']));
          await databaseService.insertNote(_buildNote('note-2', tags: ['urgent']));

          final liveTags = await databaseService.getAllTags();
          expect(
            liveTags.length,
            1,
            reason: 'both notes share the same live tag row, not two',
          );
        },
      );
    },
  );
}
