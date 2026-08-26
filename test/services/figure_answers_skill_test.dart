// Step 15 — the bundled "Figure Answers" agent skill (plan §4.2).
//
// The skill is what carries the reply-quality guidance for `search_figures`
// (the tool description stays to one guardrail line), so two things must
// hold: SkillService can parse its frontmatter, and StarterService offers it
// for installation under the ref Step 10's settings cross-link looks for
// (`figure-answers`) — deduping once the user has installed it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/starter_service.dart';

// Reuses the mocks generated for the AgentService binding test — building an
// AgentService needs four collaborators, none of which this test exercises.
import 'agent_service_binding_test.mocks.dart';

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      Directory.systemTemp.path;
}

const String _skillAssetPath = 'assets/starter/skills/Figure_Answers.md';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final String skillSource = File(_skillAssetPath).readAsStringSync();

  late DatabaseService db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });

  setUp(() async {
    await resetForTesting();
    db = DatabaseService.createNew();
    await db.database;
    getIt.registerSingleton<DatabaseService>(db);
  });

  tearDown(() async {
    await db.close();
    await resetForTesting();
  });

  group('frontmatter', () {
    test('parseSkillMetadata accepts it and yields the pinned ref', () {
      final meta = SkillService(db).parseSkillMetadata('note-1', skillSource);

      expect(meta, isNotNull);
      expect(meta!.name, 'Figure Answers');
      // Step 10's settings cross-link detects exactly this ref.
      expect(meta.skillRef, 'figure-answers');
      expect(meta.enabled, isTrue);
      expect(meta.description, isNotEmpty);
      expect(meta.description.toLowerCase(), contains('visual'));
    });

    test('the body carries the guidance the tool description does not', () {
      final body = SkillService(db).stripFrontmatter(skillSource);

      expect(body, contains('search_figures'));
      // Retrieval before generation, figures vs pages, provenance, no-match
      // handling keyed off the tool's layer/index report, and cost.
      expect(body, contains('generate an image'));
      expect(body, contains('Never turn one into an image'));
      expect(body, contains('Layers off:'));
      expect(body, contains('Index:'));
      expect(body, contains('Scope:'));
      expect(body.toLowerCase(), contains('provenance'));
      expect(body.toLowerCase(), contains('cost'));
    });

    test('the no-match rule forbids asserting absence on an unusable '
        'index', () {
      final body = SkillService(db).stripFrontmatter(skillSource);

      // The tool prints an `Index:` line ONLY when the index could not answer
      // (mid-backfill, or no FTS4 on this device). The skill must turn that
      // into "the search could not complete", never "you have no such
      // figure" — the whole point of Step 15's honesty contract.
      expect(body, contains('non-answer'));
      expect(body, contains('never that the figure is missing'));
    });

    test('the cost section does not claim retrieval is offline', () {
      final body = SkillService(db).stripFrontmatter(skillSource);

      // Every call embeds the query through the SERVING provider, which is a
      // network round-trip whenever that provider is a cloud one.
      expect(body, isNot(contains('free and offline')));
      expect(body.toLowerCase(), isNot(contains('retrieval is free')));
    });
  });

  group('tool grant', () {
    // ConversationService.handleLoadSkillResult grants a session's tools by
    // scanning the LOADED SKILL for notesynapse://tool/builtin/<name> URIs and
    // resolving them against AgentService.nativeTools. Without a link in the
    // body the skill tells the model to call a tool it was never given, unless
    // the user separately ticked Search Figures in the system-tool picker.
    test('the body carries a builtin tool URI that the loader resolves to '
        'search_figures', () {
      final skillService = SkillService(db);
      final uris = skillService.extractToolUris(
        skillService.stripFrontmatter(skillSource),
      );

      final parsed = [
        for (final uri in uris) skillService.parseToolUri(uri),
      ].nonNulls.where((p) => p.namespace == 'builtin').toList();

      expect(
        [for (final p in parsed) p.id],
        contains('search_figures'),
        reason: 'this exact URI shape is what handleLoadSkillResult parses',
      );

      // ...and the id it parses must exist in the native tool list it is
      // resolved against, or the grant silently no-ops.
      final agentService = AgentService(
        MockContextManagerService(),
        MockModelSelector(),
        MockAIService(),
        MockDatabaseService(),
      );
      expect(
        agentService.nativeTools.map((tool) => tool.name),
        contains('search_figures'),
      );
    });
  });

  group('StarterService', () {
    test('lists Figure Answers as an installable starter skill', () async {
      final skills = await StarterService.getStarterSkills();

      final figureAnswers = skills.firstWhere(
        (skill) => skill['skillRef'] == 'figure-answers',
        orElse: () => <String, dynamic>{},
      );
      expect(
        figureAnswers,
        isNotEmpty,
        reason: 'the bundled skill must be enumerated from the asset bundle',
      );
      expect(figureAnswers['name'], 'Figure Answers');
      expect(figureAnswers['filePath'], _skillAssetPath);
      expect(figureAnswers['isInstalled'], isFalse);
    });

    test('dedupes by skillRef once the skill note exists', () async {
      await db.insertNote(
        Note(
          id: 'starter-skill-figure-answers',
          title: 'Figure Answers',
          content: skillSource,
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          tags: const [SkillService.agentSkillTag, 'starter-skill'],
        ),
      );

      final skills = await StarterService.getStarterSkills();

      final figureAnswers = skills.firstWhere(
        (skill) => skill['skillRef'] == 'figure-answers',
      );
      expect(figureAnswers['isInstalled'], isTrue);
      // The other bundled skill is unaffected by the dedupe.
      final knowledge = skills.firstWhere(
        (skill) => skill['skillRef'] == 'knowledge-exploration',
        orElse: () => <String, dynamic>{},
      );
      expect(knowledge['isInstalled'], isFalse);
    });

    test('installStarterSkills installs it once, then no-ops', () async {
      final installed = await StarterService.installStarterSkills(
        skillRefs: {'figure-answers'},
      );
      expect(installed, 1);

      final notes = await db.getNotesByTag(SkillService.agentSkillTag);
      expect(notes, hasLength(1));
      final meta = SkillService(
        db,
      ).parseSkillMetadata(notes.single.id, notes.single.content);
      expect(meta!.skillRef, 'figure-answers');

      expect(
        await StarterService.installStarterSkills(
          skillRefs: {'figure-answers'},
        ),
        0,
        reason: 'an installed skill must not be duplicated',
      );
    });
  });
}
