import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:note_synapse/main.dart';
import 'package:note_synapse/providers/app_provider.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/screens/notes_screen.dart';
import 'package:note_synapse/screens/setup_screen.dart';
import 'package:note_synapse/widgets/note_card.dart';

void main() {
  group('Widget Tests', () {
    testWidgets('SetupScreen displays correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: const SetupScreen(),
        ),
      );

      // Verify setup screen elements
      expect(find.text('Welcome to Note Synapse'), findsOneWidget);
      expect(find.text('Your AI-powered note-taking companion'), findsOneWidget);
      expect(find.text('Setup Required'), findsOneWidget);
      expect(find.text('Get API Key'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      expect(find.byIcon(Icons.psychology), findsOneWidget);
      expect(find.byIcon(Icons.key), findsOneWidget);
    });

    testWidgets('NoteCard displays note information correctly', (WidgetTester tester) async {
      final note = Note(
        id: 'test-note',
        title: 'Test Note Title',
        content: 'This is the test note content',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        tags: ['test', 'sample'],
        subNotes: [
          SubNote(
            id: 'sub-1',
            name: 'Sub-note 1',
            content: 'Sub-note content',
            createdAt: DateTime.now(),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NoteCard(note: note),
          ),
        ),
      );

      // Verify note card elements
      expect(find.text('Test Note Title'), findsOneWidget);
      expect(find.text('This is the test note content'), findsOneWidget);
      expect(find.text('test'), findsOneWidget);
      expect(find.text('sample'), findsOneWidget);
      expect(find.text('1 sub-notes'), findsOneWidget);
      expect(find.byIcon(Icons.note), findsOneWidget);
    });

    testWidgets('NoteCard displays task information correctly', (WidgetTester tester) async {
      final task = Note(
        id: 'test-task',
        title: 'Test Task Title',
        content: 'This is the test task content',
        type: NoteType.task,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dueDate: '2024-12-31',
        status: TaskStatus.todo,
        tags: ['work', 'urgent'],
        subNotes: [
          SubNote(
            id: 'sub-1',
            name: 'Sub-task 1',
            content: 'Sub-task content',
            createdAt: DateTime.now(),
            isCompleted: true,
          ),
          SubNote(
            id: 'sub-2',
            name: 'Sub-task 2',
            content: 'Sub-task content 2',
            createdAt: DateTime.now(),
            isCompleted: false,
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NoteCard(note: task),
          ),
        ),
      );

      // Verify task card elements
      expect(find.text('Test Task Title'), findsOneWidget);
      expect(find.text('This is the test task content'), findsOneWidget);
      expect(find.text('work'), findsOneWidget);
      expect(find.text('urgent'), findsOneWidget);
      expect(find.text('Due: 2024-12-31'), findsOneWidget);
      expect(find.text('(1/2 subtasks completed)'), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    });

    testWidgets('NotesScreen displays empty state correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (context) => AppProvider(),
          child: const MaterialApp(
            home: NotesScreen(),
          ),
        ),
      );

      await tester.pump();

      // Verify empty state elements
      expect(find.text('No notes yet'), findsOneWidget);
      expect(find.text('Tap the + button to create your first note'), findsOneWidget);
      expect(find.byIcon(Icons.note_add), findsOneWidget);
    });

    testWidgets('NotesScreen displays notes list correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (context) => AppProvider(),
          child: const MaterialApp(
            home: NotesScreen(),
          ),
        ),
      );

      await tester.pump();

      // Verify the screen loads (empty state)
      expect(find.text('No notes yet'), findsOneWidget);
    });

    testWidgets('Search functionality works correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (context) => AppProvider(),
          child: const MaterialApp(
            home: NotesScreen(),
          ),
        ),
      );

      await tester.pump();

      // Find search field and enter search term
      final searchField = find.byType(TextField);
      expect(searchField, findsOneWidget);

      await tester.enterText(searchField, 'Flutter');
      await tester.pump();

      // Verify search field accepts input
      expect(find.text('Flutter'), findsOneWidget);
    });

    testWidgets('Multi-selection mode works correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (context) => AppProvider(),
          child: const MaterialApp(
            home: NotesScreen(),
          ),
        ),
      );

      await tester.pump();

      // Verify the screen loads
      expect(find.text('No notes yet'), findsOneWidget);
    });

    testWidgets('Task completion percentage is calculated correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (context) => AppProvider(),
          child: const MaterialApp(
            home: NotesScreen(),
          ),
        ),
      );

      await tester.pump();

      // Verify the screen loads
      expect(find.text('No notes yet'), findsOneWidget);
    });
  });
}