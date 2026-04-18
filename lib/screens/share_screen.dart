import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html2md/html2md.dart';

import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../services/approval_service.dart';
import '../services/share_service.dart';
import '../services/ai_service.dart';
import '../services/content_ingestion_service.dart';
import '../services/service_locator.dart';
import '../services/logger_service.dart';
import '../services/web_content_extraction_service.dart';
import '../services/media_attachment_service.dart';
import '../services/network_provider.dart';
import '../utils/file_utils.dart';
import '../utils/file_type_utils.dart';
import '../utils/remote_image_utils.dart';
import '../utils/html_rules.dart';
import '../utils/markdown_cleaner.dart';
import '../utils/web_content_processor.dart';
import '../widgets/approval_dialog.dart';
import 'note_selection_dialog.dart';
import '../widgets/hierarchy_dialog.dart';

class ShareScreen extends StatefulWidget {
  final Map<String, dynamic> sharedData;

  const ShareScreen({super.key, required this.sharedData});

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
  String? _detectedUrl;
  String? _contentType;
  String _tagSearchQuery = '';
  String? _downloadedFilePath; // Track downloaded file path for cleanup
  List<RemoteImageReference> _remoteImages = const [];
  final Set<String> _selectedImageUrls = <String>{};
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _tagsController = TextEditingController();
  final Set<String> _selectedTags = <String>{};
  final Set<String> _filterDerivedTags = <String>{};
  final TextEditingController _newTagController = TextEditingController();
  final ScrollController _contentPreviewScrollController = ScrollController();
  final ScrollController _mediaSelectionScrollController = ScrollController();
  Future<ApprovalResult> Function(ApprovalRequest)? _approvalCallback;

  /// Check if running on Linux (non-web)
  bool get _isLinux => !kIsWeb && Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _setupApprovalCallback();
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
    _titleController.dispose();
    _tagsController.dispose();
    _newTagController.dispose();
    _contentPreviewScrollController.dispose();
    _mediaSelectionScrollController.dispose();
    if (ApprovalService.onApprovalRequest == _approvalCallback) {
      ApprovalService.onApprovalRequest = null;
    }
    super.dispose();
  }

  void _setupApprovalCallback() {
    _approvalCallback = (request) async {
      if (!mounted) {
        throw StateError('Share screen is not mounted');
      }
      return ApprovalDialog.showWithContext(context, request);
    };
    ApprovalService.onApprovalRequest = _approvalCallback;
  }

  /// Cleans up downloaded file if it exists and hasn't been added to a note
  Future<void> _cleanupDownloadedFile() async {
    if (_downloadedFilePath != null) {
      try {
        final absolutePath = await FileUtils.getFullFilePath(
          _downloadedFilePath!,
          true,
        );
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

  void _applyPreparedNote(
    Note? note, {
    List<RemoteImageReference>? precomputedImages,
  }) {
    _preparedNote = note;
    if (note == null) {
      _remoteImages = const [];
      _selectedImageUrls.clear();
    } else {
      _remoteImages =
          precomputedImages ??
          RemoteImageUtils.extractRemoteImages(note.content);
      _selectedImageUrls
        ..clear()
        ..addAll(_remoteImages.map((image) => image.url));
    }
  }

  void _toggleAllMediaSelection(bool selectAll) {
    setState(() {
      if (selectAll) {
        _selectedImageUrls
          ..clear()
          ..addAll(_remoteImages.map((image) => image.url));
      } else {
        _selectedImageUrls.clear();
      }
    });
  }

  void _toggleMediaUrl(String url, bool selected) {
    setState(() {
      if (selected) {
        _selectedImageUrls.add(url);
      } else {
        _selectedImageUrls.remove(url);
      }
    });
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
            _applyPreparedNote(note);
          });
          // Initialize the text controllers with the prepared note's data
          _titleController.text = note.title;
          _tagsController.text = note.tags.join(', ');
          _selectedTags.addAll(note.tags);
        } else if (result['contentType'] == 'image' ||
            result['contentType'] == 'pdf') {
          // For images and PDFs, show extraction options
          setState(() {
            _applyPreparedNote(null); // Will be created after extraction
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
    final activeNoteId = _selectedNote?.id ?? _preparedNote?.id;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.sharedContent)),
      body: _buildBodyWithWorkflowBanner(
        activeNoteId,
        _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _buildErrorWidget(l10n)
            : _buildContentWidget(l10n),
      ),
    );
  }

  Widget _buildBodyWithWorkflowBanner(String? noteId, Widget child) {
    // Workflow status is now shown globally via WorkflowShell + WorkflowMiniPlayer.
    return child;
  }

  Widget _buildErrorWidget(AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
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
    if (_preparedNote == null &&
        _contentType != 'url' &&
        _contentType != 'image' &&
        _contentType != 'pdf') {
      return Center(child: Text(l10n.noNotesAvailable));
    }

    // Show URL detection and extraction option
    if (_contentType == 'url' &&
        _detectedUrl != null &&
        _preparedNote == null) {
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
                    // Selected note display
                    if (_selectedNote != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.note,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _selectedNote!.title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                  if (_selectedNote!.content.isNotEmpty)
                                    Text(
                                      _selectedNote!.content.length > 60
                                          ? '${_selectedNote!.content.substring(0, 60)}...'
                                          : _selectedNote!.content,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: Colors.grey[600]),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                setState(() {
                                  _selectedNote = null;
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    // Button to open note selection dialog
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final selectedNotes = await showDialog<List<Note>>(
                            context: context,
                            builder: (context) => NoteSelectionDialog(
                              onNotesSelected: (notes) =>
                                  Navigator.of(context).pop(notes),
                              title: l10n.selectNoteToAppend,
                              singleSelection: true,
                            ),
                          );

                          if (selectedNotes != null &&
                              selectedNotes.isNotEmpty) {
                            setState(() {
                              // Take the first selected note
                              _selectedNote = selectedNotes.first;
                            });
                          }
                        },
                        icon: Icon(
                          _selectedNote == null ? Icons.note_add : Icons.edit,
                        ),
                        label: Text(l10n.selectNote),
                      ),
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
                            _preparedNote = _preparedNote!.copyWith(
                              title: value,
                            );
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
            // Media selection (only for create new note with remote images)
            if (_preparedNote != null && _remoteImages.isNotEmpty) ...[
              _buildMediaSelection(l10n),
              const SizedBox(height: 16),
            ],
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
                    Navigator.of(
                      context,
                    ).pushNamedAndRemoveUntil('/main', (route) => false);
                  },
                  child: Text(l10n.cancel),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed: (_isCreating || _isExtracting)
                      ? null
                      : _handleAction,
                  child: (_isCreating || _isExtracting)
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _action == 'create'
                              ? l10n.createNote
                              : l10n.appendToNote,
                        ),
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
        final allTags = appProvider.tags.map((tag) => tag.name).toList()
          ..sort();

        // Filter available tags based on search query
        final availableTags = allTags
            .where(
              (tag) =>
                  !_selectedTags.contains(tag) &&
                  (tag.toLowerCase().contains(_tagSearchQuery.toLowerCase())),
            )
            .toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.tags, style: Theme.of(context).textTheme.titleSmall),
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
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.7),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: _selectedTags.map((tag) {
                          return Chip(
                            label: Text(tag),
                            backgroundColor:
                                _filterDerivedTags.contains(tag)
                                    ? Colors.purple.withOpacity(0.1)
                                    : null,
                            deleteIcon: const Icon(Icons.close, size: 18),
                            onDeleted: () {
                              setState(() {
                                _selectedTags.remove(tag);
                                _filterDerivedTags.remove(tag);
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
                              if (value.trim().isNotEmpty &&
                                  !_selectedTags.contains(value.trim())) {
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
                            if (value.isNotEmpty &&
                                !_selectedTags.contains(value)) {
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
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () =>
                            _openFilterSelectionForTags(context, appProvider),
                        icon: const Icon(Icons.filter_list, size: 18),
                        label: Text(l10n.addFromFilter),
                      ),
                    ),

                    // Available tags to select from
                    if (availableTags.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        l10n.availableTags,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.7),
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

  void _openFilterSelectionForTags(
      BuildContext context, AppProvider appProvider) {
    showDialog(
      context: context,
      builder: (context) => HierarchyDialog(
        allFilters: appProvider.filters,
        filterPredicate: (f) => f.includeTags.isNotEmpty,
        onConfirmSelection: (selectedIds) {
          setState(() {
            for (final filterId in selectedIds) {
              try {
                final filter =
                    appProvider.filters.firstWhere((f) => f.id == filterId);
                for (final tag in filter.includeTags) {
                  if (!_selectedTags.contains(tag)) {
                    _selectedTags.add(tag);
                    _filterDerivedTags.add(tag);
                  } else {
                    _filterDerivedTags.add(tag);
                  }
                }
              } catch (_) {}
            }
            _updatePreparedNoteTags();
          });
        },
        onEdit: (_) {},
        onPin: (_) {},
        onDelete: (_) {},
      ),
    );
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
                      Icon(Icons.warning, color: Colors.orange[700], size: 32),
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
                        style: TextStyle(color: Colors.orange[600]),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              l10n.shareUrlChoiceTitle,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.shareUrlChoiceDescription,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[700]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isLinux || _isExtracting
                        ? null
                        : _extractWebContent,
                    child: _isExtracting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.webExtractionManualExtract),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _isExtracting ? null : _createUrlAsIs,
                    child: Text(l10n.asIs),
                  ),
                ),
              ],
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
        _applyPreparedNote(note);
        _isExtracting = false;
      });
    } catch (e) {
      setState(() {
        _error = l10n.failedToPrepareNote(e.toString());
        _isExtracting = false;
      });
    }
  }

  Future<void> _extractWebContent() async {
    if (_detectedUrl == null) return;

    final l10n = AppLocalizations.of(context)!;

    setState(() {
      _isExtracting = true;
      _error = null;
    });

    try {
      // Show a dialog with the WebView for content extraction
      final result = await _showWebExtractionDialog(_detectedUrl!);

      if (result['success'] == true) {
        final note = result['note'] as Note;
        final precomputedImages =
            result['precomputedImages'] as List<RemoteImageReference>?;

        // Handle downloaded file path - only track it for cleanup, don't add it again if already in note
        if (result['downloadedFilePath'] != null) {
          _downloadedFilePath = result['downloadedFilePath'] as String;
          // Check if the attachment is already in the note's attachmentPaths
          final attachmentAlreadyInNote = note.attachmentPaths.contains(
            _downloadedFilePath!,
          );
          if (!attachmentAlreadyInNote) {
            // Only add if not already present
            final noteWithAttachment = note.copyWith(
              attachmentPaths: [...note.attachmentPaths, _downloadedFilePath!],
            );
            setState(() {
              _applyPreparedNote(
                noteWithAttachment,
                precomputedImages: precomputedImages,
              );
              _isExtracting = false;
            });
          } else {
            // Already in note, just use the note as-is
            setState(() {
              _applyPreparedNote(note, precomputedImages: precomputedImages);
              _isExtracting = false;
            });
          }
        } else {
          setState(() {
            _applyPreparedNote(note, precomputedImages: precomputedImages);
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

  Future<Map<String, dynamic>> _showWebExtractionDialog(String url) async {
    final completer = Completer<Map<String, dynamic>>();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _WebExtractionDialog(
        url: url,
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
                    label: Text(
                      _isExtracting
                          ? l10n.extracting
                          : l10n.extractImageContent,
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
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
                      label: Text(
                        _isExtracting
                            ? l10n.extractingWithAi
                            : l10n.extractWithAi,
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.secondary,
                        foregroundColor: Theme.of(
                          context,
                        ).colorScheme.onSecondary,
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
                    label: Text(
                      _isExtracting ? l10n.extracting : l10n.extractPdfContent,
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
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
                      label: Text(
                        _isExtracting
                            ? l10n.extractingWithAi
                            : l10n.extractWithAi,
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.secondary,
                        foregroundColor: Theme.of(
                          context,
                        ).colorScheme.onSecondary,
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
      // Use ShareService to process the image content (copies to storage)
      final result = await ShareService.processSharedContent({
        'action': 'SEND',
        'type': 'image/jpeg', // Trigger image processing path
        'filePath': filePath,
        'fileName': fileName,
      });

      if (result['success'] != true) {
        setState(() {
          _isExtracting = false;
          _error = result['error'] ?? 'Could not process image file';
        });
        return;
      }

      Note note = result['note'] as Note;
      final relativePath = note.attachmentPaths.first;

      if (useAI) {
        // Let AI service handle API key validation

        // Extract content using AI - use the saved file path
        final absolutePath = await FileUtils.getFullFilePath(
          relativePath,
          true,
        );

        final aiResult = await getIt<AIService>().extractContentFromImage(
          absolutePath,
        );
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
        _applyPreparedNote(note);
        _isExtracting = false;
      });

      // Initialize the text controllers with the extracted note's data
      _titleController.text = note.title;
      _tagsController.text = note.tags.join(', ');
      _selectedTags.clear();
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
        final absolutePath = await FileUtils.getFullFilePath(
          relativePath,
          true,
        );
        final aiResult = await getIt<AIService>().extractContentFromPdf(
          absolutePath,
        );
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
        _applyPreparedNote(note);
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
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 600),
            child: Scrollbar(
              controller: _contentPreviewScrollController,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _contentPreviewScrollController,
                child: Text(
                  note.content,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ),
        ),
        if (note.attachmentPaths.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '${l10n.attachments}:',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 4),
          ...note.attachmentPaths.map(
            (path) => Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text(
                '• ${path.split('/').last}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
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

  Widget _buildMediaSelection(AppLocalizations l10n) {
    if (_remoteImages.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Icon(
                Icons.photo_library_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.noRemoteImagesDetected,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final allSelected = _selectedImageUrls.length == _remoteImages.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  l10n.mediaDownloadsHeader,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => _toggleAllMediaSelection(!allSelected),
                  child: Text(allSelected ? l10n.clearAll : l10n.selectAll),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l10n.mediaDownloadsDescription,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            _buildMediaSelectionTable(l10n),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaSelectionTable(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              l10n.mediaPreviewLabel,
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                l10n.imageUrlLabel,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            const SizedBox(width: 16),
            Text(
              l10n.downloadToLocalLabel,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: Scrollbar(
            controller: _mediaSelectionScrollController,
            thumbVisibility: true,
            child: ListView.separated(
              controller: _mediaSelectionScrollController,
              shrinkWrap: true,
              itemCount: _remoteImages.length,
              itemBuilder: (context, index) =>
                  _buildMediaRow(_remoteImages[index]),
              separatorBuilder: (context, index) => const Divider(height: 16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMediaRow(RemoteImageReference media) {
    final isSelected = _selectedImageUrls.contains(media.url);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 72,
            height: 72,
            color: Theme.of(
              context,
            ).colorScheme.surfaceVariant.withOpacity(0.3),
            child: Image.network(
              media.url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Icon(
                Icons.broken_image,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SelectableText(
            media.url,
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 3,
          ),
        ),
        const SizedBox(width: 12),
        Checkbox(
          value: isSelected,
          onChanged: (value) => _toggleMediaUrl(media.url, value ?? false),
        ),
      ],
    );
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
      final key = _attachmentKey(normalized);
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

  String _attachmentKey(String path) {
    return path.toLowerCase();
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

  void _showMediaDownloadFailures(
    RemoteImageDownloadReport? report,
    AppLocalizations l10n,
  ) {
    if (!mounted || report == null || report.failedUrls.isEmpty) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.mediaDownloadFailed(report.failedUrls.length)),
        backgroundColor: Colors.orange,
      ),
    );
  }

  Future<void> _handleAction() async {
    final l10n = AppLocalizations.of(context)!;

    if (_action == 'append' && _selectedNote == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.pleaseSelectNoteToAppend)));
      return;
    }

    setState(() {
      _isCreating = true;
    });

    // Capture ScaffoldMessenger and Navigator before any async operations
    // to avoid using deactivated context
    ScaffoldMessengerState? scaffoldMessenger;
    NavigatorState? navigator;
    if (mounted) {
      scaffoldMessenger = ScaffoldMessenger.of(context);
      navigator = Navigator.of(context);
    }

    try {
      final appProvider = context.read<AppProvider>();

      if (_action == 'create') {
        // Create note with edited title and tags
        var finalNote = _preparedNote!.copyWith(
          title: _titleController.text.isNotEmpty
              ? _titleController.text
              : _preparedNote!.title,
          tags: _selectedTags.isNotEmpty
              ? _selectedTags.toList()
              : _preparedNote!.tags,
        );

        RemoteImageDownloadReport? downloadReport;
        if (_selectedImageUrls.isNotEmpty) {
          downloadReport = await MediaAttachmentService.downloadRemoteImages(
            noteId: finalNote.id,
            imageUrls: _selectedImageUrls,
          );
          finalNote = finalNote.copyWith(
            attachmentPaths: _mergeAttachmentPaths(
              finalNote.attachmentPaths,
              downloadReport.urlToRelativePath.values,
            ),
          );
        }

        await appProvider.addNote(finalNote);

        // Trigger AI content ingestion if needed (fire and forget)
        if (!finalNote.content.contains('> [!SUMMARY]')) {
          getIt<ContentIngestionService>().processNote(
            finalNote,
            appProvider,
            onMessage: (_) {},
            onError: (msg) =>
                LoggerService.error('Share Screen AI Ingestion Error: $msg'),
            onSuccess: () {},
          );
        }

        // Clear downloaded file path after successful note creation
        _downloadedFilePath = null;
        _showMediaDownloadFailures(downloadReport, l10n);
        if (mounted && scaffoldMessenger != null && navigator != null) {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(l10n.noteCreatedSuccessfully(finalNote.title)),
              backgroundColor: Colors.green,
            ),
          );
          // Navigate to main screen instead of just popping
          navigator.pushNamedAndRemoveUntil('/main', (route) => false);
        }
      } else {
        RemoteImageDownloadReport? downloadReport;
        if (_selectedImageUrls.isNotEmpty) {
          downloadReport = await MediaAttachmentService.downloadRemoteImages(
            noteId: _selectedNote!.id,
            imageUrls: _selectedImageUrls,
          );
        }

        // Append to existing note
        final updatedNote = _selectedNote!.copyWith(
          content:
              '${_selectedNote!.content}\n\n--- Shared Content ---\n${_preparedNote!.content}',
          updatedAt: DateTime.now(),
          attachmentPaths: _mergeAttachmentPaths([
            ..._selectedNote!.attachmentPaths,
            ..._preparedNote!.attachmentPaths,
          ], downloadReport?.urlToRelativePath.values ?? const []),
          tags: [
            ..._selectedNote!.tags,
            ..._preparedNote!.tags.where(
              (tag) => !_selectedNote!.tags.contains(tag),
            ),
          ],
        );

        await appProvider.updateNote(updatedNote);

        // Trigger AI content ingestion if needed (fire and forget)
        if (!updatedNote.content.contains('> [!SUMMARY]')) {
          getIt<ContentIngestionService>().processNote(
            updatedNote,
            appProvider,
            onMessage: (_) {},
            onError: (msg) =>
                LoggerService.error('Share Screen AI Ingestion Error: $msg'),
            onSuccess: () {},
          );
        }

        // Clear downloaded file path after successful note update
        _downloadedFilePath = null;
        _showMediaDownloadFailures(downloadReport, l10n);
        if (mounted && scaffoldMessenger != null && navigator != null) {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(l10n.contentAppendedSuccessfully),
              backgroundColor: Colors.green,
            ),
          );
          // Navigate to main screen instead of just popping
          navigator.pushNamedAndRemoveUntil('/main', (route) => false);
        }
      }
    } catch (e) {
      setState(() {
        _isCreating = false;
      });

      if (mounted && scaffoldMessenger != null) {
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
}

class _WebExtractionDialog extends StatefulWidget {
  final String url;
  final Function(Map<String, dynamic>) onComplete;

  const _WebExtractionDialog({required this.url, required this.onComplete});

  @override
  State<_WebExtractionDialog> createState() => _WebExtractionDialogState();
}

class _WebExtractionDialogState extends State<_WebExtractionDialog> {
  bool _isLoading = true;
  bool _isProcessing = false;
  bool _isApplyingReadability = false;
  bool _readabilityEnabled = true;
  bool _isDownloading = false;
  bool _fileDownloaded = false;
  bool _downloadFailed = false;
  bool _fileCheckCompleted = false;
  bool _hasStartedFileCheck = false;
  String _status = '';
  String? _errorMessage;
  String? _downloadedFilePath;
  String? _activeAction;
  InAppWebViewController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hasStartedFileCheck) {
      return;
    }
    _hasStartedFileCheck = true;
    _status = AppLocalizations.of(context)!.loadingWebPage;
    _checkAndDownloadFile();
  }

  Future<void> _checkAndDownloadFile() async {
    try {
      final l10n = AppLocalizations.of(context)!;

      final uri = Uri.parse(widget.url);
      final path = uri.path.toLowerCase();
      final hasFileExtension =
          path.endsWith('.pdf') ||
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

      String? detectedContentType;
      if (!hasFileExtension) {
        setState(() {
          _status = l10n.webExtractionStatusCheckingFileType;
        });
        try {
          final headResponse = await NetworkProvider.head(
            Uri.parse(widget.url),
          );
          if (headResponse.statusCode == 200) {
            detectedContentType = headResponse.headers['content-type']
                ?.toLowerCase();
          }
        } catch (_) {
          // Ignore HEAD failures and fall back to WebView.
        }
      }

      final contentType = detectedContentType ?? '';

      final isPdfOrStaticFile =
          hasFileExtension ||
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

      final isRawTextOrCode =
          !contentType.startsWith('text/html') &&
          (contentType.startsWith('text/') ||
              contentType.startsWith('application/json') ||
              contentType.startsWith('application/xml') ||
              contentType.startsWith('application/javascript') ||
              contentType.startsWith('text/x-java-source') ||
              path.endsWith('.java') ||
              path.endsWith('.kt') ||
              path.endsWith('.dart') ||
              path.endsWith('.py') ||
              path.endsWith('.js') ||
              path.endsWith('.ts') ||
              path.endsWith('.c') ||
              path.endsWith('.cpp') ||
              path.endsWith('.h') ||
              path.endsWith('.cs') ||
              path.endsWith('.go') ||
              path.endsWith('.rs') ||
              path.endsWith('.rb') ||
              path.endsWith('.php') ||
              path.endsWith('.sh') ||
              path.endsWith('.md') ||
              path.endsWith('.txt') ||
              path.endsWith('.xml') ||
              path.endsWith('.gradle') ||
              path.endsWith('.properties') ||
              path.endsWith('.sql') ||
              path.endsWith('.json') ||
              path.endsWith('.yaml') ||
              path.endsWith('.yml'));

      if (isRawTextOrCode && !isPdfOrStaticFile) {
        setState(() {
          _isDownloading = true;
          _status = l10n.webExtractionStatusDownloadingFile;
        });

        try {
          final response = await NetworkProvider.get(Uri.parse(widget.url));
          if (response.statusCode == 200) {
            final content = response.body;

            String language = '';
            if (path.endsWith('.java'))
              language = 'java';
            else if (path.endsWith('.kt'))
              language = 'kotlin';
            else if (path.endsWith('.dart'))
              language = 'dart';
            else if (path.endsWith('.py'))
              language = 'python';
            else if (path.endsWith('.js'))
              language = 'javascript';
            else if (path.endsWith('.ts'))
              language = 'typescript';
            else if (path.endsWith('.c'))
              language = 'c';
            else if (path.endsWith('.cpp'))
              language = 'cpp';
            else if (path.endsWith('.h'))
              language = 'cpp';
            else if (path.endsWith('.cs'))
              language = 'csharp';
            else if (path.endsWith('.go'))
              language = 'go';
            else if (path.endsWith('.rs'))
              language = 'rust';
            else if (path.endsWith('.rb'))
              language = 'ruby';
            else if (path.endsWith('.php'))
              language = 'php';
            else if (path.endsWith('.sh'))
              language = 'bash';
            else if (path.endsWith('.md'))
              language = 'markdown';
            else if (path.endsWith('.xml'))
              language = 'xml';
            else if (path.endsWith('.gradle'))
              language = 'gradle';
            else if (path.endsWith('.properties'))
              language = 'properties';
            else if (path.endsWith('.sql'))
              language = 'sql';
            else if (path.endsWith('.json'))
              language = 'json';
            else if (path.endsWith('.yaml'))
              language = 'yaml';
            else if (path.endsWith('.yml'))
              language = 'yaml';
            else if (path.endsWith('.html'))
              language = 'html';
            else if (path.endsWith('.css'))
              language = 'css';

            final note = Note(
              id: const Uuid().v4(),
              title: path.split('/').last,
              content: '```$language\n$content\n```',
              type: NoteType.note,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              tags: ['shared', 'code', 'web-clip'],
            );

            if (!mounted) return;

            setState(() {
              _fileDownloaded = true;
              _isDownloading = false;
              _isLoading = false;
              _status = l10n.webExtractionStatusFileDownloaded;
            });

            await Future.delayed(const Duration(milliseconds: 500));

            widget.onComplete({
              'success': true,
              'note': note,
              'contentType': 'text',
            });
            return;
          }
        } catch (e) {
          // Fallback to WebView if direct download fails
          print('Direct download failed: $e');
        }
      }

      if (isPdfOrStaticFile) {
        setState(() {
          _isDownloading = true;
          _status = l10n.webExtractionStatusDownloadingFile;
        });

        try {
          final response = await NetworkProvider.get(Uri.parse(widget.url));

          if (response.statusCode == 200) {
            final responseContentType =
                response.headers['content-type']?.toLowerCase() ?? contentType;
            final isBinaryContent =
                responseContentType.startsWith('application/pdf') ||
                responseContentType.startsWith('application/msword') ||
                responseContentType.startsWith('application/vnd.ms-word') ||
                responseContentType.startsWith('application/vnd.ms-excel') ||
                responseContentType.startsWith(
                  'application/vnd.ms-powerpoint',
                ) ||
                responseContentType.startsWith(
                  'application/vnd.openxmlformats',
                ) ||
                responseContentType.startsWith('application/zip') ||
                responseContentType.startsWith('application/x-rar') ||
                responseContentType.startsWith('application/x-tar') ||
                responseContentType.startsWith('application/gzip') ||
                (responseContentType.startsWith('application/') &&
                    !responseContentType.startsWith('application/json') &&
                    !responseContentType.startsWith('application/xml') &&
                    !responseContentType.startsWith(
                      'application/javascript',
                    )) ||
                !responseContentType.startsWith('text/') &&
                    !responseContentType.startsWith('image/') &&
                    !responseContentType.startsWith('video/');

            if (isBinaryContent || isPdfOrStaticFile) {
              String fileName = path.split('/').last;
              if (fileName.isEmpty || !fileName.contains('.')) {
                final contentDisposition =
                    response.headers['content-disposition'];
                if (contentDisposition != null) {
                  final filenameRegex = RegExp(
                    r'filename\s*=\s*(?:"([^"]+)"|([^;]+))',
                  );
                  final filenameMatch = filenameRegex.firstMatch(
                    contentDisposition,
                  );
                  if (filenameMatch != null) {
                    final matchedFilename =
                        filenameMatch.group(1) ?? filenameMatch.group(2);
                    if (matchedFilename != null &&
                        matchedFilename.trim().isNotEmpty) {
                      fileName = matchedFilename.trim();
                    }
                  }
                }

                if (fileName.isEmpty || !fileName.contains('.')) {
                  if (responseContentType.contains('pdf')) {
                    fileName = 'document.pdf';
                  } else if (responseContentType.contains('msword') ||
                      responseContentType.contains('wordprocessingml')) {
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

              final currentExt = FileTypeUtils.getFileExtension(fileName);
              String effectiveMime = responseContentType;
              if (effectiveMime.isEmpty ||
                  effectiveMime.startsWith('application/octet-stream')) {
                effectiveMime = FileTypeUtils.getMimeTypeForBytes(
                  response.bodyBytes,
                  extension: currentExt.isEmpty ? null : currentExt,
                );
              }
              final expectedExt = FileTypeUtils.getExtensionForMime(
                effectiveMime,
              );
              if (currentExt.isEmpty && expectedExt.isNotEmpty) {
                fileName = '$fileName.$expectedExt';
              } else if (currentExt.isNotEmpty &&
                  expectedExt.isNotEmpty &&
                  expectedExt != 'bin' &&
                  currentExt != expectedExt) {
                final base = fileName.substring(0, fileName.lastIndexOf('.'));
                fileName = '$base.$expectedExt';
              }

              final relativePath = await FileUtils.saveFileToPrivateStorage(
                response.bodyBytes,
                fileName,
              );

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

              if (!mounted) {
                return;
              }

              setState(() {
                _downloadedFilePath = relativePath;
                _fileDownloaded = true;
                _isDownloading = false;
                _isLoading = false;
                _status = l10n.webExtractionStatusFileDownloaded;
              });

              await Future.delayed(const Duration(milliseconds: 500));

              widget.onComplete({
                'success': true,
                'note': note,
                'downloadedFilePath': relativePath,
                'contentType': 'file',
              });
              return;
            }
          } else {
            if (!mounted) {
              return;
            }
            setState(() {
              _downloadFailed = true;
              _isDownloading = false;
              _isLoading = false;
              _status = l10n.webExtractionStatusDownloadFailed(
                'HTTP ${response.statusCode}',
              );
            });
            widget.onComplete({
              'success': false,
              'error': l10n.errorDownloading(
                'HTTP ${response.statusCode}',
                widget.url,
              ),
            });
            return;
          }
        } catch (e) {
          if (!mounted) {
            return;
          }
          setState(() {
            _downloadFailed = true;
            _isDownloading = false;
            _isLoading = false;
            _status = l10n.webExtractionStatusDownloadFailed(e.toString());
          });
          widget.onComplete({
            'success': false,
            'error': l10n.errorDownloading(e.toString(), widget.url),
          });
          return;
        }
      }
    } catch (_) {
      setState(() {
        _isDownloading = false;
      });
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _fileCheckCompleted = true;
      _isLoading = true;
      _status = AppLocalizations.of(context)!.loadingWebPage;
    });
  }

  Future<void> _handleCancel() async {
    await _deleteDownloadedFileIfNeeded();
    if (!mounted) {
      return;
    }
    widget.onComplete({
      'success': false,
      'error': AppLocalizations.of(context)!.extractionCancelledByUser,
    });
  }

  Future<void> _deleteDownloadedFileIfNeeded() async {
    if (_downloadedFilePath == null) {
      return;
    }
    try {
      final absolutePath = await FileUtils.getFullFilePath(
        _downloadedFilePath!,
        true,
      );
      final file = File(absolutePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Ignore cleanup errors.
    }
  }

  Future<void> _handleReadabilityToggle(bool enabled) async {
    if (_controller == null) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;

    if (!enabled) {
      setState(() {
        _readabilityEnabled = false;
        _isApplyingReadability = true;
        _status = l10n.webExtractionStatusReloadingOriginal;
      });
      await _reloadCurrentPage();
      if (!mounted) {
        return;
      }
      setState(() {
        _isApplyingReadability = false;
        _status = l10n.loadingWebPage;
      });
      return;
    }

    setState(() {
      _readabilityEnabled = true;
      _errorMessage = null;
    });

    await _applyReadabilityMode();
  }

  Future<void> _reloadCurrentPage() async {
    if (_controller == null) {
      return;
    }
    await _controller!.reload();
  }

  Future<bool> _applyReadabilityMode() async {
    if (_controller == null) {
      return false;
    }

    final l10n = AppLocalizations.of(context)!;

    setState(() {
      _isApplyingReadability = true;
      _status = l10n.webExtractionStatusApplyingReadability;
      _errorMessage = null;
    });

    try {
      await WebContentExtractionService.applyReadabilityView(_controller!);
      if (!mounted) {
        return true;
      }
      setState(() {
        _isApplyingReadability = false;
        _status = l10n.webExtractionStatusReadabilityEnabled;
      });
      return true;
    } on ReadabilityExtractionException catch (e) {
      if (!mounted) {
        return false;
      }
      // Save error message before reload
      final errorMsg = l10n.readabilityExtractionFailed(e.message);
      // Reload the page to remove readability injections
      setState(() {
        _readabilityEnabled = false;
        _isApplyingReadability = true;
        _status = l10n.webExtractionStatusReloadingOriginal;
        _errorMessage = errorMsg;
      });
      await _reloadCurrentPage();
      if (!mounted) {
        return false;
      }
      // Restore error message after reload (onLoadStop may have cleared it)
      setState(() {
        _isApplyingReadability = false;
        _status = l10n.webExtractionStatusReady;
        _errorMessage = errorMsg;
      });
    } catch (e) {
      if (!mounted) {
        return false;
      }
      // Save error message before reload
      final errorMsg = e.toString();
      // Reload the page to remove readability injections
      setState(() {
        _readabilityEnabled = false;
        _isApplyingReadability = true;
        _status = l10n.webExtractionStatusReloadingOriginal;
        _errorMessage = errorMsg;
      });
      await _reloadCurrentPage();
      if (!mounted) {
        return false;
      }
      // Restore error message after reload (onLoadStop may have cleared it)
      setState(() {
        _isApplyingReadability = false;
        _status = l10n.webExtractionStatusReady;
        _errorMessage = errorMsg;
      });
    }
    return false;
  }

  Future<String> _getCurrentPageBodyHtml() async {
    if (_controller == null) {
      throw Exception('WebView controller not ready');
    }
    final l10n = AppLocalizations.of(context)!;

    // Execute JavaScript to extract content and return a JSON string with status and debug info
    final result = await _controller!.evaluateJavascript(
      source: '''
        (function() {
          var debug = {
            contentType: document.contentType,
            url: window.location.href,
            hasBody: !!document.body,
            hasDocEl: !!document.documentElement,
            bodyTextLength: document.body ? document.body.innerText.length : -1,
            docTextLength: document.documentElement ? document.documentElement.innerText.length : -1
          };

          function escapeHtml(text) {
            if (!text) return "";
            return text
                .replace(/&/g, "&amp;")
                .replace(/</g, "&lt;")
                .replace(/>/g, "&gt;")
                .replace(/"/g, "&quot;")
                .replace(/'/g, "&#039;");
          }

          try {
            // Handle plain text or code files directly
            var isText = document.contentType === 'text/plain' || 
                document.contentType === 'text/x-java-source' ||
                document.contentType === 'application/json' ||
                window.location.pathname.match(/\\.(java|kt|dart|py|js|ts|c|cpp|h|cs|go|rs|rb|php|sh|md|txt|xml|gradle|properties|sql|json|yaml|yml)\$/i);

            debug.isText = !!isText;

            if (isText) {
              var content = document.body ? document.body.innerText : (document.documentElement ? document.documentElement.innerText : '');
              // If content is found, wrap it in pre tags to preserve formatting
              if (content && content.trim().length > 0) {
                return JSON.stringify({
                  status: 'success',
                  content: '<pre>' + escapeHtml(content) + '</pre>',
                  debug: debug
                });
              } else {
                 debug.error = "Empty content for text document";
              }
            }

            if (document.body) {
              return JSON.stringify({
                  status: 'success',
                  content: document.body.innerHTML,
                  debug: debug
              });
            }
            
            var docContent = document.documentElement ? document.documentElement.innerHTML : '';
            if (docContent) {
               return JSON.stringify({
                  status: 'success',
                  content: docContent,
                  debug: debug
               });
            }

            return JSON.stringify({
              status: 'error',
              message: 'No content found',
              debug: debug
            });
          } catch (e) {
            return JSON.stringify({
              status: 'error',
              message: e.toString(),
              debug: debug
            });
          }
        })();
      ''',
    );

    if (result == null) {
      throw Exception("JavaScript execution returned null");
    }

    try {
      final Map<String, dynamic> response = jsonDecode(result.toString());

      if (response['status'] == 'success') {
        final content = response['content'] as String?;
        if (content == null || content.isEmpty) {
          throw Exception(
            "Extracted content is empty. Debug: ${jsonEncode(response['debug'])}",
          );
        }
        return content;
      } else {
        final message = response['message'] ?? 'Unknown error';
        final debug = response['debug'];
        throw Exception("$message. Debug: ${jsonEncode(debug)}");
      }
    } catch (e) {
      if (e.toString().contains('Debug:')) {
        rethrow;
      }
      throw Exception(
        "${l10n.failedToExtractContentFromWebPage}. Error parsing result: $e. Raw result: $result",
      );
    }
  }

  Future<String> _getCurrentPageTitle() async {
    if (_controller == null) {
      return '';
    }
    final result = await _controller!.evaluateJavascript(
      source: 'document.title || ""',
    );
    return result?.toString().trim() ?? '';
  }

  Future<void> _performExtraction({required bool useAI}) async {
    if (_controller == null) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;

    setState(() {
      _isProcessing = true;
      _activeAction = useAI ? 'ai' : 'extract';
      _status = useAI ? l10n.processingWithAi : l10n.extractingContent;
      _errorMessage = null;
    });

    try {
      final htmlContent = await _getCurrentPageBodyHtml();

      // Run heavy parsing in background isolate
      String finalContent = await compute(
        WebContentProcessor.processHtml,
        htmlContent,
      );

      var title = await _getCurrentPageTitle();
      if (title.isEmpty) {
        title = 'Web Content - ${DateTime.now().toString().substring(0, 16)}';
      }

      final tags = <String>{'shared', 'web', 'extracted'};
      if (_readabilityEnabled) {
        tags.add('readability');
      }

      if (useAI) {
        // Use the cleaned content as input for AI processing
        final aiResult = await getIt<AIService>().extractContentFromText(
          finalContent,
          'web_content',
          title,
        );
        if (aiResult['success'] == true) {
          finalContent = aiResult['content'] ?? finalContent;
          tags.add('ai_processed');
        }
      } else {
        tags.add('markdown');
      }

      // Process data URLs in the content
      final dataUrlResult = await _processDataUrls(finalContent);
      finalContent = dataUrlResult['content'] as String;
      final newAttachments = dataUrlResult['attachments'] as List<String>;

      final note = Note(
        id: const Uuid().v4(),
        title: title,
        content: finalContent,
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        tags: tags.toList(),
        attachmentPaths: newAttachments,
      );

      final preview = title.isNotEmpty
          ? title
          : 'Web content extracted from ${widget.url}';

      // Extract remote images in background isolate
      final remoteImages = await compute(
        WebContentProcessor.extractImages,
        finalContent,
      );

      widget.onComplete({
        'success': true,
        'note': note,
        'contentType': 'web',
        'preview': preview,
        'url': widget.url,
        'precomputedImages': remoteImages,
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isProcessing = false;
        _activeAction = null;
        _errorMessage = e.toString();
        _status = l10n.errorExtractingWebContent(e.toString());
      });
    }
  }

  Future<Map<String, dynamic>> _processDataUrls(String content) async {
    String processedContent = content;
    final List<String> newAttachments = [];

    // Regex to find data URLs in markdown images: ![](data:image/type;base64,data)
    // Captures: 1=alt text, 2=mime type, 3=base64 data
    final dataUrlPattern = RegExp(
      r'!\[([^\]]*)\]\(data:image\/([a-zA-Z0-9]+);base64,([^)]+)\)',
    );

    final matches = dataUrlPattern.allMatches(content).toList();

    // Process matches in reverse order to avoid index issues when replacing
    for (final match in matches.reversed) {
      try {
        final altText = match.group(1) ?? '';
        final extension = match.group(2) ?? 'png';
        final base64Data = match.group(3);

        if (base64Data != null) {
          // Decode base64 data
          // Remove any newlines or whitespace that might be in the base64 string
          final cleanBase64 = base64Data.replaceAll(RegExp(r'\s'), '');
          final bytes = base64Decode(cleanBase64);

          // Generate a filename
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final filename = 'extracted_image_$timestamp.$extension';

          // Save to private storage
          final relativePath = await FileUtils.saveFileToPrivateStorage(
            bytes,
            filename,
          );

          newAttachments.add(relativePath);

          // The user requested that the replacement should NOT include "attachments/" portion,
          // but only the base name.
          // FileUtils.saveFileToPrivateStorage returns 'attachments/filename', so we split it.
          final baseName = relativePath.split('/').last;

          // Replace the data URL with the local filename
          final replacement = '![$altText]($baseName)';

          processedContent = processedContent.replaceRange(
            match.start,
            match.end,
            replacement,
          );
        }
      } catch (e) {
        print('Error processing data URL: $e');
        // Continue to next match if one fails
      }
    }

    return {'content': processedContent, 'attachments': newAttachments};
  }

  Widget _buildHeader(AppLocalizations l10n) {
    return Container(
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
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: Colors.white),
            ),
          ),
          IconButton(
            onPressed: _isProcessing ? null : _handleCancel,
            icon: const Icon(Icons.close, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_isLoading || _isApplyingReadability || _isProcessing)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (_isLoading || _isApplyingReadability || _isProcessing)
                const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _status,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
    );
  }

  Widget _buildReadabilityToggle(AppLocalizations l10n) {
    final toggleBackground = Theme.of(
      context,
    ).colorScheme.primaryContainer.withValues(alpha: 0.3);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: toggleBackground),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.webExtractionReadabilityLabel,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.webExtractionReadabilityDescription,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey[700]),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: _readabilityEnabled,
            onChanged:
                (_isLoading ||
                    _isApplyingReadability ||
                    _isProcessing ||
                    _controller == null)
                ? null
                : _handleReadabilityToggle,
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed:
                      (_controller == null || _isProcessing || _isLoading)
                      ? null
                      : () => _performExtraction(useAI: false),
                  child: _isProcessing && _activeAction == 'extract'
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.webExtractionManualExtract),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Tooltip(
                  message: l10n.extractContentUsingAiForBetterResults,
                  child: ElevatedButton(
                    onPressed:
                        (_controller == null || _isProcessing || _isLoading)
                        ? null
                        : () => _performExtraction(useAI: true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.secondary,
                      foregroundColor: Theme.of(
                        context,
                      ).colorScheme.onSecondary,
                    ),
                    child: _isProcessing && _activeAction == 'ai'
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.webExtractionAiExtract),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: _isProcessing ? null : _handleCancel,
              child: Text(l10n.cancel),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebView(AppLocalizations l10n) {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.url)),
      onWebViewCreated: (controller) => _controller = controller,
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final url = navigationAction.request.url;
        if (url == null) {
          return NavigationActionPolicy.CANCEL;
        }

        final scheme = url.scheme.toLowerCase();
        if ([
          'http',
          'https',
          'data',
          'about',
          'file',
          'javascript',
        ].contains(scheme)) {
          return NavigationActionPolicy.ALLOW;
        }
        return NavigationActionPolicy.CANCEL;
      },
      onLoadStart: (controller, url) {
        setState(() {
          _isLoading = true;
          _status = l10n.loadingWebPage;
          _errorMessage = null;
          _isApplyingReadability = false;
        });
      },
      onLoadStop: (controller, url) async {
        if (!mounted) {
          return;
        }
        setState(() {
          _isLoading = false;
          _status = l10n.webExtractionStatusReady;
          _errorMessage = null;
        });

        if (_readabilityEnabled) {
          await _applyReadabilityMode();
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (_fileDownloaded) {
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

    if (_downloadFailed) {
      return Dialog(
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text(
                _status,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (_isDownloading || !_fileCheckCompleted) {
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
      child: SizedBox(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            _buildHeader(l10n),
            _buildStatusSection(),
            _buildReadabilityToggle(l10n),
            Expanded(child: _buildWebView(l10n)),
            _buildActionButtons(l10n),
          ],
        ),
      ),
    );
  }
}
