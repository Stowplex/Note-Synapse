import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import 'notes_screen.dart';
import 'calendar_screen.dart';
import 'todo_screen.dart';
import 'timeline_screen.dart';
import 'ai_action_screen.dart';
import 'note_detail_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = [
    const NotesScreen(),
    const CalendarScreen(),
    const TodoScreen(),
    const TimelineScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppProvider>().loadData();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.note),
            label: 'Notes',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.calendar_today),
            label: 'Calendar',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.checklist),
            label: 'Todo',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.timeline),
            label: 'Timeline',
          ),
        ],
      ),
      floatingActionButton: _currentIndex == 0 
          ? FloatingActionButton(
              onPressed: () => _showAddNoteMenu(context),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  void _showAddNoteMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40), // Added bottom padding to prevent overflow
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Add New Content',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            ListTile(
              leading: const Icon(Icons.psychology),
              title: const Text('New AI Action'),
              subtitle: const Text('Create content using AI'),
              onTap: () {
                Navigator.pop(context);
                _navigateToAIAction(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.note_add),
              title: const Text('New Note'),
              subtitle: const Text('Create a regular note'),
              onTap: () {
                Navigator.pop(context);
                _navigateToNewNote(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.mic),
              title: const Text('New Voice'),
              subtitle: const Text('Record voice note'),
              onTap: () {
                Navigator.pop(context);
                _navigateToVoiceNote(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('New Picture'),
              subtitle: const Text('Add image from camera or gallery'),
              onTap: () {
                Navigator.pop(context);
                _navigateToImageNote(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('Attachment'),
              subtitle: const Text('Add file attachment'),
              onTap: () {
                Navigator.pop(context);
                _navigateToFileAttachment(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _navigateToAIAction(BuildContext context) {
    // Navigate to AI action screen
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const AIActionScreen(selectedNotes: []),
      ),
    );
  }

  void _navigateToNewNote(BuildContext context) {
    // Create a new note and navigate to note creation screen
    final newNote = Note(
      id: const Uuid().v4(),
      title: '',
      content: '',
      type: NoteType.note,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => NoteDetailScreen(note: newNote, isNewNote: true),
      ),
    );
  }

  void _navigateToVoiceNote(BuildContext context) {
    // TODO: Implement voice note recording
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Voice recording feature coming soon!')),
    );
  }

  void _navigateToImageNote(BuildContext context) {
    // TODO: Implement image picker
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Image picker feature coming soon!')),
    );
  }

  void _navigateToFileAttachment(BuildContext context) {
    // TODO: Implement file picker
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('File attachment feature coming soon!')),
    );
  }
}
