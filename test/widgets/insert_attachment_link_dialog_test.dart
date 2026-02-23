import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/widgets/insert_attachment_link_dialog.dart';
import 'package:note_synapse/screens/note_selection_dialog.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/services/tag_image_service.dart';
import 'package:note_synapse/widgets/note_card.dart';

@GenerateMocks([DatabaseService, AppProvider])
import 'insert_attachment_link_dialog_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;
  late MockAppProvider mockProvider;

  final testNotes = [
    Note(
      id: 'note-1',
      title: 'Research Notes',
      content: 'Some research content',
      type: NoteType.note,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    ),
  ];

  final imageAttachment = Attachment(
    id: 'att-img',
    noteId: 'note-1',
    filePath: 'path/to/photo.png',
    fileName: 'photo.png',
    fileType: 'image/png',
    createdAt: DateTime(2026, 1, 2),
  );

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    mockProvider = MockAppProvider();
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<TagImageService>(TagImageService(mockDb));

    when(mockProvider.notes).thenReturn(testNotes);
    when(mockProvider.addListener(any)).thenReturn(null);
    when(mockProvider.removeListener(any)).thenReturn(null);
    when(mockProvider.hasListeners).thenReturn(false);
  });

  tearDown(() async {
    await resetForTesting();
  });

  Widget buildTestApp({ValueChanged<String?>? onResult}) {
    return ChangeNotifierProvider<AppProvider>.value(
      value: mockProvider,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  final result = await showDialog<String>(
                    context: context,
                    builder: (context) =>
                        ChangeNotifierProvider<AppProvider>.value(
                      value: mockProvider,
                      child: const InsertAttachmentLinkDialog(),
                    ),
                  );
                  onResult?.call(result);
                },
                child: const Text('Open Dialog'),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();
  }

  /// Select the only note in NoteSelectionDialog by tapping its InkWell
  /// then the Proceed button. Uses explicit pump() calls to avoid
  /// pumpAndSettle timeouts from CircularProgressIndicator animations.
  Future<void> selectNoteInDialog(WidgetTester tester) async {
    final inkWells = find.descendant(
      of: find.byType(NoteCard),
      matching: find.byType(InkWell),
    );
    expect(inkWells, findsWidgets);
    await tester.ensureVisible(inkWells.first);
    await tester.tap(inkWells.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Tap Proceed button
    final proceedButton = find.textContaining('Proceed');
    expect(proceedButton, findsOneWidget);
    await tester.tap(proceedButton);
    // Pump through the dialog transition and async data loading
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('launches NoteSelectionDialog on open',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildTestApp());
    await openDialog(tester);

    expect(find.byType(NoteSelectionDialog), findsOneWidget);
    expect(find.text('Select Note'), findsOneWidget);
    expect(find.byType(NoteCard), findsOneWidget);
  });

  testWidgets('after selecting a note in sub-dialog, shows attachment step',
      (WidgetTester tester) async {
    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => [imageAttachment]);

    await tester.pumpWidget(buildTestApp());
    await openDialog(tester);

    await selectNoteInDialog(tester);

    // Should now show attachment step
    expect(find.text('Select Attachment'), findsOneWidget);
    expect(find.text('photo.png'), findsOneWidget);
  });

  testWidgets('cancelling NoteSelectionDialog closes main dialog',
      (WidgetTester tester) async {
    String? dialogResult = 'not-null';

    await tester.pumpWidget(buildTestApp(
      onResult: (result) => dialogResult = result,
    ));
    await openDialog(tester);

    expect(find.byType(NoteSelectionDialog), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    expect(dialogResult, isNull);
  });

  testWidgets(
      'after selecting an image attachment, shows confirm step',
      (WidgetTester tester) async {
    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => [imageAttachment]);

    await tester.pumpWidget(buildTestApp());
    await openDialog(tester);

    await selectNoteInDialog(tester);

    await tester.tap(find.text('photo.png'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm Link'), findsOneWidget);
    expect(find.text('Insert'), findsOneWidget);
    expect(find.textContaining('synapseresource://attachment/att-img'),
        findsOneWidget);
  });

  testWidgets('inserting link returns markdown string',
      (WidgetTester tester) async {
    String? dialogResult;

    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => [imageAttachment]);

    await tester.pumpWidget(buildTestApp(
      onResult: (result) => dialogResult = result,
    ));
    await openDialog(tester);

    await selectNoteInDialog(tester);

    await tester.tap(find.text('photo.png'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Insert'));
    await tester.pumpAndSettle();

    expect(dialogResult, isNotNull);
    expect(dialogResult, contains('synapseresource://attachment/att-img'));
    expect(dialogResult, contains('photo.png'));
  });

  testWidgets('back button from attachment step re-shows NoteSelectionDialog',
      (WidgetTester tester) async {
    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => [imageAttachment]);

    await tester.pumpWidget(buildTestApp());
    await openDialog(tester);

    await selectNoteInDialog(tester);

    expect(find.text('Select Attachment'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.byType(NoteSelectionDialog), findsOneWidget);
  });

  testWidgets('close button at attachment step returns null',
      (WidgetTester tester) async {
    String? dialogResult = 'not-null';

    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => [imageAttachment]);

    await tester.pumpWidget(buildTestApp(
      onResult: (result) => dialogResult = result,
    ));
    await openDialog(tester);

    await selectNoteInDialog(tester);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(dialogResult, isNull);
  });
}
