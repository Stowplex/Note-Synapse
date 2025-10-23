import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../models/conversation.dart';
import '../models/note.dart';
import '../services/conversation_service.dart';
import '../services/ai_service.dart';
import '../services/logger_service.dart';
import '../services/database_service.dart';
import 'note_selection_dialog.dart';
import 'note_detail_screen.dart';
import 'conversation_tree_screen.dart';

class ConversationChatScreen extends StatefulWidget {
  final String? conversationId;
  final List<String>? initialNoteIds;

  const ConversationChatScreen({
    Key? key,
    this.conversationId,
    this.initialNoteIds,
  }) : super(key: key);

  @override
  State<ConversationChatScreen> createState() => _ConversationChatScreenState();
}

class _ConversationChatScreenState extends State<ConversationChatScreen> {
  final ConversationService _conversationService = ConversationService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  Conversation? _conversation;
  List<ConversationMessage> _messages = [];
  List<Note> _notes = [];
  bool _isLoading = false;
  bool _isSending = false;
  List<PlatformFile> _attachedFiles = [];

  @override
  void initState() {
    super.initState();
    _initializeConversation();
  }

  Future<void> _initializeConversation() async {
    setState(() => _isLoading = true);

    try {
      if (widget.conversationId != null) {
        // Load existing conversation
        final conversationWithMessages = await _conversationService.getConversationWithMessages(widget.conversationId!);
        if (conversationWithMessages != null) {
          _conversation = conversationWithMessages.conversation;
          _messages = conversationWithMessages.messages;
          _notes = await _conversationService.getConversationNotes(widget.conversationId!);
        }
      } else {
        // Create new conversation
        final noteIds = widget.initialNoteIds ?? [];
        _conversation = await _conversationService.createConversation(
          title: 'New Conversation',
          noteIds: noteIds,
        );
        _notes = await _conversationService.getConversationNotes(_conversation!.id);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading conversation: $e')),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty || _isSending) return;

    final messageText = _messageController.text.trim();
    _messageController.clear();

    setState(() {
      _isSending = true;
      _attachedFiles.clear(); // Clear attachments after sending
    });

    try {
      // Add user message
      final userMessage = await _conversationService.addUserMessage(
        conversationId: _conversation!.id,
        content: messageText,
      );
      _messages.add(userMessage);
      setState(() {});
      _scrollToBottom();

      // Generate AI response
      final aiResponse = await _generateAIResponse(messageText);
      final aiMessage = await _conversationService.addAIResponse(
        conversationId: _conversation!.id,
        content: aiResponse,
        modelUsed: 'gpt-4', // This should come from the AI service
      );
      _messages.add(aiMessage);

      setState(() {});
      _scrollToBottom();
    } catch (e) {
      LoggerService.error('Error sending message: $e', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending message: ${e.toString()}'),
            backgroundColor: Theme.of(context).colorScheme.error,
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () {
                _messageController.text = messageText;
                _sendMessage();
              },
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  Future<String> _generateAIResponse(String userMessage) async {
    try {
      // Build conversation context for the prompt
      final contextMessages = _messages.map((msg) => {
        'role': msg.type == MessageType.user ? 'user' : 'assistant',
        'content': msg.content,
      }).toList();

      // Build conversation history string
      String conversationHistory = '';
      for (final msg in contextMessages) {
        conversationHistory += '${msg['role']}: ${msg['content']}\n';
      }

      // Create a comprehensive question that includes conversation context
      String question = userMessage;
      if (conversationHistory.isNotEmpty) {
        question = 'Conversation context:\n$conversationHistory\n\nCurrent question: $userMessage';
      }

      // Use AI service's answerNoteQuestion method which handles note context and attachments
      final response = await AIService.answerNoteQuestion(
        question,
        _notes,
        attachedFiles: _attachedFiles.isNotEmpty ? _attachedFiles : null,
        useOwnKnowledge: true, // Allow AI to use its own knowledge in conversations
      );
      return response;
    } catch (e) {
      LoggerService.error('Error generating AI response: $e', error: e);
      return 'I apologize, but I encountered an error while generating a response. Please try again.';
    }
  }

  Future<void> _attachFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: true, // Load file data into memory
      );

      if (result != null) {
        setState(() {
          _attachedFiles.addAll(result.files);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking files: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _captureImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      
      final XFile? image = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        // Convert XFile to PlatformFile for consistency with existing attachment system
        final file = File(image.path);
        final bytes = await file.readAsBytes();
        
        final platformFile = PlatformFile(
          name: image.name,
          size: bytes.length,
          bytes: bytes,
          path: image.path,
        );
        
        setState(() {
          _attachedFiles.add(platformFile);
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Photo captured and added as attachment'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error capturing image: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _removeAttachedFile(int index) {
    setState(() {
      _attachedFiles.removeAt(index);
    });
  }

  IconData _getFileIcon(String? extension) {
    if (extension == null) return Icons.insert_drive_file;
    
    switch (extension.toLowerCase()) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'txt':
        return Icons.text_snippet;
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
      case 'wmv':
        return Icons.videocam;
      case 'mp3':
      case 'wav':
      case 'flac':
        return Icons.audiotrack;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.archive;
      default:
        return Icons.insert_drive_file;
    }
  }

  Widget _buildAttachedFilesSection() {
    if (_attachedFiles.isEmpty) return const SizedBox.shrink();
    
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.attach_file, size: 16, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
              const SizedBox(width: 8),
              Text(
                'Attached Files (${_attachedFiles.length})',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...List.generate(_attachedFiles.length, (index) {
            final file = _attachedFiles[index];
            return Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(
                    _getFileIcon(file.extension),
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      file.name,
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => _removeAttachedFile(index),
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Future<void> _addResponseToNote(String responseContent) async {
    try {
      // Show a dialog to get the note title
      final titleController = TextEditingController();
      final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Add to Note'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter a title for the new note:'),
              const SizedBox(height: 16),
              TextField(
                controller: titleController,
                decoration: const InputDecoration(
                  hintText: 'Note title',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final title = titleController.text.trim();
                if (title.isNotEmpty) {
                  Navigator.of(context).pop(title);
                }
              },
              child: const Text('Create Note'),
            ),
          ],
        ),
      );

      if (result != null && result.isNotEmpty) {
        // Create a new note with the AI response content
        final newNote = Note(
          id: const Uuid().v4(),
          title: result,
          content: responseContent,
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          subNotes: [],
          tags: [],
          attachmentPaths: [],
          scheduledAt: null,
          completeBy: null,
          status: null,
          pinned: false,
          isArchived: false,
        );

        // Save the note to the database
        final databaseService = DatabaseService();
        await databaseService.insertNote(newNote);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Note "${result}" created successfully'),
              backgroundColor: Colors.green,
              action: SnackBarAction(
                label: 'View',
                onPressed: () {
                  // Navigate to the note detail screen
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => NoteDetailScreen(note: newNote),
                    ),
                  );
                },
              ),
            ),
          );
        }
      }
    } catch (e) {
      LoggerService.error('Error creating note from AI response: $e', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating note: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _forkConversation(String messageId) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fork Conversation'),
        content: const Text('Fork this conversation?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Fork'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        final forkedConversation = await _conversationService.forkConversation(
          originalConversationId: _conversation!.id,
          forkFromMessageId: messageId,
          newTitle: 'Forked conversation',
        );

        // Navigate to the forked conversation
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ConversationChatScreen(
              conversationId: forkedConversation.id,
            ),
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error forking conversation: $e')),
        );
      }
    }
  }

  Future<void> _showNoteSelection() async {
    final selectedNotes = await showDialog<List<Note>>(
      context: context,
      builder: (context) => NoteSelectionDialog(
        onNotesSelected: (notes) => Navigator.of(context).pop(notes),
      ),
    );

    if (selectedNotes != null) {
      final noteIds = selectedNotes.map((note) => note.id).toList();
      await _conversationService.addNotesToConversation(_conversation!.id, noteIds);
      setState(() {
        _notes = selectedNotes;
      });
    }
  }

  Future<void> _showNotesAndContext() async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Notes and Context'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Notes section
              Text(
                'Notes (${_notes.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: _notes.length,
                  itemBuilder: (context, index) {
                    final note = _notes[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.note, size: 20),
                        title: Text(
                          note.title,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        subtitle: Text(
                          note.content.length > 100 
                              ? '${note.content.substring(0, 100)}...'
                              : note.content,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () => _removeNote(note),
                        ),
                        onTap: () {
                          Navigator.of(context).pop();
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => NoteDetailScreen(note: note),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              // Action buttons
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _showNoteSelection();
                    },
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add Notes'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _clearAllNotes();
                    },
                    icon: const Icon(Icons.clear_all, size: 16),
                    label: const Text('Clear All'),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _removeNote(Note note) async {
    await _conversationService.removeNotesFromConversation(_conversation!.id, [note.id]);
    setState(() {
      _notes.removeWhere((n) => n.id == note.id);
    });
  }

  Future<void> _clearAllNotes() async {
    if (_notes.isEmpty) return;
    
    final noteIds = _notes.map((note) => note.id).toList();
    await _conversationService.removeNotesFromConversation(_conversation!.id, noteIds);
    setState(() {
      _notes.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_conversation == null) {
      return const Scaffold(
        body: Center(child: Text('Error loading conversation')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_conversation!.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.library_books),
            onPressed: _showNoteSelection,
            tooltip: 'Manage Notes',
          ),
          IconButton(
            icon: const Icon(Icons.account_tree),
            onPressed: () {
              // Navigate to tree view
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const ConversationTreeScreen(),
                ),
              );
            },
            tooltip: 'View Tree',
          ),
        ],
      ),
      body: Column(
        children: [
          // Notes summary
          if (_notes.isNotEmpty)
            GestureDetector(
              onTap: () => _showNotesAndContext(),
              child: Container(
                padding: const EdgeInsets.all(8.0),
                color: Theme.of(context).colorScheme.surfaceVariant,
                child: Row(
                  children: [
                    const Icon(Icons.note, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${_notes.length} note${_notes.length == 1 ? '' : 's'} included',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios, size: 12),
                  ],
                ),
              ),
            ),
          // Messages
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16.0),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return _buildMessageCard(message);
              },
            ),
          ),
          // Attached files section
          _buildAttachedFilesSection(),
          // Input area
          Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Type your message...',
                      border: const OutlineInputBorder(),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.attach_file),
                            onPressed: _attachFiles,
                            tooltip: 'Attach files',
                          ),
                          IconButton(
                            icon: const Icon(Icons.camera_alt),
                            onPressed: _captureImage,
                            tooltip: 'Take photo',
                          ),
                        ],
                      ),
                    ),
                    maxLines: null,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _isSending ? null : _sendMessage,
                  icon: _isSending 
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageCard(ConversationMessage message) {
    final isUser = message.type == MessageType.user;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 8.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isUser ? Icons.person : Icons.smart_toy,
                  size: 20,
                  color: isUser 
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.secondary,
                ),
                const SizedBox(width: 8),
                Text(
                  isUser ? 'You' : 'AI',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: isUser 
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.secondary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  _formatTimestamp(message.timestamp),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (isUser) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.call_split, size: 16),
                    onPressed: () => _forkConversation(message.id),
                    tooltip: 'Fork conversation',
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            if (isUser)
              Text(message.content)
            else ...[
              GptMarkdown(message.content),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: () => _addResponseToNote(message.content),
                  icon: const Icon(Icons.note_add, size: 16),
                  label: const Text('Add to Note'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);
    
    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

