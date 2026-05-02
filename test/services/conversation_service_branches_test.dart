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

  test('returns empty map immediately after fork creation (no post-fork messages yet)',
      () async {
    // Verifies the spec semantic: strip only renders when message_parents
    // shows multiple children. A bare fork (no new messages) must not trigger
    // the strip.
    final parent = await convService.createConversation(
        title: 'Parent', noteIds: const []);
    final m = await convService.addUserMessage(
        conversationId: parent.id, content: 'Q?');
    await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: m.id,
        newTitle: 'Branch');
    // No new messages added on either branch yet — message_parents has no
    // row pointing at m, so the strip must not render.
    final result = await convService.getAllForkPointBranches(parent.id);
    expect(result, isEmpty,
        reason:
            'No message_parents row yet — strip should not render');
  });

  test(
      'returns each child branch keyed by parent message ID after both branches have post-fork content',
      () async {
    final parent = await convService.createConversation(
        title: 'Parent', noteIds: const []);
    final forkPoint = await convService.addUserMessage(
        conversationId: parent.id, content: 'Q?');
    final childA = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: forkPoint.id,
        newTitle: 'Branch A');
    final childB = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: forkPoint.id,
        newTitle: 'Branch B');
    // Add post-fork user messages so message_parents gets populated.
    // addUserMessage detects the fork point (forkPoint exists in 3+ conversations)
    // and writes message_parents(newMsg, parent=forkPoint).
    await convService.addUserMessage(
        conversationId: childA.id, content: 'A1');
    await convService.addUserMessage(
        conversationId: childB.id, content: 'B1');

    final result = await convService.getAllForkPointBranches(parent.id);
    expect(result.containsKey(forkPoint.id), isTrue);
    final branches = result[forkPoint.id]!;
    expect(branches.length, 2);
    final ids = branches.map((b) => b.conversationId).toSet();
    expect(ids, {childA.id, childB.id});
    // The active (parent) conversation must NOT appear as a branch entry.
    expect(ids.contains(parent.id), isFalse);
  });

  test(
      'dedups: child conversation appears once per fork point even if it has multiple message_parents rows pointing at the same parent',
      () async {
    final parent = await convService.createConversation(
        title: 'Parent', noteIds: const []);
    final forkPoint = await convService.addUserMessage(
        conversationId: parent.id, content: 'Q?');
    final child = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: forkPoint.id,
        newTitle: 'Child');
    // Two new messages on the child — first points at forkPoint (fork detection),
    // second points at C1 (normal sequential parent). GROUP BY collapses both.
    await convService.addUserMessage(
        conversationId: child.id, content: 'C1');
    await convService.addUserMessage(
        conversationId: child.id, content: 'C2');

    final result = await convService.getAllForkPointBranches(parent.id);
    final allBranches = result.values.expand((l) => l).toList();
    final childCount =
        allBranches.where((b) => b.conversationId == child.id).length;
    expect(childCount, 1,
        reason:
            'GROUP BY (parentMessageId, conversationId) collapses to one entry per fork-point/child pair');
  });

  test('summary populates noteIds and core fields for the child conversation',
      () async {
    final parent = await convService.createConversation(
        title: 'P', noteIds: const []);
    final forkPoint = await convService.addUserMessage(
        conversationId: parent.id, content: 'Q');
    final child = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: forkPoint.id,
        newTitle: 'C');
    await convService.addUserMessage(
        conversationId: child.id, content: 'C1');

    final result = await convService.getAllForkPointBranches(parent.id);
    final branch = result[forkPoint.id]!.first;
    // noteIds is a List<String> (possibly empty when no notes attached)
    expect(branch.noteIds, isA<List<String>>());
    expect(branch.conversationId, child.id);
    expect(branch.forkPointMessageId, forkPoint.id);
    expect(branch.title, 'C');
  });

  test(
      'firstChildMessageId is the earliest-timestamped child message in that branch',
      () async {
    final parent = await convService.createConversation(
        title: 'P', noteIds: const []);
    final forkPoint = await convService.addUserMessage(
        conversationId: parent.id, content: 'Q');
    final child = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: forkPoint.id,
        newTitle: 'C');
    final firstNewMsg = await convService.addUserMessage(
        conversationId: child.id, content: 'C1');
    await convService.addUserMessage(
        conversationId: child.id, content: 'C2');

    final result = await convService.getAllForkPointBranches(parent.id);
    final branch = result[forkPoint.id]!.first;
    // firstChildMessageId must point at C1 (earliest), not C2.
    expect(branch.firstChildMessageId, firstNewMsg.id);
  });

  test(
      'getChildBranches returns the same data as getAllForkPointBranches for one parent',
      () async {
    final parent = await convService.createConversation(
        title: 'P', noteIds: const []);
    final m = await convService.addUserMessage(
        conversationId: parent.id, content: 'Q');
    final child = await convService.forkConversation(
        originalConversationId: parent.id,
        forkFromMessageId: m.id,
        newTitle: 'C');
    await convService.addUserMessage(
        conversationId: child.id, content: 'C1');

    final batched = await convService.getAllForkPointBranches(parent.id);
    final single = await convService.getChildBranches(m.id);
    expect(single.length, batched[m.id]!.length);
    expect(single.first.conversationId, batched[m.id]!.first.conversationId);
  });

  test('EXPLAIN QUERY PLAN uses idx_message_parents_parentMessageId', () async {
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
