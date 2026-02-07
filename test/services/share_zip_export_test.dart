import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/l10n/app_localizations_en.dart';
import 'package:note_synapse/services/share_service.dart';
import 'package:note_synapse/models/note.dart';
import 'package:archive/archive_io.dart';

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

  setUp(() async {
    mockAppProvider = MockAppProvider();
    l10n = AppLocalizationsEn();
    tempDir = await Directory.systemTemp.createTemp();
    PathProviderPlatform.instance = MockPathProviderPlatform(tempDir.path);
    log.clear();

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
            // Return a dummy path, though we care about the intermediate file in tempDir
            return '${tempDir.path}/mock_saved_file.zip';
          }
          return null;
        });

    // Mock ShareService.filePickerSaveOverride to intercept save call if needed
    ShareService.filePickerSaveOverride =
        ({allowedExtensions, dialogTitle, fileName}) async {
          log.add(MethodCall('saveFile', {'fileName': fileName}));
          return '${tempDir.path}/$fileName';
        };
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (e) {
      // ignore
    }
    ShareService.filePickerSaveOverride = null;
  });

  test('shareAsMarkdownZip exports scheduled and due times for tasks', () async {
    // 1. Setup Note with scheduledAt and completeBy
    final task = Note(
      id: 'task-1',
      title: 'Important Task',
      content: 'Do this task',
      type: NoteType.task,
      status: TaskStatus.todo,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      scheduledAt: '2026-03-01T10:00:00.000',
      completeBy: '2026-03-05T17:00:00.000',
    );

    // 2. Call shareAsMarkdownZip
    await ShareService.shareAsMarkdownZip(
      notes: [task],
      includeSubNotesAndLinkedNotes: false,
      appProvider: mockAppProvider,
      l10n: l10n,
    );

    // 3. Find the exported ZIP file in tempDir
    // The service creates a zip file with name format: notes_export_yyyyMMdd_HHmm.zip
    final zipEntity = tempDir.listSync().firstWhere(
      (e) => e.path.endsWith('.zip'),
      orElse: () => throw Exception('ZIP file not found in ${tempDir.path}'),
    );
    final zipFile = File(zipEntity.path);

    // 4. Unzip and verify content
    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final noteFile = archive.findFile('task-1__Important Task.md');
    expect(noteFile, isNotNull, reason: 'Note markdown file not found in ZIP');

    final content = String.fromCharCodes(noteFile!.content as List<int>);

    // 5. Assert missing fields
    // We expect these to BE present after the fix.
    // We also expect them to be in ISO format as per user request.
    expect(
      content,
      contains('**Scheduled:**'),
      reason: 'Missing Scheduled field',
    );
    expect(
      content,
      contains('2026-03-01T10:00:00.000'),
      reason: 'Scheduled date should be ISO',
    );
    expect(content, contains('**Due:**'), reason: 'Missing Due field');
    expect(
      content,
      contains('2026-03-05T17:00:00.000'),
      reason: 'Due date should be ISO',
    );
  });
}
