// Tests for `dot_redirect_resolver.dart` — transitive resolution against
// `sync_dot_redirects` (M2.5, § Architecture 11.4).
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/sync/causal/dot.dart';
import 'package:note_synapse/services/sync/causal/dot_redirect_resolver.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late DatabaseService databaseService;
  late Database db;
  const resolver = DotRedirectResolver();

  setUp(() async {
    databaseService = DatabaseService.createNew();
    db = await databaseService.database;
  });

  tearDown(() async {
    await databaseService.close();
  });

  Future<void> writeRedirect(Dot observed, Dot canonical) async {
    await db.insert('sync_dot_redirects', {
      'observedAuthorId': observed.authorId,
      'observedAuthorSeq': observed.authorSeq,
      'canonicalAuthorId': canonical.authorId,
      'canonicalAuthorSeq': canonical.authorSeq,
    });
  }

  test('a dot with no redirect resolves to itself', () async {
    final d = Dot('A', 1);
    expect(await resolver.resolveDot(db, d), d);
  });

  test('a single-hop redirect resolves to the canonical target', () async {
    final observed = Dot('B', 1);
    final canonical = Dot('A', 1);
    await writeRedirect(observed, canonical);
    expect(await resolver.resolveDot(db, observed), canonical);
  });

  test('a multi-hop chain resolves transitively to the final canonical dot', () async {
    // C -> B -> A (a canonical swap history: B was once canonical, then A
    // superseded it, per content_key_dedup.dart's canonical-swap
    // behavior -- the OLD canonical gets ONE new redirect entry, stale
    // one-hop entries pointing at it are left as-is and must resolve
    // transitively).
    final c = Dot('C', 1);
    final b = Dot('B', 1);
    final a = Dot('A', 1);
    await writeRedirect(c, b);
    await writeRedirect(b, a);
    expect(await resolver.resolveDot(db, c), a);
    expect(await resolver.resolveDot(db, b), a);
    expect(await resolver.resolveDot(db, a), a);
  });

  test('resolveMany resolves each dot independently, preserving order', () async {
    final c = Dot('C', 1);
    final b = Dot('B', 1);
    final a = Dot('A', 1);
    await writeRedirect(c, a);
    final resolved = await resolver.resolveMany(db, [c, b, a]);
    expect(resolved, [a, b, a]);
  });
}
