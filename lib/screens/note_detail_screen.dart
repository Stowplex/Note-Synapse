import 'dart:async';
import 'dart:io';
import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:re_editor/re_editor.dart';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import '../widgets/drawing_editor.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../models/attachment.dart';
import '../models/relationship.dart';
import '../services/audio_recording_service.dart';
import '../services/ai_service.dart';
import '../widgets/interactive_checkbox_markdown.dart';
import '../widgets/interactive_checkbox_component.dart';
import '../widgets/share_dialog.dart';
import '../widgets/tag_selection_dialog.dart';
import '../widgets/synapse_note_editor.dart';
import '../widgets/block_editor_dialog.dart';
import '../widgets/block_ai_edit_dialog.dart';
import '../widgets/block_diff_preview_dialog.dart';
import '../utils/markdown_block_tracker.dart';
import '../widgets/block_markdown_body.dart';
import '../widgets/block_selection_menu.dart';

import '../utils/date_utils.dart';
import '../utils/file_utils.dart';
import '../utils/file_type_utils.dart';
import 'ai_action_screen.dart';
import 'subnote_edit_screen.dart';
import 'note_action_app_selection_screen.dart';
import 'note_selection_dialog.dart';
import '../widgets/insert_attachment_link_dialog.dart';
import '../services/logger_service.dart';
import '../services/database_service.dart';
import '../services/conversation_service.dart';
import '../services/media_attachment_service.dart';
import '../services/content_ingestion_service.dart';
import '../services/service_locator.dart';
import '../models/conversation.dart';
import '../widgets/pdf_ai_context_dialog.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';

import 'conversation_tree_screen.dart';
import 'immersive_note_screen.dart';
import 'conversation_chat_screen.dart';
import '../utils/remote_image_utils.dart';
import '../models/recurrence_rule.dart';

class NoteDetailScreen extends StatefulWidget {
  final Note note;
  final bool isNewNote;

  const NoteDetailScreen({
    super.key,
    required this.note,
    this.isNewNote = false,
  });

  @override
  State<NoteDetailScreen> createState() => _NoteDetailScreenState();
}

class _NoteDetailScreenState extends State<NoteDetailScreen> {
  late TextEditingController _titleController;
  late CodeLineEditingController _codeController;
  late FocusNode _codeFocusNode;
  bool _isEditing = false;
  bool _hasChanges = false;
  bool _hasBeenSaved = false; // Track if note has been saved to database
  Timer? _autoSaveTimer;
  DateTime? _scheduledAt;
  DateTime? _completeBy;

  String? _dateValidationError;

  // Recurrence state
  RecurrenceRule? _recurrenceRule;
  RecurrenceType _recurrenceType = RecurrenceType.none;
  List<int> _selectedRecurrenceDays = [];
  final TextEditingController _recurrenceIntervalController =
      TextEditingController();

  List<Relationship> _relationships = [];
  List<Note> _linkedNotes = [];
  final DatabaseService _databaseService = DatabaseService();

  // Audio recording state
  AudioRecordingService? _audioService;
  bool _isRecording = false;
  bool _isPlaying = false;
  String? _currentPlayingPath;
  Duration _playingPosition = Duration.zero;
  Duration _playingDuration = Duration.zero;

  // Attachment metadata state
  Map<String, Attachment> _attachmentsMap = {};

  // Multi-block selection state
  bool _isSelectionMode = false;
  Set<int> _selectedBlockIndices = {};
  List<MarkdownBlock> _parsedBlocks = [];
  Offset? _selectionMenuPosition;

  Future<void> _loadAttachments() async {
    if (widget.isNewNote) return;
    final attachments = await _databaseService.getAttachmentsForNote(
      widget.note.id,
    );

    final Map<String, Attachment> tempMap = {};
    for (var a in attachments) {
      final fullPath = await FileUtils.getFullFilePath(
        a.filePath,
        a.isRelativePath,
      );
      tempMap[fullPath] = a;
    }

    if (mounted) {
      setState(() {
        _attachmentsMap = tempMap;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _codeController = CodeLineEditingController.fromText(widget.note.content);
    _codeFocusNode = FocusNode();

    // Initialize date fields for tasks
    if (widget.note.isTask) {
      _scheduledAt = widget.note.scheduledAt != null
          ? DateTime.tryParse(widget.note.scheduledAt!)
          : null;
      _completeBy = widget.note.completeBy != null
          ? DateTime.tryParse(widget.note.completeBy!)
          : null;

      // Initialize recurrence state
      _recurrenceRule = RecurrenceRule.decode(widget.note.recurrenceRule);
      if (_recurrenceRule != null) {
        _recurrenceType = _recurrenceRule!.type;
        _selectedRecurrenceDays = _recurrenceRule!.daysOfWeek ?? [];
        _recurrenceIntervalController.text =
            _recurrenceRule!.intervalDays?.toString() ?? '';
      }
    }

    _titleController.addListener(_onTextChanged);
    _codeController.addListener(_onTextChanged);

    // Start in editing mode for new notes
    if (widget.isNewNote) {
      _isEditing = true;
      _hasBeenSaved = false; // New notes haven't been saved yet
    } else {
      _hasBeenSaved = true; // Existing notes are already in the database
    }

    // Load relationships
    _loadRelationships();

    // Load attachment metadata
    _loadAttachments();

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
  void didUpdateWidget(NoteDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.note.id != oldWidget.note.id ||
        widget.note.updatedAt != oldWidget.note.updatedAt) {
      _loadAttachments();
    }
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

    _codeController.dispose();
    _codeFocusNode.dispose();
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
      LoggerService.debug('Audio playing state changed: $isPlaying');
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
    // Avoid setState during build
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _onTextChanged());
      return;
    }

    if (!_hasChanges) {
      setState(() {
        _hasChanges = true;
      });
    }

    // Auto-save after 2 seconds of no typing
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () {
      if (_hasChanges) {
        unawaited(_autoSave());
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
        unawaited(_autoSave());
      }
    });
  }

  Future<void> _loadRelationships() async {
    try {
      final appProvider = context.read<AppProvider>();
      final relationships = await appProvider.getNoteRelationships(
        widget.note.id,
      );
      final linkedNotes = await appProvider.getLinkedNotes(widget.note.id);

      if (mounted) {
        setState(() {
          _relationships = relationships;
          _linkedNotes = linkedNotes;
        });
      }
    } catch (e) {
      LoggerService.error('Error loading relationships: $e', error: e);
    }
  }

  void _handleBlocksParsed(List<MarkdownBlock> blocks) {
    _parsedBlocks = blocks;
  }

  void _handleBlockDropped(
    int index,
    MarkdownBlock block,
    Offset globalPosition,
  ) {
    if (!mounted) return;

    RenderBox? box = context.findRenderObject() as RenderBox?;
    Offset localPosition = box?.globalToLocal(globalPosition) ?? globalPosition;

    // Adjust y to account for app bar if needed?
    // globalToLocal converts to the coordinate space of the render object.
    // If render object is NoteDetailScreen, it starts below status bar?
    // Let's rely on globalToLocal.

    setState(() {
      _isSelectionMode = true;
      _selectedBlockIndices = {index};
      _selectionMenuPosition = localPosition;
    });
  }

  void _clearSelection() {
    if (!mounted) return;
    setState(() {
      _isSelectionMode = false;
      _selectedBlockIndices = {};
      _selectionMenuPosition = null;
    });
  }

  void _expandSelectionAbove() {
    if (_selectedBlockIndices.isEmpty) return;
    final minIndex = _selectedBlockIndices.reduce((a, b) => a < b ? a : b);
    if (minIndex > 0) {
      setState(() {
        _selectedBlockIndices.add(minIndex - 1);
      });
    }
  }

  void _contractSelectionAbove() {
    if (_selectedBlockIndices.length <= 1) return;
    final minIndex = _selectedBlockIndices.reduce((a, b) => a < b ? a : b);
    setState(() {
      _selectedBlockIndices.remove(minIndex);
    });
  }

  void _expandSelectionBelow() {
    if (_selectedBlockIndices.isEmpty) return;
    final maxIndex = _selectedBlockIndices.reduce((a, b) => a > b ? a : b);
    if (_parsedBlocks.isNotEmpty && maxIndex < _parsedBlocks.length - 1) {
      setState(() {
        _selectedBlockIndices.add(maxIndex + 1);
      });
    }
  }

  void _contractSelectionBelow() {
    if (_selectedBlockIndices.length <= 1) return;
    final maxIndex = _selectedBlockIndices.reduce((a, b) => a > b ? a : b);
    setState(() {
      _selectedBlockIndices.remove(maxIndex);
    });
  }

  Future<void> _handleEditSelection() async {
    if (_selectedBlockIndices.isEmpty) return;

    final sortedIndices = _selectedBlockIndices.toList()..sort();
    final blocksToEdit = sortedIndices.map((i) => _parsedBlocks[i]).toList();

    // Consolidate content
    final tracker = MarkdownBlockTracker();
    // Using \n\n to preserve block separation.
    final initialContent = blocksToEdit.map((b) => b.content).join('\n\n');

    final result = await BlockEditorDialog.show(
      context,
      initialContent,
      onPickImage: () => _pickImageAndReturnMarkdown(context),
      onPickNoteLink: () => _pickNoteLinkAndReturnMarkdown(context),
      onPickAttachmentLink: () => _pickAttachmentLinkAndReturnMarkdown(context),
    );

    if (result == null || !mounted) return;

    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final currentNote = appProvider.notes.firstWhere(
      (n) => n.id == widget.note.id,
      orElse: () => widget.note,
    );

    if (result.result == BlockEditorResult.saved &&
        result.editedContent != null) {
      final newContent = tracker.replaceBlockRange(
        currentNote.content,
        blocksToEdit,
        result.editedContent!,
      );
      _updateNoteContent(newContent);
      _clearSelection();
    } else if (result.result == BlockEditorResult.deleted) {
      final newContent = tracker.deleteBlockRange(
        currentNote.content,
        blocksToEdit,
      );
      _updateNoteContent(newContent);
      _clearSelection();
    }
  }

  Future<void> _handleDeleteSelection() async {
    if (_selectedBlockIndices.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;

    final sortedIndices = _selectedBlockIndices.toList()..sort();
    final blocksToDelete = sortedIndices.map((i) => _parsedBlocks[i]).toList();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteSelection),
        content: Text(l10n.confirmDeleteBlocks(blocksToDelete.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final appProvider = Provider.of<AppProvider>(context, listen: false);
      final currentNote = appProvider.notes.firstWhere(
        (n) => n.id == widget.note.id,
        orElse: () => widget.note,
      );

      final tracker = MarkdownBlockTracker();
      final newContent = tracker.deleteBlockRange(
        currentNote.content,
        blocksToDelete,
      );
      _updateNoteContent(newContent);
      _clearSelection();
    }
  }

  Future<void> _handleAIEditSelection() async {
    if (_selectedBlockIndices.isEmpty) return;

    final sortedIndices = _selectedBlockIndices.toList()..sort();
    final blocksToEdit = sortedIndices.map((i) => _parsedBlocks[i]).toList();
    final originalContent = blocksToEdit.map((b) => b.content).join('\n\n');

    // Show prompt dialog — loading/error handled inline within the dialog
    final transformedContent = await BlockAIEditDialog.show(
      context,
      onTransform: (instruction) async {
        final aiService = getIt<AIService>();
        return await aiService.transformBlock(originalContent, instruction);
      },
    );

    if (transformedContent == null || !mounted) return;

    // Show diff preview
    final accepted = await BlockDiffPreviewDialog.show(
      context,
      original: originalContent,
      transformed: transformedContent,
    );

    if (!accepted || !mounted) return;

    // Apply changes
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final currentNote = appProvider.notes.firstWhere(
      (n) => n.id == widget.note.id,
      orElse: () => widget.note,
    );

    final tracker = MarkdownBlockTracker();
    final newContent = tracker.replaceBlockRange(
      currentNote.content,
      blocksToEdit,
      transformedContent,
    );
    _updateNoteContent(newContent);
    _clearSelection();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

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
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    child: Chip(
                      label: Text(_hasChanges ? l10n.unsaved : l10n.saved),
                      backgroundColor: _hasChanges
                          ? Colors.orange.withOpacity(0.1)
                          : Colors.green.withOpacity(0.1),
                      labelStyle: TextStyle(
                        color: _hasChanges ? Colors.orange : Colors.green,
                        fontWeight: FontWeight.w500,
                      ),
                      avatar: Icon(
                        _hasChanges ? Icons.edit : Icons.check,
                        size: 16,
                        color: _hasChanges ? Colors.orange : Colors.green,
                      ),
                    ),
                  ),
                ] else ...[
                  LongPressDraggable<String>(
                    data: kBlockEditDragData,
                    feedback: Material(
                      elevation: 4.0,
                      shape: const CircleBorder(),
                      child: CircleAvatar(
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primaryContainer,
                        child: Icon(
                          Icons.edit,
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    childWhenDragging: IconButton(
                      icon: Icon(
                        Icons.edit,
                        color: Theme.of(context).disabledColor,
                      ),
                      onPressed: null,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: _startEditing,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.psychology),
                    onPressed: _openAIAction,
                  ),
                  IconButton(
                    icon: const Icon(Icons.apps),
                    onPressed: _openNoteActionApps,
                    tooltip: 'Run Note Action App',
                  ),
                  IconButton(
                    icon: const Icon(Icons.chrome_reader_mode),
                    tooltip: l10n.immersiveMode,
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) =>
                              ImmersiveNoteScreen(notes: [currentNote]),
                        ),
                      );
                    },
                  ),
                  PopupMenuButton(
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'share',
                        child: Row(
                          children: [
                            const Icon(Icons.share),
                            const SizedBox(width: 8),
                            Text(l10n.shareNote),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'fetch_images',
                        child: Row(
                          children: [
                            const Icon(Icons.download),
                            const SizedBox(width: 8),
                            Text(l10n.fetchRemoteImages),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'force_fetch_images',
                        child: Row(
                          children: [
                            const Icon(Icons.cloud_sync),
                            const SizedBox(width: 8),
                            Text(l10n.forceRefetchImages),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete, color: Colors.red),
                            const SizedBox(width: 8),
                            Text(
                              l10n.deleteNote,
                              style: TextStyle(color: Colors.red),
                            ),
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
                              Text(l10n.convertToNote),
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
                              Text(l10n.convertToTask),
                            ],
                          ),
                        ),
                      PopupMenuItem(
                        value: 'archive',
                        child: Row(
                          children: [
                            Icon(
                              currentNote.isArchived
                                  ? Icons.unarchive
                                  : Icons.archive,
                              color: currentNote.isArchived
                                  ? Colors.orange
                                  : Colors.grey[600],
                            ),
                            const SizedBox(width: 8),
                            Text(
                              currentNote.isArchived
                                  ? l10n.unarchiveNote
                                  : l10n.archiveNote,
                              style: TextStyle(
                                color: currentNote.isArchived
                                    ? Colors.orange
                                    : Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    onSelected: (value) {
                      if (value == 'share') {
                        _shareNote();
                      } else if (value == 'fetch_images') {
                        _fetchRemoteImages();
                      } else if (value == 'force_fetch_images') {
                        _fetchRemoteImages(force: true);
                      } else if (value == 'delete') {
                        _deleteNote();
                      } else if (value == 'convert') {
                        _convertNoteType();
                      } else if (value == 'archive') {
                        _toggleArchive();
                      }
                    },
                  ),
                ],
              ],
            ),
            body: _isEditing
                ? _buildEditingView()
                : _buildViewingView(currentNote, l10n),
            bottomNavigationBar: _isEditing ? null : _buildBottomBar(),
          ),
        );
      },
    );
  }

  Future<void> _showImagePicker(BuildContext context) async {
    // Get selected text for alt text
    final sel = _codeController.selection;
    final text = _codeController.text;
    final codeLines = _codeController.value.codeLines;
    final startOff = _getOffsetForPosition(codeLines, sel.start);
    final endOff = _getOffsetForPosition(codeLines, sel.end);
    final selectedText = text.substring(startOff, endOff);

    // Load existing image attachments
    final attachments = widget.isNewNote
        ? <Attachment>[]
        : await _databaseService.getAttachmentsForNote(widget.note.id);

    final imageAttachments = attachments.where((a) {
      final lower = a.filePath.toLowerCase();
      return lower.endsWith('.jpg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.gif');
    }).toList();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _ImagePickerDialog(
        initialAltText: selectedText,
        existingAttachments: imageAttachments,
        onSaveNote: () async {
          // Save note if new with no title
          if (widget.isNewNote && !_hasBeenSaved) {
            final l10n = AppLocalizations.of(context)!;
            if (_titleController.text.trim().isEmpty) {
              _titleController.text = l10n.untitled;
            }
            await _autoSave();
          }
          return widget.note.id;
        },
        onAddAttachment: (File imageFile, String fileName) async {
          // Use existing attachment logic
          final bytes = await imageFile.readAsBytes();
          final relativePath = await FileUtils.saveFileToPrivateStorage(
            bytes,
            fileName,
          );

          // Add to note's attachments
          final currentNote = context.read<AppProvider>().notes.firstWhere(
            (note) => note.id == widget.note.id,
            orElse: () => widget.note,
          );
          final updatedAttachmentPaths = List<String>.from(
            currentNote.attachmentPaths,
          )..add(relativePath);
          final updatedNote = currentNote.copyWith(
            attachmentPaths: updatedAttachmentPaths,
            updatedAt: DateTime.now(),
          );
          await context.read<AppProvider>().updateNote(updatedNote);

          return relativePath;
        },
      ),
    );

    if (result != null) {
      final markdown = '![${result['alt']}](${result['src']})';
      if (selectedText.isNotEmpty) {
        // Replace selected text with markdown
        final sb = StringBuffer();
        sb.write(text.substring(0, startOff));
        sb.write(markdown);
        sb.write(text.substring(endOff));
        _codeController.text = sb.toString();
      } else {
        // Insert at cursor
        _insertText(markdown, selectionOffset: markdown.length);
      }
    }
  }

  /// Similar to _showImagePicker but returns the markdown string instead of inserting
  Future<String?> _pickImageAndReturnMarkdown(BuildContext context) async {
    // Load existing image attachments
    final attachments = widget.isNewNote
        ? <Attachment>[]
        : await _databaseService.getAttachmentsForNote(widget.note.id);

    final imageAttachments = attachments.where((a) {
      final lower = a.filePath.toLowerCase();
      return lower.endsWith('.jpg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.gif');
    }).toList();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _ImagePickerDialog(
        initialAltText: '',
        existingAttachments: imageAttachments,
        onSaveNote: () async {
          // Save note if new with no title
          if (widget.isNewNote && !_hasBeenSaved) {
            final l10n = AppLocalizations.of(context)!;
            if (_titleController.text.trim().isEmpty) {
              _titleController.text = l10n.untitled;
            }
            await _autoSave();
          }
          return widget.note.id;
        },
        onAddAttachment: (File imageFile, String fileName) async {
          // Use existing attachment logic
          final bytes = await imageFile.readAsBytes();
          final relativePath = await FileUtils.saveFileToPrivateStorage(
            bytes,
            fileName,
          );

          // Add to note's attachments
          if (!context.mounted) return relativePath;
          final currentNote = context.read<AppProvider>().notes.firstWhere(
            (note) => note.id == widget.note.id,
            orElse: () => widget.note,
          );
          final updatedAttachmentPaths = List<String>.from(
            currentNote.attachmentPaths,
          )..add(relativePath);
          final updatedNote = currentNote.copyWith(
            attachmentPaths: updatedAttachmentPaths,
            updatedAt: DateTime.now(),
          );
          await context.read<AppProvider>().updateNote(updatedNote);

          return relativePath;
        },
      ),
    );

    if (result != null) {
      return '![${result['alt']}](${result['src']})';
    }
    return null;
  }

  void _insertText(String text, {int selectionOffset = 0}) {
    final selection = _codeController.selection;
    final codeLines = _codeController.value.codeLines;
    final startOffset = _getOffsetForPosition(codeLines, selection.start);
    final endOffset = _getOffsetForPosition(codeLines, selection.end);

    final currentText = _codeController.text;
    final newText =
        currentText.substring(0, startOffset) +
        text +
        currentText.substring(endOffset);

    _codeController.text = newText;

    final newCursorOffset = startOffset + selectionOffset;
    final newPos = _getPositionForOffset(
      _codeController.value.codeLines,
      newCursorOffset,
    );

    _codeController.selection = CodeLineSelection.collapsed(
      index: newPos.index,
      offset: newPos.offset,
    );
  }

  int _getOffsetForPosition(CodeLines codeLines, CodeLinePosition position) {
    int offset = 0;
    for (int i = 0; i < position.index && i < codeLines.length; i++) {
      offset += codeLines[i].text.length + 1; // +1 for newline
    }
    return offset + position.offset;
  }

  CodeLinePosition _getPositionForOffset(CodeLines codeLines, int offset) {
    int currentOffset = 0;
    for (int i = 0; i < codeLines.length; i++) {
      final lineLength = codeLines[i].text.length + 1; // +1 for newline
      if (currentOffset + lineLength > offset) {
        return CodeLinePosition(index: i, offset: offset - currentOffset);
      }
      currentOffset += lineLength;
    }
    if (codeLines.length > 0) {
      return CodeLinePosition(
        index: codeLines.length - 1,
        offset: codeLines.last.text.length,
      );
    }
    return const CodeLinePosition(index: 0, offset: 0);
  }

  Widget _buildViewingView(Note currentNote, AppLocalizations l10n) {
    return NotificationListener<ScrollNotification>(
      onNotification: (scrollNotification) {
        if (_isSelectionMode &&
            scrollNotification is ScrollUpdateNotification) {
          _clearSelection();
        }
        return false;
      },
      child: Stack(
        children: [
          SelectionArea(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 16,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (currentNote.isTask) ...[
                          _buildTaskStatus(currentNote),
                          const SizedBox(height: 16),
                        ],
                        SelectableText(
                          currentNote.title,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: BlockMarkdownBody(
                    key: ValueKey('note_${currentNote.id}'),
                    noteId: currentNote.id,
                    content: currentNote.content,
                    onContentChanged: _updateNoteContent,
                    style: Theme.of(context).textTheme.bodyLarge,
                    onLinkTap: _handleLinkTap,
                    onBlockEditRequested: _handleBlockEditRequest,
                    selectedBlockIndices: _selectedBlockIndices,
                    onBlocksParsed: _handleBlocksParsed,
                    onBlockDropped: _handleBlockDropped,
                    onFetchImage: _handleImageFetch,
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left: 16,
                      right: 16,
                      bottom: 16,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (currentNote.subNotes.isNotEmpty) ...[
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Text(
                                l10n.subNotes,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.add),
                                onPressed: () => _addSubNote(currentNote),
                                tooltip: l10n.addSubNote,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ...currentNote.subNotes.map(
                            (subNote) => Card(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Header with completed toggle and three dot menu
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4.0,
                                    ),
                                    child: Row(
                                      children: [
                                        // Completed status toggle
                                        IconButton(
                                          icon: Icon(
                                            subNote.isCompleted
                                                ? Icons.check_circle
                                                : Icons.radio_button_unchecked,
                                            color: subNote.isCompleted
                                                ? Colors.green
                                                : Colors.grey,
                                          ),
                                          onPressed: () =>
                                              _toggleSubNoteCompletion(subNote),
                                          tooltip: subNote.isCompleted
                                              ? l10n.markIncomplete
                                              : l10n.markComplete,
                                        ),
                                        const Spacer(),
                                        // Three dot menu
                                        PopupMenuButton(
                                          itemBuilder: (context) => [
                                            PopupMenuItem(
                                              value: 'edit',
                                              child: Row(
                                                children: [
                                                  const Icon(Icons.edit),
                                                  const SizedBox(width: 8),
                                                  Text(l10n.edit),
                                                ],
                                              ),
                                            ),
                                            PopupMenuItem(
                                              value: 'reparent',
                                              child: Row(
                                                children: [
                                                  const Icon(
                                                    Icons.move_to_inbox,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Text(l10n.reparentSubNote),
                                                ],
                                              ),
                                            ),
                                            PopupMenuItem(
                                              value: 'delete',
                                              child: Row(
                                                children: [
                                                  const Icon(
                                                    Icons.delete,
                                                    color: Colors.red,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Text(
                                                    l10n.delete,
                                                    style: const TextStyle(
                                                      color: Colors.red,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                          onSelected: (value) {
                                            if (value == 'edit') {
                                              _editSubNote(
                                                currentNote,
                                                subNote,
                                              );
                                            } else if (value == 'reparent') {
                                              _reparentSubNote(
                                                currentNote,
                                                subNote,
                                              );
                                            } else if (value == 'delete') {
                                              _deleteSubNote(
                                                currentNote,
                                                subNote,
                                              );
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16.0,
                                      0.0,
                                      16.0,
                                      16.0,
                                    ),
                                    child: Text(
                                      subNote.name,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            decoration: subNote.isCompleted
                                                ? TextDecoration.lineThrough
                                                : null,
                                            color: subNote.isCompleted
                                                ? Colors.grey
                                                : null,
                                          ),
                                    ),
                                  ),
                                  if (subNote.content.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16.0,
                                        0.0,
                                        16.0,
                                        16.0,
                                      ),
                                      child: SelectionArea(
                                        child: InteractiveCheckboxMarkdown(
                                          key: ValueKey(
                                            'subnote_${subNote.id}',
                                          ),
                                          noteId: currentNote.id,
                                          originalContent: subNote.content,
                                          onContentChanged: (newContent) =>
                                              _updateSubNoteContent(
                                                subNote,
                                                newContent,
                                              ),
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodyMedium,
                                          textDirection: TextDirection.ltr,
                                          onLinkTap: _handleLinkTap,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ] else ...[
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Text(
                                l10n.subNotes,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.add),
                                onPressed: () => _addSubNote(currentNote),
                                tooltip: l10n.addSubNote,
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Text(
                              l10n.tags,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: () => _showAddTagDialog(currentNote),
                              icon: const Icon(Icons.add, size: 16),
                              label: Text(l10n.addTag),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (currentNote.tags.isNotEmpty)
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: currentNote.tags
                                .map(
                                  (tag) => Chip(
                                    label: Text(tag),
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.primary.withOpacity(0.1),
                                    labelStyle: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                    deleteIcon: const Icon(
                                      Icons.close,
                                      size: 16,
                                    ),
                                    onDeleted: () =>
                                        _removeTag(currentNote, tag),
                                  ),
                                )
                                .toList(),
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
                                Icon(
                                  Icons.label_outline,
                                  color: Colors.grey[400],
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  l10n.noTagsYet,
                                  style: TextStyle(color: Colors.grey[600]),
                                ),
                              ],
                            ),
                          ),
                        if (currentNote.attachmentPaths.isNotEmpty) ...[
                          const SizedBox(height: 24),
                          Text(
                            l10n.attachments,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          ...currentNote.attachmentPaths.map(
                            (path) => _buildAttachmentCard(path, currentNote),
                          ),
                        ],
                        if (_linkedNotes.isNotEmpty) ...[
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Text(
                                l10n.linkedNotes,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              const Spacer(),
                              TextButton.icon(
                                onPressed: _addLinkedNote,
                                icon: const Icon(Icons.add, size: 16),
                                label: Text(l10n.addLink),
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
                                l10n.linkedNotes,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              const Spacer(),
                              TextButton.icon(
                                onPressed: _addLinkedNote,
                                icon: const Icon(Icons.add, size: 16),
                                label: Text(l10n.addLink),
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
                                    l10n.noLinkedNotesYet,
                                    style: TextStyle(color: Colors.grey[600]),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Text(
                              l10n.conversations,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const Spacer(),
                            FutureBuilder<int>(
                              future: context
                                  .read<AppProvider>()
                                  .getNoteConversationCount(currentNote.id),
                              builder: (context, snapshot) {
                                if (snapshot.hasData) {
                                  final count = snapshot.data!;
                                  if (count > 0) {
                                    return TextButton.icon(
                                      onPressed: _showConversationsDialog,
                                      icon: const Icon(Icons.chat, size: 16),
                                      label: Text(
                                        l10n.conversationCount(count),
                                      ),
                                    );
                                  } else {
                                    return Text(
                                      l10n.noConversations,
                                      style: TextStyle(color: Colors.grey[600]),
                                    );
                                  }
                                } else {
                                  return Text(
                                    'Loading...',
                                    style: TextStyle(color: Colors.grey[600]),
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        SelectableText(
                          '${l10n.created}: ${_formatDate(currentNote.createdAt)}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.grey[600]),
                        ),
                        if (currentNote.updatedAt != currentNote.createdAt)
                          SelectableText(
                            '${l10n.updated}: ${_formatDate(currentNote.updatedAt)}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: Colors.grey[600]),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_isSelectionMode && _selectionMenuPosition != null)
            Positioned(
              left: (_selectionMenuPosition!.dx - 150).clamp(
                0.0,
                MediaQuery.of(context).size.width - 320,
              ), // Center-ish logic needs refinement
              top: (_selectionMenuPosition!.dy - 60).clamp(
                0.0,
                MediaQuery.of(context).size.height - 100,
              ),
              child: BlockSelectionMenu(
                onExpandAbove: _expandSelectionAbove,
                onContractAbove: _contractSelectionAbove,
                onExpandBelow: _expandSelectionBelow,
                onContractBelow: _contractSelectionBelow,
                onEdit: () => _handleEditSelection(),
                onAIEdit: () => _handleAIEditSelection(),
                onDelete: () => _handleDeleteSelection(),
                onExit: _clearSelection,
                canExpandAbove:
                    _selectedBlockIndices.isNotEmpty &&
                    _selectedBlockIndices.reduce((a, b) => a < b ? a : b) > 0,
                canContractAbove: _selectedBlockIndices.length > 1,
                canExpandBelow:
                    _selectedBlockIndices.isNotEmpty &&
                    _parsedBlocks.isNotEmpty &&
                    _selectedBlockIndices.reduce((a, b) => a > b ? a : b) <
                        _parsedBlocks.length - 1,
                canContractBelow: _selectedBlockIndices.length > 1,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEditingView() {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: _titleController,
            decoration: InputDecoration(
              labelText: l10n.title,
              border: const OutlineInputBorder(),
            ),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          if (widget.note.isTask) ...[
            _buildDateSelectionFields(),
            const SizedBox(height: 16),
            _buildRecurrenceFields(),
            const SizedBox(height: 16),
          ],
          Expanded(
            child: SynapseNoteEditor(
              controller: _codeController,
              focusNode: _codeFocusNode,
              onPickImage: () => _showImagePicker(context),
              onPickNoteLink: () => _showNoteLinkPicker(context),
              onPickAttachmentLink: () => _showAttachmentLinkPicker(context),
              language: 'markdown',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showNoteLinkPicker(BuildContext context) async {
    final result = await _pickNoteLinkAndReturnMarkdown(context);
    if (result != null) {
      _insertText(result);
    }
  }

  Future<void> _showAttachmentLinkPicker(BuildContext context) async {
    final result = await _pickAttachmentLinkAndReturnMarkdown(context);
    if (result != null) {
      _insertText(result);
    }
  }

  /// Like _showNoteLinkPicker but returns the markdown string instead of inserting
  Future<String?> _pickNoteLinkAndReturnMarkdown(BuildContext context) async {
    return showDialog<String>(
      context: context,
      builder: (context) => _NoteLinkPickerDialog(
        existingLinkedNotes: _linkedNotes,
        onLinkNote: (newNote) async {
          await _addRelationship(newNote.id);
        },
      ),
    );
  }

  /// Like _showAttachmentLinkPicker but returns the markdown string instead of inserting
  Future<String?> _pickAttachmentLinkAndReturnMarkdown(
    BuildContext context,
  ) async {
    return showDialog<String>(
      context: context,
      builder: (context) => const InsertAttachmentLinkDialog(),
    );
  }

  Future<void> _addRelationship(String otherNoteId) async {
    final appProvider = context.read<AppProvider>();
    await appProvider.createNoteRelationships(widget.note.id, [
      otherNoteId,
    ], 'references');
    await _loadRelationships();
  }

  void _handleToolbarImageAdded(String imagePath) async {
    // The image is already saved to the attachments directory by the picker/toolbar logic if needed.
    // But wait, the toolbar logic I wrote:
    // 1. _pickFromDevice calls onImageSelected with path.
    // 2. _showImagePicker calls onImageAdded(imagePath).
    // But it doesn't actually copy the file to the note's specific attachment folder if it's a new file from outside.
    // The toolbar's _pickFromDevice just returns the XFile path.
    // So I need to handle the copying here if it's not already in the attachments folder.

    final l10n = AppLocalizations.of(context)!;
    try {
      final file = File(imagePath);
      final fileName = p.basename(imagePath);

      // Check if it's already in the attachments folder
      // We assume attachments are stored in a specific way.
      // FileUtils.saveFileToPrivateStorage handles this.

      // If the path is already relative or in the private storage, we might not need to copy.
      // But the picker returns a cache path or gallery path.

      final bytes = await file.readAsBytes();
      final relativePath = await FileUtils.saveFileToPrivateStorage(
        bytes,
        fileName,
      );

      final currentNote = context.read<AppProvider>().notes.firstWhere(
        (note) => note.id == widget.note.id,
        orElse: () => widget.note,
      );

      final updatedAttachmentPaths = List<String>.from(
        currentNote.attachmentPaths,
      );
      updatedAttachmentPaths.add(relativePath);

      final updatedNote = currentNote.copyWith(
        attachmentPaths: updatedAttachmentPaths,
        updatedAt: DateTime.now(),
      );

      await context.read<AppProvider>().updateNote(updatedNote);

      // Update local map
      await _loadAttachments();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.photoAddedToNote),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      LoggerService.error('Error adding image from toolbar: $e', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error adding image: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildDateSelectionFields() {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () => _selectScheduledAt(),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: l10n.scheduledAt,
                    border: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: _dateValidationError != null
                            ? Colors.red
                            : Colors.grey,
                      ),
                    ),
                  ),
                  child: Text(
                    _scheduledAt != null
                        ? AppDateUtils.formatDateNumeric(_scheduledAt!, context)
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
                    labelText: l10n.completeBy,
                    border: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: _dateValidationError != null
                            ? Colors.red
                            : Colors.grey,
                      ),
                    ),
                  ),
                  child: Text(
                    _completeBy != null
                        ? AppDateUtils.formatDateNumeric(_completeBy!, context)
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
              style: TextStyle(color: Colors.red[600], fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRecurrenceFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<RecurrenceType>(
          value: _recurrenceType,
          items: RecurrenceType.values.map((type) {
            String label;
            switch (type) {
              case RecurrenceType.none:
                label = 'No Recurrence'; // Todo: l10n
                break;
              case RecurrenceType.weekly:
                label = 'Weekly'; // Todo: l10n
                break;
              case RecurrenceType.interval:
                label = 'Repeat every X days'; // Todo: l10n
                break;
            }
            return DropdownMenuItem(value: type, child: Text(label));
          }).toList(),
          onChanged: (value) {
            setState(() {
              _recurrenceType = value!;
              _hasChanges = true;
            });
            _autoSave();
          },
          decoration: InputDecoration(
            labelText: 'Recurrence', // Todo: l10n
            border: OutlineInputBorder(),
          ),
        ),
        if (_recurrenceType == RecurrenceType.weekly) ...[
          const SizedBox(height: 8),
          Text(
            'Days of week',
            style: Theme.of(context).textTheme.titleSmall,
          ), // Todo: l10n
          Wrap(
            spacing: 8,
            children: [
              for (int i = 1; i <= 7; i++)
                FilterChip(
                  label: Text(_getDayLabel(i)),
                  selected: _selectedRecurrenceDays.contains(i),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        if (!_selectedRecurrenceDays.contains(i)) {
                          _selectedRecurrenceDays.add(i);
                        }
                      } else {
                        _selectedRecurrenceDays.remove(i);
                      }
                      _selectedRecurrenceDays.sort();
                      _hasChanges = true;
                    });
                    _autoSave();
                  },
                ),
            ],
          ),
        ],
        if (_recurrenceType == RecurrenceType.interval) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _recurrenceIntervalController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Interval (Days)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) {
              setState(() {
                _hasChanges = true;
              });
              _autoSave();
            },
          ),
        ],
      ],
    );
  }

  String _getDayLabel(int day) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[day - 1];
  }

  Widget _buildTaskStatus(Note currentNote) {
    if (!currentNote.isTask) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;

    return Card(
      color: _getStatusColor().withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(_getStatusIcon(), color: _getStatusColor(), size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '${l10n.status}: ',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: _getStatusColor(),
                            ),
                      ),
                      _buildStatusDropdown(currentNote),
                    ],
                  ),
                  if (currentNote.scheduledAt != null)
                    SelectableText(
                      '${l10n.scheduled}: ${AppDateUtils.formatDateForDisplayLocalized(currentNote.scheduledAt, context)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  if (currentNote.completeBy != null)
                    SelectableText(
                      '${l10n.due}: ${AppDateUtils.formatDateForDisplayLocalized(currentNote.completeBy, context)}',
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
          _dateValidationError =
              'Complete By must be no earlier than Schedule At';
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
    final l10n = AppLocalizations.of(context)!;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: Colors.grey[300]!)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_audioService != null && _isRecording) _buildRecordingIndicator(),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _takePhoto,
                  icon: const Icon(Icons.camera_alt),
                  label: Text(l10n.takePhoto),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _addAttachment,
                  icon: const Icon(Icons.attach_file),
                  label: Text(l10n.attach),
                ),
              ),
              if (_audioService != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isRecording ? _stopRecording : _startRecording,
                    icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                    label: Text(
                      _isRecording ? l10n.stopRecording : l10n.recordAudio,
                    ),
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
                  style: TextStyle(color: Colors.red[700], fontSize: 12),
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
    final l10n = AppLocalizations.of(context)!;
    // Get the current note from the provider
    final currentNote = context.read<AppProvider>().notes.firstWhere(
      (note) => note.id == widget.note.id,
      orElse: () => widget.note,
    );
    switch (currentNote.status) {
      case TaskStatus.complete:
        return l10n.completed;
      case TaskStatus.inProgress:
        return l10n.inProgress;
      case TaskStatus.abandoned:
        return l10n.cancelled;
      case TaskStatus.todo:
      default:
        return l10n.toDo;
    }
  }

  String _formatDate(DateTime date) {
    final locale = Localizations.localeOf(context);
    String dateStr;

    // Format date part based on locale
    if (locale.languageCode == 'zh') {
      dateStr =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    } else {
      // Default to mm/dd/yyyy for English and other locales
      dateStr =
          '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}/${date.year}';
    }

    return '$dateStr at ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  void _startEditing() {
    // Get the current note from the provider to ensure we have the latest content
    final currentNote = context.read<AppProvider>().notes.firstWhere(
      (note) => note.id == widget.note.id,
      orElse: () => widget.note,
    );

    // Update controllers with the latest content
    _titleController.text = currentNote.title;
    _codeController.text = currentNote.content;

    // Update date fields for tasks
    if (currentNote.isTask) {
      _scheduledAt = currentNote.scheduledAt != null
          ? DateTime.tryParse(currentNote.scheduledAt!)
          : null;
      _completeBy = currentNote.completeBy != null
          ? DateTime.tryParse(currentNote.completeBy!)
          : null;

      // Initialize recurrence state
      _recurrenceRule = RecurrenceRule.decode(currentNote.recurrenceRule);
      if (_recurrenceRule != null) {
        _recurrenceType = _recurrenceRule!.type;
        _selectedRecurrenceDays = _recurrenceRule!.daysOfWeek ?? [];
        _recurrenceIntervalController.text =
            _recurrenceRule!.intervalDays?.toString() ?? '';
      } else {
        _recurrenceType = RecurrenceType.none;
        _selectedRecurrenceDays = [];
        _recurrenceIntervalController.clear();
      }
    }

    setState(() {
      _isEditing = true;
      _hasChanges = false;
    });
  }

  void _cancelEditing() {
    // Get the current note from the provider
    final currentNote = context.read<AppProvider>().notes.firstWhere(
      (note) => note.id == widget.note.id,
      orElse: () => widget.note,
    );

    setState(() {
      _isEditing = false;
      _hasChanges = false;
      _titleController.text = currentNote.title;
      _codeController.text = currentNote.content;
      _dateValidationError = null;

      // Reset date fields for tasks
      if (currentNote.isTask) {
        _scheduledAt = currentNote.scheduledAt != null
            ? DateTime.tryParse(currentNote.scheduledAt!)
            : null;
        _completeBy = currentNote.completeBy != null
            ? DateTime.tryParse(currentNote.completeBy!)
            : null;

        // Reset recurrence state
        _recurrenceRule = RecurrenceRule.decode(currentNote.recurrenceRule);
        if (_recurrenceRule != null) {
          _recurrenceType = _recurrenceRule!.type;
          _selectedRecurrenceDays = _recurrenceRule!.daysOfWeek ?? [];
          _recurrenceIntervalController.text =
              _recurrenceRule!.intervalDays?.toString() ?? '';
        } else {
          _recurrenceType = RecurrenceType.none;
          _selectedRecurrenceDays = [];
          _recurrenceIntervalController.clear();
        }
      }
    });
  }

  Future<void> _autoSave() async {
    final l10n = AppLocalizations.of(context)!;
    if (_titleController.text.trim().isEmpty &&
        _codeController.text.trim().isEmpty) {
      return; // Don't save empty notes
    }

    // Don't save if there are validation errors
    if (_dateValidationError != null) {
      return;
    }

    // Get the current note from the provider to preserve any tags that were added
    final appProvider = context.read<AppProvider>();
    final currentNote = appProvider.notes.firstWhere(
      (note) => note.id == widget.note.id,
      orElse: () => widget.note,
    );

    // We no longer automatically download images here to prevent unwanted data usage.
    RemoteImageDownloadReport? downloadReport;
    /*
    final remoteImages = RemoteImageUtils.extractRemoteImages(
      _codeController.text,
    );
    if (remoteImages.isNotEmpty) {
      downloadReport = await MediaAttachmentService.downloadRemoteImages(
        noteId: currentNote.id,
        imageUrls: remoteImages.map((image) => image.url),
      );
    }
    */

    final updatedNote = currentNote.copyWith(
      title: _titleController.text.trim().isEmpty
          ? 'Untitled'
          : _titleController.text.trim(),
      content: _codeController.text.trim(),
      updatedAt: DateTime.now(),
      scheduledAt: _scheduledAt != null
          ? AppDateUtils.formatDateOnly(_scheduledAt!)
          : null,
      completeBy: _completeBy != null
          ? AppDateUtils.formatDateOnly(_completeBy!)
          : null,
      recurrenceRule: RecurrenceRule.encode(
        RecurrenceRule(
          type: _recurrenceType,
          daysOfWeek: _recurrenceType == RecurrenceType.weekly
              ? _selectedRecurrenceDays
              : null,
          intervalDays: _recurrenceType == RecurrenceType.interval
              ? int.tryParse(_recurrenceIntervalController.text)
              : null,
        ),
      ),
      attachmentPaths: _mergeAttachmentPaths(
        currentNote.attachmentPaths,
        downloadReport?.urlToRelativePath.values ?? const [],
      ),
    );

    final bool isFirstSave = !_hasBeenSaved;

    try {
      if (!_hasBeenSaved) {
        await appProvider.addNote(updatedNote);
        setState(() {
          _hasBeenSaved = true; // Mark as saved after first insert
        });
      } else {
        await appProvider.updateNote(updatedNote);
      }

      setState(() {
        _hasChanges = false;
      });

      if ((downloadReport?.failedUrls.isNotEmpty ?? false) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.mediaDownloadFailed(downloadReport!.failedUrls.length),
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }

      // Trigger AI Ingestion ONLY on first save (new note) AND if summary doesn't exist
      if (isFirstSave && !updatedNote.content.contains('> [!SUMMARY]')) {
        getIt<ContentIngestionService>().processNote(
          updatedNote,
          appProvider,
          onMessage: (msg) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(msg),
                  duration: const Duration(seconds: 4),
                ),
              );
            }
          },
          onError: (err) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(err), backgroundColor: Colors.red),
              );
            }
          },
          onSuccess: () {
            if (mounted) {
              // Refresh local state if content changed
              setState(() {
                // We need to fetch the updated content from provider
                final freshNote = appProvider.notes.firstWhere(
                  (n) => n.id == updatedNote.id,
                  orElse: () => updatedNote,
                );
                if (freshNote.content != _codeController.text) {
                  _codeController.text = freshNote.content;
                }
              });
            }
          },
        );
      }
    } catch (e, stackTrace) {
      LoggerService.error(
        'Auto-save failed: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  List<String> _mergeAttachmentPaths(
    List<String> base,
    Iterable<String> additional,
  ) {
    final merged = <String>[];
    final seen = <String>{};

    void addPath(String path) {
      if (path.isEmpty) return;
      final normalized = _normalizeAttachmentPath(path);
      final key = normalized.toLowerCase();
      if (seen.add(key)) {
        merged.add(normalized);
      }
    }

    for (final path in base) {
      addPath(path);
    }
    for (final path in additional) {
      addPath(path);
    }
    return merged;
  }

  String _normalizeAttachmentPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    const marker = 'attachments/';
    final index = normalized.lastIndexOf(marker);
    if (index != -1) {
      return normalized.substring(index);
    }
    return path;
  }

  Future<void> _fetchRemoteImages({bool force = false}) async {
    final l10n = AppLocalizations.of(context)!;
    final remoteUrls = RemoteImageUtils.extractRemoteImages(
      _codeController.text,
    ).map((image) => image.url).toSet();

    if (remoteUrls.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.mediaDownloadNoneAvailable)),
        );
      }
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final report = await MediaAttachmentService.downloadRemoteImages(
        noteId: widget.note.id,
        imageUrls: remoteUrls,
        force: force,
      );

      if (report.downloadedRelativePaths.isEmpty && report.failedUrls.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.mediaDownloadAlreadyCached)),
          );
        }
        return;
      }

      final appProvider = context.read<AppProvider>();
      final currentNote = appProvider.notes.firstWhere(
        (note) => note.id == widget.note.id,
        orElse: () => widget.note,
      );

      final updatedNote = currentNote.copyWith(
        attachmentPaths: _mergeAttachmentPaths(
          currentNote.attachmentPaths,
          report.urlToRelativePath.values,
        ),
        updatedAt: DateTime.now(),
      );

      await appProvider.updateNote(updatedNote);

      if (!mounted) {
        return;
      }

      if (report.failedUrls.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.mediaDownloadSuccess(report.downloadedRelativePaths.length),
            ),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.mediaDownloadPartial(
                report.downloadedRelativePaths.length,
                report.failedUrls.length,
              ),
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.mediaDownloadFailedGeneric(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  Future<void> _handleImageFetch(String url) async {
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.fetchingImage ?? 'Fetching image...'),
        duration: const Duration(seconds: 1),
      ),
    );

    try {
      final report = await MediaAttachmentService.downloadRemoteImages(
        noteId: widget.note.id,
        imageUrls: [url],
        force: true,
      );

      if (report.downloadedRelativePaths.isNotEmpty) {
        final appProvider = context.read<AppProvider>();
        final currentNote = appProvider.notes.firstWhere(
          (note) => note.id == widget.note.id,
          orElse: () => widget.note,
        );

        final updatedNote = currentNote.copyWith(
          attachmentPaths: _mergeAttachmentPaths(
            currentNote.attachmentPaths,
            report.urlToRelativePath.values,
          ),
          updatedAt: DateTime.now(),
        );

        await appProvider.updateNote(updatedNote);
        setState(() {}); // Rebuild to show the fetched image
      } else if (report.failedUrls.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.mediaDownloadFailed(1))));
        }
      }
    } catch (e) {
      LoggerService.error('Error fetching single image: $e', error: e);
    }
  }

  void _deleteNote() async {
    // Check if there are associated conversations
    final appProvider = context.read<AppProvider>();
    final conversationCount = await appProvider.getNoteConversationCount(
      widget.note.id,
    );

    if (conversationCount > 0) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete Note'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('This note is associated with active conversations.'),
              const SizedBox(height: 8),
              Text(
                'Deleting this note will remove it from $conversationCount conversation${conversationCount == 1 ? '' : 's'}.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 16),
              const Text('Are you sure you want to delete this note?'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _showConversationsDialog();
              },
              child: const Text('View Conversations'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _confirmDeleteNote();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete Anyway'),
            ),
          ],
        ),
      );
    } else {
      _confirmDeleteNote();
    }
  }

  void _confirmDeleteNote() {
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
    // Get the current note from the provider to preserve any tags that were added
    final currentNote = context.read<AppProvider>().notes.firstWhere(
      (note) => note.id == widget.note.id,
      orElse: () => widget.note,
    );

    final newType = currentNote.isTask ? NoteType.note : NoteType.task;
    final updatedNote = currentNote.copyWith(
      type: newType,
      updatedAt: DateTime.now(),
    );

    context.read<AppProvider>().updateNote(updatedNote);
    Navigator.pop(context);
  }

  void _toggleArchive() {
    final currentNote = context.read<AppProvider>().notes.firstWhere(
      (note) => note.id == widget.note.id,
      orElse: () => widget.note,
    );

    // Check if trying to archive a pinned note
    if (!currentNote.isArchived && currentNote.pinned) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Cannot Archive Pinned Note'),
          content: const Text(
            'Please unpin the note first before archiving it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final action = currentNote.isArchived ? 'unarchive' : 'archive';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${action == 'archive' ? 'Archive' : 'Unarchive'} Note'),
        content: Text('Are you sure you want to $action this note?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              final updatedNote = currentNote.copyWith(
                isArchived: !currentNote.isArchived,
                pinned: currentNote.isArchived
                    ? currentNote.pinned
                    : false, // Unpin when archiving
                updatedAt: DateTime.now(),
              );
              context.read<AppProvider>().updateNote(updatedNote);
              Navigator.pop(context);
            },
            child: Text(action == 'archive' ? 'Archive' : 'Unarchive'),
          ),
        ],
      ),
    );
  }

  void _toggleSubNoteCompletion(SubNote subNote) {
    context.read<AppProvider>().toggleSubNoteCompletion(
      widget.note.id,
      subNote.id,
    );
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
        builder: (context) =>
            SubNoteEditScreen(parentNote: note, subNote: subNote),
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
              context.read<AppProvider>().deleteSubNoteFromNote(
                note.id,
                subNote.id,
              );
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _updateNote(Note newNote) {
    setState(() {
      _titleController.text = newNote.title;
      _codeController.text = newNote.content;
      if (newNote.isTask) {
        _scheduledAt = newNote.scheduledAt != null
            ? DateTime.tryParse(newNote.scheduledAt!)
            : null;
        _completeBy = newNote.completeBy != null
            ? DateTime.tryParse(newNote.completeBy!)
            : null;
      }
    });
  }

  void _openAIAction() async {
    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AIActionScreen(selectedNotes: [widget.note]),
      ),
    );

    if (result != null && result is Note) {
      _updateNote(result);
    }
  }

  void _openNoteActionApps() {
    // Get the current note from the provider to include any attachments that were added
    final currentNote = context.read<AppProvider>().notes.firstWhere(
      (note) => note.id == widget.note.id,
      orElse: () => widget.note,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            NoteActionAppSelectionScreen(selectedNotes: [currentNote]),
      ),
    );
  }

  void _shareNote() {
    // Get the current note from the provider to include any attachments that were added
    final currentNote = context.read<AppProvider>().notes.firstWhere(
      (note) => note.id == widget.note.id,
      orElse: () => widget.note,
    );

    showDialog(
      context: context,
      builder: (context) =>
          ShareDialog(notes: [currentNote], title: currentNote.title),
    );
  }

  Widget _buildAttachmentCard(String attachmentPath, Note currentNote) {
    final l10n = AppLocalizations.of(context)!;
    final fileName = attachmentPath.split('/').last;

    // The attachmentPath should already be an absolute path when loaded from the database
    // If it's not, there's an issue with the database service
    final file = File(attachmentPath);
    final fileExists = file.existsSync();
    final isAudioFile = _isAudioFile(fileName);
    final isCurrentlyPlaying =
        _isPlaying && _currentPlayingPath == attachmentPath;

    // Check if this PDF has a custom AI context config
    final hasCustomAiContext =
        fileName.toLowerCase().endsWith('.pdf') &&
        _attachmentsMap[attachmentPath]?.getAiContextConfig() != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: hasCustomAiContext
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              ),
            )
          : null,
      child: InkWell(
        onTap: fileExists && !isAudioFile
            ? () => FileUtils.openFile(attachmentPath, context)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _getFileIcon(fileName),
                    color: fileExists ? null : Colors.grey,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          fileName,
                          style: TextStyle(
                            color: fileExists ? null : Colors.grey,
                            fontSize: 16,
                          ),
                          maxLines: 3,
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          fileExists
                              ? _formatFileSize(file.lengthSync())
                              : 'File not found',
                          style: TextStyle(
                            color: fileExists ? Colors.grey[600] : Colors.red,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isAudioFile &&
                          fileExists &&
                          _audioService != null) ...[
                        IconButton(
                          icon: Icon(
                            isCurrentlyPlaying ? Icons.pause : Icons.play_arrow,
                          ),
                          onPressed: () => _toggleAudioPlayback(attachmentPath),
                          tooltip: isCurrentlyPlaying ? 'Pause' : 'Play',
                          padding: const EdgeInsets.all(8),
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                          ),
                        ),
                        if (isCurrentlyPlaying)
                          IconButton(
                            icon: const Icon(Icons.stop),
                            onPressed: () => _stopAudioPlayback(),
                            tooltip: 'Stop',
                            padding: const EdgeInsets.all(8),
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                          ),
                        IconButton(
                          icon: const Icon(Icons.text_fields),
                          onPressed: () => _transcribeAudio(attachmentPath),
                          tooltip: 'Transcribe with AI',
                          padding: const EdgeInsets.all(8),
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                          ),
                        ),
                      ],
                      // Unified popup menu for all attachments
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert),
                        tooltip: 'Options',
                        padding: const EdgeInsets.all(8),
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 40,
                        ),
                        onSelected: (value) async {
                          switch (value) {
                            case 'open':
                              FileUtils.openFile(attachmentPath, context);
                              break;
                            case 'open_immersive':
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (context) => ImmersiveNoteScreen(
                                    notes: [currentNote],
                                    initialAttachmentPath: attachmentPath,
                                  ),
                                ),
                              );
                              break;
                            case 'toggle_ai':
                              await _toggleAiContext(attachmentPath);
                              break;
                            case 'configure_ai_range':
                              await _showPdfAiContextDialog(attachmentPath);
                              break;
                            case 'delete':
                              await _removeAttachment(
                                attachmentPath,
                                currentNote,
                              );
                              break;
                          }
                        },
                        itemBuilder: (context) {
                          final includeInAI =
                              _attachmentsMap[attachmentPath]
                                  ?.includeInAIContext ??
                              true;
                          final isPdf = fileName.toLowerCase().endsWith('.pdf');
                          final hasCustomAiRange =
                              _attachmentsMap[attachmentPath]
                                  ?.getAiContextConfig() !=
                              null;

                          return [
                            if (fileExists && !isAudioFile)
                              const PopupMenuItem<String>(
                                value: 'open',
                                child: Row(
                                  children: [
                                    Icon(Icons.open_in_new),
                                    SizedBox(width: 12),
                                    Text('Open'),
                                  ],
                                ),
                              ),
                            if (fileExists &&
                                (FileTypeUtils.getFileCategory(
                                          FileTypeUtils.getFileExtension(
                                            fileName,
                                          ),
                                        ) ==
                                        'image' ||
                                    FileTypeUtils.getFileExtension(fileName) ==
                                        'pdf'))
                              PopupMenuItem<String>(
                                value: 'open_immersive',
                                child: Row(
                                  children: [
                                    const Icon(Icons.chrome_reader_mode),
                                    const SizedBox(width: 12),
                                    Text(l10n.immersiveMode),
                                  ],
                                ),
                              ),
                            PopupMenuItem<String>(
                              value: 'toggle_ai',
                              child: Row(
                                children: [
                                  Icon(
                                    includeInAI
                                        ? Icons.check_box
                                        : Icons.check_box_outline_blank,
                                    color: includeInAI
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                                  const SizedBox(width: 12),
                                  const Text('Include in AI Context'),
                                ],
                              ),
                            ),
                            if (isPdf)
                              PopupMenuItem<String>(
                                value: 'configure_ai_range',
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.tune,
                                      color: hasCustomAiRange
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : null,
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      hasCustomAiRange
                                          ? 'Edit AI Context Range'
                                          : 'Configure AI Context Range',
                                    ),
                                  ],
                                ),
                              ),
                            const PopupMenuDivider(),
                            PopupMenuItem<String>(
                              value: 'delete',
                              child: Row(
                                children: [
                                  Icon(Icons.delete, color: Colors.red),
                                  const SizedBox(width: 12),
                                  Text(
                                    l10n.removeAttachmentTooltip,
                                    style: const TextStyle(color: Colors.red),
                                  ),
                                ],
                              ),
                            ),
                          ];
                        },
                      ),
                    ],
                  ),
                ],
              ),
              if (isAudioFile && fileExists && _audioService != null) ...[
                const SizedBox(height: 8),
                _buildAudioPlayer(attachmentPath, isCurrentlyPlaying),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAudioPlayer(String attachmentPath, bool isCurrentlyPlaying) {
    return Column(
      children: [
        if (isCurrentlyPlaying) ...[
          Slider(
            value: _playingDuration.inMilliseconds > 0
                ? _playingPosition.inMilliseconds /
                      _playingDuration.inMilliseconds
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
    final extension = FileTypeUtils.getFileExtension(fileName);
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
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _removeAttachment(
    String attachmentPath,
    Note currentNote,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      // Show confirmation dialog
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.removeAttachment),
          content: Text(
            l10n.removeAttachmentConfirm(attachmentPath.split('/').last),
          ),
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
        final updatedAttachmentPaths = List<String>.from(
          currentNote.attachmentPaths,
        );
        updatedAttachmentPaths.remove(attachmentPath);

        final updatedNote = currentNote.copyWith(
          attachmentPaths: updatedAttachmentPaths,
          updatedAt: DateTime.now(),
        );

        // Update the note in the database
        await context.read<AppProvider>().updateNote(updatedNote);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.attachmentRemoved),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${l10n.errorRemovingAttachment}: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _toggleAiContext(String attachmentPath) async {
    final currentAttachment = _attachmentsMap[attachmentPath];
    final currentStatus = currentAttachment?.includeInAIContext ?? true;
    final newStatus = !currentStatus;

    LoggerService.debug(
      'Toggling AI Context for ${attachmentPath.split('/').last}: $currentStatus -> $newStatus',
    );

    // Optimistic update
    setState(() {
      if (currentAttachment != null) {
        _attachmentsMap[attachmentPath] = currentAttachment.copyWith(
          includeInAIContext: newStatus,
        );
      }
    });

    try {
      if (currentAttachment != null) {
        await _databaseService.updateAttachmentAIContext(
          widget.note.id,
          currentAttachment.filePath,
          newStatus,
        );
      }
    } catch (e) {
      LoggerService.error('Failed to update database: $e');
      // Revert optimistic update on error
      setState(() {
        if (currentAttachment != null) {
          _attachmentsMap[attachmentPath] = currentAttachment;
        }
      });
    }

    // Reload to ensure consistency
    await _loadAttachments();
  }

  Future<void> _showPdfAiContextDialog(String attachmentPath) async {
    final attachment = _attachmentsMap[attachmentPath];
    if (attachment == null) return;

    final currentConfig = attachment.getAiContextConfig();

    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    // Load the PDF to get outline and page count
    PdfDocument? pdfDocument;
    List<PdfOutlineNode>? outline;
    int totalPages = 0;

    try {
      final absPath = await attachment.getAbsolutePath();
      LoggerService.debug('Loading PDF for AI context dialog: $absPath');

      // Ensure Pdfrx cache directory is set (required for programmatic PDF loading)
      Pdfrx.getCacheDirectory ??= () async {
        final tempDir = await getTemporaryDirectory();
        return tempDir.path;
      };

      pdfDocument = await PdfDocument.openFile(absPath);
      totalPages = pdfDocument.pages.length;
      outline = await pdfDocument.loadOutline();
      LoggerService.debug(
        'PDF loaded: $totalPages pages, outline has ${outline?.length ?? 0} items',
      );
      if (outline != null && outline.isNotEmpty) {
        LoggerService.debug('First outline item: ${outline.first.title}');
      }
    } catch (e) {
      LoggerService.error('Failed to load PDF for AI context dialog: $e');
    }

    // Close loading indicator
    if (mounted) Navigator.pop(context);
    if (!mounted) {
      pdfDocument?.dispose();
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => PdfAiContextDialog(
        attachment: attachment,
        currentConfig: currentConfig,
        outline: outline,
        totalPages: totalPages,
        onSave: (config) async {
          // Build new metadata
          final currentMetadata = Map<String, dynamic>.from(
            attachment.metadata ?? {},
          );
          if (config == null) {
            currentMetadata.remove('aiContextConfig');
          } else {
            currentMetadata['aiContextConfig'] = config.toJson();
          }

          // Update database
          await _databaseService.updateAttachmentMetadata(
            attachment.id,
            currentMetadata.isEmpty ? null : currentMetadata,
          );

          // Reload attachments
          await _loadAttachments();
        },
      ),
    );

    // Dispose PDF document after dialog is closed
    pdfDocument?.dispose();
  }

  Future<void> _addAttachment() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: true, // Load file data into memory
      );

      if (result != null && result.files.isNotEmpty) {
        final currentNote = context.read<AppProvider>().notes.firstWhere(
          (note) => note.id == widget.note.id,
          orElse: () => widget.note,
        );

        // Get existing attachment paths
        final updatedAttachmentPaths = List<String>.from(
          currentNote.attachmentPaths,
        );

        // Process and add new attachment paths
        for (final file in result.files) {
          try {
            // Read file bytes and save to private storage
            final bytes = file.bytes ?? await File(file.path!).readAsBytes();
            final relativePath = await FileUtils.saveFileToPrivateStorage(
              bytes,
              file.name,
            );
            updatedAttachmentPaths.add(relativePath);
          } catch (e) {
            LoggerService.error(
              'Error processing file ${file.name}: $e',
              error: e,
            );
            // Continue with other files even if one fails
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
            content: Text(l10n.addedAttachments(result.files.length)),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${l10n.errorAddingAttachment}: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _takePhoto() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );

      if (image != null) {
        // Read file bytes and save to private storage
        final file = File(image.path);
        final bytes = await file.readAsBytes();
        final relativePath = await FileUtils.saveFileToPrivateStorage(
          bytes,
          image.name,
        );

        final currentNote = context.read<AppProvider>().notes.firstWhere(
          (note) => note.id == widget.note.id,
          orElse: () => widget.note,
        );

        // Get existing attachment paths
        final updatedAttachmentPaths = List<String>.from(
          currentNote.attachmentPaths,
        );

        // Add the new photo path (relative path)
        updatedAttachmentPaths.add(relativePath);

        // Update the note
        final updatedNote = currentNote.copyWith(
          attachmentPaths: updatedAttachmentPaths,
          updatedAt: DateTime.now(),
        );

        await context.read<AppProvider>().updateNote(updatedNote);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.photoAddedToNote),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.errorTakingPhoto(e.toString())),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildStatusDropdown(Note currentNote) {
    final l10n = AppLocalizations.of(context)!;
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
              Text(l10n.toDo),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.inProgress,
          child: Row(
            children: [
              Icon(Icons.play_circle, color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              Text(l10n.inProgress),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.complete,
          child: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 20),
              const SizedBox(width: 8),
              Text(l10n.completed),
            ],
          ),
        ),
        PopupMenuItem<TaskStatus>(
          value: TaskStatus.abandoned,
          child: Row(
            children: [
              Icon(Icons.cancel, color: Colors.red, size: 20),
              const SizedBox(width: 8),
              Text(l10n.cancelled),
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
        (note) =>
            note.id ==
            (relationship.fromNoteId == currentNote.id
                ? relationship.toNoteId
                : relationship.fromNoteId),
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
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
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

  void _addLinkedNote() async {
    // Step 1: Show multi-note selection dialog
    final selectedNotes = await showDialog<List<Note>>(
      context: context,
      builder: (context) => NoteSelectionDialog(
        onNotesSelected: (notes) => Navigator.of(context).pop(notes),
      ),
    );

    if (selectedNotes == null || selectedNotes.isEmpty) return;

    // Filter out the current note if it was somehow selected
    final notesToLink = selectedNotes
        .where((note) => note.id != widget.note.id)
        .toList();
    if (notesToLink.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot link a note to itself')),
        );
      }
      return;
    }

    // Step 2: Show relationship type selection dialog
    final relationshipType = await showDialog<String>(
      context: context,
      builder: (context) =>
          _RelationshipTypeSelectionDialog(noteCount: notesToLink.length),
    );

    if (relationshipType == null || relationshipType.isEmpty) return;

    // Step 3: Create relationships for all selected notes
    try {
      final noteIds = notesToLink.map((note) => note.id).toList();
      await context.read<AppProvider>().createNoteRelationships(
        widget.note.id,
        noteIds,
        relationshipType,
      );
      await _loadRelationships();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              notesToLink.length == 1
                  ? 'Linked 1 note successfully'
                  : 'Linked ${notesToLink.length} notes successfully',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      LoggerService.error('Error linking notes: $e', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error linking notes: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _removeLinkedNote(String relationshipId) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.removeLink),
        content: Text(l10n.confirmRemoveLink),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await context.read<AppProvider>().deleteRelationship(
                relationshipId,
              );
              await _loadRelationships();
            },
            child: Text(l10n.remove, style: const TextStyle(color: Colors.red)),
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
        content: Text(
          'Are you sure you want to remove the tag "$tagName" from this note?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await context.read<AppProvider>().removeTagFromNote(
                currentNote.id,
                tagName,
              );
            },
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showAddTagDialog(Note currentNote) {
    final appProvider = context.read<AppProvider>();
    final l10n = AppLocalizations.of(context)!;
    showDialog<List<String>>(
      context: context,
      builder: (context) => TagSelectionDialog(
        title: l10n.addTagsCapitalized,
        description: 'Add tags to "${currentNote.title}":',
        excludedTags: currentNote.tags,
        allowCreateNew: true,
        allowEmptySelection: false,
        confirmLabelBuilder: (count) =>
            count > 0 ? l10n.addTagsWithCount(count) : l10n.addTagsCapitalized,
      ),
    ).then((tagNames) async {
      if (tagNames == null || tagNames.isEmpty) return;
      for (final tagName in tagNames) {
        await appProvider.addTagToNote(currentNote.id, tagName);
      }

      if (mounted) {
        final updatedNote = context.read<AppProvider>().notes.firstWhere(
          (n) => n.id == currentNote.id,
          orElse: () => currentNote,
        );

        getIt<ContentIngestionService>().processNote(
          updatedNote,
          appProvider,
          onMessage: (msg) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(msg),
                  duration: const Duration(seconds: 4),
                ),
              );
            }
          },
          onError: (err) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(err), backgroundColor: Colors.red),
              );
            }
          },
          onSuccess: () {
            if (mounted) {
              setState(() {
                // Refresh state if needed, though provider update should handle it
                final freshNote = appProvider.notes.firstWhere(
                  (n) => n.id == updatedNote.id,
                  orElse: () => updatedNote,
                );
                if (freshNote.content != _codeController.text) {
                  _codeController.text = freshNote.content;
                }
              });
            }
          },
        );
      }
    });
  }

  void _showConversationsDialog() async {
    try {
      final appProvider = context.read<AppProvider>();
      final conversationIds = await appProvider.getNoteConversationIds(
        widget.note.id,
      );

      if (conversationIds.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No conversations found for this note')),
        );
        return;
      }

      // Get conversation details with messages
      final conversations = <Conversation>[];
      for (final conversationId in conversationIds) {
        final conversation = await _databaseService.getConversation(
          conversationId,
        );
        if (conversation != null) {
          conversations.add(conversation);
        }
      }

      // Sort by updated date (most recent first) - conversations list is guaranteed to have non-null items
      conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => _NoteConversationsDialog(
            conversations: conversations,
            appProvider: appProvider,
          ),
        );
      }
    } catch (e) {
      LoggerService.error('Error loading conversations: $e', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading conversations: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
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
            content: Text(
              'Failed to start recording. Please check microphone permissions.',
            ),
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
    final l10n = AppLocalizations.of(context)!;

    try {
      final audioPath = await _audioService!.stopRecording();
      if (audioPath != null) {
        // Read file bytes and save to private storage
        final file = File(audioPath);
        final bytes = await file.readAsBytes();
        final fileName = audioPath.split('/').last;
        final relativePath = await FileUtils.saveFileToPrivateStorage(
          bytes,
          fileName,
        );

        // Add the recorded audio as an attachment
        final currentNote = context.read<AppProvider>().notes.firstWhere(
          (note) => note.id == widget.note.id,
          orElse: () => widget.note,
        );

        final updatedAttachmentPaths = List<String>.from(
          currentNote.attachmentPaths,
        );
        updatedAttachmentPaths.add(relativePath);

        final updatedNote = currentNote.copyWith(
          attachmentPaths: updatedAttachmentPaths,
          updatedAt: DateTime.now(),
        );

        await context.read<AppProvider>().updateNote(updatedNote);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.recordingSavedAsAttachment),
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
      LoggerService.error('Error playing audio: $e', error: e);
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
    final l10n = AppLocalizations.of(context)!;

    try {
      // Show loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Text(l10n.transcribingAudio),
            ],
          ),
        ),
      );

      final transcription = await getIt<AIService>().transcribeAudio(audioPath);

      // Close loading dialog
      Navigator.of(context).pop();

      // Show transcription dialog
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.audioTranscription),
          content: SingleChildScrollView(child: Text(transcription)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.close),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _addTranscriptionToNote(transcription);
              },
              child: Text(l10n.addToNote),
            ),
          ],
        ),
      );
    } catch (e) {
      // Close loading dialog if it's open
      Navigator.of(context).pop();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.errorTranscribingAudio(e.toString())),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _addTranscriptionToNote(String transcription) async {
    final l10n = AppLocalizations.of(context)!;

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
        _codeController.text = updatedContent;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.transcriptionAddedToNote),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.errorAddingTranscription(e.toString())),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Helper methods
  bool _isAudioFile(String fileName) {
    final extension = FileTypeUtils.getFileExtension(fileName);
    return [
      'mp3',
      'wav',
      'aac',
      'm4a',
      'ogg',
      'flac',
      'wma',
    ].contains(extension);
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
      // Cancel any pending auto-save to prevent race condition
      _autoSaveTimer?.cancel();

      final appProvider = Provider.of<AppProvider>(context, listen: false);
      await appProvider.updateNoteContent(widget.note.id, newContent);

      // If we're in editing mode, update the content controller to reflect the changes
      if (_isEditing) {
        _codeController.text = newContent;
        // Reset the hasChanges flag since we just updated the controller
        setState(() {
          _hasChanges = false;
        });
      }
    }
  }

  /// Handle block edit request from drag-and-drop
  Future<void> _handleBlockEditRequest(MarkdownBlock block) async {
    debugPrint(
      '_handleBlockEditRequest: type=${block.type}, content=${block.content}',
    );
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final currentNote = appProvider.notes.firstWhere(
      (n) => n.id == widget.note.id,
      orElse: () => widget.note,
    );

    final result = await BlockEditorDialog.show(
      context,
      block.content,
      onPickImage: () => _pickImageAndReturnMarkdown(context),
      onPickNoteLink: () => _pickNoteLinkAndReturnMarkdown(context),
      onPickAttachmentLink: () => _pickAttachmentLinkAndReturnMarkdown(context),
    );
    if (result == null || result.result == BlockEditorResult.cancelled) {
      return;
    }

    // We can assume the tracker used by BlockMarkdownBody (which passed us this block)
    // produced valid offsets for the content AS IT WAS when rendered.
    // However, if the note content changed asynchronously, these offsets might be stale.
    // In a real-time collaborative app this is hard, but here:
    // We get 'block' from the current render.
    // We should treat the current note content as the source of truth but verify?
    // BlockMarkdownBody takes 'content' as input.
    // If we assume 'currentNote.content' hasn't changed since render, we are good.
    // But relying on offsets directly is safer if we trust BlockMarkdownBody to rebuild on change.

    // We need a tracker instance to perform operations.
    final tracker = MarkdownBlockTracker();

    if (result.result == BlockEditorResult.deleted) {
      final newContent = tracker.deleteBlock(currentNote.content, block);
      _updateNoteContent(newContent);
    } else if (result.result == BlockEditorResult.saved &&
        result.editedContent != null) {
      final newContent = tracker.replaceBlock(
        currentNote.content,
        block,
        result.editedContent!,
      );
      _updateNoteContent(newContent);
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
          await appProvider.reparentSubNote(
            currentNote.id,
            newParentNoteId,
            subNote,
          );
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
  void _handleLinkTap(String url, String? text) {
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

class _RelationshipTypeSelectionDialog extends StatefulWidget {
  final int noteCount;

  const _RelationshipTypeSelectionDialog({required this.noteCount});

  @override
  State<_RelationshipTypeSelectionDialog> createState() =>
      _RelationshipTypeSelectionDialogState();
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
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
    final l10n = AppLocalizations.of(context)!;
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    var notes = appProvider.notes
        .where((note) => note.id != widget.currentNote.id)
        .toList();

    // Filter by search query
    if (_searchQuery.isNotEmpty) {
      notes = notes.where((note) {
        return note.title.toLowerCase().contains(_searchQuery) ||
            note.content.toLowerCase().contains(_searchQuery);
      }).toList();
    }

    // Filter by selected tag
    if (_selectedTag != null && _selectedTag != l10n.allNotes) {
      notes = notes.where((note) {
        return note.tags.contains(_selectedTag);
      }).toList();
    }

    return notes;
  }

  List<String> _getAllTags() {
    final l10n = AppLocalizations.of(context)!;
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final allTags = <String>{};
    for (final note in appProvider.notes) {
      allTags.addAll(note.tags);
    }
    final tagList = allTags.toList()..sort();
    return [l10n.allNotes, ...tagList];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
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
                    initialValue: _selectedTag,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    hint: Text(l10n.allNotes),
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
                        _searchQuery.isNotEmpty ||
                                (_selectedTag != null &&
                                    _selectedTag != l10n.allNotes)
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
                          color: isSelected
                              ? Theme.of(context).primaryColor.withOpacity(0.1)
                              : null,
                          child: ListTile(
                            title: Text(
                              note.title,
                              style: TextStyle(
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
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
                                    children: note.tags
                                        .take(3)
                                        .map(
                                          (tag) => Chip(
                                            label: Text(
                                              tag,
                                              style: const TextStyle(
                                                fontSize: 10,
                                              ),
                                            ),
                                            backgroundColor: Theme.of(context)
                                                .colorScheme
                                                .primary
                                                .withOpacity(0.1),
                                            labelStyle: TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              fontSize: 10,
                                            ),
                                          ),
                                        )
                                        .toList(),
                                  ),
                                ],
                              ],
                            ),
                            trailing: isSelected
                                ? const Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                  )
                                : const Icon(
                                    Icons.radio_button_unchecked,
                                    color: Colors.grey,
                                  ),
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

class _RelationshipTypeSelectionDialogState
    extends State<_RelationshipTypeSelectionDialog> {
  String _selectedRelationshipType = RelationshipType.related;
  bool _isCustomMode = false;
  final TextEditingController _customTypeController = TextEditingController();

  @override
  void dispose() {
    _customTypeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.selectRelationshipType),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.selectRelationshipTypeForNotes(widget.noteCount),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _isCustomMode
                  ? 'custom'
                  : _selectedRelationshipType,
              decoration: InputDecoration(
                labelText: l10n.relationshipType,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              items: [
                ...RelationshipType.predefined.map(
                  (type) => DropdownMenuItem(
                    value: type,
                    child: Row(
                      children: [
                        Icon(RelationshipType.getIcon(type), size: 20),
                        const SizedBox(width: 8),
                        Text(RelationshipType.getDisplayName(type)),
                      ],
                    ),
                  ),
                ),
                DropdownMenuItem(
                  value: 'custom',
                  child: Row(
                    children: [
                      const Icon(Icons.edit, size: 20),
                      const SizedBox(width: 8),
                      Text(l10n.customEllipsis),
                    ],
                  ),
                ),
              ],
              onChanged: (value) {
                setState(() {
                  if (value == 'custom') {
                    _isCustomMode = true;
                  } else {
                    _isCustomMode = false;
                    _selectedRelationshipType = value!;
                  }
                });
              },
            ),
            if (_isCustomMode) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _customTypeController,
                decoration: InputDecoration(
                  labelText: l10n.customRelationshipType,
                  border: const OutlineInputBorder(),
                  hintText: l10n.enterCustomRelationshipType,
                ),
                autofocus: true,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          onPressed: () {
            final relationshipType = _isCustomMode
                ? _customTypeController.text.trim()
                : _selectedRelationshipType;
            if (relationshipType.isNotEmpty) {
              Navigator.pop(context, relationshipType);
            }
          },
          child: Text(l10n.linkNotes(widget.noteCount)),
        ),
      ],
    );
  }
}

class _NoteConversationsDialog extends StatefulWidget {
  final List<Conversation> conversations;
  final AppProvider appProvider;

  const _NoteConversationsDialog({
    required this.conversations,
    required this.appProvider,
  });

  @override
  State<_NoteConversationsDialog> createState() =>
      _NoteConversationsDialogState();
}

class _NoteConversationsDialogState extends State<_NoteConversationsDialog> {
  late List<Conversation> _conversations;
  ConversationService get _conversationService => getIt<ConversationService>();

  @override
  void initState() {
    super.initState();
    _conversations = List.from(widget.conversations);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Dialog(
      child: SizedBox(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.chat,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.conversationsWithThisNote,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop(); // Close the current dialog
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => ConversationTreeScreen(
                            activeConversationIds: widget.conversations
                                .map((c) => c.id)
                                .toList(),
                            filterByActiveConversations:
                                true, // Filter mode (from note)
                          ),
                        ),
                      );
                    },
                    child: Text(
                      l10n.openInTree,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                ],
              ),
            ),

            // Conversations list
            Expanded(
              child: _conversations.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline,
                            size: 64,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No conversations found',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      itemCount: _conversations.length,
                      itemBuilder: (context, index) {
                        final conversation = _conversations[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide(
                              color: Theme.of(
                                context,
                              ).colorScheme.outline.withOpacity(0.5),
                              width: 1,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        conversation.title,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.open_in_new),
                                          onPressed: () {
                                            Navigator.of(context).pop();
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (context) =>
                                                    ConversationChatScreen(
                                                      conversationId:
                                                          conversation.id,
                                                    ),
                                              ),
                                            );
                                          },
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete),
                                          onPressed: () =>
                                              _showDeleteConfirmation(
                                                context,
                                                conversation,
                                                l10n,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                FutureBuilder<ConversationWithMessages?>(
                                  future: _conversationService
                                      .getConversationWithMessages(
                                        conversation.id,
                                      ),
                                  builder: (context, snapshot) {
                                    if (!snapshot.hasData ||
                                        snapshot.data!.messages.isEmpty) {
                                      return const SizedBox.shrink();
                                    }
                                    final messages = snapshot.data!.messages;
                                    return Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${l10n.first}: ${messages.first.content}',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                            maxLines: 3,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Container(
                                          width: 1,
                                          height: 40,
                                          color: Colors.grey,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            '${l10n.last}: ${messages.last.content}',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                            maxLines: 3,
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteConfirmation(
    BuildContext context,
    Conversation conversation,
    AppLocalizations l10n,
  ) {
    // Capture AppProvider and ScaffoldMessenger before showing dialog
    final appProvider = widget.appProvider;
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.deleteConversation),
        content: Text(l10n.confirmDeleteConversation),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await _deleteConversation(
                conversation.id,
                l10n,
                appProvider,
                scaffoldMessenger,
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteConversation(
    String conversationId,
    AppLocalizations l10n,
    AppProvider appProvider,
    ScaffoldMessengerState scaffoldMessenger,
  ) async {
    try {
      // Perform deletion - this doesn't depend on context
      await appProvider.deleteConversation(conversationId);

      // Check if widget is still mounted before updating UI
      if (!mounted) return;

      // Remove conversation from local list
      setState(() {
        _conversations.removeWhere((c) => c.id == conversationId);
      });

      // Show success message
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(l10n.conversationDeletedSuccessfully),
          backgroundColor: Colors.green,
        ),
      );

      // If no conversations left, close the dialog after a short delay
      if (_conversations.isEmpty && mounted) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            Navigator.of(context).pop();
          }
        });
      }
    } catch (e) {
      LoggerService.error('Error deleting conversation: $e', error: e);

      // Check if widget is still mounted before showing error
      if (!mounted) return;

      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(l10n.errorDeletingConversation(e.toString())),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }
}

// Image Picker Dialog Widget
class _ImagePickerDialog extends StatefulWidget {
  final String initialAltText;
  final List<Attachment> existingAttachments;
  final Future<String> Function() onSaveNote;
  final Future<String> Function(File imageFile, String fileName)
  onAddAttachment;

  const _ImagePickerDialog({
    required this.initialAltText,
    required this.existingAttachments,
    required this.onSaveNote,
    required this.onAddAttachment,
  });

  @override
  State<_ImagePickerDialog> createState() => _ImagePickerDialogState();
}

class _ImagePickerDialogState extends State<_ImagePickerDialog> {
  late TextEditingController _altTextController;
  late TextEditingController _srcController;
  String? _selectedAttachmentPath;
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _altTextController = TextEditingController(text: widget.initialAltText);
    _srcController = TextEditingController();
  }

  @override
  void dispose() {
    _altTextController.dispose();
    _srcController.dispose();
    super.dispose();
  }

  Future<void> _pickNewImage() async {
    setState(() {
      _isImporting = true;
    });

    try {
      // Ensure note is saved first
      await widget.onSaveNote();

      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);

      if (image == null) {
        setState(() {
          _isImporting = false;
        });
        return;
      }

      // Generate unique filename
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final extension = p.extension(image.path);
      final fileName = 'image_$timestamp$extension';

      // Save attachment using callback
      final relativePath = await widget.onAddAttachment(
        File(image.path),
        fileName,
      );

      // Update UI
      setState(() {
        _selectedAttachmentPath = relativePath;
        _srcController.text = relativePath.replaceFirst('attachments/', '');
        _isImporting = false;
      });
    } catch (e) {
      setState(() {
        _isImporting = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to import image: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: const Text('Insert Image'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: MediaQuery.of(context).size.width * 0.8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _altTextController,
                decoration: const InputDecoration(
                  labelText: 'Alt Text (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _srcController,
                decoration: const InputDecoration(
                  labelText: 'Source',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              if (widget.existingAttachments.isNotEmpty) ...[
                Text('Existing Attachments', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                SizedBox(
                  height: 100,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.existingAttachments.length,
                    itemBuilder: (context, index) {
                      final attachment = widget.existingAttachments[index];
                      final isSelected =
                          _selectedAttachmentPath == attachment.filePath;

                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedAttachmentPath = attachment.filePath;
                            _srcController.text = attachment.filePath
                                .replaceFirst('attachments/', '');
                          });
                        },
                        child: Container(
                          width: 80,
                          height: 80,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: isSelected
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                              width: isSelected ? 3 : 1,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: FutureBuilder<String>(
                              future: attachment.getAbsolutePath(),
                              builder: (context, snapshot) {
                                if (!snapshot.hasData) {
                                  return const Center(
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  );
                                }
                                return Image.file(
                                  File(snapshot.data!),
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return const Icon(Icons.broken_image);
                                  },
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isImporting ? null : _pickNewImage,
          child: _isImporting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Pick'),
        ),
        TextButton(
          onPressed: _isImporting
              ? null
              : () async {
                  setState(() {
                    _isImporting = true;
                  });
                  try {
                    // Ensure note is saved first
                    await widget.onSaveNote();

                    final File? drawnFile = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const DrawingEditor(),
                      ),
                    );

                    if (drawnFile != null) {
                      // Generate timestamp for filename
                      final timestamp = DateTime.now().millisecondsSinceEpoch;
                      final fileName = 'drawing_$timestamp.png';

                      // Save attachment using callback
                      final relativePath = await widget.onAddAttachment(
                        drawnFile,
                        fileName,
                      );

                      // Update UI
                      setState(() {
                        _selectedAttachmentPath = relativePath;
                        _srcController.text = relativePath.replaceFirst(
                          'attachments/',
                          '',
                        );
                        _isImporting = false;
                      });
                    } else {
                      setState(() {
                        _isImporting = false;
                      });
                    }
                  } catch (e) {
                    setState(() {
                      _isImporting = false;
                    });
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to save drawing: $e')),
                      );
                    }
                  }
                },
          child: _isImporting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Draw'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: _srcController.text.isEmpty
              ? null
              : () {
                  Navigator.pop(context, {
                    'alt': _altTextController.text,
                    'src': _srcController.text,
                  });
                },
          child: const Text('OK'),
        ),
      ],
    );
  }
}

class _NoteLinkPickerDialog extends StatefulWidget {
  final List<Note> existingLinkedNotes;
  final Future<void> Function(Note newNote) onLinkNote;

  const _NoteLinkPickerDialog({
    required this.existingLinkedNotes,
    required this.onLinkNote,
  });

  @override
  State<_NoteLinkPickerDialog> createState() => _NoteLinkPickerDialogState();
}

class _NoteLinkPickerDialogState extends State<_NoteLinkPickerDialog> {
  Note? _selectedNote;
  final TextEditingController _linkTextController = TextEditingController();

  @override
  void dispose() {
    _linkTextController.dispose();
    super.dispose();
  }

  Future<void> _pickNewNote() async {
    await showDialog(
      context: context,
      builder: (context) => NoteSelectionDialog(
        title: 'Select Note to Link',
        singleSelection: true,
        onNotesSelected: (notes) async {
          if (notes.isNotEmpty) {
            Navigator.of(context).pop();
            final note = notes.first;
            // Link the note if not already linked
            if (!widget.existingLinkedNotes.any((n) => n.id == note.id)) {
              await widget.onLinkNote(note);
            }
            setState(() {
              _selectedNote = note;
              _linkTextController.text = note.title.length > 50
                  ? '${note.title.substring(0, 50)}...'
                  : note.title;
            });
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    // Combine existing linked notes and the newly selected one if it's new
    final notesToShow = [...widget.existingLinkedNotes];
    if (_selectedNote != null &&
        !notesToShow.any((n) => n.id == _selectedNote!.id)) {
      notesToShow.insert(0, _selectedNote!);
    }

    return AlertDialog(
      title: const Text('Insert Note Link'),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.8,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (notesToShow.isNotEmpty) ...[
              Text('Linked Notes', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              SizedBox(
                height: 120,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: notesToShow.length,
                  itemBuilder: (context, index) {
                    final note = notesToShow[index];
                    final isSelected = _selectedNote?.id == note.id;

                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedNote = note;
                          _linkTextController.text = note.title.length > 50
                              ? '${note.title.substring(0, 50)}...'
                              : note.title;
                        });
                      },
                      child: Container(
                        width: 100,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceVariant,
                          border: Border.all(
                            color: isSelected
                                ? theme.colorScheme.primary
                                : Colors.transparent,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              note.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _linkTextController,
              decoration: const InputDecoration(
                labelText: 'Link Text',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: ElevatedButton.icon(
                onPressed: _pickNewNote,
                icon: const Icon(Icons.search),
                label: const Text('Pick Note'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: _selectedNote == null
              ? null
              : () {
                  final text = _linkTextController.text.isEmpty
                      ? _selectedNote!.title
                      : _linkTextController.text;
                  final markdown =
                      '[$text](synapseresource://note/${_selectedNote!.id})';
                  Navigator.of(context).pop(markdown);
                },
          child: const Text('Insert'),
        ),
      ],
    );
  }
}
