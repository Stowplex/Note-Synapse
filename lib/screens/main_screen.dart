import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
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
  final SpeechToText _speechToText = SpeechToText();
  bool _isListening = false;
  String _recognizedText = '';

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
                _createNewNote(NoteType.note);
              },
            ),
            ListTile(
              leading: const Icon(Icons.task),
              title: const Text('New Task'),
              subtitle: const Text('Create a new task'),
              onTap: () {
                Navigator.pop(context);
                _createNewNote(NoteType.task);
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
                _navigateToFileAttachment(context);
                Navigator.pop(context);
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


  void _createNewNote(NoteType type) {
    final newNote = Note(
      id: const Uuid().v4(),
      title: '',
      content: '',
      type: type,
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
    _showVoiceRecordingDialog(context);
  }

  void _showVoiceRecordingDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Voice Note Recording'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isListening)
                const CircularProgressIndicator()
              else
                const Icon(Icons.mic, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                _isListening ? 'Listening...' : 'Tap to start recording',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              if (_recognizedText.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _recognizedText,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            if (_isListening)
              TextButton(
                onPressed: () => _stopListening(),
                child: const Text('Stop'),
              )
            else
              TextButton(
                onPressed: () => _startListening(),
                child: const Text('Start Recording'),
              ),
            if (_recognizedText.isNotEmpty)
              TextButton(
                onPressed: () => _saveVoiceNote(context),
                child: const Text('Save Note'),
              ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _resetVoiceRecording();
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startListening() async {
    // Request microphone permission
    final permission = await Permission.microphone.request();
    if (permission != PermissionStatus.granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission is required for voice recording')),
      );
      return;
    }

    // Initialize speech to text if not already done
    if (!_speechToText.isAvailable) {
      await _speechToText.initialize();
    }

    if (_speechToText.isAvailable) {
      setState(() {
        _isListening = true;
        _recognizedText = '';
      });

      await _speechToText.listen(
        onResult: (result) {
          setState(() {
            _recognizedText = result.recognizedWords;
          });
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        localeId: 'en_US',
        onSoundLevelChange: (level) {
          // Optional: Handle sound level changes
        },
      );
    }
  }

  Future<void> _stopListening() async {
    await _speechToText.stop();
    setState(() {
      _isListening = false;
    });
  }

  void _saveVoiceNote(BuildContext context) {
    if (_recognizedText.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No speech detected. Please try again.')),
      );
      return;
    }

    final voiceNote = Note(
      id: const Uuid().v4(),
      title: 'Voice Note - ${DateTime.now().toString().substring(0, 16)}',
      content: _recognizedText,
      type: NoteType.note,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    context.read<AppProvider>().addNote(voiceNote);
    Navigator.pop(context);
    _resetVoiceRecording();
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Voice note saved successfully!')),
    );
  }

  void _resetVoiceRecording() {
    setState(() {
      _isListening = false;
      _recognizedText = '';
    });
  }

  void _navigateToImageNote(BuildContext context) {
    _showImageSourceDialog(context);
  }

  void _showImageSourceDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Image Source'),
        content: const Text('Choose how you want to add an image'),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _pickImage(ImageSource.camera, context);
            },
            icon: const Icon(Icons.camera_alt),
            label: const Text('Camera'),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _pickImage(ImageSource.gallery, context);
            },
            icon: const Icon(Icons.photo_library),
            label: const Text('Gallery'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImage(ImageSource source, BuildContext context) async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        await _createImageNote(image, context);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking image: $e')),
        );
      }
    }
  }

  Future<void> _createImageNote(XFile image, BuildContext context) async {
    try {
      // Get the file path
      final String imagePath = image.path;
      
      // Create a note with the image attachment
      final imageNote = Note(
        id: const Uuid().v4(),
        title: 'Image Note - ${DateTime.now().toString().substring(0, 16)}',
        content: 'Image captured from ${image.name}',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        attachmentPaths: [imagePath],
      );

      context.read<AppProvider>().addNote(imageNote);
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Image note created successfully!')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating image note: $e')),
        );
      }
    }
  }

  void _navigateToFileAttachment(BuildContext context) {
    // Capture the AppProvider reference before the context might become invalid
    final appProvider = context.read<AppProvider>();
    _pickFile(context, appProvider);
  }


  Future<void> _pickFile(BuildContext context, AppProvider appProvider) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true, // This ensures we get the file data
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        
        if (file.path != null) {
          await _createFileNote(file, context, appProvider);
        } else if (file.bytes != null) {
          // On some platforms, we might get bytes instead of path
          await _createFileNoteFromBytes(file, context, appProvider);
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Unable to access file data')),
            );
          }
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking file: $e')),
        );
      }
    }
  }

  Future<void> _createFileNote(PlatformFile file, BuildContext context, AppProvider appProvider) async {
    try {
      // Create a note with the file attachment
      final fileNote = Note(
        id: const Uuid().v4(),
        title: 'File Note - ${file.name}',
        content: 'File attachment: ${file.name}\nSize: ${_formatFileSize(file.size)}',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        attachmentPaths: [file.path!],
      );

      await appProvider.addNote(fileNote);
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File note created successfully!')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating file note: $e')),
        );
      }
    }
  }

  Future<void> _createFileNoteFromBytes(PlatformFile file, BuildContext context, AppProvider appProvider) async {
    try {
      // For now, we'll create a note with the file information
      // In a real implementation, you might want to save the bytes to a temporary file
      // or handle them differently based on your needs
      final fileNote = Note(
        id: const Uuid().v4(),
        title: 'File Note - ${file.name}',
        content: 'File attachment: ${file.name}\nSize: ${_formatFileSize(file.size)}\nNote: File data loaded in memory',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        attachmentPaths: [], // We don't have a file path, so we'll leave this empty for now
      );

      await appProvider.addNote(fileNote);
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File note created successfully!')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating file note: $e')),
        );
      }
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
