import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../services/audio_recording_service.dart';
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
  
  // Audio recording service
  AudioRecordingService? _audioService;
  bool _isRecording = false;

  final List<Widget> _screens = [
    const NotesScreen(),
    const CalendarScreen(),
    const TodoScreen(),
    const TimelineScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _audioService = AudioRecordingService();
    _setupAudioListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppProvider>().loadData();
    });
  }

  @override
  void dispose() {
    _audioService?.resetState();
    super.dispose();
  }

  void _setupAudioListeners() {
    if (_audioService == null) return;
    
    _audioService!.recordingStateStream.listen((isRecording) {
      if (mounted) {
        setState(() {
          _isRecording = isRecording;
        });
      }
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
      builder: (context) => _VoiceRecordingDialog(
        isListening: _isListening,
        isRecording: _isRecording,
        recognizedText: _recognizedText,
        onStartListening: _startListening,
        onStopListening: _stopListening,
        onStartAudioRecording: _startAudioRecording,
        onStopAudioRecording: _stopAudioRecording,
        onSaveVoiceNote: _saveVoiceNote,
        onReset: _resetVoiceRecording,
      ),
    );
  }

  Future<void> _startListening() async {
    // Request microphone permission (skip on Linux)
    if (!Platform.isLinux) {
      try {
        final permission = await Permission.microphone.request();
        if (permission != PermissionStatus.granted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission is required for voice recording')),
          );
          return;
        }
      } catch (e) {
        print('Permission request failed: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to request microphone permission')),
        );
        return;
      }
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
      
      // Close and reopen dialog to show listening state
      Navigator.of(context).pop();
      _showVoiceRecordingDialog(context);

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

  Future<void> _saveVoiceNote(BuildContext context) async {
    if (_recognizedText.trim().isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No speech detected. Please try again.')),
        );
      }
      return;
    }

    try {
      // Capture the AppProvider reference before the context might become invalid
      final appProvider = context.read<AppProvider>();
      
      final voiceNote = Note(
        id: const Uuid().v4(),
        title: 'Voice Note - ${DateTime.now().toString().substring(0, 16)}',
        content: _recognizedText,
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await appProvider.addNote(voiceNote);
      
      if (mounted && context.mounted) {
        Navigator.pop(context);
        _resetVoiceRecording();
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Voice note saved successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('Error saving voice note: $e'); // Debug logging
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving voice note: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _resetVoiceRecording() {
    setState(() {
      _isListening = false;
      _recognizedText = '';
      _isRecording = false;
    });
  }

  // Audio recording methods
  Future<void> _startAudioRecording() async {
    if (_audioService == null) return;
    
    try {
      final success = await _audioService!.startRecording();
      if (success) {
        setState(() {
          _isRecording = true;
        });
        // Close and reopen dialog to show recording state
        Navigator.of(context).pop();
        _showVoiceRecordingDialog(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recording started'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Platform.isLinux 
                ? 'Failed to start recording. Please check if gstreamer and PulseAudio are installed.'
                : 'Failed to start recording. Please check microphone permissions.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error starting recording: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _stopAudioRecording(BuildContext context) async {
    if (_audioService == null) return;
    
    try {
      final audioPath = await _audioService!.stopRecording();
      if (audioPath != null) {
        setState(() {
          _isRecording = false;
        });
        
        // Create a note with the audio attachment
        final audioNote = Note(
          id: const Uuid().v4(),
          title: 'Audio Note - ${DateTime.now().toString().substring(0, 16)}',
          content: 'Audio recording from ${DateTime.now().toString().substring(0, 16)}',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          attachmentPaths: [audioPath],
        );

        // Capture the AppProvider reference before the context might become invalid
        final appProvider = context.read<AppProvider>();
        await appProvider.addNote(audioNote);
        
        if (mounted && context.mounted) {
          Navigator.pop(context);
          _resetVoiceRecording();
          
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Audio note saved successfully!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error stopping recording: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _navigateToImageNote(BuildContext context) {
    // Capture the main screen context and AppProvider before showing dialog
    final mainContext = context;
    final appProvider = context.read<AppProvider>();
    _showImageSourceDialog(mainContext, appProvider);
  }

  void _showImageSourceDialog(BuildContext mainContext, AppProvider appProvider) {
    showDialog(
      context: mainContext,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Select Image Source'),
        content: const Text('Choose how you want to add an image'),
        actions: [
          TextButton.icon(
            onPressed: () async {
              Navigator.pop(dialogContext);
              // Use a small delay to ensure the dialog is fully dismissed
              await Future.delayed(const Duration(milliseconds: 100));
              _pickImage(ImageSource.camera, mainContext, appProvider);
            },
            icon: const Icon(Icons.camera_alt),
            label: const Text('Camera'),
          ),
          TextButton.icon(
            onPressed: () async {
              Navigator.pop(dialogContext);
              // Use a small delay to ensure the dialog is fully dismissed
              await Future.delayed(const Duration(milliseconds: 100));
              _pickImage(ImageSource.gallery, mainContext, appProvider);
            },
            icon: const Icon(Icons.photo_library),
            label: const Text('Gallery'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImage(ImageSource source, BuildContext context, AppProvider appProvider) async {
    try {
      final ImagePicker picker = ImagePicker();
      
      final XFile? image = await picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        await _createImageNote(image, context, appProvider);
      }
    } catch (e) {
      // Try to show error message if context is still valid
      try {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error picking image: $e')),
          );
        }
      } catch (contextError) {
        // Context issue - error logged silently
      }
    }
  }

  Future<void> _createImageNote(XFile image, BuildContext context, AppProvider appProvider) async {
    try {
      // Get the file path
      final String imagePath = image.path;
      
      // Verify the file exists
      final file = File(imagePath);
      final fileExists = await file.exists();
      
      if (!fileExists) {
        throw Exception('Image file does not exist at path: $imagePath');
      }
      
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

      // Use the captured AppProvider reference instead of context.read
      await appProvider.addNote(imageNote);
      
      // Try to show success message if context is still valid
      try {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Image note created successfully!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (contextError) {
        // Context issue - note was still created successfully
      }
    } catch (e) {
      // Try to show error message if context is still valid
      try {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error creating image note: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } catch (contextError) {
        // Context issue - error logged silently
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
          const SnackBar(
            content: Text('File note created successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('Error creating file note: $e'); // Debug logging
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating file note: $e'),
            backgroundColor: Colors.red,
          ),
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
          const SnackBar(
            content: Text('File note created successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('Error creating file note from bytes: $e'); // Debug logging
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating file note: $e'),
            backgroundColor: Colors.red,
          ),
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

class _VoiceRecordingDialog extends StatefulWidget {
  final bool isListening;
  final bool isRecording;
  final String recognizedText;
  final VoidCallback onStartListening;
  final VoidCallback onStopListening;
  final VoidCallback onStartAudioRecording;
  final Function(BuildContext) onStopAudioRecording;
  final Future<void> Function(BuildContext) onSaveVoiceNote;
  final VoidCallback onReset;

  const _VoiceRecordingDialog({
    required this.isListening,
    required this.isRecording,
    required this.recognizedText,
    required this.onStartListening,
    required this.onStopListening,
    required this.onStartAudioRecording,
    required this.onStopAudioRecording,
    required this.onSaveVoiceNote,
    required this.onReset,
  });

  @override
  State<_VoiceRecordingDialog> createState() => _VoiceRecordingDialogState();
}

class _VoiceRecordingDialogState extends State<_VoiceRecordingDialog> {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isRecording ? 'Recording...' : 'Voice Note Recording'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.isListening || widget.isRecording) ...[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(50),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: Icon(
                widget.isListening ? Icons.record_voice_over : Icons.mic,
                size: 48,
                color: Colors.red,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.isListening ? 'Listening... Speak now' : 'Recording... Tap stop when done',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (widget.isRecording) ...[
              const SizedBox(height: 8),
              Text(
                'Recording will continue until you tap "Stop Recording"',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ] else ...[
            const Icon(Icons.mic, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('Choose recording method'),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.onStartListening,
                    icon: const Icon(Icons.record_voice_over),
                    label: const Text('Speech-to-Text'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.onStartAudioRecording,
                    icon: const Icon(Icons.mic),
                    label: const Text('Audio Record'),
                  ),
                ),
              ],
            ),
          ],
          if (widget.recognizedText.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                widget.recognizedText,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (widget.isListening) ...[
          ElevatedButton.icon(
            onPressed: widget.onStopListening,
            icon: const Icon(Icons.stop),
            label: const Text('Stop Listening'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
          ),
          if (widget.recognizedText.isNotEmpty)
            ElevatedButton(
              onPressed: () => widget.onSaveVoiceNote(context),
              child: const Text('Save Note'),
            ),
        ] else if (widget.isRecording) ...[
          ElevatedButton.icon(
            onPressed: () => widget.onStopAudioRecording(context),
            icon: const Icon(Icons.stop),
            label: const Text('Stop Recording'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
          ),
        ] else ...[
          TextButton(
            onPressed: widget.onStartListening,
            child: const Text('Start Speech-to-Text'),
          ),
        ],
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            widget.onReset();
          },
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
