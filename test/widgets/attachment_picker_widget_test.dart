import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/widgets/attachment_picker_widget.dart';

@GenerateMocks([DatabaseService])
import 'attachment_picker_widget_test.mocks.dart';

void main() {
  late MockDatabaseService mockDb;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
  });

  tearDown(() async {
    await resetForTesting();
  });

  Widget buildWidget({
    String noteId = 'note-1',
    Function(Attachment)? onSelected,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: AttachmentPickerWidget(
          noteId: noteId,
          onSelected: onSelected ?? (_) {},
        ),
      ),
    );
  }

  testWidgets('shows attachment filenames for a given noteId',
      (WidgetTester tester) async {
    final attachments = [
      Attachment(
        id: 'att-1',
        noteId: 'note-1',
        filePath: 'path/to/report.pdf',
        fileName: 'report.pdf',
        fileType: 'application/pdf',
        createdAt: DateTime(2026, 1, 1),
      ),
      Attachment(
        id: 'att-2',
        noteId: 'note-1',
        filePath: 'path/to/photo.png',
        fileName: 'photo.png',
        fileType: 'image/png',
        createdAt: DateTime(2026, 1, 2),
      ),
    ];

    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => attachments);

    await tester.pumpWidget(buildWidget());
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('photo.png'), findsOneWidget);
    verify(mockDb.getAttachmentsForNote('note-1')).called(1);
  });

  testWidgets('shows correct file type icons', (WidgetTester tester) async {
    final attachments = [
      Attachment(
        id: 'att-1',
        noteId: 'note-1',
        filePath: 'path/to/report.pdf',
        fileName: 'report.pdf',
        fileType: 'application/pdf',
        createdAt: DateTime(2026, 1, 1),
      ),
      Attachment(
        id: 'att-2',
        noteId: 'note-1',
        filePath: 'path/to/photo.png',
        fileName: 'photo.png',
        fileType: 'image/png',
        createdAt: DateTime(2026, 1, 2),
      ),
      Attachment(
        id: 'att-3',
        noteId: 'note-1',
        filePath: 'path/to/data.csv',
        fileName: 'data.csv',
        fileType: 'text/csv',
        createdAt: DateTime(2026, 1, 3),
      ),
    ];

    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => attachments);

    await tester.pumpWidget(buildWidget());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.picture_as_pdf), findsOneWidget);
    expect(find.byIcon(Icons.image), findsOneWidget);
    expect(find.byIcon(Icons.insert_drive_file), findsOneWidget);
  });

  testWidgets('tapping an attachment calls onSelected callback',
      (WidgetTester tester) async {
    Attachment? selectedAttachment;
    final attachment = Attachment(
      id: 'att-1',
      noteId: 'note-1',
      filePath: 'path/to/report.pdf',
      fileName: 'report.pdf',
      fileType: 'application/pdf',
      createdAt: DateTime(2026, 1, 1),
    );

    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => [attachment]);

    await tester.pumpWidget(buildWidget(
      onSelected: (att) => selectedAttachment = att,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('report.pdf'));
    await tester.pumpAndSettle();

    expect(selectedAttachment, isNotNull);
    expect(selectedAttachment!.id, 'att-1');
    expect(selectedAttachment!.fileName, 'report.pdf');
  });

  testWidgets('shows "No attachments" when list is empty',
      (WidgetTester tester) async {
    when(mockDb.getAttachmentsForNote('note-1'))
        .thenAnswer((_) async => []);

    await tester.pumpWidget(buildWidget());
    await tester.pumpAndSettle();

    expect(find.text('No attachments'), findsOneWidget);
  });
}
