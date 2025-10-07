import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../services/share_service.dart';

class ShareScreen extends StatefulWidget {
  final Map<String, dynamic> sharedData;

  const ShareScreen({
    super.key,
    required this.sharedData,
  });

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  Note? _preparedNote;
  String? _error;
  bool _isLoading = true;
  bool _isCreating = false;
  String _action = 'create'; // 'create' or 'append'
  Note? _selectedNote;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _tagsController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _processSharedData();
    // Load notes when the screen initializes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppProvider>().loadData();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _titleController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  Future<void> _processSharedData() async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      final result = await ShareServiceExtension.processSharedContent(widget.sharedData);
      
      if (result['success'] == true) {
        final note = Note.fromJson(result['note']);
        setState(() {
          _preparedNote = note;
          _isLoading = false;
        });
        // Initialize the text controllers with the prepared note's data
        _titleController.text = note.title;
        _tagsController.text = note.tags.join(', ');
      } else {
        setState(() {
          _error = result['error'] ?? 'Unknown error processing shared content';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error processing shared content: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Share to Note Synapse'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildErrorWidget()
              : _buildContentWidget(),
    );
  }

  Widget _buildErrorWidget() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Colors.red[300],
            ),
            const SizedBox(height: 16),
            Text(
              'Error Processing Shared Content',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContentWidget() {
    if (_preparedNote == null) {
      return const Center(child: Text('No content to share'));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Action selection
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'What would you like to do?',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  RadioListTile<String>(
                    title: const Text('Create new note'),
                    subtitle: const Text('Create a new note with this content'),
                    value: 'create',
                    groupValue: _action,
                    onChanged: (value) {
                      setState(() {
                        _action = value!;
                        _selectedNote = null;
                      });
                    },
                  ),
                  RadioListTile<String>(
                    title: const Text('Append to existing note'),
                    subtitle: const Text('Add this content to an existing note'),
                    value: 'append',
                    groupValue: _action,
                    onChanged: (value) {
                      setState(() {
                        _action = value!;
                      });
                    },
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Note selection for append mode
          if (_action == 'append') ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Select Note to Append To',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    Consumer<AppProvider>(
                      builder: (context, appProvider, child) {
                        final notes = appProvider.notes;
                        if (appProvider.isLoading) {
                          return const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          );
                        }
                        if (notes.isEmpty) {
                          return const Text('No notes available');
                        }
                        
                        // Filter notes based on search query
                        final filteredNotes = _searchQuery.isEmpty 
                            ? notes 
                            : notes.where((note) {
                                final query = _searchQuery.toLowerCase();
                                return note.title.toLowerCase().contains(query) ||
                                       note.content.toLowerCase().contains(query) ||
                                       note.tags.any((tag) => tag.toLowerCase().contains(query));
                              }).toList();
                        
                        return Column(
                          children: [
                            // Search field
                            TextField(
                              controller: _searchController,
                              decoration: InputDecoration(
                                hintText: 'Search notes...',
                                prefixIcon: const Icon(Icons.search),
                                suffixIcon: _searchQuery.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.clear),
                                        onPressed: () {
                                          _searchController.clear();
                                          setState(() {
                                            _searchQuery = '';
                                          });
                                        },
                                      )
                                    : null,
                                border: const OutlineInputBorder(),
                              ),
                              onChanged: (value) {
                                setState(() {
                                  _searchQuery = value;
                                  _selectedNote = null; // Clear selection when searching
                                });
                              },
                            ),
                            const SizedBox(height: 12),
                            // Note selection dropdown
                            DropdownButtonFormField<Note>(
                              value: _selectedNote,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                hintText: 'Select a note...',
                                prefixIcon: Icon(Icons.note),
                              ),
                              items: filteredNotes.map((note) {
                                return DropdownMenuItem<Note>(
                                  value: note,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        note.title,
                                        style: const TextStyle(fontWeight: FontWeight.bold),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        note.content.length > 50 
                                            ? '${note.content.substring(0, 50)}...' 
                                            : note.content,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey[600],
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (note.tags.isNotEmpty)
                                        Text(
                                          'Tags: ${note.tags.take(3).join(', ')}${note.tags.length > 3 ? '...' : ''}',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Theme.of(context).colorScheme.primary,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                    ],
                                  ),
                                );
                              }).toList(),
                              onChanged: (note) {
                                setState(() {
                                  _selectedNote = note;
                                });
                              },
                            ),
                            if (filteredNotes.length != notes.length)
                              Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Text(
                                  'Showing ${filteredNotes.length} of ${notes.length} notes',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Editable note details
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Note Details',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (_titleController.text != _preparedNote?.title || 
                          _tagsController.text != (_preparedNote?.tags.join(', ') ?? ''))
                        Padding(
                          padding: const EdgeInsets.only(left: 8.0),
                          child: Icon(
                            Icons.edit,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.title),
                    ),
                    onChanged: (value) {
                      setState(() {
                        // Update the prepared note with new title
                        if (_preparedNote != null) {
                          _preparedNote = _preparedNote!.copyWith(title: value);
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _tagsController,
                    decoration: const InputDecoration(
                      labelText: 'Tags (comma-separated)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.tag),
                      helperText: 'Enter tags separated by commas',
                    ),
                    onChanged: (value) {
                      setState(() {
                        // Update the prepared note with new tags
                        if (_preparedNote != null) {
                          final tags = value.split(',').map((tag) => tag.trim()).where((tag) => tag.isNotEmpty).toList();
                          _preparedNote = _preparedNote!.copyWith(tags: tags);
                        }
                      });
                    },
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Content preview
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Content Preview',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  _buildContentPreview(),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed: _isCreating ? null : _handleAction,
                  child: _isCreating
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_action == 'create' ? 'Create Note' : 'Append to Note'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildContentPreview() {
    final note = _preparedNote!;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Title: ${_titleController.text.isNotEmpty ? _titleController.text : note.title}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Content:',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            note.content,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        if (note.attachmentPaths.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Attachments:',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 4),
          ...note.attachmentPaths.map((path) => Padding(
            padding: const EdgeInsets.only(left: 8, top: 2),
            child: Text(
              '• ${path.split('/').last}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )),
        ],
        if (_tagsController.text.isNotEmpty || note.tags.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Tags: ${_tagsController.text.isNotEmpty ? _tagsController.text : note.tags.join(', ')}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _handleAction() async {
    if (_action == 'append' && _selectedNote == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a note to append to')),
      );
      return;
    }

    setState(() {
      _isCreating = true;
    });

    try {
      final appProvider = context.read<AppProvider>();

      if (_action == 'create') {
        // Create note with edited title and tags
        final finalNote = _preparedNote!.copyWith(
          title: _titleController.text.isNotEmpty ? _titleController.text : _preparedNote!.title,
          tags: _tagsController.text.isNotEmpty 
              ? _tagsController.text.split(',').map((tag) => tag.trim()).where((tag) => tag.isNotEmpty).toList()
              : _preparedNote!.tags,
        );
        await appProvider.addNote(finalNote);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Note created successfully!'),
              backgroundColor: Colors.green,
            ),
          );
          // Navigate to main screen instead of just popping
          Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
        }
      } else {
        // Append to existing note
        final updatedNote = _selectedNote!.copyWith(
          content: '${_selectedNote!.content}\n\n--- Shared Content ---\n${_preparedNote!.content}',
          updatedAt: DateTime.now(),
          attachmentPaths: [
            ..._selectedNote!.attachmentPaths,
            ..._preparedNote!.attachmentPaths,
          ],
          tags: [
            ..._selectedNote!.tags,
            ..._preparedNote!.tags.where((tag) => !_selectedNote!.tags.contains(tag)),
          ],
        );

        await appProvider.updateNote(updatedNote);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Content appended successfully!'),
              backgroundColor: Colors.green,
            ),
          );
          // Navigate to main screen instead of just popping
          Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
        }
      }
    } catch (e) {
      setState(() {
        _isCreating = false;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

// Extension to add processSharedContent method to ShareService
extension ShareServiceExtension on ShareService {
  static Future<Map<String, dynamic>> processSharedContent(Map<String, dynamic> sharedData) async {
    try {
      final String? action = sharedData['action'];
      final String? type = sharedData['type'];
      final String? text = sharedData['text'];
      final String? filePath = sharedData['filePath'];
      final String? fileName = sharedData['fileName'];

      if (action == 'SEND' || action == 'SEND_MULTIPLE') {
        if (type == 'text/plain' && text != null) {
          return await _processTextContent(text);
        } else if (type?.startsWith('image/') == true && filePath != null) {
          return await _processImageContent(filePath, fileName);
        } else if (type == 'application/pdf' && filePath != null) {
          return await _processPdfContent(filePath, fileName);
        }
      }

      return {
        'success': false,
        'error': 'Unsupported content type: $type',
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Error processing shared content: $e',
      };
    }
  }

  static Future<Map<String, dynamic>> _processTextContent(String text) async {
    try {
      final note = Note(
        id: const Uuid().v4(),
        title: 'Shared Text - ${DateTime.now().toString().substring(0, 16)}',
        content: text,
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        tags: ['shared', 'text'],
      );

      return {
        'success': true,
        'note': note.toJson(),
        'contentType': 'text',
        'preview': text.length > 100 ? '${text.substring(0, 100)}...' : text,
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Error processing text content: $e',
      };
    }
  }

  static Future<Map<String, dynamic>> _processImageContent(String filePath, String? fileName) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return {
          'success': false,
          'error': 'Image file not found: $filePath',
        };
      }

      final note = Note(
        id: const Uuid().v4(),
        title: 'Shared Image - ${DateTime.now().toString().substring(0, 16)}',
        content: 'Image shared from ${fileName ?? 'unknown source'}',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        attachmentPaths: [filePath],
        tags: ['shared', 'image'],
      );

      return {
        'success': true,
        'note': note.toJson(),
        'contentType': 'image',
        'preview': 'Image: ${fileName ?? 'unknown'}',
        'filePath': filePath,
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Error processing image content: $e',
      };
    }
  }

  static Future<Map<String, dynamic>> _processPdfContent(String filePath, String? fileName) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return {
          'success': false,
          'error': 'PDF file not found: $filePath',
        };
      }

      final note = Note(
        id: const Uuid().v4(),
        title: 'Shared PDF - ${DateTime.now().toString().substring(0, 16)}',
        content: 'PDF shared from ${fileName ?? 'unknown source'}',
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        attachmentPaths: [filePath],
        tags: ['shared', 'pdf'],
      );

      return {
        'success': true,
        'note': note.toJson(),
        'contentType': 'pdf',
        'preview': 'PDF: ${fileName ?? 'unknown'}',
        'filePath': filePath,
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Error processing PDF content: $e',
      };
    }
  }
}
