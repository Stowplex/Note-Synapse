import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html2md/html2md.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../services/share_service.dart';
import '../services/gemini_api_service.dart';
import '../services/secure_storage_service.dart';
import '../services/logger_service.dart';

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
  bool _isExtracting = false;
  bool _hasApiKey = false;
  String _action = 'create'; // 'create' or 'append'
  Note? _selectedNote;
  String _searchQuery = '';
  String? _detectedUrl;
  String? _contentType;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _tagsController = TextEditingController();
  final Set<String> _selectedTags = <String>{};
  final TextEditingController _newTagController = TextEditingController();

  /// Check if running on Linux (non-web)
  bool get _isLinux => !kIsWeb && Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _processSharedData();
    _initializeAndCheckApiKey();
    // Load notes when the screen initializes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppProvider>().loadData();
    });
  }

  Future<void> _initializeAndCheckApiKey() async {
    // Ensure storage is properly initialized before checking
    await _ensureStorageInitialized();
    await _checkApiKeyStatus();
  }

  Future<void> _ensureStorageInitialized() async {
    try {
      // Initialize secure storage
      await SecureStorageService.initialize();
      LoggerService.debug('ShareScreen: Storage initialized successfully');
    } catch (e) {
      LoggerService.error('ShareScreen: Storage initialization failed: $e', error: e);
      // Add a delay and try again
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        await SecureStorageService.initialize();
        LoggerService.debug('ShareScreen: Storage initialized on retry');
      } catch (e2) {
        LoggerService.error('ShareScreen: Storage initialization failed on retry: $e2', error: e2);
      }
    }
  }

  Future<void> _checkApiKeyStatus() async {
    try {
      LoggerService.debug('ShareScreen: Checking API key status...');
      
      // Add a small delay to ensure storage is properly initialized
      await Future.delayed(const Duration(milliseconds: 100));
      
      bool hasApiKey = await SecureStorageService.hasApiKey();
      LoggerService.debug('ShareScreen: API key available: $hasApiKey');
      
      
      if (hasApiKey) {
        final apiKey = await SecureStorageService.getApiKey();
        LoggerService.debug('ShareScreen: API key length: ${apiKey?.length ?? 0}');
        
        // If we got a key, verify it's not empty
        if (apiKey == null || apiKey.isEmpty) {
          LoggerService.warning('ShareScreen: API key is empty, treating as unavailable');
          if (mounted) {
            setState(() {
              _hasApiKey = false;
            });
          }
          return;
        }
      }
      
      if (mounted) {
        setState(() {
          _hasApiKey = hasApiKey;
        });
      }
    } catch (e) {
      LoggerService.error('ShareScreen: Error checking API key: $e', error: e);
      if (mounted) {
        setState(() {
          _hasApiKey = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _titleController.dispose();
    _tagsController.dispose();
    _newTagController.dispose();
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
        setState(() {
          _contentType = result['contentType'];
          _detectedUrl = result['url'];
          _isLoading = false;
        });
        
        if (result['note'] != null) {
          final note = Note.fromJson(result['note']);
          setState(() {
            _preparedNote = note;
          });
          // Initialize the text controllers with the prepared note's data
          _titleController.text = note.title;
          _tagsController.text = note.tags.join(', ');
          _selectedTags.addAll(note.tags);
        } else if (result['contentType'] == 'image' || result['contentType'] == 'pdf') {
          // For images and PDFs, show extraction options
          setState(() {
            _preparedNote = null; // Will be created after extraction
          });
        }
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
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.sharedContent),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildErrorWidget(l10n)
              : _buildContentWidget(l10n),
    );
  }

  Widget _buildErrorWidget(AppLocalizations l10n) {
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
              child: Text(l10n.close),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContentWidget(AppLocalizations l10n) {
    if (_preparedNote == null && _contentType != 'url' && _contentType != 'image' && _contentType != 'pdf') {
      return Center(child: Text(l10n.noNotesAvailable));
    }

    // Show URL detection and extraction option
    if (_contentType == 'url' && _detectedUrl != null && _preparedNote == null) {
      return _buildUrlExtractionWidget();
    }

    // Show image extraction options
    if (_contentType == 'image' && _preparedNote == null) {
      return _buildImageExtractionWidget();
    }

    // Show PDF extraction options
    if (_contentType == 'pdf' && _preparedNote == null) {
      return _buildPdfExtractionWidget();
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
                    title: Text(l10n.createNote),
                    subtitle: Text('Create a new note with this content'),
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
                    title: Text(l10n.appendToNote),
                    subtitle: Text('Add this content to an existing note'),
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
                      l10n.selectNoteToAppend,
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
                          return Text(l10n.noNotesAvailable);
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

          // Editable note details (only for create new note)
          if (_action == 'create') ...[
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
                            _selectedTags.isNotEmpty)
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
                    _buildTagSelection(l10n),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Content preview (only for create new note)
          if (_action == 'create') ...[
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
            const SizedBox(height: 16),
          ],

          const SizedBox(height: 24),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed: (_isCreating || _isExtracting) ? null : _handleAction,
                  child: (_isCreating || _isExtracting)
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

  Widget _buildTagSelection(AppLocalizations l10n) {
    return Consumer<AppProvider>(
      builder: (context, appProvider, child) {
        final allTags = appProvider.tags.map((tag) => tag.name).toList();
        final availableTags = allTags.where((tag) => !_selectedTags.contains(tag)).toList();
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.tags,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            
            // Scrollable tags container with constrained height
            Container(
              height: 200, // Fixed height for scrollable area
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey[300]!),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Selected tags
                    if (_selectedTags.isNotEmpty) ...[
                      Text(
                        'Selected tags:',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: _selectedTags.map((tag) {
                          return Chip(
                            label: Text(tag),
                            deleteIcon: const Icon(Icons.close, size: 18),
                            onDeleted: () {
                              setState(() {
                                _selectedTags.remove(tag);
                                _updatePreparedNoteTags();
                              });
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),
                    ],
                    
                    // Add new tag
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _newTagController,
                            decoration: InputDecoration(
                              labelText: l10n.addTag,
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.add),
                              isDense: true,
                            ),
                            onSubmitted: (value) {
                              if (value.trim().isNotEmpty && !_selectedTags.contains(value.trim())) {
                                setState(() {
                                  _selectedTags.add(value.trim());
                                  _newTagController.clear();
                                  _updatePreparedNoteTags();
                                });
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () {
                            final value = _newTagController.text.trim();
                            if (value.isNotEmpty && !_selectedTags.contains(value)) {
                              setState(() {
                                _selectedTags.add(value);
                                _newTagController.clear();
                                _updatePreparedNoteTags();
                              });
                            }
                          },
                          icon: const Icon(Icons.add),
                          style: IconButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.primary,
                            foregroundColor: Theme.of(context).colorScheme.onPrimary,
                          ),
                        ),
                      ],
                    ),
                    
                    // Available tags to select from
                    if (availableTags.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Available tags:',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: availableTags.map((tag) {
                          return ActionChip(
                            label: Text(tag),
                            onPressed: () {
                              setState(() {
                                _selectedTags.add(tag);
                                _updatePreparedNoteTags();
                              });
                            },
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _updatePreparedNoteTags() {
    if (_preparedNote != null) {
      _preparedNote = _preparedNote!.copyWith(tags: _selectedTags.toList());
    }
  }

  Widget _buildUrlExtractionWidget() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.link,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'URL Detected',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _detectedUrl!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (_isLinux) ...[
              Card(
                color: Colors.orange[50],
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Icon(
                        Icons.warning,
                        color: Colors.orange[700],
                        size: 32,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Web content extraction is not supported on Linux.',
                        style: TextStyle(
                          color: Colors.orange[700],
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Please use Android, iOS, or Web to extract web content.',
                        style: TextStyle(
                          color: Colors.orange[600],
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            // Extract options
            Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isLinux ? null : () => _extractWebContent(false),
                    icon: _isExtracting 
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.web),
                    label: Text(_isExtracting ? 'Extracting...' : 'Extract Web Content'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: Tooltip(
                    message: !_hasApiKey ? 'API key required. Configure in settings first.' : 'Extract content using AI for better results',
                    child: ElevatedButton.icon(
                      onPressed: (_isLinux || !_hasApiKey) ? null : () => _extractWebContent(true),
                      icon: _isExtracting 
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.psychology),
                      label: Text(_isExtracting ? 'Extracting with AI...' : 'Extract with AI (Slower)'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        backgroundColor: Theme.of(context).colorScheme.secondary,
                        foregroundColor: Theme.of(context).colorScheme.onSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => _createUrlAsIs(),
              child: const Text('As-Is'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createUrlAsIs() async {
    if (_detectedUrl == null) return;

    setState(() {
      _isExtracting = true;
      _error = null;
    });

    try {
      // Prepare a note with the URL as-is (don't save yet)
      final note = Note(
        id: const Uuid().v4(),
        title: 'Shared URL',
        content: _detectedUrl!,
        type: NoteType.note,
        tags: ['shared', 'url'],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      setState(() {
        _preparedNote = note;
        _isExtracting = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to prepare note: $e';
        _isExtracting = false;
      });
    }
  }

  Future<void> _extractWebContent(bool useAI) async {
    if (_detectedUrl == null) return;

    setState(() {
      _isExtracting = true;
      _error = null;
    });

    try {
      // Show a dialog with the WebView for content extraction
      final result = await _showWebExtractionDialog(_detectedUrl!, useAI);
      
      if (result['success'] == true) {
        final note = Note.fromJson(result['note']);
        setState(() {
          _preparedNote = note;
          _isExtracting = false;
        });
        // Initialize the text controllers with the extracted note's data
        _titleController.text = note.title;
        _tagsController.text = note.tags.join(', ');
        _selectedTags.addAll(note.tags);
      } else {
        setState(() {
          _error = result['error'] ?? 'Failed to extract web content';
          _isExtracting = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error extracting web content: $e';
        _isExtracting = false;
      });
    }
  }

  Future<Map<String, dynamic>> _showWebExtractionDialog(String url, bool useAI) async {
    final completer = Completer<Map<String, dynamic>>();
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _WebExtractionDialog(
        url: url,
        useAI: useAI,
        onComplete: (result) {
          completer.complete(result);
          Navigator.of(context).pop();
        },
      ),
    );
    
    return completer.future;
  }

  void _showApiKeyRequiredDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('API Key Required'),
        content: const Text('To use AI extraction, you need to configure your Gemini API key in the app settings first.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pushNamed('/settings');
            },
            child: const Text('Go to Settings'),
          ),
        ],
      ),
    );
  }

  Widget _buildImageExtractionWidget() {
    final fileName = widget.sharedData['fileName'] as String?;
    
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.image,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Image Detected',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              fileName ?? 'Unknown image',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            // Extract options
            Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _extractImageContent(false),
                    icon: _isExtracting 
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.image),
                    label: Text(_isExtracting ? 'Extracting...' : 'Extract Image Content'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: Tooltip(
                    message: !_hasApiKey ? 'API key required. Configure in settings first.' : 'Extract content using AI for better results',
                    child: ElevatedButton.icon(
                      onPressed: !_hasApiKey ? null : () => _extractImageContent(true),
                      icon: _isExtracting 
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.psychology),
                      label: Text(_isExtracting ? 'Extracting with AI...' : 'Extract with AI (Slower)'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        backgroundColor: Theme.of(context).colorScheme.secondary,
                        foregroundColor: Theme.of(context).colorScheme.onSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPdfExtractionWidget() {
    final fileName = widget.sharedData['fileName'] as String?;
    
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.picture_as_pdf,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'PDF Detected',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              fileName ?? 'Unknown PDF',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            // Extract options
            Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _extractPdfContent(false),
                    icon: _isExtracting 
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.picture_as_pdf),
                    label: Text(_isExtracting ? 'Extracting...' : 'Extract PDF Content'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: Tooltip(
                    message: !_hasApiKey ? 'API key required. Configure in settings first.' : 'Extract content using AI for better results',
                    child: ElevatedButton.icon(
                      onPressed: !_hasApiKey ? null : () => _extractPdfContent(true),
                      icon: _isExtracting 
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.psychology),
                      label: Text(_isExtracting ? 'Extracting with AI...' : 'Extract with AI (Slower)'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        backgroundColor: Theme.of(context).colorScheme.secondary,
                        foregroundColor: Theme.of(context).colorScheme.onSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _extractImageContent(bool useAI) async {
    final filePath = widget.sharedData['filePath'] as String?;
    final fileName = widget.sharedData['fileName'] as String?;
    
    if (filePath == null) return;

    setState(() {
      _isExtracting = true;
      _error = null;
    });

    try {
      String content;
      List<String> tags = ['shared', 'image'];
      
      if (useAI) {
        // Check if API key is available before attempting AI extraction
        final hasApiKey = await SecureStorageService.hasApiKey();
        if (!hasApiKey) {
          setState(() {
            _isExtracting = false;
          });
          _showApiKeyRequiredDialog();
          return;
        }
        
        // Extract content using AI
        final result = await GeminiApiService.extractContentFromImage(filePath);
        if (result['success'] == true) {
          content = result['content'] ?? 'Image content extracted with AI';
          tags.add('ai_processed');
        } else {
          content = 'Image shared from ${fileName ?? 'unknown source'}';
        }
      } else {
        // Basic image note
        content = 'Image shared from ${fileName ?? 'unknown source'}';
      }

      final note = Note(
        id: const Uuid().v4(),
        title: 'Shared Image - ${DateTime.now().toString().substring(0, 16)}',
        content: content,
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        attachmentPaths: [filePath],
        tags: tags,
      );

      setState(() {
        _preparedNote = note;
        _isExtracting = false;
      });
      
      // Initialize the text controllers with the extracted note's data
      _titleController.text = note.title;
      _tagsController.text = note.tags.join(', ');
      _selectedTags.addAll(note.tags);
    } catch (e) {
      setState(() {
        _error = 'Error extracting image content: $e';
        _isExtracting = false;
      });
    }
  }

  Future<void> _extractPdfContent(bool useAI) async {
    final filePath = widget.sharedData['filePath'] as String?;
    final fileName = widget.sharedData['fileName'] as String?;
    
    if (filePath == null) return;

    setState(() {
      _isExtracting = true;
      _error = null;
    });

    try {
      String content;
      List<String> tags = ['shared', 'pdf'];
      
      if (useAI) {
        // Check if API key is available before attempting AI extraction
        final hasApiKey = await SecureStorageService.hasApiKey();
        if (!hasApiKey) {
          setState(() {
            _isExtracting = false;
          });
          _showApiKeyRequiredDialog();
          return;
        }
        
        // Extract content using AI
        final result = await GeminiApiService.extractContentFromPdf(filePath);
        if (result['success'] == true) {
          content = result['content'] ?? 'PDF content extracted with AI';
          tags.add('ai_processed');
        } else {
          content = 'PDF shared from ${fileName ?? 'unknown source'}';
        }
      } else {
        // Basic PDF note
        content = 'PDF shared from ${fileName ?? 'unknown source'}';
      }

      final note = Note(
        id: const Uuid().v4(),
        title: 'Shared PDF - ${DateTime.now().toString().substring(0, 16)}',
        content: content,
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        attachmentPaths: [filePath],
        tags: tags,
      );

      setState(() {
        _preparedNote = note;
        _isExtracting = false;
      });
      
      // Initialize the text controllers with the extracted note's data
      _titleController.text = note.title;
      _tagsController.text = note.tags.join(', ');
      _selectedTags.addAll(note.tags);
    } catch (e) {
      setState(() {
        _error = 'Error extracting PDF content: $e';
        _isExtracting = false;
      });
    }
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
        if (_selectedTags.isNotEmpty || note.tags.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Tags: ${_selectedTags.isNotEmpty ? _selectedTags.join(', ') : note.tags.join(', ')}',
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
          tags: _selectedTags.isNotEmpty ? _selectedTags.toList() : _preparedNote!.tags,
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
      // Check if the text is a URL
      final url = _extractUrl(text);
      if (url != null) {
        return {
          'success': true,
          'note': null, // Will be created after web extraction
          'contentType': 'url',
          'url': url,
          'preview': 'URL detected: $url',
        };
      }

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

  static String? _extractUrl(String text) {
    final trimmedText = text.trim();
    final uriPattern = RegExp(r'^https?://[^\s]+$');
    
    if (uriPattern.hasMatch(trimmedText)) {
      try {
        final uri = Uri.parse(trimmedText);
        if (uri.scheme == 'http' || uri.scheme == 'https') {
          return trimmedText;
        }
      } catch (e) {
        // Invalid URI
      }
    }
    
    return null;
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

class _WebExtractionDialog extends StatefulWidget {
  final String url;
  final bool useAI;
  final Function(Map<String, dynamic>) onComplete;

  const _WebExtractionDialog({
    required this.url,
    required this.useAI,
    required this.onComplete,
  });

  @override
  State<_WebExtractionDialog> createState() => _WebExtractionDialogState();
}

class _WebExtractionDialogState extends State<_WebExtractionDialog> {
  bool _isLoading = true;
  String _status = 'Loading web page...';

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
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
                  const Icon(Icons.web, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Extracting Web Content',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      widget.onComplete({
                        'success': false,
                        'error': 'Extraction cancelled by user',
                      });
                    },
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),
            // Status
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  if (_isLoading) const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_status)),
                ],
              ),
            ),
             // WebView
             Expanded(
               child: InAppWebView(
                 initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                 shouldOverrideUrlLoading: (controller, navigationAction) async {
                   final url = navigationAction.request.url;
                   if (url == null) return NavigationActionPolicy.CANCEL;
                   
                   final scheme = url.scheme.toLowerCase();
                   
                   // Allow only safe URL schemes
                   if (['http', 'https', 'data', 'about', 'file', 'javascript'].contains(scheme)) {
                     return NavigationActionPolicy.ALLOW;
                   }
                   
                   // Reject all other schemes (like app://, intent://, etc.)
                   return NavigationActionPolicy.CANCEL;
                 },
                 onLoadStart: (controller, url) {
                   setState(() {
                     _status = 'Loading web page...';
                     _isLoading = true;
                   });
                 },
                onLoadStop: (controller, url) async {
                  setState(() {
                    _status = 'Extracting content...';
                  });
                  
                  try {
                    // Load Readability.js from assets
                    final jsLib = await rootBundle.loadString('assets/scripts/Readability.min.js');
                    
                    // Inject Readability.js
                    await controller.evaluateJavascript(source: jsLib);
                    
                    // Extract content using Readability
                    final result = await controller.evaluateJavascript(source: '''
                      (function() {
                        try {
                          const article = new Readability(document).parse();
                          if (article) {
                            return {
                              title: article.title || document.title || '',
                              content: article.content || '',
                              textContent: article.textContent || '',
                              excerpt: article.excerpt || ''
                            };
                          }
                          return null;
                        } catch (e) {
                          return { error: e.toString() };
                        }
                      })();
                    ''');
                    
                    if (result != null && result is Map) {
                      if (result.containsKey('error')) {
                        widget.onComplete({
                          'success': false,
                          'error': 'Readability extraction failed: ${result['error']}',
                        });
                        return;
                      }
                      
                      final extractedTitle = result['title']?.toString();
                      final extractedContent = result['content']?.toString();

                      if (extractedContent == null || extractedContent.isEmpty) {
                        widget.onComplete({
                          'success': false,
                          'error': 'Failed to extract content from the web page',
                        });
                        return;
                      }

                      // Process content based on extraction method
                      String finalContent;
                      List<String> tags = ['shared', 'web', 'extracted'];
                      
                      if (widget.useAI) {
                        setState(() {
                          _status = 'Checking API key...';
                        });
                        
                        // Check if API key is available before attempting AI extraction
                        final hasApiKey = await SecureStorageService.hasApiKey();
                        if (!hasApiKey) {
                          widget.onComplete({
                            'success': false,
                            'error': 'API key not configured. Please configure your Gemini API key in settings first.',
                          });
                          return;
                        }
                        
                        setState(() {
                          _status = 'Processing with AI...';
                        });
                        
                        // Convert HTML to markdown first
                        final markdownContent = convert(extractedContent);
                        
                        // Send to AI for better extraction
                        final aiResult = await GeminiApiService.extractContentFromText(
                          markdownContent,
                          'web_content',
                          extractedTitle ?? 'Web Content',
                        );
                        
                        if (aiResult['success'] == true) {
                          finalContent = aiResult['content'] ?? markdownContent;
                          tags.add('ai_processed');
                        } else {
                          // Fallback to markdown if AI fails
                          finalContent = markdownContent;
                        }
                      } else {
                        // Convert HTML to markdown
                        finalContent = convert(extractedContent);
                        tags.add('markdown');
                      }

                      final note = Note(
                        id: const Uuid().v4(),
                        title: (extractedTitle?.isNotEmpty == true) 
                            ? extractedTitle! 
                            : 'Web Content - ${DateTime.now().toString().substring(0, 16)}',
                        content: finalContent,
                        type: NoteType.note,
                        createdAt: DateTime.now(),
                        updatedAt: DateTime.now(),
                        tags: tags,
                      );

                      widget.onComplete({
                        'success': true,
                        'note': note.toJson(),
                        'contentType': 'web',
                        'preview': (extractedTitle?.isNotEmpty == true) 
                            ? extractedTitle! 
                            : 'Web content extracted from ${widget.url}',
                        'url': widget.url,
                      });
                    } else {
                      widget.onComplete({
                        'success': false,
                        'error': 'Failed to extract content from the web page',
                      });
                    }
                  } catch (e) {
                    widget.onComplete({
                      'success': false,
                      'error': 'Failed to extract web content: $e',
                    });
                  }
                },
                onLoadError: (controller, url, code, message) {
                  widget.onComplete({
                    'success': false,
                    'error': 'Failed to load web page: $message',
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
