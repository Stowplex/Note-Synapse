import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html2md/html2md.dart';
import 'package:http/http.dart' as http;
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../services/share_service.dart';
import '../services/ai_service.dart';
import '../utils/file_utils.dart';

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
  String _action = 'create'; // 'create' or 'append'
  Note? _selectedNote;
  String _searchQuery = '';
  String? _detectedUrl;
  String? _contentType;
  String _tagSearchQuery = '';
  String? _downloadedFilePath; // Track downloaded file path for cleanup
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
    // Load notes when the screen initializes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppProvider>().loadData();
    });
  }



  @override
  void dispose() {
    // Clean up downloaded file if user doesn't proceed
    _cleanupDownloadedFile();
    _searchController.dispose();
    _titleController.dispose();
    _tagsController.dispose();
    _newTagController.dispose();
    super.dispose();
  }

  /// Cleans up downloaded file if it exists and hasn't been added to a note
  Future<void> _cleanupDownloadedFile() async {
    if (_downloadedFilePath != null) {
      try {
        final absolutePath = await FileUtils.getFullFilePath(_downloadedFilePath!, true);
        final file = File(absolutePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        // Ignore errors during cleanup
      }
      _downloadedFilePath = null;
    }
  }

  Future<void> _processSharedData() async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      final result = await ShareService.processSharedContent(widget.sharedData);
      
      if (result['success'] == true) {
        setState(() {
          _contentType = result['contentType'];
          _detectedUrl = result['url'];
          _isLoading = false;
        });
        
        if (result['note'] != null) {
          final note = result['note'] as Note;
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
              l10n.errorProcessingSharedContent,
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
                    l10n.whatWouldYouLikeToDo,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  RadioListTile<String>(
                    title: Text(l10n.createNote),
                    subtitle: Text(l10n.createNewNoteWithThisContent),
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
                    subtitle: Text(l10n.addThisContentToExistingNote),
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
                                hintText: l10n.searchNotes,
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
                              decoration: InputDecoration(
                                border: const OutlineInputBorder(),
                                hintText: l10n.selectNote,
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
                                  l10n.showingNotes(filteredNotes.length, notes.length),
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
                          l10n.noteDetails,
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
                      decoration: InputDecoration(
                        labelText: l10n.title,
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
                      l10n.contentPreview,
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
              onPressed: () async {
                // Clean up downloaded file on cancel
                await _cleanupDownloadedFile();
                Navigator.of(context).pushNamedAndRemoveUntil('/main', (route) => false);
              },
              child: Text(l10n.cancel),
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
                      : Text(_action == 'create' ? l10n.createNote : l10n.appendToNote),
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
        final allTags = appProvider.tags.map((tag) => tag.name).toList()..sort();
        
        // Filter available tags based on search query
        final availableTags = allTags.where((tag) => 
          !_selectedTags.contains(tag) && 
          (tag.toLowerCase().contains(_tagSearchQuery.toLowerCase()))
        ).toList();
        
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
                        l10n.selectedTags,
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
                              labelText: '${l10n.addTag} or search',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.add),
                              isDense: true,
                            ),
                            onChanged: (value) {
                              setState(() {
                                _tagSearchQuery = value;
                              });
                            },
                            onSubmitted: (value) {
                              if (value.trim().isNotEmpty && !_selectedTags.contains(value.trim())) {
                                setState(() {
                                  _selectedTags.add(value.trim());
                                  _newTagController.clear();
                                  _tagSearchQuery = '';
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
                                _tagSearchQuery = '';
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
                        l10n.availableTags,
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
    final l10n = AppLocalizations.of(context)!;
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
              l10n.urlDetected,
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
                        l10n.webContentExtractionNotSupportedLinux,
                        style: TextStyle(
                          color: Colors.orange[700],
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.pleaseUseOtherPlatformsForWebExtraction,
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
                    label: Text(_isExtracting ? l10n.extracting : l10n.extractWebContent),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: Tooltip(
                    message: l10n.extractContentUsingAiForBetterResults,
                      child: ElevatedButton.icon(
                      onPressed: _isLinux ? null : () => _extractWebContent(true),
                      icon: _isExtracting 
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.psychology),
                      label: Text(_isExtracting ? l10n.extractingWithAi : l10n.extractWithAi),
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
              child: Text(l10n.asIs),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createUrlAsIs() async {
    if (_detectedUrl == null) return;

    final l10n = AppLocalizations.of(context)!;

    setState(() {
      _isExtracting = true;
      _error = null;
    });

    try {
      // Prepare a note with the URL as-is (don't save yet)
      final note = Note(
        id: const Uuid().v4(),
        title: l10n.sharedUrl,
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
      _error = l10n.failedToPrepareNote(e.toString());
        _isExtracting = false;
      });
    }
  }

  Future<void> _extractWebContent(bool useAI) async {
    if (_detectedUrl == null) return;

    final l10n = AppLocalizations.of(context)!;

    setState(() {
      _isExtracting = true;
      _error = null;
    });

    try {
      // Show a dialog with the WebView for content extraction
      final result = await _showWebExtractionDialog(_detectedUrl!, useAI);
      
      if (result['success'] == true) {
        final note = result['note'] as Note;
        // Handle downloaded file path - only track it for cleanup, don't add it again if already in note
        if (result['downloadedFilePath'] != null) {
          _downloadedFilePath = result['downloadedFilePath'] as String;
          // Check if the attachment is already in the note's attachmentPaths
          final attachmentAlreadyInNote = note.attachmentPaths.contains(_downloadedFilePath!);
          if (!attachmentAlreadyInNote) {
            // Only add if not already present
            final noteWithAttachment = note.copyWith(
              attachmentPaths: [...note.attachmentPaths, _downloadedFilePath!],
            );
            setState(() {
              _preparedNote = noteWithAttachment;
              _isExtracting = false;
            });
          } else {
            // Already in note, just use the note as-is
            setState(() {
              _preparedNote = note;
              _isExtracting = false;
            });
          }
        } else {
          setState(() {
            _preparedNote = note;
            _isExtracting = false;
          });
        }
        // Initialize the text controllers with the extracted note's data
        _titleController.text = note.title;
        _tagsController.text = note.tags.join(', ');
        _selectedTags.addAll(note.tags);
      } else {
        // Cleanup downloaded file on error
        await _cleanupDownloadedFile();
        setState(() {
          _error = result['error'] ?? 'Failed to extract web content';
          _isExtracting = false;
        });
      }
    } catch (e) {
    setState(() {
      _error = l10n.errorExtractingWebContent(e.toString());
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


  Widget _buildImageExtractionWidget() {
    final l10n = AppLocalizations.of(context)!;
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
              l10n.imageDetected,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              fileName ?? l10n.unknownImage,
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
                    label: Text(_isExtracting ? l10n.extracting : l10n.extractImageContent),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: Tooltip(
                    message: 'Extract content using AI for better results',
                    child: ElevatedButton.icon(
                      onPressed: () => _extractImageContent(true),
                      icon: _isExtracting 
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.psychology),
                      label: Text(_isExtracting ? l10n.extractingWithAi : l10n.extractWithAi),
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
              child: Text(l10n.cancel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPdfExtractionWidget() {
    final l10n = AppLocalizations.of(context)!;
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
              l10n.pdfDetected,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              fileName ?? l10n.unknownPdf,
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
                    label: Text(_isExtracting ? l10n.extracting : l10n.extractPdfContent),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: Tooltip(
                    message: l10n.extractContentUsingAiForBetterResults,
                    child: ElevatedButton.icon(
                      onPressed: () => _extractPdfContent(true),
                      icon: _isExtracting 
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.psychology),
                      label: Text(_isExtracting ? l10n.extractingWithAi : l10n.extractWithAi),
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
              child: Text(l10n.cancel),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _extractImageContent(bool useAI) async {
    final l10n = AppLocalizations.of(context)!;
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
        // Let AI service handle API key validation
        
        // Extract content using AI
        final result = await AIService.extractContentFromImage(filePath);
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
        title: '${l10n.sharedImage} - ${DateTime.now().toString().substring(0, 16)}',
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
        _error = l10n.errorExtractingImageContent(e.toString());
        _isExtracting = false;
      });
    }
  }


  Future<void> _extractPdfContent(bool useAI) async {
    final l10n = AppLocalizations.of(context)!;
    final filePath = widget.sharedData['filePath'] as String?;
    final fileName = widget.sharedData['fileName'] as String?;
    
    if (filePath == null) return;

    setState(() {
      _isExtracting = true;
      _error = null;
    });

    try {
      // Use ShareService to process the PDF content
      final result = await ShareService.processSharedContent({
        'action': 'SEND',
        'type': 'application/pdf',
        'filePath': filePath,
        'fileName': fileName,
      });

      if (result['success'] != true) {
        setState(() {
          _isExtracting = false;
          _error = result['error'] ?? 'Could not process PDF file';
        });
        return;
      }

      Note note = result['note'] as Note;
      final relativePath = note.attachmentPaths.first;
      
      if (useAI) {
        // Let AI service handle API key validation
        
        // Extract content using AI - use the saved file path
        final absolutePath = await FileUtils.getFullFilePath(relativePath, true);
        final aiResult = await AIService.extractContentFromPdf(absolutePath);
        if (aiResult['success'] == true) {
          // Update the note with AI-extracted content
          note = Note(
            id: note.id,
            title: note.title,
            content: aiResult['content'] ?? note.content,
            type: note.type,
            createdAt: note.createdAt,
            updatedAt: DateTime.now(),
            attachmentPaths: note.attachmentPaths,
            tags: [...note.tags, 'ai_processed'],
          );
        }
      }

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
        _error = l10n.errorExtractingPdfContent(e.toString());
        _isExtracting = false;
      });
    }
  }

  Widget _buildContentPreview() {
    final l10n = AppLocalizations.of(context)!;
    final note = _preparedNote!;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
            Text(
              '${l10n.title}: ${_titleController.text.isNotEmpty ? _titleController.text : note.title}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              '${l10n.content}:',
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
            '${l10n.attachments}:',
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
            '${l10n.tags}: ${_selectedTags.isNotEmpty ? _selectedTags.join(', ') : note.tags.join(', ')}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _handleAction() async {
    final l10n = AppLocalizations.of(context)!;

    if (_action == 'append' && _selectedNote == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.pleaseSelectNoteToAppend)),
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
        // Clear downloaded file path after successful note creation
        _downloadedFilePath = null;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.noteCreatedSuccessfully(finalNote.title)),
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
        // Clear downloaded file path after successful note update
        _downloadedFilePath = null;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.contentAppendedSuccessfully),
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
  late String _status;
  String? _downloadedFilePath;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    _status = 'Loading...';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isLoading) {
      final l10n = AppLocalizations.of(context)!;
      _status = l10n.loadingWebPage;
      _checkAndDownloadFile();
    }
  }

  /// Checks if the URL is a PDF or static file and downloads it if needed
  Future<void> _checkAndDownloadFile() async {
    try {
      final l10n = AppLocalizations.of(context)!;
      
      // First, check the URL extension for quick detection
      final uri = Uri.parse(widget.url);
      final path = uri.path.toLowerCase();
      final hasFileExtension = path.endsWith('.pdf') ||
          path.endsWith('.doc') ||
          path.endsWith('.docx') ||
          path.endsWith('.xls') ||
          path.endsWith('.xlsx') ||
          path.endsWith('.ppt') ||
          path.endsWith('.pptx') ||
          path.endsWith('.zip') ||
          path.endsWith('.rar') ||
          path.endsWith('.tar') ||
          path.endsWith('.gz');
      
      // Check content-type header to detect files even if URL has no extension
      String? detectedContentType;
      if (!hasFileExtension) {
        // Make a HEAD request to check content-type without downloading
        setState(() {
          _status = 'Checking file type...';
        });
        try {
          final headResponse = await http.head(Uri.parse(widget.url));
          detectedContentType = headResponse.headers['content-type']?.toLowerCase();
        } catch (e) {
          // If HEAD fails, proceed with webview
        }
      }
      
      // Check if it's a binary/static file based on extension or content-type
      final contentType = detectedContentType ?? '';
      final isPdfOrStaticFile = hasFileExtension || 
          contentType.startsWith('application/pdf') ||
          contentType.startsWith('application/msword') ||
          contentType.startsWith('application/vnd.ms-word') ||
          contentType.startsWith('application/vnd.ms-excel') ||
          contentType.startsWith('application/vnd.ms-powerpoint') ||
          contentType.startsWith('application/vnd.openxmlformats') ||
          contentType.startsWith('application/zip') ||
          contentType.startsWith('application/x-rar') ||
          contentType.startsWith('application/x-tar') ||
          contentType.startsWith('application/gzip') ||
          (contentType.startsWith('application/') && 
           !contentType.startsWith('application/json') &&
           !contentType.startsWith('application/xml') &&
           !contentType.startsWith('application/javascript'));
      
      if (isPdfOrStaticFile) {
        // Download the file
        setState(() {
          _isDownloading = true;
          _status = 'Downloading file...';
        });
        
        try {
          final response = await http.get(Uri.parse(widget.url));
          
          if (response.statusCode == 200) {
            // Get content type from actual response headers
            final responseContentType = response.headers['content-type']?.toLowerCase() ?? contentType;
            final isBinaryContent = responseContentType.startsWith('application/pdf') ||
                responseContentType.startsWith('application/msword') ||
                responseContentType.startsWith('application/vnd.ms-word') ||
                responseContentType.startsWith('application/vnd.ms-excel') ||
                responseContentType.startsWith('application/vnd.ms-powerpoint') ||
                responseContentType.startsWith('application/vnd.openxmlformats') ||
                responseContentType.startsWith('application/zip') ||
                responseContentType.startsWith('application/x-rar') ||
                responseContentType.startsWith('application/x-tar') ||
                responseContentType.startsWith('application/gzip') ||
                (responseContentType.startsWith('application/') && 
                 !responseContentType.startsWith('application/json') &&
                 !responseContentType.startsWith('application/xml') &&
                 !responseContentType.startsWith('application/javascript')) ||
                !responseContentType.startsWith('text/') && 
                !responseContentType.startsWith('image/') &&
                !responseContentType.startsWith('video/');
            
            if (isBinaryContent || isPdfOrStaticFile) {
              // Extract filename from URL or Content-Disposition header
              String fileName = path.split('/').last;
              if (fileName.isEmpty || !fileName.contains('.')) {
                // Try to get filename from Content-Disposition header
                final contentDisposition = response.headers['content-disposition'];
                if (contentDisposition != null) {
                  // Try to extract filename from Content-Disposition header
                  // Pattern: filename="..." or filename=...
                  final filenameRegex = RegExp(r'filename\s*=\s*(?:"([^"]+)"|([^;]+))');
                  final filenameMatch = filenameRegex.firstMatch(contentDisposition);
                  if (filenameMatch != null) {
                    final matchedFilename = filenameMatch.group(1) ?? filenameMatch.group(2);
                    if (matchedFilename != null && matchedFilename.trim().isNotEmpty) {
                      fileName = matchedFilename.trim();
                    }
                  }
                }
                
                // Fallback filename based on content type
                if (fileName.isEmpty || !fileName.contains('.')) {
                  if (responseContentType.contains('pdf')) {
                    fileName = 'document.pdf';
                  } else if (responseContentType.contains('msword') || responseContentType.contains('wordprocessingml')) {
                    fileName = 'document.doc';
                  } else if (responseContentType.contains('spreadsheetml')) {
                    fileName = 'document.xls';
                  } else if (responseContentType.contains('presentation')) {
                    fileName = 'document.ppt';
                  } else {
                    fileName = 'document.bin';
                  }
                }
              }
              
              // Save file to attachment directory
              final relativePath = await FileUtils.saveFileToPrivateStorage(
                response.bodyBytes,
                fileName,
              );
              
              setState(() {
                _downloadedFilePath = relativePath;
                _isDownloading = false;
                _status = 'File downloaded successfully';
              });
              
              // Create a note with the downloaded file as attachment
              final note = Note(
                id: const Uuid().v4(),
                title: fileName,
                content: 'Downloaded file from ${widget.url}',
                type: NoteType.note,
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
                attachmentPaths: [relativePath],
                tags: ['shared', 'download', 'file'],
              );
              
              // Return the result after a short delay to show success message
              await Future.delayed(const Duration(milliseconds: 500));
              
              widget.onComplete({
                'success': true,
                'note': note,
                'downloadedFilePath': relativePath,
                'contentType': 'file',
              });
              return;
            }
          }
        } catch (e) {
          // If download fails, fall through to webview
          setState(() {
            _isDownloading = false;
            _status = l10n.loadingWebPage;
          });
        }
      }
      
      // If not a static file or download failed, proceed with webview
      // The webview will be shown in the build method
    } catch (e) {
      // Error checking URL, proceed with webview
      final l10n = AppLocalizations.of(context)!;
      setState(() {
        _isDownloading = false;
        _status = l10n.loadingWebPage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    // Show downloading status if downloading
    if (_isDownloading) {
      return Dialog(
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_status),
            ],
          ),
        ),
      );
    }
    
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
                      l10n.extractingWebContent,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      // Clean up downloaded file if exists
                      if (_downloadedFilePath != null) {
                        try {
                          final absolutePath = await FileUtils.getFullFilePath(_downloadedFilePath!, true);
                          final file = File(absolutePath);
                          if (await file.exists()) {
                            await file.delete();
                          }
                        } catch (e) {
                          // Ignore errors
                        }
                      }
                      widget.onComplete({
                        'success': false,
                        'error': l10n.extractionCancelledByUser,
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
                    _status = l10n.loadingWebPage;
                     _isLoading = true;
                   });
                 },
                onLoadStop: (controller, url) async {
                  setState(() {
                    _status = l10n.extractingContent;
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
                          'error': l10n.readabilityExtractionFailed(result['error'].toString()),
                        });
                        return;
                      }
                      
                      final extractedTitle = result['title']?.toString();
                      final extractedContent = result['content']?.toString();

                      if (extractedContent == null || extractedContent.isEmpty) {
                        widget.onComplete({
                          'success': false,
                          'error': l10n.failedToExtractContentFromWebPage,
                        });
                        return;
                      }

                      // Process content based on extraction method
                      String finalContent;
                      List<String> tags = ['shared', 'web', 'extracted'];
                      
                      if (widget.useAI) {
                        setState(() {
                          _status = l10n.checkingApiKey;
                        });
                        
                        // Let AI service handle API key validation
                        
                        setState(() {
                          _status = l10n.processingWithAi;
                        });
                        
                        // Convert HTML to markdown first
                        final markdownContent = convert(extractedContent);
                        
                        // Send to AI for better extraction
                        final aiResult = await AIService.extractContentFromText(
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
                        'note': note,
                        'contentType': 'web',
                        'preview': (extractedTitle?.isNotEmpty == true) 
                            ? extractedTitle! 
                            : 'Web content extracted from ${widget.url}',
                        'url': widget.url,
                      });
                    } else {
                      widget.onComplete({
                        'success': false,
                        'error': l10n.failedToExtractContentFromWebPage,
                      });
                    }
                  } catch (e) {
                    widget.onComplete({
                      'success': false,
                      'error': l10n.errorExtractingWebContent(e.toString()),
                    });
                  }
                },
                onLoadError: (controller, url, code, message) {
                  widget.onComplete({
                    'success': false,
                    'error': l10n.failedToLoadWebPage(message),
                  });
                },
                initialSettings: InAppWebViewSettings(
                  allowFileAccess: false,
                  allowContentAccess: false,
                  allowFileAccessFromFileURLs: false,
                ),
               ),
            ),
          ],
        ),
      ),
    );
  }
}
