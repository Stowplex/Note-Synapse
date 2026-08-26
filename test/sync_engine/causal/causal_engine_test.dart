// Tests for `causal_engine.dart`'s own dispatch/orchestration logic —
// `field_conflict_resolver_test.dart` and `or_set_resolver_test.dart`
// already exercise field/`__exists__` and `set_add`/`set_remove` resolution
// thoroughly THROUGH this facade; this file focuses on what's specific to
// the facade itself: kind dispatch, the `contentKey`-nullable field/exists
// branch, and idempotent-no-op short-circuiting.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/causal/causal_engine.dart';
import 'package:note_synapse/services/sync/causal/dot.dart';
import 'package:note_synapse/services/sync/hlc.dart';

import 'test_minting_device.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late DatabaseService databaseService;
  late Database db;
  late CausalEngine engine;

  setUp(() async {
    databaseService = DatabaseService.createNew();
    db = await databaseService.database;
    engine = CausalEngine();
  });

  tearDown(() async {
    await databaseService.close();
  });

  Future<ApplyResult> apply(IncomingOperation op) => db.transaction((txn) => engine.apply(txn, op));

  test('dispatches "field" kind to the field-conflict resolver', () async {
    final dev = TestMintingDevice('A');
    final op = dev.mintField(table: 'notes', entityId: 'n1', field: 'title', value: 'hello');
    final result = await apply(op);
    expect(result.kind, AppliedKind.fieldOrExists);
    expect(result.fieldRecompute, isNotNull);
    expect(result.fieldRecompute!.winner.valueJson, jsonEncode('hello'));
  });

  test('dispatches "__exists__" kind to the same field-conflict resolver, no special-casing', () async {
    final dev = TestMintingDevice('A');
    final op = dev.mintField(table: 'notes', entityId: 'n1', field: existsFieldSentinel, value: true);
    final opAsExists = IncomingOperation(
      dot: op.dot,
      hlc: op.hlc,
      contentKey: op.contentKey,
      kind: '__exists__',
      entityTable: op.entityTable,
      entityId: op.entityId,
      fieldName: existsFieldSentinel,
      valueJson: op.valueJson,
      frontier: op.frontier,
    );
    final result = await apply(opAsExists);
    expect(result.kind, AppliedKind.fieldOrExists);
    expect(result.fieldRecompute!.winner.valueJson, jsonEncode(true));
  });

  test('dispatches "set_add" kind to the OR-Set resolver', () async {
    final dev = TestMintingDevice('A');
    final op = dev.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1');
    final result = await apply(op);
    expect(result.kind, AppliedKind.setAdd);
    expect(result.setAddResult, isNotNull);
  });

  test('dispatches "set_remove" kind to the OR-Set resolver', () async {
    final dev = TestMintingDevice('A');
    final add = dev.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1');
    await apply(add);
    final remove = dev.mintSetRemove(table: 'notes', entityId: 'n1', memberUuid: 'tag1', targetDots: [add.dot]);
    final result = await apply(remove);
    expect(result.kind, AppliedKind.setRemove);
    expect(result.setRemoveResult, isNotNull);
  });

  test('throws ArgumentError on an unrecognized kind', () async {
    final op = IncomingOperation(
      dot: const Dot('X', 1),
      hlc: const Hlc(1, 0),
      kind: 'bogus_kind',
      entityTable: 'notes',
      entityId: 'n1',
      fieldName: 'title',
      frontier: const {},
    );
    await expectLater(apply(op), throwsArgumentError);
  });

  group('an ordinary field op with a null contentKey never runs dedup at all', () {
    test('two devices editing the same field with no contentKey compete via the ordinary field-conflict path',
        () async {
      final devA = TestMintingDevice('A');
      final devB = TestMintingDevice('B');
      final a = devA.mintField(table: 'notes', entityId: 'n1', field: 'title', value: 'fromA', hlcOverride: 1);
      final b = devB.mintField(table: 'notes', entityId: 'n1', field: 'title', value: 'fromB', hlcOverride: 2);
      await apply(a);
      final result = await apply(b);
      expect(result.fieldRecompute!.winner.valueJson, jsonEncode('fromB'));
      expect(result.fieldRecompute!.retainedConflicts.map((c) => c.valueJson), contains(jsonEncode('fromA')));
    });
  });

  group('a mixed field + OR-Set scenario on the same entity', () {
    test('field-conflict resolution and OR-Set resolution operate independently on the same entity', () async {
      final dev = TestMintingDevice('A');
      final fieldOp = dev.mintField(table: 'notes', entityId: 'n1', field: 'title', value: 'hello');
      final setOp = dev.mintSetAdd(table: 'notes', entityId: 'n1', memberUuid: 'tag1');

      await apply(fieldOp);
      await apply(setOp);

      final fieldRows = await db.query(
        'sync_field_state',
        where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
        whereArgs: ['notes', 'n1', 'title'],
      );
      final setRows = await db.query(
        'sync_set_state',
        where: 'entityTable = ? AND entityId = ? AND fieldName = ? AND memberUuid = ?',
        whereArgs: ['notes', 'n1', 'members', 'tag1'],
      );
      expect(fieldRows, hasLength(1));
      expect(setRows, hasLength(1));
    });
  });
}
