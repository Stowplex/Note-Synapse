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
    Note(
      id: 'note-2',
      title: 'Meeting Minutes',
      content: 'Meeting discussion',
      type: NoteType.note,
      createdAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
    ),
  ];

  final pdfAttachment = Attachment(
    id: 'att-pdf',
    noteId: 'note-1',
    filePath: 'path/to/report.pdf',
    fileName: 'report.pdf',
    fileType: 'application/pdf',
    createdAt: DateTime(2026, 1, 1),
  );

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

    when(mockProvider.notes).thenReturn(testNotes);
    // AppProvider is a ChangeNotifier; mock addListener/removeListener
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

  testWidgets('shows note selection step initially with search and note list',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildTestApp());
    await openDialog(tester);

    // Should show step title
    expect(find.text('Select Note'), findsOneWidget);
    // Should show search field
    expect(find.byIcon(Icons.search), findsOneWidget);
    // Should show note titles
    expect(find.text('Research Notes'), findsOneWidget);
    expect(find.text('Meeting Minutes'), findsOneWidget);
  });

  testWidgets('after selecting a note, shows attachment selection step',
      (WidgetTester tester) async {
    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => [pdfAttachment, imageAttachment]);

    await tester.pumpWidget(buildTestApp());
    await openDialog(tester);

    // Tap on a note
    await tester.tap(find.text('Research Notes'));
    await tester.pumpAndSettle();

    // Should show attachment step title
    expect(find.text('Select Attachment'), findsOneWidget);
    // Should show attachments from the AttachmentPickerWidget
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('photo.png'), findsOneWidget);
  });

  testWidgets('after selecting a PDF attachment, shows location picker step',
      (WidgetTester tester) async {
    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => [pdfAttachment]);

    await tester.pumpWidget(buildTestApp());
    await openDialog(tester);

    // Select note
    await tester.tap(find.text('Research Notes'));
    await tester.pumpAndSettle();

    // Select PDF attachment
    await tester.tap(find.text('report.pdf'));
    await tester.pumpAndSettle();

    // Should show location step
    expect(find.text('Select Location'), findsOneWidget);
    // PdfLocationPicker shows "Go to page" and "No specific page"
    expect(find.text('Go to page'), findsOneWidget);
    expect(find.text('No specific page'), findsOneWidget);
  });

  testWidgets(
      'after selecting an image attachment, skips to confirm step',
      (WidgetTester tester) async {
    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => [imageAttachment]);

    await tester.pumpWidget(buildTestApp());
    await openDialog(tester);

    // Select note
    await tester.tap(find.text('Research Notes'));
    await tester.pumpAndSettle();

    // Select image attachment
    await tester.tap(find.text('photo.png'));
    await tester.pumpAndSettle();

    // Should skip to confirm step (no location step for images)
    expect(find.text('Confirm Link'), findsOneWidget);
    // Should show the default link text pre-filled
    expect(find.text('photo.png'), findsOneWidget);
    expect(find.text('Insert'), findsOneWidget);
  });

  testWidgets('confirm step shows editable link text and insert button',
      (WidgetTester tester) async {
    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => [imageAttachment]);

    await tester.pumpWidget(buildTestApp());
    await openDialog(tester);

    // Navigate to confirm step
    await tester.tap(find.text('Research Notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('photo.png'));
    await tester.pumpAndSettle();

    // Should show editable link text field
    expect(find.text('Link Text'), findsOneWidget);
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Insert'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    // The preview should contain the markdown link
    expect(
      find.textContaining('synapseresource://attachment/att-img'),
      findsOneWidget,
    );
  });

  testWidgets('cancel at any step returns null', (WidgetTester tester) async {
    String? dialogResult = 'not-null';

    await tester.pumpWidget(buildTestApp(
      onResult: (result) => dialogResult = result,
    ));
    await openDialog(tester);

    // Close button should be visible
    expect(find.byIcon(Icons.close), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(dialogResult, isNull);
  });

  testWidgets('back button returns to previous step',
      (WidgetTester tester) async {
    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => [pdfAttachment, imageAttachment]);

    await tester.pumpWidget(buildTestApp());
    await openDialog(tester);

    // Go to attachment step
    await tester.tap(find.text('Research Notes'));
    await tester.pumpAndSettle();
    expect(find.text('Select Attachment'), findsOneWidget);

    // Back button should be visible
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    // Should be back at note selection
    expect(find.text('Select Note'), findsOneWidget);
    expect(find.text('Research Notes'), findsOneWidget);
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

    // Navigate to confirm
    await tester.tap(find.text('Research Notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('photo.png'));
    await tester.pumpAndSettle();

    // Tap Insert
    await tester.tap(find.text('Insert'));
    await tester.pumpAndSettle();

    expect(dialogResult, isNotNull);
    expect(dialogResult, contains('synapseresource://attachment/att-img'));
    expect(dialogResult, contains('photo.png'));
  });

  testWidgets('search filters notes', (WidgetTester tester) async {
    await tester.pumpWidget(buildTestApp());
    await openDialog(tester);

    // Both notes visible initially
    expect(find.text('Research Notes'), findsOneWidget);
    expect(find.text('Meeting Minutes'), findsOneWidget);

    // Type in search field
    await tester.enterText(find.byType(TextField), 'Research');
    await tester.pumpAndSettle();

    // Only matching note visible
    expect(find.text('Research Notes'), findsOneWidget);
    expect(find.text('Meeting Minutes'), findsNothing);
  });

  testWidgets('PDF location step with "No specific page" goes to confirm',
      (WidgetTester tester) async {
    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => [pdfAttachment]);

    await tester.pumpWidget(buildTestApp());
    await openDialog(tester);

    // Select note
    await tester.tap(find.text('Research Notes'));
    await tester.pumpAndSettle();

    // Select PDF
    await tester.tap(find.text('report.pdf'));
    await tester.pumpAndSettle();

    // Tap "No specific page"
    await tester.tap(find.text('No specific page'));
    await tester.pumpAndSettle();

    // Should be at confirm step
    expect(find.text('Confirm Link'), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
  });
}
