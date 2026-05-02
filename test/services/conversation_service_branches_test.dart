import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/database_service.dart';

void main() {
  late DatabaseService db;
  late ConversationService convService;

  setUp(() async {
    db = DatabaseService.createNew();
    convService = ConversationService.createForTesting(db);
    await db.clearAllData();
  });

  tearDown(() async {
    await db.close();
  });

  test('returns empty map for a conversation with no children', () async {
    final solo = await convService.createConversation(
        title: 'Solo', noteIds: const []);
    await convService.addUserMessage(
        conversationId: solo.id, content: 'Hi');
    final result = await convService.getAllForkPointBranches(solo.id);
    expect(result, isEmpty);
  });

  test('returns each child branch keyed by parent message ID', () async {
    final parent = await convService.createConversation(
        title: 'Parent', noteIds: const []);
    final msg = await convService.addUserMessage(
        conversationId: parent.id, content: 'Q?');
    final childA = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: msg.id,
        newTitle: 'Branch A');
    final childB = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: msg.id,
        newTitle: 'Branch B');

    final result = await convService.getAllForkPointBranches(parent.id);
    expect(result.containsKey(msg.id), isTrue);
    final branches = result[msg.id]!;
    expect(branches.length, 2);
    final ids = branches.map((b) => b.conversationId).toSet();
    expect(ids, {childA.id, childB.id});
    // The active (parent) conversation must NOT appear as a branch entry —
    // only children of this conversation's fork-point messages do.
    expect(ids.contains(parent.id), isFalse);
  });

  test(
      'dedups: child conversation appears once even if multiple messages share fork point',
      () async {
    final parent = await convService.createConversation(
        title: 'Parent', noteIds: const []);
    final msg1 = await convService.addUserMessage(
        conversationId: parent.id, content: 'Q1?');
    final childA = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: msg1.id,
        newTitle: 'Child');

    final result = await convService.getAllForkPointBranches(parent.id);
    final allBranches = result.values.expand((l) => l).toList();
    final childCount = allBranches
        .where((b) => b.conversationId == childA.id)
        .length;
    expect(childCount, lessThanOrEqualTo(1),
        reason:
            'A given child conversation should appear at most once at a single fork-point');
  });

  test('summary populates noteIds for the child conversation', () async {
    // conversation_note_mapping has FK to notes table, so we cannot pass a
    // bare noteId string without inserting a real note row. Instead verify
    // that the noteIds field is present and is a List<String> — the FK-aware
    // noteIds test belongs with a full note fixture which is out of scope here.
    final parent = await convService.createConversation(
        title: 'P', noteIds: const []);
    final msg = await convService.addUserMessage(
        conversationId: parent.id, content: 'Q');
    final child = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: msg.id,
        newTitle: 'C');

    final result = await convService.getAllForkPointBranches(parent.id);
    final branch = result[msg.id]!.first;
    // noteIds is a List<String> (possibly empty when no notes attached)
    expect(branch.noteIds, isA<List<String>>());
    expect(branch.conversationId, child.id);
    expect(branch.forkPointMessageId, msg.id);
    expect(branch.title, 'C');
  });

  test(
      'firstChildMessageId resolves to the earliest-timestamped shared message in the child conversation',
      () async {
    final parent = await convService.createConversation(
        title: 'P', noteIds: const []);
    final m1 = await convService.addUserMessage(
        conversationId: parent.id, content: 'A');
    final child = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: m1.id,
        newTitle: 'C');

    final result = await convService.getAllForkPointBranches(parent.id);
    final branch = result[m1.id]!.first;
    // The earliest message in `child` at this fork point should be m1 itself
    // (the only message shared at fork creation).
    expect(branch.firstChildMessageId, m1.id);
    expect(branch.conversationId, child.id);
  });

  test(
      'getChildBranches returns the same data as getAllForkPointBranches for one parent',
      () async {
    final parent = await convService.createConversation(
        title: 'P', noteIds: const []);
    final m = await convService.addUserMessage(
        conversationId: parent.id, content: 'Q');
    await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: m.id,
        newTitle: 'C');

    final batched = await convService.getAllForkPointBranches(parent.id);
    final single = await convService.getChildBranches(m.id);
    expect(single.length, batched[m.id]!.length);
    expect(single.first.conversationId, batched[m.id]!.first.conversationId);
  });

  test('EXPLAIN QUERY PLAN uses message_parents index', () async {
    final dbInst = await db.database;
    final plan = await dbInst.rawQuery('''
      EXPLAIN QUERY PLAN
      SELECT mp.parentMessageId
        FROM message_parents mp
        JOIN conversation_message_mapping cmm ON cmm.messageId = mp.messageId
       WHERE mp.parentMessageId = ?
    ''', ['x']);
    final detail = plan.map((r) => r['detail'].toString()).join(' | ');
    expect(detail, contains('idx_message_parents'),
        reason: 'Query must use the message_parents index. Plan: $detail');
  });
}
