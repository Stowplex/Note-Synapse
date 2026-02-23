import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/widgets/pdf_location_picker.dart';

@GenerateMocks([DatabaseService])
import 'pdf_location_picker_test.mocks.dart';

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

  group('PdfLocationSelection model', () {
    test('holds page and displayText', () {
      const sel = PdfLocationSelection(page: 5, displayText: 'Chapter 1');
      expect(sel.page, 5);
      expect(sel.displayText, 'Chapter 1');
    });

    test('displayText is optional', () {
      const sel = PdfLocationSelection(page: 3);
      expect(sel.page, 3);
      expect(sel.displayText, isNull);
    });
  });

  group('PdfLocationPicker', () {
    Widget buildPicker({
      int? totalPages,
      List<PdfBookmark> bookmarks = const [],
      List<PdfOutlineNode>? outline,
      String? pdfPath,
      String attachmentId = 'att-1',
      String fileName = 'test.pdf',
      Function(String)? onInsert,
      VoidCallback? onCancel,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: PdfLocationPicker(
            totalPages: totalPages,
            bookmarks: bookmarks,
            outline: outline,
            pdfPath: pdfPath,
            attachmentId: attachmentId,
            fileName: fileName,
            onInsert: onInsert,
            onCancel: onCancel,
          ),
        ),
      );
    }

    testWidgets('shows prev/next buttons and page input', (tester) async {
      await tester.pumpWidget(buildPicker(totalPages: 10));

      expect(find.byIcon(Icons.chevron_left), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      // Page input field with "1" as initial value
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('prev button is disabled on page 1', (tester) async {
      await tester.pumpWidget(buildPicker(totalPages: 10));

      final prevButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_left),
      );
      expect(prevButton.onPressed, isNull);
    });

    testWidgets('next button navigates to next page', (tester) async {
      await tester.pumpWidget(buildPicker(totalPages: 10));

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pump();

      // Page input should now show "2"
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('next button is disabled on last page', (tester) async {
      await tester.pumpWidget(buildPicker(totalPages: 1));

      final nextButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_right),
      );
      expect(nextButton.onPressed, isNull);
    });

    testWidgets('page input navigates to entered page', (tester) async {
      await tester.pumpWidget(buildPicker(totalPages: 50));

      // Clear and enter a page number
      final textField = find.byType(TextField).first;
      await tester.enterText(textField, '25');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('25'), findsOneWidget);
    });

    testWidgets('shows ToC dropdown when outline provided', (tester) async {
      final outline = [
        PdfOutlineNode(title: 'Introduction', page: 1),
        PdfOutlineNode(title: 'Methods', page: 20),
      ];

      await tester.pumpWidget(buildPicker(totalPages: 50, outline: outline));

      expect(find.text('ToC'), findsOneWidget);
    });

    testWidgets('ToC dropdown not shown when no outline', (tester) async {
      await tester.pumpWidget(buildPicker(totalPages: 50));

      expect(find.text('ToC'), findsNothing);
    });

    testWidgets('shows Bookmarks dropdown when bookmarks exist', (
      tester,
    ) async {
      final bookmarks = [
        PdfBookmark(
          title: 'Important',
          pageNumber: 10,
          createdAt: DateTime(2026, 1, 1),
        ),
      ];

      await tester.pumpWidget(
        buildPicker(totalPages: 50, bookmarks: bookmarks),
      );

      expect(find.text('Bookmarks'), findsOneWidget);
    });

    testWidgets('Bookmarks dropdown not shown when empty', (tester) async {
      await tester.pumpWidget(buildPicker(totalPages: 50));

      expect(find.text('Bookmarks'), findsNothing);
    });

    testWidgets('bookmark annotation shows in dropdown subtitle', (
      tester,
    ) async {
      final bookmarks = [
        PdfBookmark(
          title: 'Chapter 3',
          pageNumber: 41,
          createdAt: DateTime(2026, 1, 1),
          annotation: 'This section covers the basics of neural networks',
        ),
      ];

      await tester.pumpWidget(
        buildPicker(totalPages: 100, bookmarks: bookmarks),
      );

      // Open the bookmarks dropdown
      await tester.tap(find.text('Bookmarks'));
      await tester.pumpAndSettle();

      // Should show bookmark title and annotation in subtitle
      expect(find.text('Chapter 3'), findsOneWidget);
      expect(
        find.textContaining(
          'This section covers the basics of neural networks',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Page 42'), findsOneWidget);
    });

    testWidgets('bookmark without annotation shows only page in subtitle', (
      tester,
    ) async {
      final bookmarks = [
        PdfBookmark(
          title: 'Page 5',
          pageNumber: 4,
          createdAt: DateTime(2026, 1, 1),
        ),
      ];

      await tester.pumpWidget(
        buildPicker(totalPages: 100, bookmarks: bookmarks),
      );

      // Open the bookmarks dropdown
      await tester.tap(find.text('Bookmarks'));
      await tester.pumpAndSettle();

      expect(find.text('Page 5'), findsWidgets);
    });

    testWidgets('shows link text field and insert/cancel buttons', (
      tester,
    ) async {
      await tester.pumpWidget(buildPicker(totalPages: 10));

      expect(find.text('Link text'), findsOneWidget);
      expect(find.text('Insert Link'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('cancel button calls onCancel', (tester) async {
      bool cancelled = false;

      await tester.pumpWidget(
        buildPicker(totalPages: 10, onCancel: () => cancelled = true),
      );

      await tester.tap(find.text('Cancel'));
      await tester.pump();

      expect(cancelled, isTrue);
    });

    testWidgets('insert button calls onInsert with markdown link', (
      tester,
    ) async {
      String? result;

      await tester.pumpWidget(
        buildPicker(
          totalPages: 10,
          attachmentId: 'att-42',
          fileName: 'report.pdf',
          onInsert: (link) => result = link,
        ),
      );

      // The link text should be pre-filled; tap Insert
      await tester.tap(find.text('Insert Link'));
      await tester.pump();

      expect(result, isNotNull);
      expect(result, contains('synapseresource://attachment/att-42'));
      expect(result, contains('page=1'));
    });

    testWidgets('shows PDF icon when no pdfPath provided (no preview)', (
      tester,
    ) async {
      await tester.pumpWidget(buildPicker(totalPages: 10));

      expect(find.byIcon(Icons.picture_as_pdf), findsOneWidget);
      expect(find.text('Page 1'), findsOneWidget);
    });

    testWidgets('selecting ToC item navigates to that page', (tester) async {
      final outline = [PdfOutlineNode(title: 'Results', page: 29)];

      await tester.pumpWidget(buildPicker(totalPages: 50, outline: outline));

      // Open ToC dropdown
      await tester.tap(find.text('ToC'));
      await tester.pumpAndSettle();

      // Select the item
      await tester.tap(find.text('Results · p.30'));
      await tester.pumpAndSettle();

      // Page should now be 30
      expect(find.text('30'), findsOneWidget);
    });
  });
}
