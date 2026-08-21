// M2.8, § Architecture 11.8 item 5(b) — the first time the FULL sync
// engine (M2.3 identity/HLC/seq, M2.4 outbox, M2.5 causal engine, M2.6
// wire format/push/pull, M2.7 materialization) is exercised against
// `GoogleDriveBackend` specifically, rather than `MockSyncBackend`.
// Everything before this milestone that ran a real, multi-device
// `SyncSession.run()` scenario (`sync_session_test.dart`, `materializer_
// test.dart`, this milestone's own `mock_backend_multi_device_e2e_test.
// dart`) did so against `MockSyncBackend` only — `GoogleDriveBackend` had
// only ever been exercised directly against the M2.1 conformance suite
// (`google_drive_backend_test.dart`, M2.2), never through a real
// `SyncSession`.
//
// **What this test proves, and what it explicitly does NOT — stated with
// the same care § 8.6/M2.2's own report already established for
// `GoogleDriveBackend`, not silently assumed to now be settled.** This
// runs two independent `DatabaseService`-backed devices, sharing one
// `GoogleDriveBackend` instance wired to `FakeDriveHttpTransport` (M2.2's
// own hand-written model of Drive's REST API v3 surface — the SAME
// fake-transport-fidelity standard `google_drive_backend_test.dart`
// already established: it exercises `GoogleDriveBackend`'s REAL
// translation code — JSON request/response shaping, `files.create`/
// `files.list`/`files.get` calls, the §8.4 existence-check-before-create
// mitigation, hash-chain commit encoding — not a shortcut or a second
// mock standing in for it. What it does NOT prove, and cannot from this
// environment: behavior against Google's REAL servers (auth quirks, rate
// limits, real network partial failures, real Drive API behavior this
// hand-written model might not perfectly match) — a real-Google-endpoints
// smoke test remains a separate, manual, non-automatable step, exactly as
// M2.2 already disclosed and this milestone does not change.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/oauth_token_manager.dart';
import 'package:note_synapse/services/sync/google_drive_backend.dart';
import 'package:note_synapse/services/sync/sync_session.dart';

import '../sync_backend/fake_drive_http_transport.dart';

OAuthConfig _testOAuthConfig() => OAuthConfig(
  authorizationEndpoint: 'https://accounts.google.test/o/oauth2/auth',
  tokenEndpoint: 'https://oauth2.google.test/token',
  clientId: 'test-client-id',
  scope: 'https://www.googleapis.com/auth/drive.file',
  usePkce: true,
  redirectUri: 'notesynapse://oauth/callback',
);

/// Mirrors `google_drive_backend_test.dart`'s own `_backendWithTransport`
/// helper — a `GoogleDriveBackend` wired to a shared [FakeDriveHttpTransport]
/// with a pre-seeded, never-expiring access token, so this test is scoped
/// to the sync-engine integration question, not auth/refresh (already
/// covered by `google_drive_backend_test.dart` itself).
GoogleDriveBackend _backendWithTransport(FakeDriveHttpTransport transport, {String endpointId = 'drive-test'}) {
  final tokenManager = OAuthTokenManager(
    endpointId: endpointId,
    config: _testOAuthConfig(),
    storagePrefix: 'gdrive_oauth_test_',
  );
  return GoogleDriveBackend(tokenManager: tokenManager, httpClient: transport);
}

class _Device {
  _Device(DatabaseService service) : databaseService = service {
    session = SyncSession(databaseService);
  }

  final DatabaseService databaseService;
  late final SyncSession session;

  Future<Database> get db => databaseService.database;

  Future<void> close() => databaseService.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'gdrive_oauth_test_token_drive-test': 'test-access-token',
    });
  });

  Future<dynamic> fieldValue(_Device d, String table, String id, String field) async {
    final db = await d.db;
    final rows = await db.query(
      'sync_field_state',
      where: 'entityTable = ? AND entityId = ? AND fieldName = ?',
      whereArgs: [table, id, field],
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['valueJson'] as String);
  }

  test(
    'a full SyncSession.run() round-trip through GoogleDriveBackend + FakeDriveHttpTransport: '
    'drain -> push -> (Drive) -> pull -> materialize, real notes.title lands on the second device',
    () async {
      final transport = FakeDriveHttpTransport();
      final backend = _backendWithTransport(transport);

      final a = _Device(DatabaseService.createNew());
      final b = _Device(DatabaseService.createNew());
      try {
        final dbA = await a.db;
        await dbA.insert('notes', {
          'id': 'n1',
          'title': 'from A via Drive',
          'content': 'body',
          'type': 'note',
          'createdAt': 1000,
          'updatedAt': 1000,
        });

        // A: drain its local write, push it as a real Drive commit (a real
        // `files.create` call against the fake transport, through the
        // REAL wire-format encoding — § 11.5 — and the REAL push-phase
        // resume-safe publish-intent bookkeeping — § 11.7 Phase A).
        final aResult = await a.session.run(backend);
        expect(aResult.push.publishedCount, greaterThan(0));

        // B: pull those commits from Drive (real `files.list`/`files.get`
        // calls against the fake transport, real hash-chain verification,
        // real decode), resolve them through the REAL causal engine (M2.5),
        // and materialize the result into its own real `notes` row (M2.7)
        // — all via ONE ordinary `SyncSession.run()` call, exactly as a
        // real device's manual-sync button would trigger.
        final bResult = await b.session.run(backend);
        expect(bResult.pull.commitsApplied, greaterThan(0));

        final titleB = await fieldValue(b, 'notes', 'n1', 'title');
        expect(titleB, 'from A via Drive');

        final dbB = await b.db;
        final rawRow = (await dbB.query('notes', where: 'id = ?', whereArgs: ['n1'])).single;
        expect(rawRow['title'], 'from A via Drive',
            reason: 'the real notes.title row on B must be materialized from what actually round-tripped through '
                'GoogleDriveBackend, not merely land in sync_field_state');

        // A round trip BACK: B edits the now-shared note; A must converge
        // to it too — proving the loop is genuinely bidirectional through
        // Drive, not a one-shot fluke.
        await dbB.update('notes', {'title': 'edited on B, via Drive'}, where: 'id = ?', whereArgs: ['n1']);
        await b.session.run(backend);
        await a.session.run(backend);

        final titleA = await fieldValue(a, 'notes', 'n1', 'title');
        expect(titleA, 'edited on B, via Drive');
        final dbA2 = await a.db;
        final rawRowA = (await dbA2.query('notes', where: 'id = ?', whereArgs: ['n1'])).single;
        expect(rawRowA['title'], 'edited on B, via Drive');
      } finally {
        await a.close();
        await b.close();
      }
    },
  );
}
