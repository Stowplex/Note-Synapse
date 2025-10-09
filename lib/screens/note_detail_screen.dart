import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:open_file/open_file.dart';
import 'package:file_picker/file_picker.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import '../services/audio_recording_service.dart';
import '../services/gemini_api_service.dart';
import '../widgets/interactive_checkbox_list.dart';
import '../utils/date_utils.dart';
import 'ai_action_screen.dart';
import 'subnote_edit_screen.dart';

class NoteDetailScreen extends StatefulWidget {
  final Note note;
  final bool isNewNote;

  const NoteDetailScreen({super.key, required this.note, this.isNewNote = false});

  @override
  State<NoteDetailScreen> createState() => _NoteDetailScreenState();
}

class _NoteDetailScreenState extends State<NoteDetailScreen> {
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  bool _isEditing = false;
  bool _hasChanges = false;
  bool _hasBeenSaved = false; // Track if note has been saved to database
  Timer? _autoSaveTimer;
  DateTime? _scheduledAt;
  DateTime? _completeBy;
  String? _dateValidationError;
  List<Relationship> _relationships = [];
  List<Note> _linkedNotes = [];
  
  // Audio recording state
  AudioRecordingService? _audioService;
  bool _isRecording = false;
  bool _isPlaying = false;
  String? _currentPlayingPath;
  Duration _playingPosition = Duration.zero;
  Duration _playingDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _contentController = TextEditingController(text: widget.note.content);
    
    // Initialize date fields for tasks
    if (widget.note.isTask) {
      _scheduledAt = widget.note.scheduledAt != null 
          ? DateTime.tryParse(widget.note.scheduledAt!) 
          : null;
      _completeBy = widget.note.completeBy != null 
          ? DateTime.tryParse(widget.note.completeBy!) 
          : null;
    }
    
    _titleController.addListener(_onTextChanged);
    _contentController.addListener(_onTextChanged);
    
    // Start in editing mode for new notes
    if (widget.isNewNote) {
      _isEditing = true;
      _hasBeenSaved = false; // New notes haven't been saved yet
    } else {
      _hasBeenSaved = true; // Existing notes are already in the database
    }
    
    // Load relationships
    _loadRelationships();
    
    // Initialize audio service on all platforms (including Linux)
    _initializeAudioService();
  }

  void _initializeAudioService() {
    _audioService = AudioRecordingService();
    _setupAudioListeners();
    
    // Reset audio state
    _isRecording = false;
    _isPlaying = false;
    _currentPlayingPath = null;
    _playingPosition = Duration.zero;
    _playingDuration = Duration.zero;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reinitialize audio service if it was disposed
    if (_audioService == null) {
      _initializeAudioService();
    }
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _titleController.dispose();
    _contentController.dispose();
    // Reset audio state but don't dispose the service (it's a singleton)
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

    _audioService!.playingStateStream.listen((isPlaying) {
      print('Audio playing state changed: $isPlaying');
      if (mounted) {
        setState(() {
          _isPlaying = isPlaying;
          if (isPlaying) {
            _currentPlayingPath = _audioService!.currentPlayingPath;
          } else {
            _currentPlayingPath = null;
          }
        });
      }
    });

    _audioService!.playingPositionStream.listen((position) {
      if (mounted) {
        setState(() {
          _playingPosition = position;
        });
      }
    });

    _audioService!.playingDurationStream.listen((duration) {
      if (mounted) {
        setState(() {
          _playingDuration = duration;
        });
      }
    });
  }

  void _onTextChanged() {
    if (!_hasChanges) {
      setState(() {
        _hasChanges = true;
      });
    }
    
    // Auto-save after 2 seconds of no typing
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () {
      if (_hasChanges) {
        _autoSave();
      }
    });
  }

  void _onDateChanged() {
    _validateDates();
    if (!_hasChanges) {
      setState(() {
        _hasChanges = true;
      });
    }
    
    // Auto-save after 2 seconds of no changes
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () {
      if (_hasChanges) {
        _autoSave();
      }
    });
  }

  Future<void> _loadRelationships() async {
    try {
      final appProvider = context.read<AppProvider>();
      final relationships = await appProvider.getNoteRelationships(widget.note.id);
      final linkedNotes = await appProvider.getLinkedNotes(widget.note.id);
      
      if (mounted) {
        setState(() {
          _relationships = relationships;
          _linkedNotes = linkedNotes;
        });
      }
    } catch (e) {
      print('Error loading relationships: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, appProvider, child) {
        // Get the latest version of the note from the provider
        final currentNote = appProvider.notes.firstWhere(
          (note) => note.id == widget.note.id,
          orElse: () => widget.note,
        );
        
        return PopScope(
          canPop: !_isEditing, // Don't allow popping when editing
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && _isEditing) {
              // If we're in editing mode and back was pressed, cancel editing instead
              _cancelEditing();
            }
          },
          child: Scaffold(
          appBar: AppBar(
            title: Text(currentNote.title),
        actions: [
          if (_isEditing) ...[
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _hasChanges ? _saveChanges : null,
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: _startEditing,
            ),
            IconButton(
              icon: const Icon(Icons.psychology),
              onPressed: _openAIAction,
            ),
            PopupMenuButton(
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete, color: Colors.red),
                      const SizedBox(width: 8),
                      Text('Delete', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
                if (widget.note.isTask)
                  PopupMenuItem(
                    value: 'convert',
                    child: Row(
                      children: [
                        Icon(Icons.note),
                        const SizedBox(width: 8),
                        Text('Convert to Note'),
                      ],
                    ),
                  ),
                if (!widget.note.isTask)
                  PopupMenuItem(
                    value: 'convert',
                    child: Row(
                      children: [
                        Icon(Icons.task),
                        const SizedBox(width: 8),
                        Text('Convert to Task'),
                      ],
                    ),
                  ),
              ],
              onSelected: (value) {
                if (value == 'delete') {
                  _deleteNote();
                } else if (value == 'convert') {
                  _convertNoteType();
                }
              },
            ),
          ],
        ],
      ),
            body: _isEditing ? _buildEditingView() : _buildViewingView(currentNote),
            bottomNavigationBar: _isEditing ? null : _buildBottomBar(),
          ),
        );
      },
    );
  }

  Widget _buildViewingView(Note currentNote) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (currentNote.isTask) ...[
            _buildTaskStatus(currentNote),
            const SizedBox(height: 16),
          ],
          SelectableText(
            currentNote.title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          SelectionArea(
            child: InteractiveCheckboxList(
              key: ValueKey('note_${currentNote.id}'),
              originalContent: currentNote.content,
              onContentChanged: _updateNoteContent,
              style: Theme.of(context).textTheme.bodyLarge,
              textDirection: TextDirection.ltr,
              onLinkTap: _handleLinkTap,
              // No truncation in detail view - show full content
              maxLines: null,
              overflow: null,
            ),
          ),
          if (currentNote.subNotes.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                Text(
                  'Sub-notes',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => _addSubNote(currentNote),
                  tooltip: 'Add sub-note',
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...currentNote.subNotes.map((subNote) => Card(
              child: ListTile(
                leading: Icon(
                  subNote.isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: subNote.isCompleted ? Colors.green : Colors.grey,
                ),
                title: SelectableText(subNote.name),
                subtitle: InteractiveCheckboxList(
                  key: ValueKey('subnote_${subNote.id}'),
                  originalContent: subNote.content,
                  onContentChanged: (newContent) => _updateSubNoteContent(subNote, newContent),
                  style: Theme.of(context).textTheme.bodySmall,
                  textDirection: TextDirection.ltr,
                  onLinkTap: _handleLinkTap,
                ),
                trailing: PopupMenuButton(
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: const Row(
                        children: [
                          Icon(Icons.edit, size: 16),
                          SizedBox(width: 8),
                          Text('Edit'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'toggle',
                      child: Row(
                        children: [
                          Icon(
                            subNote.isCompleted ? Icons.undo : Icons.check,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(subNote.isCompleted ? 'Mark Incomplete' : 'Mark Complete'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'reparent',
                      child: const Row(
                        children: [
                          Icon(Icons.move_to_inbox, size: 16),
                          SizedBox(width: 8),
                          Text('Reparent'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: const Row(
                        children: [
                          Icon(Icons.delete, color: Colors.red, size: 16),
                          SizedBox(width: 8),
                          Text('Delete', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                  onSelected: (value) {
                    switch (value) {
                      case 'edit':
                        _editSubNote(currentNote, subNote);
                        break;
                      case 'toggle':
                        _toggleSubNoteCompletion(subNote);
                        break;
                      case 'reparent':
                        _reparentSubNote(currentNote, subNote);
                        break;
                      case 'delete':
                        _deleteSubNote(currentNote, subNote);
                        break;
                    }
                  },
                ),
                onTap: () => _toggleSubNoteCompletion(subNote),
              ),
            )),
          ] else if (!_isEditing) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                Text(
                  'Sub-notes',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => _addSubNote(currentNote),
                  tooltip: 'Add sub-note',
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Text(
                'Tags',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _showAddTagDialog(currentNote),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Tag'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (currentNote.tags.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: currentNote.tags.map((tag) => Chip(
                label: Text(tag),
                backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                labelStyle: TextStyle(color: Theme.of(context).colorScheme.primary),
                deleteIcon: const Icon(Icons.close, size: 16),
                onDeleted: () => _removeTag(currentNote, tag),
              )).toList(),
            )
          else
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey[300]!),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.label_outline, color: Colors.grey[400]),
                  const SizedBox(width: 8),
                  Text(
                    'No tags yet. Tap "Add Tag" to add some.',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
          if (currentNote.attachmentPaths.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'Attachments',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ...currentNote.attachmentPaths.map((path) => _buildAttachmentCard(path, currentNote)),
          ],
          if (_linkedNotes.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                Text(
                  'Linked Notes',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addLinkedNote,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add Link'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ..._buildLinkedNotesList(currentNote),
          ] else ...[
            const SizedBox(height: 24),
            Row(
              children: [
                Text(
                  'Linked Notes',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addLinkedNote,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add Link'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.link_off, color: Colors.grey[400]),
                    const SizedBox(width: 8),
                    Text(
                      'No linked notes yet',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          SelectableText(
            'Created: ${_formatDate(currentNote.createdAt)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          if (currentNote.updatedAt != currentNote.createdAt)
            SelectableText(
              'Updated: ${_formatDate(currentNote.updatedAt)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEditingView() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          if (widget.note.isTask) ...[
            _buildDateSelectionFields(),
            const SizedBox(height: 16),
          ],
          Expanded(
            child: TextField(
              controller: _contentController,
              decoration: const InputDecoration(
                labelText: 'Content',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
            ),
          ),
          const SizedBox(height: 8),
          _buildMarkdownButtons(),
        ],
      ),
    );
  }

  Widget _buildMarkdownButtons() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildMarkdownButton(
            icon: Icons.check_box_outline_blank,
            label: 'Checkbox',
            onPressed: _insertCheckbox,
          ),
          _buildMarkdownButton(
            icon: Icons.title,
            label: 'Title',
            onPressed: _insertTitle,
          ),
          _buildMarkdownButton(
            icon: Icons.format_bold,
            label: 'Bold',
            onPressed: _insertBold,
          ),
        ],
      ),
    );
  }

  Widget _buildMarkdownButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 36),
      ),
    );
  }

  void _insertCheckbox() {
    _insertTextAtCursor('\n\n[ ] \n\n');
  }

  void _insertTitle() {
    _insertTextAtCursor('\n\n** \n\n');
  }

  void _insertBold() {
    _insertTextAtCursor('****', selectMiddle: true);
  }

  void _insertTextAtCursor(String text, {bool selectMiddle = false}) {
    final textEditingValue = _contentController.value;
    final selection = textEditingValue.selection;
    
    if (selection.isValid) {
      final newText = textEditingValue.text.replaceRange(
        selection.start,
        selection.end,
        text,
      );
      
      int newCursorPosition;
      if (selectMiddle && text.length > 0) {
        // For bold text, place cursor between the ** markers
        newCursorPosition = selection.start + (text.length ~/ 2);
      } else {
        // For other text, place cursor at the end
        newCursorPosition = selection.start + text.length;
      }
      
      _contentController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newCursorPosition),
      );
    } else {
      // If no selection, append to the end
      _contentController.text += text;
      _contentController.selection = TextSelection.collapsed(
        offset: _contentController.text.length,
      );
    }
  }

  Widget _buildDateSelectionFields() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () => _selectScheduledAt(),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Schedule At',
                    border: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: _dateValidationError != null ? Colors.red : Colors.grey,
                      ),
                    ),
                  ),
                  child: Text(
                    _scheduledAt != null 
                        ? '${_scheduledAt!.day}/${_scheduledAt!.month}/${_scheduledAt!.year}'
                        : 'Select date',
                    style: _scheduledAt != null 
                        ? null 
                        : TextStyle(color: Colors.grey[600]),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: InkWell(
                onTap: () => _selectCompleteBy(),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Complete By',
                    border: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: _dateValidationError != null ? Colors.red : Colors.grey,
                      ),
                    ),
                  ),
                  child: Text(
                    _completeBy != null 
                        ? '${_completeBy!.day}/${_completeBy!.month}/${_completeBy!.year}'
                        : 'Select date',
                    style: _completeBy != null 
                        ? null 
                        : TextStyle(color: Colors.grey[600]),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_dateValidationError != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _dateValidationError!,
              style: TextStyle(
                color: Colors.red[600],
                fontSize: 12,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTaskStatus(Note currentNote) {
    if (!currentNote.isTask) return const SizedBox.shrink();
    
    return Card(
      color: _getStatusColor().withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              _getStatusIcon(),
              color: _getStatusColor(),
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Status: ',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: _getStatusColor(),
                        ),
                      ),
                      _buildStatusDropdown(currentNote),
                    ],
                  ),
                  if (currentNote.scheduledAt != null)
                    SelectableText(
                      'Scheduled: ${AppDateUtils.formatDateForDisplay(currentNote.scheduledAt)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  if (currentNote.completeBy != null)
                    SelectableText(
                      'Due: ${AppDateUtils.formatDateForDisplay(currentNote.completeBy)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectScheduledAt() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _scheduledAt ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    
    if (picked != null) {
      setState(() {
        _scheduledAt = picked;
      });
      _onDateChanged();
    }
  }

  Future<void> _selectCompleteBy() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _completeBy ?? (_scheduledAt ?? DateTime.now()),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    
    if (picked != null) {
      setState(() {
        _completeBy = picked;
      });
      _onDateChanged();
    }
  }

  void _validateDates() {
    if (_scheduledAt != null && _completeBy != null) {
      if (_completeBy!.isBefore(_scheduledAt!)) {
        setState(() {
          _dateValidationError = 'Complete By must be no earlier than Schedule At';
        });
      } else {
        setState(() {
          _dateValidationError = null;
        });
      }
    } else {
      setState(() {
        _dateValidationError = null;
      });
    }
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: Colors.grey[300]!),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_audioService != null && _isRecording) _buildRecordingIndicator(),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openAIAction,
                  icon: const Icon(Icons.psychology),
                  label: const Text('AI Actions'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _addAttachment,
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Attach'),
                ),
              ),
              if (_audioService != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isRecording ? _stopRecording : _startRecording,
                    icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                    label: Text(_isRecording ? 'Stop Recording' : 'Record Audio'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _isRecording ? Colors.red : null,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingIndicator() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withOpacity(0.5), width: 2),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(Icons.mic, color: Colors.red, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Recording in progress...',
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Tap "Stop Recording" when you\'re done',
                  style: TextStyle(
                    color: Colors.red[700],
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _cancelRecording,
            icon: Icon(Icons.cancel, color: Colors.red, size: 18),
            label: Text('Cancel', style: TextStyle(color: Colors.red)),
            style: TextButton.styleFrom(
              backgroundColor: Colors.red.withOpacity(0.1),
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor() {
    // Get the current note from the provider
    final currentNote = context.read<AppProvider>().notes.firstWhere(
      (note) => note.id == widget.note.id,
      orElse: () => widget.note,
    );
    switch (currentNote.status) {
      case TaskStatus.complete:
        return Colors.green;
      case TaskStatus.inProgress:
        return Colors.orange;
      case TaskStatus.abandoned:
        return Colors.red;
      case TaskStatus.todo:
      default:
        return Colors.grey;
    }
  }

  IconData _getStatusIcon() {
    // Get the current note from the provider
    final currentNote = context.read<AppProvider>().notes.firstWhere(
      (note) => note.id == widget.note.id,
      orElse: () => widget.note,
    );
    switch (currentNote.status) {
      case TaskStatus.complete:
        return Icons.check_circle;
      case TaskStatus.inProgress:
        return Icons.play_circle;
      case TaskStatus.abandoned:
        return Icons.cancel;
      case TaskStatus.todo:
      default:
        return Icons.radio_button_unchecked;
    }
  }

  String _getStatusText() {
    // Get the current note from the provider
    final currentNote = context.read<AppProvider>().notes.firstWhere(
      (note) => note.id == widget.note.id,
      orElse: () => widget.note,
    );
    switch (currentNote.status) {
      case TaskStatus.complete:
        return 'Complete';
      case TaskStatus.inProgress:
        return 'In Progress';
      case TaskStatus.abandoned:
        return 'Cancelled';
      case TaskStatus.todo:
      default:
        return 'To Do';
    }
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} at ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  void _startEditing() {
    setState(() {
      _isEditing = true;
      _hasChanges = false;
    });
  }

  void _cancelEditing() {
    setState(() {
      _isEditing = false;
      _hasChanges = false;
      _titleController.text = widget.note.title;
      _contentController.text = widget.note.content;
      _dateValidationError = null;
      
      // Reset date fields for tasks
      if (widget.note.isTask) {
        _scheduledAt = widget.note.scheduledAt != null 
            ? DateTime.tryParse(widget.note.scheduledAt!) 
            : null;
        _completeBy = widget.note.completeBy != null 
            ? DateTime.tryParse(widget.note.completeBy!) 
            : null;
      }
    });
  }

  void _autoSave() {
    if (_titleController.text.trim().isEmpty && _contentController.text.trim().isEmpty) {
      return; // Don't save empty notes
    }
    
    // Don't save if there are validation errors
    if (_dateValidationError != null) {
      return;
    }
    
    final updatedNote = widget.note.copyWith(
      title: _titleController.text.trim().isEmpty ? 'Untitled' : _titleController.text.trim(),
      content: _contentController.text.trim(),
      updatedAt: DateTime.now(),
      scheduledAt: _scheduledAt != null ? AppDateUtils.formatDateOnly(_scheduledAt!) : null,
      completeBy: _completeBy != null ? AppDateUtils.formatDateOnly(_completeBy!) : null,
    );
    
    if (!_hasBeenSaved) {
      // First save: Add new note to the database
      context.read<AppProvider>().addNote(updatedNote);
      setState(() {
        _hasBeenSaved = true; // Mark as saved after first insert
      });
    } else {
      // Subsequent saves: Update existing note
      context.read<AppProvider>().updateNote(updatedNote);
    }
    
    setState(() {
      _hasChanges = false;
    });
  }

  void _saveChanges() {
    // Validate dates before saving
    _validateDates();
    
    if (_dateValidationError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_dateValidationError!),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    
    _autoSave();
    setState(() {
      _isEditing = false;
    });
  }

  void _deleteNote() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Note'),
        content: const Text('Are you sure you want to delete this note?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              context.read<AppProvider>().deleteNote(widget.note.id);
              Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _convertNoteType() {
    final newType = widget.note.isTask ? NoteType.note : NoteType.task;
    final updatedNote = widget.note.copyWith(
      type: newType,
      updatedAt: DateTime.now(),
    );
    
    context.read<AppProvider>().updateNote(updatedNote);
    Navigator.pop(context);
  }

  void _toggleSubNoteCompletion(SubNote subNote) {
    context.read<AppProvider>().toggleSubNoteCompletion(widget.note.id, subNote.id);
  }

  void _addSubNote(Note note) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SubNoteEditScreen(parentNote: note),
      ),
    );
  }

  void _editSubNote(Note note, SubNote subNote) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SubNoteEditScreen(
          parentNote: note,
          subNote: subNote,
        ),
      ),
    );
  }

  void _deleteSubNote(Note note, SubNote subNote) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Sub-note'),
        content: Text('Are you sure you want to delete "${subNote.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              context.read<AppProvider>().deleteSubNoteFromNote(note.id, subNote.id);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }


  void _openAIAction() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AIActionScreen(selectedNotes: [widget.note]),
      ),
    );
  }

  Widget _buildAttachmentCard(String attachmentPath, Note currentNote) {
    final fileName = attachmentPath.split('/').last;
    final file = File(attachmentPath);
    final fileExists = file.existsSync();
    final isAudioFile = _isAudioFile(fileName);
    final isCurrentlyPlaying = _isPlaying && _currentPlayingPath == attachmentPath;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          _getFileIcon(fileName),
          color: fileExists ? null : Colors.grey,
        ),
        title: Text(
          fileName,
          style: TextStyle(
            color: fileExists ? null : Colors.grey,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              fileExists ? _formatFileSize(file.lengthSync()) : 'File not found',
              style: TextStyle(
                color: fileExists ? Colors.grey[600] : Colors.red,
              ),
            ),
            if (isAudioFile && fileExists && _audioService != null) ...[
              const SizedBox(height: 4),
              _buildAudioPlayer(attachmentPath, isCurrentlyPlaying),
            ],
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isAudioFile && fileExists && _audioService != null) ...[
              IconButton(
                icon: Icon(isCurrentlyPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () => _toggleAudioPlayback(attachmentPath),
                tooltip: isCurrentlyPlaying ? 'Pause' : 'Play',
              ),
              if (isCurrentlyPlaying)
                IconButton(
                  icon: const Icon(Icons.stop),
                  onPressed: () => _stopAudioPlayback(),
                  tooltip: 'Stop',
                ),
              IconButton(
                icon: const Icon(Icons.text_fields),
                onPressed: () => _transcribeAudio(attachmentPath),
                tooltip: 'Transcribe with AI',
              ),
            ] else if (fileExists)
              IconButton(
                icon: const Icon(Icons.open_in_new),
                onPressed: () => _openAttachment(attachmentPath),
                tooltip: 'Open with default application',
              ),
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: () => _removeAttachment(attachmentPath, currentNote),
              tooltip: 'Remove attachment',
            ),
          ],
        ),
        onTap: fileExists && !isAudioFile ? () => _openAttachment(attachmentPath) : null,
      ),
    );
  }

  Widget _buildAudioPlayer(String attachmentPath, bool isCurrentlyPlaying) {
    return Column(
      children: [
        if (isCurrentlyPlaying) ...[
          Slider(
            value: _playingDuration.inMilliseconds > 0 
                ? _playingPosition.inMilliseconds / _playingDuration.inMilliseconds 
                : 0.0,
            onChanged: (value) {
              final newPosition = Duration(
                milliseconds: (value * _playingDuration.inMilliseconds).round(),
              );
              _audioService?.seekTo(newPosition);
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatDuration(_playingPosition)),
              Text(_formatDuration(_playingDuration)),
            ],
          ),
        ],
      ],
    );
  }

  IconData _getFileIcon(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    switch (extension) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'bmp':
      case 'webp':
        return Icons.image;
      case 'mp4':
      case 'avi':
      case 'mov':
        return Icons.videocam;
      case 'mp3':
      case 'wav':
      case 'aac':
        return Icons.audiotrack;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'txt':
      case 'md':
        return Icons.text_snippet;
      default:
        return Icons.attach_file;
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _openAttachment(String attachmentPath) async {
    try {
      final file = File(attachmentPath);
      if (!file.existsSync()) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File not found'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Use open_file package for proper Android file handling
      final result = await OpenFile.open(attachmentPath);
      
      if (result.type != ResultType.done) {
        String errorMessage = 'Cannot open file';
        switch (result.type) {
          case ResultType.noAppToOpen:
            errorMessage = 'No application found to open this file type';
            break;
          case ResultType.fileNotFound:
            errorMessage = 'File not found';
            break;
          case ResultType.permissionDenied:
            errorMessage = 'Permission denied to open file';
            break;
          case ResultType.error:
            errorMessage = 'Error opening file: ${result.message}';
            break;
          default:
            errorMessage = 'Unknown error opening file';
        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error opening file: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _removeAttachment(String attachmentPath, Note currentNote) async {
    try {
      // Show confirmation dialog
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove Attachment'),
          content: Text('Are you sure you want to remove "${attachmentPath.split('/').last}" from this note?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        // Remove attachment from note
        final updatedAttachmentPaths = List<String>.from(currentNote.attachmentPaths);
        updatedAttachmentPaths.remove(attachmentPath);
        
        final updatedNote = currentNote.copyWith(
          attachmentPaths: updatedAttachmentPaths,
          updatedAt: DateTime.now(),
        );

        // Update the note in the database
        await context.read<AppProvider>().updateNote(updatedNote);
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Attachment removed'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error removing attachment: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _addAttachment() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );

      if (result != null && result.files.isNotEmpty) {
        final currentNote = context.read<AppProvider>().notes.firstWhere(
          (note) => note.id == widget.note.id,
          orElse: () => widget.note,
        );

        // Get existing attachment paths
        final updatedAttachmentPaths = List<String>.from(currentNote.attachmentPaths);
        
        // Add new attachment paths
        for (final file in result.files) {
          if (file.path != null) {
            updatedAttachmentPaths.add(file.path!);
          }
        }

        // Update the note
        final updatedNote = currentNote.copyWith(
          attachmentPaths: updatedAttachmentPaths,
          updatedAt: DateTime.now(),
        );

        await context.read<AppProvider>().updateNote(updatedNote);
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added ${result.files.length} attachment(s)'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error adding attachment: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildStatusDropdown(Note currentNote) {
    return PopupMenuButton<TaskStatus>(
      onSelected: (TaskStatus status) {
        context.read<AppProvider>().updateTaskStatus(currentNote.id, status);
      },
      itemBuilder: (BuildContext context) => [
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.todo,
          child: Row(
            children: [
              Icon(Icons.radio_button_unchecked, color: Colors.grey, size: 20),
              const SizedBox(width: 8),
              const Text('To Do'),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.inProgress,
          child: Row(
            children: [
              Icon(Icons.play_circle, color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              const Text('In Progress'),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.complete,
          child: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 20),
              const SizedBox(width: 8),
              const Text('Complete'),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.abandoned,
          child: Row(
            children: [
              Icon(Icons.cancel, color: Colors.red, size: 20),
              const SizedBox(width: 8),
              const Text('Cancelled'),
            ],
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey[300]!),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _getStatusText(),
              style: TextStyle(
                color: _getStatusColor(),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, size: 16),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildLinkedNotesList(Note currentNote) {
    return _relationships.map((relationship) {
      final linkedNote = _linkedNotes.firstWhere(
        (note) => note.id == (relationship.fromNoteId == currentNote.id ? relationship.toNoteId : relationship.fromNoteId),
        orElse: () => Note(
          id: 'unknown',
          title: 'Unknown Note',
          content: '',
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      
      final isOutgoing = relationship.fromNoteId == currentNote.id;
      
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: Icon(
            RelationshipType.getIcon(relationship.type),
            color: Theme.of(context).primaryColor,
          ),
          title: SelectableText(linkedNote.title),
          subtitle: Text(
            '${RelationshipType.getDisplayName(relationship.type)} ${isOutgoing ? '→' : '←'}',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 12,
            ),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.remove_circle, color: Colors.red),
            onPressed: () => _removeLinkedNote(relationship.id),
          ),
          onTap: () {
            if (linkedNote.id != 'unknown') {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => NoteDetailScreen(note: linkedNote),
                ),
              );
            }
          },
        ),
      );
    }).toList();
  }

  void _addLinkedNote() {
    showDialog(
      context: context,
      builder: (context) => _AddLinkedNoteDialog(
        currentNote: widget.note,
        onLink: (noteId, relationshipType) async {
          Navigator.pop(context);
          await context.read<AppProvider>().createNoteRelationships(
            widget.note.id,
            [noteId],
            relationshipType,
          );
          await _loadRelationships();
        },
      ),
    );
  }

  void _removeLinkedNote(String relationshipId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Link'),
        content: const Text('Are you sure you want to remove this link?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await context.read<AppProvider>().deleteRelationship(relationshipId);
              await _loadRelationships();
            },
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _removeTag(Note currentNote, String tagName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Tag'),
        content: Text('Are you sure you want to remove the tag "$tagName" from this note?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await context.read<AppProvider>().removeTagFromNote(currentNote.id, tagName);
            },
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showAddTagDialog(Note currentNote) {
    showDialog(
      context: context,
      builder: (context) => _AddTagDialog(
        currentNote: currentNote,
        onAddTags: (tagNames) async {
          Navigator.pop(context);
          for (final tagName in tagNames) {
            await context.read<AppProvider>().addTagToNote(currentNote.id, tagName);
          }
        },
      ),
    );
  }

  // Audio recording methods
  Future<void> _startRecording() async {
    if (_audioService == null) return;
    
    try {
      final success = await _audioService!.startRecording();
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recording started'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to start recording. Please check microphone permissions.'),
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

  Future<void> _stopRecording() async {
    if (_audioService == null) return;
    
    try {
      final audioPath = await _audioService!.stopRecording();
      if (audioPath != null) {
        // Add the recorded audio as an attachment
        final currentNote = context.read<AppProvider>().notes.firstWhere(
          (note) => note.id == widget.note.id,
          orElse: () => widget.note,
        );

        final updatedAttachmentPaths = List<String>.from(currentNote.attachmentPaths);
        updatedAttachmentPaths.add(audioPath);

        final updatedNote = currentNote.copyWith(
          attachmentPaths: updatedAttachmentPaths,
          updatedAt: DateTime.now(),
        );

        await context.read<AppProvider>().updateNote(updatedNote);

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recording saved as attachment'),
            backgroundColor: Colors.green,
          ),
        );
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

  Future<void> _cancelRecording() async {
    if (_audioService == null) return;
    
    await _audioService!.cancelRecording();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Recording cancelled'),
        backgroundColor: Colors.orange,
      ),
    );
  }

  // Audio playback methods
  Future<void> _toggleAudioPlayback(String audioPath) async {
    if (_audioService == null) return;
    
    try {
      if (_isPlaying && _currentPlayingPath == audioPath) {
        await _audioService!.pausePlaying();
      } else if (_isPlaying) {
        await _audioService!.stopPlaying();
        await _audioService!.startPlaying(audioPath);
        setState(() {
          _currentPlayingPath = audioPath;
        });
      } else {
        final success = await _audioService!.startPlaying(audioPath);
        if (success) {
          setState(() {
            _currentPlayingPath = audioPath;
          });
        }
      }
    } catch (e) {
      print('Error playing audio: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error playing audio: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _stopAudioPlayback() async {
    if (_audioService == null) return;
    
    try {
      await _audioService!.stopPlaying();
      setState(() {
        _currentPlayingPath = null;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error stopping audio: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Audio transcription methods
  Future<void> _transcribeAudio(String audioPath) async {
    try {
      // Show loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Transcribing audio...'),
            ],
          ),
        ),
      );

      final transcription = await GeminiApiService.transcribeAudio(audioPath);
      
      // Close loading dialog
      Navigator.of(context).pop();

      // Show transcription dialog
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Audio Transcription'),
          content: SingleChildScrollView(
            child: Text(transcription),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _addTranscriptionToNote(transcription);
              },
              child: const Text('Add to Note'),
            ),
          ],
        ),
      );
    } catch (e) {
      // Close loading dialog if it's open
      Navigator.of(context).pop();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error transcribing audio: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _addTranscriptionToNote(String transcription) async {
    try {
      final currentNote = context.read<AppProvider>().notes.firstWhere(
        (note) => note.id == widget.note.id,
        orElse: () => widget.note,
      );

      final updatedContent = currentNote.content.isEmpty 
          ? transcription 
          : '${currentNote.content}\n\n--- Audio Transcription ---\n$transcription';

      final updatedNote = currentNote.copyWith(
        content: updatedContent,
        updatedAt: DateTime.now(),
      );

      await context.read<AppProvider>().updateNote(updatedNote);

      // Update the content controller if we're in editing mode
      if (_isEditing) {
        _contentController.text = updatedContent;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transcription added to note'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error adding transcription: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Helper methods
  bool _isAudioFile(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    return ['mp3', 'wav', 'aac', 'm4a', 'ogg', 'flac', 'wma'].contains(extension);
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  // Update note content when checkboxes are toggled
  void _updateNoteContent(String newContent) async {
    if (mounted) {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      await appProvider.updateNoteContent(widget.note.id, newContent);
    }
  }

  // Update subnote content when checkboxes are toggled
  void _updateSubNoteContent(SubNote subNote, String newContent) async {
    if (mounted) {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      final updatedSubNote = subNote.copyWith(content: newContent);
      await appProvider.updateSubNoteInNote(widget.note.id, updatedSubNote);
    }
  }

  // Reparent subnote
  void _reparentSubNote(Note currentNote, SubNote subNote) {
    showDialog(
      context: context,
      builder: (context) => _ReparentSubNoteDialog(
        currentNote: currentNote,
        subNote: subNote,
        onReparent: (newParentNoteId) async {
          final appProvider = Provider.of<AppProvider>(context, listen: false);
          await appProvider.reparentSubNote(currentNote.id, newParentNoteId, subNote);
          if (mounted) {
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Sub-note moved successfully'),
                backgroundColor: Colors.green,
              ),
            );
          }
        },
      ),
    );
  }

  // Link handling function
  void _handleLinkTap(String url, String text) {
    // Note: gpt_markdown passes parameters in reverse order
    // First parameter is the actual URL, second is the display text
    _launchUrl(url);
  }

  Future<void> _launchUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Cannot open link: $url'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening link: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

class _AddLinkedNoteDialog extends StatefulWidget {
  final Note currentNote;
  final Function(String noteId, String relationshipType) onLink;

  const _AddLinkedNoteDialog({
    required this.currentNote,
    required this.onLink,
  });

  @override
  State<_AddLinkedNoteDialog> createState() => _AddLinkedNoteDialogState();
}

class _ReparentSubNoteDialog extends StatefulWidget {
  final Note currentNote;
  final SubNote subNote;
  final Function(String) onReparent;

  const _ReparentSubNoteDialog({
    required this.currentNote,
    required this.subNote,
    required this.onReparent,
  });

  @override
  State<_ReparentSubNoteDialog> createState() => _ReparentSubNoteDialogState();
}

class _ReparentSubNoteDialogState extends State<_ReparentSubNoteDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String? _selectedNoteId;
  List<Note> _filteredNotes = [];
  String? _selectedTag;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _filteredNotes = _getAvailableNotes();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.toLowerCase();
      _filteredNotes = _getAvailableNotes();
    });
  }

  List<Note> _getAvailableNotes() {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    var notes = appProvider.notes.where((note) => note.id != widget.currentNote.id).toList();

    // Filter by search query
    if (_searchQuery.isNotEmpty) {
      notes = notes.where((note) {
        return note.title.toLowerCase().contains(_searchQuery) ||
               note.content.toLowerCase().contains(_searchQuery);
      }).toList();
    }

    // Filter by selected tag
    if (_selectedTag != null && _selectedTag != 'All Notes') {
      notes = notes.where((note) {
        return note.tags.contains(_selectedTag);
      }).toList();
    }

    return notes;
  }

  List<String> _getAllTags() {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final allTags = <String>{};
    for (final note in appProvider.notes) {
      allTags.addAll(note.tags);
    }
    final tagList = allTags.toList()..sort();
    return ['All Notes', ...tagList];
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Move "${widget.subNote.name}" to another note'),
      content: SizedBox(
        width: 500,
        height: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Search Box
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search notes...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
            const SizedBox(height: 16),
            
            // Tags Dropdown
            Row(
              children: [
                Text(
                  'Filter by tag:',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedTag,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    hint: const Text('All Notes'),
                    items: _getAllTags().map((tag) {
                      return DropdownMenuItem<String>(
                        value: tag,
                        child: Text(tag),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedTag = value;
                        _filteredNotes = _getAvailableNotes();
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Notes List
            Expanded(
              child: _filteredNotes.isEmpty
                  ? Center(
                      child: Text(
                        _searchQuery.isNotEmpty || (_selectedTag != null && _selectedTag != 'All Notes')
                            ? 'No notes match your search'
                            : 'No other notes available',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey[600],
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _filteredNotes.length,
                      itemBuilder: (context, index) {
                        final note = _filteredNotes[index];
                        final isSelected = _selectedNoteId == note.id;
                        
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          color: isSelected ? Theme.of(context).primaryColor.withOpacity(0.1) : null,
                          child: ListTile(
                            title: Text(
                              note.title,
                              style: TextStyle(
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 4),
                                Text(
                                  note.content.length > 80 
                                      ? '${note.content.substring(0, 80)}...'
                                      : note.content,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 12,
                                  ),
                                ),
                                if (note.tags.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 2,
                                    children: note.tags.take(3).map((tag) => Chip(
                                      label: Text(
                                        tag,
                                        style: const TextStyle(fontSize: 10),
                                      ),
                                      backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                                      labelStyle: TextStyle(
                                        color: Theme.of(context).colorScheme.primary,
                                        fontSize: 10,
                                      ),
                                    )).toList(),
                                  ),
                                ],
                              ],
                            ),
                            trailing: isSelected 
                                ? const Icon(Icons.check_circle, color: Colors.green)
                                : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
                            onTap: () {
                              setState(() {
                                _selectedNoteId = note.id;
                              });
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _selectedNoteId != null
              ? () => widget.onReparent(_selectedNoteId!)
              : null,
          child: const Text('Move'),
        ),
      ],
    );
  }
}

class _AddLinkedNoteDialogState extends State<_AddLinkedNoteDialog> {
  String _selectedRelationshipType = RelationshipType.related;
  Note? _selectedNote;
  final TextEditingController _customTypeController = TextEditingController();
  List<Note> _availableNotes = [];

  @override
  void initState() {
    super.initState();
    _loadAvailableNotes();
  }

  @override
  void dispose() {
    _customTypeController.dispose();
    super.dispose();
  }

  Future<void> _loadAvailableNotes() async {
    final appProvider = context.read<AppProvider>();
    final allNotes = appProvider.notes.where((note) => note.id != widget.currentNote.id).toList();
    setState(() {
      _availableNotes = allNotes;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Link Note'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Select a note to link to "${widget.currentNote.title}":',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            if (_availableNotes.isEmpty)
              const Text('No other notes available to link.')
            else
              DropdownButtonFormField<Note>(
                value: _selectedNote,
                decoration: const InputDecoration(
                  labelText: 'Select Note',
                  border: OutlineInputBorder(),
                ),
                items: _availableNotes.map((note) => DropdownMenuItem(
                  value: note,
                  child: Text(note.title),
                )).toList(),
                onChanged: (note) {
                  setState(() {
                    _selectedNote = note;
                  });
                },
              ),
            const SizedBox(height: 16),
            Text(
              'Relationship Type:',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedRelationshipType,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: [
                ...RelationshipType.predefined.map((type) => DropdownMenuItem(
                  value: type,
                  child: Row(
                    children: [
                      Icon(RelationshipType.getIcon(type), size: 20),
                      const SizedBox(width: 8),
                      Text(RelationshipType.getDisplayName(type)),
                    ],
                  ),
                )),
                const DropdownMenuItem(
                  value: 'custom',
                  child: Row(
                    children: [
                      Icon(Icons.edit, size: 20),
                      SizedBox(width: 8),
                      Text('Custom...'),
                    ],
                  ),
                ),
              ],
              onChanged: (value) {
                setState(() {
                  _selectedRelationshipType = value!;
                });
              },
            ),
            if (_selectedRelationshipType == 'custom') ...[
              const SizedBox(height: 16),
              TextField(
                controller: _customTypeController,
                decoration: const InputDecoration(
                  labelText: 'Custom Relationship Type',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) {
                  setState(() {
                    _selectedRelationshipType = value;
                  });
                },
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _selectedNote != null ? () {
            final relationshipType = _selectedRelationshipType == 'custom' 
                ? _customTypeController.text.trim()
                : _selectedRelationshipType;
            if (relationshipType.isNotEmpty) {
              widget.onLink(_selectedNote!.id, relationshipType);
            }
          } : null,
          child: const Text('Link'),
        ),
      ],
    );
  }
}

class _AddTagDialog extends StatefulWidget {
  final Note currentNote;
  final Function(List<String> tagNames) onAddTags;

  const _AddTagDialog({
    required this.currentNote,
    required this.onAddTags,
  });

  @override
  State<_AddTagDialog> createState() => _AddTagDialogState();
}

class _AddTagDialogState extends State<_AddTagDialog> {
  final TextEditingController _tagController = TextEditingController();
  Set<String> _selectedExistingTags = {};
  List<String> _availableTags = [];

  @override
  void initState() {
    super.initState();
    _loadAvailableTags();
  }

  @override
  void dispose() {
    _tagController.dispose();
    super.dispose();
  }

  void _loadAvailableTags() {
    final appProvider = context.read<AppProvider>();
    final allTags = appProvider.getAllAvailableTags();
    // Filter out tags that are already on this note
    final availableTags = allTags.where((tag) => !widget.currentNote.tags.contains(tag)).toList();
    setState(() {
      _availableTags = availableTags;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Tags'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add tags to "${widget.currentNote.title}":',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tagController,
              decoration: const InputDecoration(
                labelText: 'New Tag',
                border: OutlineInputBorder(),
                hintText: 'Enter tag name',
              ),
              onChanged: (value) {
                setState(() {
                  // Clear existing selections when typing
                });
              },
            ),
            if (_availableTags.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Select from existing tags:',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _availableTags.map((tag) => FilterChip(
                  label: Text(tag),
                  selected: _selectedExistingTags.contains(tag),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _selectedExistingTags.add(tag);
                      } else {
                        _selectedExistingTags.remove(tag);
                      }
                    });
                  },
                )).toList(),
              ),
            ],
            if (_selectedExistingTags.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Selected tags:',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _selectedExistingTags.map((tag) => Chip(
                  label: Text(tag),
                  backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                  labelStyle: TextStyle(color: Theme.of(context).colorScheme.primary),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: () {
                    setState(() {
                      _selectedExistingTags.remove(tag);
                    });
                  },
                )).toList(),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _canAddTags() ? () {
            final List<String> tagsToAdd = [];
            
            // Add new tag if entered
            final newTag = _tagController.text.trim();
            if (newTag.isNotEmpty && !widget.currentNote.tags.contains(newTag)) {
              tagsToAdd.add(newTag);
            }
            
            // Add selected existing tags
            tagsToAdd.addAll(_selectedExistingTags);
            
            if (tagsToAdd.isNotEmpty) {
              widget.onAddTags(tagsToAdd);
            }
          } : null,
          child: Text(_selectedExistingTags.length > 0 || _tagController.text.trim().isNotEmpty 
              ? 'Add ${_selectedExistingTags.length + (_tagController.text.trim().isNotEmpty ? 1 : 0)} Tag${_selectedExistingTags.length + (_tagController.text.trim().isNotEmpty ? 1 : 0) > 1 ? 's' : ''}' 
              : 'Add Tag'),
        ),
      ],
    );
  }

  bool _canAddTags() {
    // Check if there are any selected existing tags
    if (_selectedExistingTags.isNotEmpty) {
      return true;
    }
    
    // Check if there's a new tag entered that's not already on the note
    final newTag = _tagController.text.trim();
    return newTag.isNotEmpty && !widget.currentNote.tags.contains(newTag);
  }
}

