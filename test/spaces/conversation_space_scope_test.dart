import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/space_scope_service.dart';

/// M5 / correction C3: `getAllConversations(tagNames:)` ANDs its tags, so
/// seeding the conversation tree with a Space's tags could never also surface
/// the cross-Space conversations design §4.12 promises.
///
/// `includeAllSpacesTag` ORs the reserved tag around the whole conjunction,
/// mirroring the `searchNotesFTS` seam from M2. Real sqflite: the point is the
/// SQL, and the AND/OR distinction only exists there.
void main() {
  late DatabaseService db;
  late ConversationService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    db = DatabaseService.createNew();
    await db.database;
    service = ConversationService(db);
  });

  tearDown(() async {
    await db.close();
  });

  var clock = DateTime(2026, 1, 1);

  Future<Conversation> seed(String id, {List<String> tags = const []}) async {
    // Distinct, increasing timestamps so `ORDER BY updatedAt DESC` is stable.
    clock = clock.add(const Duration(minutes: 1));
    final conversation = Conversation(
      id: id,
      title: 'Conversation $id',
      createdAt: clock,
      updatedAt: clock,
    );
    await db.insertConversation(conversation);
    if (tags.isNotEmpty) await db.addTagsToConversation(id, tags);
    return conversation;
  }

  /// [tagNames] are the caller's own tags, [scopeTags] the Space's — the two
  /// lists the query keeps apart so `all-spaces` can only widen the second.
  Future<List<String>> query(
    List<String> tagNames, {
    List<String>? scopeTags,
    bool includeAllSpacesTag = false,
    bool includeEmpty = true,
    Duration? maxAge,
    List<String>? conversationIds,
  }) async {
    final results = await db.getAllConversations(
      tagNames: tagNames,
      scopeTags: scopeTags,
      includeAllSpacesTag: includeAllSpacesTag,
      includeEmpty: includeEmpty,
      maxAge: maxAge,
      conversationIds: conversationIds,
    );
    return results.map((c) => c.id).toList()..sort();
  }

  /// A Space-scoped query with no chips of the caller's own: the shape the
  /// conversation tree issues when its chips are still the seeded Space tags.
  Future<List<String>> scoped(
    List<String> spaceTags, {
    List<String> tagNames = const [],
    bool includeEmpty = true,
    Duration? maxAge,
    List<String>? conversationIds,
  }) => query(
    tagNames,
    scopeTags: spaceTags,
    includeAllSpacesTag: true,
    includeEmpty: includeEmpty,
    maxAge: maxAge,
    conversationIds: conversationIds,
  );

  // ------------------------------------------------------- createConversation

  group('createConversation(tags:)', () {
    test('files the conversation under the tags it is given', () async {
      final conversation = await service.createConversation(
        title: 'Inside a Space',
        tags: ['thesis', '2026'],
      );

      final names = await db.getConversationTagNames(conversation.id);
      expect(names..sort(), ['2026', 'thesis']);
      expect(await query(['thesis', '2026']), [conversation.id]);
    });

    test('tags nothing by default, so every existing caller is unchanged',
        () async {
      final conversation = await service.createConversation(title: 'Plain');

      expect(await db.getConversationTagNames(conversation.id), isEmpty);
    });
  });

  // --------------------------------------------------------- the AND/OR seam

  group('getAllConversations(includeAllSpacesTag:)', () {
    test('without the flag the tags are ANDed and all-spaces is invisible',
        () async {
      await seed('member', tags: ['thesis', '2026']);
      await seed('partial', tags: ['thesis']);
      await seed('everywhere', tags: [SpaceScopeService.allSpacesTag]);

      expect(await query(['thesis', '2026']), ['member']);
    });

    test('with the flag an all-spaces conversation joins the Space\'s own',
        () async {
      await seed('member', tags: ['thesis', '2026']);
      await seed('partial', tags: ['thesis']);
      await seed('everywhere', tags: [SpaceScopeService.allSpacesTag]);
      await seed('outsider', tags: ['cooking']);

      expect(await scoped(['thesis', '2026']), ['everywhere', 'member']);
    });

    test('the tags stay ANDed inside the OR: a partial match is still out',
        () async {
      await seed('partial', tags: ['thesis']);
      await seed('everywhere', tags: [SpaceScopeService.allSpacesTag]);

      expect(await scoped(['thesis', '2026']), ['everywhere']);
    });

    test('the same all-spaces conversation appears inside EVERY Space',
        () async {
      await seed('thesisOnly', tags: ['thesis']);
      await seed('readingOnly', tags: ['reading']);
      await seed('everywhere', tags: [SpaceScopeService.allSpacesTag]);

      expect(await scoped(['thesis']), ['everywhere', 'thesisOnly']);
      expect(await scoped(['reading']), ['everywhere', 'readingOnly']);
    });

    test('a conversation carrying both the Space tags and all-spaces is '
        'returned once', () async {
      await seed('both', tags: ['thesis', '2026', SpaceScopeService.allSpacesTag]);

      final results = await db.getAllConversations(
        scopeTags: ['thesis', '2026'],
        includeAllSpacesTag: true,
      );
      expect(results.map((c) => c.id).toList(), ['both']);
    });

    test('newest first, like the unscoped query', () async {
      await seed('older', tags: ['thesis']);
      await seed('everywhere', tags: [SpaceScopeService.allSpacesTag]);
      await seed('newest', tags: ['thesis']);

      final results = await db.getAllConversations(
        scopeTags: ['thesis'],
        includeAllSpacesTag: true,
      );
      expect(results.map((c) => c.id).toList(), [
        'newest',
        'everywhere',
        'older',
      ]);
    });

    test('the other filters still apply on the OR path', () async {
      await seed('everywhere', tags: [SpaceScopeService.allSpacesTag]);
      await seed('member', tags: ['thesis']);

      // conversationIds narrows even an all-spaces conversation out.
      expect(
        await scoped(['thesis'], conversationIds: ['member']),
        ['member'],
      );
      // maxAge keeps both (they were just written).
      expect(
        await scoped(['thesis'], maxAge: const Duration(days: 3650)),
        ['everywhere', 'member'],
      );
    });

    test('includeEmpty: false drops message-less conversations on the OR path',
        () async {
      await seed('everywhere', tags: [SpaceScopeService.allSpacesTag]);
      await seed('member', tags: ['thesis']);
      await service.addUserMessage(conversationId: 'member', content: 'hello');

      expect(await scoped(['thesis'], includeEmpty: false), ['member']);
      expect(await scoped(['thesis']), ['everywhere', 'member']);
    });

    test('with no tags the flag changes nothing', () async {
      await seed('a');
      await seed('b', tags: ['thesis']);

      final all = await db.getAllConversations(includeAllSpacesTag: true);
      expect(all.map((c) => c.id).toList()..sort(), ['a', 'b']);
    });
  });

  // ----------------------------------------- composition: the M5 blocker shape

  group('scopeTags compose with the caller\'s own tags', () {
    /// The tree's chips stay editable inside a Space, so the two tag lists
    /// must reach the query separately: `all-spaces` may widen the Space's
    /// group and nothing else. Merged into one conjunction the predicate
    /// becomes `(urgent AND thesis) OR all-spaces`, which returns every
    /// cross-Space conversation whether or not it is urgent.
    Future<void> seedComposition() async {
      await seed('member', tags: ['thesis', 'urgent']);
      await seed('thesisOnly', tags: ['thesis']);
      await seed('everywhere', tags: [SpaceScopeService.allSpacesTag]);
      await seed('urgentEverywhere', tags: [
        'urgent',
        SpaceScopeService.allSpacesTag,
      ]);
      await seed('urgentOutside', tags: ['urgent', 'cooking']);
    }

    test('a chip added inside a Space narrows instead of widening', () async {
      await seedComposition();

      expect(
        await scoped(['thesis'], tagNames: ['urgent']),
        // NOT 'everywhere': it is cross-Space, but it is not urgent, and the
        // caller asked for urgent.
        ['member', 'urgentEverywhere'],
      );
    });

    test('the caller\'s tags are never escaped by all-spaces', () async {
      await seedComposition();

      // Nothing carries `budget`, so nothing matches — not even the
      // cross-Space conversations.
      expect(await scoped(['thesis'], tagNames: ['budget']), isEmpty);
    });

    test('a cross-Space conversation still has to match the caller\'s tags',
        () async {
      await seedComposition();

      final urgent = await scoped(['thesis'], tagNames: ['urgent']);
      expect(urgent.contains('urgentEverywhere'), isTrue);
      expect(urgent.contains('everywhere'), isFalse);
    });

    test('the flag fails closed: no scope tags, no OR', () async {
      await seed('member', tags: ['thesis']);
      await seed('everywhere', tags: [SpaceScopeService.allSpacesTag]);

      // With no Space there is no scope to escape, so asking for the OR
      // without scope tags must not widen the caller's own conjunction.
      expect(
        await query(['thesis'], includeAllSpacesTag: true),
        ['member'],
      );
    });

    test('scope tags without the flag are a plain extra conjunction', () async {
      await seed('member', tags: ['thesis', 'urgent']);
      await seed('everywhere', tags: ['urgent', SpaceScopeService.allSpacesTag]);

      expect(
        await query(['urgent'], scopeTags: ['thesis']),
        ['member'],
      );
    });
  });

  // ------------------------------------------------------- through the tree

  group('the conversation tree', () {
    test('seeded with a Space\'s tags still shows the all-spaces conversation',
        () async {
      await seed('member', tags: ['thesis']);
      await seed('everywhere', tags: [SpaceScopeService.allSpacesTag]);
      await seed('outsider', tags: ['cooking']);
      for (final id in ['member', 'everywhere', 'outsider']) {
        // A tree node is one User→AI interaction, so both halves are needed.
        await service.addUserMessage(conversationId: id, content: 'hello $id');
        await service.addAIResponse(conversationId: id, content: 'reply $id');
      }

      final tree = await service.refreshConversationTree(
        scopeTags: ['thesis'],
        includeAllSpacesTag: true,
      );

      expect(tree, isNotNull);
      final ids = tree!.nodes.values.map((n) => n.conversationId).toSet();
      expect(ids.contains('member'), isTrue);
      expect(ids.contains('everywhere'), isTrue);
      expect(ids.contains('outsider'), isFalse);
    });
  });
}
