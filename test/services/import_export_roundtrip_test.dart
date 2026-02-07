import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/l10n/app_localizations_en.dart';
import 'package:note_synapse/services/share_service.dart';
import 'package:note_synapse/services/import_service.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/logger_service.dart';

// Reuse existing mocks
import 'share_service_test.mocks.dart';

class MockPathProviderPlatform extends PathProviderPlatform {
  final String tempPath;

  MockPathProviderPlatform(this.tempPath);

  @override
  Future<String?> getTemporaryPath() async {
    return tempPath;
  }

  @override
  Future<String?> getApplicationDocumentsPath() async {
    return tempPath;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockAppProvider mockAppProvider;
  late AppLocalizationsEn l10n;
  late Directory tempDir;
  final List<MethodCall> log = <MethodCall>[];
  late List<Note> importedNotes;

  setUp(() async {
    mockAppProvider = MockAppProvider();
    l10n = AppLocalizationsEn();
    tempDir = await Directory.systemTemp.createTemp();
    PathProviderPlatform.instance = MockPathProviderPlatform(tempDir.path);
    log.clear();
    importedNotes = [];

    // Mock AppProvider to capture added/updated notes
    when(mockAppProvider.addNote(any)).thenAnswer((invocation) async {
      final note = invocation.positionalArguments[0] as Note;
      importedNotes.add(note);
    });
    when(mockAppProvider.updateNote(any)).thenAnswer((invocation) async {
      final note = invocation.positionalArguments[0] as Note;
      // Find and replace in importedNotes if exists
      final index = importedNotes.indexWhere((n) => n.id == note.id);
      if (index != -1) {
        importedNotes[index] = note;
      } else {
        importedNotes.add(note);
      }
    });
    // Stub these for ShareService to work
    when(mockAppProvider.getNoteRelationships(any)).thenAnswer((_) async => []);
    when(mockAppProvider.getLinkedNotes(any)).thenAnswer((_) async => []);
    when(mockAppProvider.notes).thenReturn([]);

    // Mock FilePicker channel
    const MethodChannel filePickerChannel = MethodChannel(
      'miguelruivo.flutter.plugins.filepicker',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(filePickerChannel, (
          MethodCall methodCall,
        ) async {
          log.add(methodCall);
          if (methodCall.method == 'save') {
            return '${tempDir.path}/mock_saved_file.zip';
          }
          return null;
        });

    // Mock ShareService.filePickerSaveOverride
    ShareService.filePickerSaveOverride =
        ({allowedExtensions, dialogTitle, fileName}) async {
          log.add(MethodCall('saveFile', {'fileName': fileName}));
          return '${tempDir.path}/$fileName';
        };

    // Initialize LoggerService to avoid null errors if used
    // LoggerService.init(); // Assuming static init or no-op if using standard print
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (e) {
      // ignore
    }
    ShareService.filePickerSaveOverride = null;
  });

  test(
    'Roundtrip: Export task -> Import task preserves Scheduled/Due and Dates',
    () async {
      final originalCreatedAt = DateTime(2025, 1, 1, 10, 0, 0); // Specific time
      final originalUpdatedAt = DateTime(2025, 1, 5, 15, 30, 0);
      final scheduledAt = '2026-03-01T10:00:00.000';
      final completeBy = '2026-03-05T17:00:00.000';

      final task = Note(
        id: 'task-roundtrip',
        title: 'Roundtrip Task',
        content: 'This task should survive roundtrip',
        type: NoteType.task,
        status: TaskStatus.inProgress,
        createdAt: originalCreatedAt,
        updatedAt: originalUpdatedAt,
        scheduledAt: scheduledAt,
        completeBy: completeBy,
      );

      // 1. Export to ZIP
      await ShareService.shareAsMarkdownZip(
        notes: [task],
        includeSubNotesAndLinkedNotes: false,
        appProvider: mockAppProvider,
        l10n: l10n,
      );

      // Find the exported ZIP
      final zipEntity = tempDir.listSync().firstWhere(
        (e) => e.path.endsWith('.zip'),
        orElse: () => throw Exception('ZIP file not found'),
      );
      final zipFile = File(zipEntity.path);

      // 2. Import from ZIP
      final importStats = await ImportService().importFromMarkdownZip(
        zipFile,
        mockAppProvider,
      );

      // 3. Verify Import Results
      expect(importStats.imported, 1, reason: 'Should have imported 1 note');
      expect(
        importedNotes.length,
        1,
        reason: 'Mock provider should capture 1 note',
      );

      final importedTask = importedNotes.first;

      // Verify Fields
      // Verify Fields
      // The ImportService preserves the ID if provided in markdown and not generating new one
      // (which is default behavior when not forcing new ID)
      // Actually ImportService logic:
      // ...
      //   if (existingNoteId != null) { ... }
      //   else { ... generateNewId: true ... }
      // Wait, let's check parse logic. Does it parse ID?
      // Yes: if (line.startsWith('**ID:**')) id = ...
      // So if ID is present, it attempts to update or create with that ID.
      // BUT we mocked `mockAppProvider.notes` to return empty list.
      // So `existingNote` will be null.
      // So it should call `_createNote` with the PARSED ID.
      // "LoggerService.info('Importing new note ${noteData.title} ($existingNoteId)'); await _createNote(noteData, attachmentDir, appProvider);"
      // _createNote: "final noteId = generateNewId ? const Uuid().v4() : data.id!;"
      // So it SHOULD preserve the ID if we provided it in markdown.

      // Let's verify ID
      expect(
        importedTask.id,
        'task-roundtrip',
        reason: 'Should preserve ID from markdown',
      );
      expect(importedTask.title, 'Roundtrip Task');
      expect(importedTask.status, TaskStatus.inProgress);

      // Verify Dates (ISO parsing vs Old format)
      // Note: DateTime equality might need tolerance if milliseconds are lost, but ISO string should keep them.
      // However, ShareService toIso8601String() keeps them.
      expect(
        importedTask.createdAt,
        originalCreatedAt,
        reason: 'CreatedAt mismatch',
      );
      expect(
        importedTask.updatedAt,
        originalUpdatedAt,
        reason: 'UpdatedAt mismatch',
      );

      // Verify New Fields
      expect(
        importedTask.scheduledAt,
        scheduledAt,
        reason: 'ScheduledAt mismatch',
      );
      expect(
        importedTask.completeBy,
        completeBy,
        reason: 'CompleteBy mismatch',
      );
    },
  );
}
