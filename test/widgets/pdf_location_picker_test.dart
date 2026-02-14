import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/pdf_location_picker.dart';
import 'package:note_synapse/models/attachment.dart';

void main() {
  group('PdfLocationPicker', () {
    test('PdfLocationSelection holds page and displayText', () {
      const sel = PdfLocationSelection(page: 5, displayText: 'Chapter 1');
      expect(sel.page, 5);
      expect(sel.displayText, 'Chapter 1');
    });

    test('PdfLocationSelection displayText is optional', () {
      const sel = PdfLocationSelection(page: 3);
      expect(sel.page, 3);
      expect(sel.displayText, isNull);
    });

    testWidgets('shows page number input field', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfLocationPicker(
              totalPages: 100,
              onSelected: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Go to page'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Go'), findsOneWidget);
    });

    testWidgets('page input validates range - 0 shows error', (tester) async {
      PdfLocationSelection? captured;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfLocationPicker(
              totalPages: 100,
              onSelected: (selection) {
                captured = selection;
              },
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '0');
      await tester.tap(find.text('Go'));
      await tester.pump();

      expect(find.text('Page must be between 1 and 100'), findsOneWidget);
      expect(captured, isNull);
    });

    testWidgets('page input validates range - exceeding totalPages shows error',
        (tester) async {
      PdfLocationSelection? captured;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfLocationPicker(
              totalPages: 50,
              onSelected: (selection) {
                captured = selection;
              },
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '51');
      await tester.tap(find.text('Go'));
      await tester.pump();

      expect(find.text('Page must be between 1 and 50'), findsOneWidget);
      expect(captured, isNull);
    });

    testWidgets('valid page input calls onSelected', (tester) async {
      PdfLocationSelection? captured;
      int? pageChanged;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfLocationPicker(
              totalPages: 100,
              onSelected: (selection) {
                captured = selection;
              },
              onPageChanged: (page) {
                pageChanged = page;
              },
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '42');
      await tester.tap(find.text('Go'));
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured!.page, 42);
      expect(captured!.displayText, 'Page 42');
      expect(pageChanged, 42);
    });

    testWidgets('shows bookmarks section when bookmarks exist',
        (tester) async {
      final bookmarks = [
        PdfBookmark(
          title: 'Important Section',
          pageNumber: 10,
          createdAt: DateTime(2026, 1, 1),
        ),
        PdfBookmark(
          title: 'Reference',
          pageNumber: 25,
          createdAt: DateTime(2026, 1, 2),
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfLocationPicker(
              totalPages: 100,
              bookmarks: bookmarks,
              onSelected: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Bookmarks'), findsOneWidget);
      expect(find.text('Important Section'), findsOneWidget);
      expect(find.text('Reference'), findsOneWidget);
      expect(find.text('Page 10'), findsOneWidget);
      expect(find.text('Page 25'), findsOneWidget);
    });

    testWidgets('does not show bookmarks section when bookmarks empty',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfLocationPicker(
              totalPages: 100,
              bookmarks: const [],
              onSelected: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Bookmarks'), findsNothing);
    });

    testWidgets('tapping bookmark selects it', (tester) async {
      PdfLocationSelection? captured;
      int? pageChanged;

      final bookmarks = [
        PdfBookmark(
          title: 'My Bookmark',
          pageNumber: 15,
          createdAt: DateTime(2026, 1, 1),
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfLocationPicker(
              totalPages: 100,
              bookmarks: bookmarks,
              onSelected: (selection) {
                captured = selection;
              },
              onPageChanged: (page) {
                pageChanged = page;
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('My Bookmark'));
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured!.page, 15);
      expect(captured!.displayText, 'My Bookmark');
      expect(pageChanged, 15);
    });

    testWidgets('shows chapters section when outline provided',
        (tester) async {
      final outline = [
        PdfOutlineNode(title: 'Introduction', page: 1),
        PdfOutlineNode(title: 'Methods', page: 20),
        PdfOutlineNode(title: 'Results', page: 45),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfLocationPicker(
              totalPages: 100,
              outline: outline,
              onSelected: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Chapters'), findsOneWidget);
      expect(find.text('Introduction'), findsOneWidget);
      expect(find.text('Methods'), findsOneWidget);
      expect(find.text('Results'), findsOneWidget);
    });

    testWidgets('does not show chapters section when outline is null',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfLocationPicker(
              totalPages: 100,
              onSelected: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Chapters'), findsNothing);
    });

    testWidgets('does not show chapters section when outline is empty',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfLocationPicker(
              totalPages: 100,
              outline: const [],
              onSelected: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Chapters'), findsNothing);
    });

    testWidgets('tapping chapter selects it', (tester) async {
      PdfLocationSelection? captured;
      int? pageChanged;

      final outline = [
        PdfOutlineNode(title: 'Chapter 3: Discussion', page: 30),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfLocationPicker(
              totalPages: 100,
              outline: outline,
              onSelected: (selection) {
                captured = selection;
              },
              onPageChanged: (page) {
                pageChanged = page;
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('Chapter 3: Discussion'));
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured!.page, 30);
      expect(captured!.displayText, 'Chapter 3: Discussion');
      expect(pageChanged, 30);
    });

    testWidgets('"No specific page" option returns null selection',
        (tester) async {
      bool wasCalled = false;
      PdfLocationSelection? captured = PdfLocationSelection(page: -1);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfLocationPicker(
              totalPages: 100,
              onSelected: (selection) {
                wasCalled = true;
                captured = selection;
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('No specific page'));
      await tester.pump();

      expect(wasCalled, isTrue);
      expect(captured, isNull);
    });
  });
}
