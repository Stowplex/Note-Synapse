import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';
import '../models/note.dart';
import 'data_change_notifier.dart';
import 'database_service.dart';
import 'logger_service.dart';
import 'service_locator.dart';
import 'skill_service.dart';

/// Service for managing starter content (User Manual and starter apps)
class StarterService {
  static const String userManualUuid = '00000000-0000-0000-0000-000000000001';
  static const String userManualYamlPath = 'assets/starter/USER_MANUAL.yaml';
  static const String userManualPdfPath = 'assets/starter/USER_MANUAL.pdf';
  static const String starterAppsPath = 'assets/starter/apps';
  static const String starterSkillsPath = 'assets/starter/skills';

  /// Check if User Manual note exists
  static Future<Note?> getUserManualNote() async {
    final databaseService = getIt<DatabaseService>();
    try {
      final note = await databaseService.getNote(userManualUuid);
      return note;
    } catch (e) {
      LoggerService.debug('User Manual note not found: $e');
      return null;
    }
  }

  /// Parse version from USER_MANUAL.yaml
  static Future<Map<String, String>> parseUserManualYaml() async {
    try {
      final yamlString = await rootBundle.loadString(userManualYamlPath);
      final yamlData = loadYaml(yamlString);

      final version = yamlData['version']?.toString() ?? '1.0.0';
      final updateDate = yamlData['update_date']?.toString() ?? 'Unknown';

      return {'version': version, 'updateDate': updateDate};
    } catch (e) {
      LoggerService.error('Error parsing USER_MANUAL.yaml: $e');
      rethrow;
    }
  }

  /// Parse version from existing note content
  static String? parseVersionFromNoteContent(String content) {
    final versionRegex = RegExp(r'version:\s*([^\n]+)');
    final match = versionRegex.firstMatch(content);
    return match?.group(1)?.trim();
  }

  /// Compare versions (simple string comparison for semantic versioning)
  static bool isNewerVersion(String newVersion, String oldVersion) {
    try {
      final newParts = newVersion
          .split('+')[0]
          .split('.')
          .map(int.parse)
          .toList();
      final oldParts = oldVersion
          .split('+')[0]
          .split('.')
          .map(int.parse)
          .toList();

      // Pad shorter version with zeros
      while (newParts.length < 3) {
        newParts.add(0);
      }
      while (oldParts.length < 3) {
        oldParts.add(0);
      }

      for (int i = 0; i < 3; i++) {
        if (newParts[i] > oldParts[i]) return true;
        if (newParts[i] < oldParts[i]) return false;
      }

      return false; // Versions are equal
    } catch (e) {
      LoggerService.error('Error comparing versions: $e');
      return false;
    }
  }

  /// Install or update User Manual
  static Future<void> installUserManual() async {
    final databaseService = getIt<DatabaseService>();

    // Parse YAML for version and update date
    final yamlData = await parseUserManualYaml();
    final version = yamlData['version']!;
    final updateDate = yamlData['updateDate']!;

    // Copy PDF to attachments directory
    final attachmentPath = await _copyPdfToAttachments();

    final now = DateTime.now();

    // Create note content
    final content =
        '''version: $version
last updated: $updateDate

Please refer to the attached PDF for detailed user manual.''';

    final note = Note(
      id: userManualUuid,
      title: 'User Manual',
      content: content,
      type: NoteType.note,
      createdAt: now,
      updatedAt: now,
      pinned: false,
      isArchived: false,
      tags: ['User Manual', 'Documentation'],
      attachmentPaths: [attachmentPath],
      subNotes: [],
    );

    // Check if note already exists
    final existingNote = await getUserManualNote();

    if (existingNote != null) {
      // Update existing note
      await databaseService.updateNote(note);
      LoggerService.info('Updated User Manual to version $version');
    } else {
      // Insert new note
      await databaseService.insertNote(note);
      LoggerService.info('Installed User Manual version $version');
    }
    _publishNotesChanged({note.id}, tagsChanged: true);
  }

  /// This service writes through DatabaseService directly, so it publishes
  /// its own change events to keep already-loaded UI caches fresh.
  static void _publishNotesChanged(
    Set<String> noteIds, {
    bool tagsChanged = false,
  }) {
    if (noteIds.isEmpty || !getIt.isRegistered<DataChangeNotifier>()) return;
    getIt<DataChangeNotifier>().publish(
      DataChangeEvent(noteIds: noteIds, tagsChanged: tagsChanged),
    );
  }

  /// Copy PDF from assets to attachments directory
  static Future<String> _copyPdfToAttachments() async {
    try {
      // Load PDF from assets
      final byteData = await rootBundle.load(userManualPdfPath);

      // Get attachments directory
      final appDir = await getApplicationDocumentsDirectory();
      final attachmentsDir = Directory('${appDir.path}/attachments');

      if (!await attachmentsDir.exists()) {
        await attachmentsDir.create(recursive: true);
      }

      // Create unique filename
      final fileName =
          'USER_MANUAL_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final filePath = '${attachmentsDir.path}/$fileName';

      // Write PDF to file
      final file = File(filePath);
      await file.writeAsBytes(byteData.buffer.asUint8List());

      // Return relative path for database
      return 'attachments/$fileName';
    } catch (e) {
      LoggerService.error('Error copying PDF to attachments: $e');
      rethrow;
    }
  }

  /// Get list of starter apps from assets
  static Future<List<Map<String, dynamic>>> getStarterApps() async {
    try {
      final starterApps = <Map<String, dynamic>>[];

      for (final assetKey in await _listBundledAssets()) {
        if (assetKey.startsWith(starterAppsPath) &&
            assetKey.endsWith('.yaml')) {
          try {
            final yamlString = await rootBundle.loadString(assetKey);
            final yamlData = loadYaml(yamlString);

            final name = yamlData['name']?.toString() ?? 'Unknown';
            final uuid = yamlData['uuid']?.toString() ?? '';
            final appTypeStr = yamlData['app_type']?.toString() ?? 'normal';
            final description = yamlData['description']?.toString() ?? '';

            // Check if app is already installed
            final databaseService = getIt<DatabaseService>();
            final existingApps = await databaseService.getAllUserApps();
            final isInstalled = existingApps.any((app) => app.uuid == uuid);

            starterApps.add({
              'name': name,
              'uuid': uuid,
              'appType': appTypeStr,
              'description': description,
              'isInstalled': isInstalled,
              'filePath': assetKey,
            });
          } catch (e) {
            LoggerService.error('Error parsing starter app $assetKey: $e');
          }
        }
      }

      return starterApps;
    } catch (e) {
      LoggerService.error('Error getting starter apps: $e');
      rethrow;
    }
  }

  /// Get app type explanation
  static String getAppTypeExplanation(String appType) {
    switch (appType.toLowerCase()) {
      case 'normal':
        return 'A standalone web application';
      case 'note_action':
        return 'Operates on pre-selected notes';
      case 'ai_tool':
        return 'Exposes custom functions for AI to call';
      default:
        return 'Unknown type';
    }
  }

  /// Get bundled starter skill notes from assets.
  static Future<List<Map<String, dynamic>>> getStarterSkills() async {
    try {
      final skillService = SkillService(getIt<DatabaseService>());
      final skills = <Map<String, dynamic>>[];
      final existing = await getIt<DatabaseService>().getNotesByTag(
        SkillService.agentSkillTag,
      );
      for (final assetKey in await _listBundledAssets()) {
        if (!assetKey.startsWith(starterSkillsPath) ||
            !assetKey.endsWith('.md')) {
          continue;
        }
        final content = await rootBundle.loadString(assetKey);
        final meta = skillService.parseSkillMetadata(assetKey, content);
        if (meta == null) continue;
        final installed = existing.any((note) {
          final existingMeta = skillService.parseSkillMetadata(
            note.id,
            note.content,
          );
          return existingMeta?.skillRef == meta.skillRef;
        });
        skills.add({
          'name': meta.name,
          'skillRef': meta.skillRef,
          'description': meta.description,
          'isInstalled': installed,
          'filePath': assetKey,
        });
      }
      return skills;
    } catch (e) {
      LoggerService.error('Error getting starter skills: $e');
      rethrow;
    }
  }

  static Future<List<String>> _listBundledAssets() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    return manifest.listAssets();
  }

  /// Installs bundled starter skills as ordinary notes tagged `agent-skill`.
  static Future<int> installStarterSkills({Set<String>? skillRefs}) async {
    final databaseService = getIt<DatabaseService>();
    final skillService = SkillService(databaseService);
    final existing = await databaseService.getNotesByTag(
      SkillService.agentSkillTag,
    );
    final existingRefs = existing
        .map((note) => skillService.parseSkillMetadata(note.id, note.content))
        .whereType<SkillMetadata>()
        .map((meta) => meta.skillRef)
        .toSet();
    var installed = 0;
    final installedIds = <String>{};
    for (final skill in await getStarterSkills()) {
      final skillRef = skill['skillRef'] as String;
      if (skillRefs != null && !skillRefs.contains(skillRef)) continue;
      if (existingRefs.contains(skillRef)) continue;
      final assetKey = skill['filePath'] as String;
      final content = await rootBundle.loadString(assetKey);
      final now = DateTime.now();
      await databaseService.insertNote(
        Note(
          id: 'starter-skill-$skillRef',
          title: skill['name'] as String,
          content: content,
          type: NoteType.note,
          createdAt: now,
          updatedAt: now,
          pinned: false,
          isArchived: false,
          tags: const [SkillService.agentSkillTag, 'starter-skill'],
          attachmentPaths: const [],
          subNotes: const [],
        ),
      );
      existingRefs.add(skillRef);
      installed++;
      installedIds.add('starter-skill-$skillRef');
    }
    _publishNotesChanged(installedIds, tagsChanged: installedIds.isNotEmpty);
    return installed;
  }
}
