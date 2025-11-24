import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';

import 'package:re_editor/re_editor.dart';

import '../l10n/app_localizations.dart';
import '../models/app_revision.dart';
import '../models/note.dart';
import '../models/user_app.dart';
import '../models/user_app_library.dart';
import '../providers/app_provider.dart';
import '../services/user_app_library_service.dart';

import 'note_selection_dialog.dart';
import '../widgets/synapse_code_editor.dart';

class UserAppEditScreen extends StatefulWidget {
  final UserApp app;
  final AppRevision? selectedRevision;

  const UserAppEditScreen({
    super.key,
    required this.app,
    this.selectedRevision,
  });

  @override
  State<UserAppEditScreen> createState() => _UserAppEditScreenState();
}

class _UserAppEditScreenState extends State<UserAppEditScreen>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _editSuggestionController = TextEditingController();

  late final CodeLineEditingController _codeController;
  late final CodeLineEditingController
  _viewController; // Read-only controller for viewing

  bool _isEditing = false;
  bool _isSaving = false;
  bool _isCodeEditable = false;
  bool _isSearchVisible = false; // Control search input visibility
  String _originalCode = '';

  List<String> _attachmentPaths = [];
  final List<Note> _selectedNotes = [];

  // Tab management
  late TabController _tabController;

  // Library management
  List<UserAppLibrary> _modifiedLibraries = [];
  Map<int, List<String>> _libraryLinks = {}; // libraryId -> list of links
  bool _isLoadingLibraries = false;

  // Prevent rapid state changes during transitions
  bool _isTransitioning = false;

  @override
  void initState() {
    super.initState();
    _codeController = CodeLineEditingController.fromText('');
    _viewController = CodeLineEditingController.fromText('');

    _tabController = TabController(length: 2, vsync: this);
    _loadCurrentRevisionCode();

    _loadCurrentLibraries();
  }

  AppRevision? _currentRevision;

  Future<void> _loadCurrentRevisionCode() async {
    try {
      final appProvider = context.read<AppProvider>();
      await appProvider.getAppRevisions(widget.app.id);

      // Get revisions from provider
      final revisions = appProvider.appRevisions[widget.app.id] ?? [];

      String codeToLoad = '';

      // Use the passed selected revision if available, otherwise fall back to pinned revision
      if (widget.selectedRevision != null) {
        // Use the temporarily selected revision
        _currentRevision = widget.selectedRevision;
        codeToLoad = widget.selectedRevision!.appCode;
      } else {
        // Fall back to the pinned revision (current app's selectedRevisionId)
        final currentApp = appProvider.userApps.firstWhere(
          (app) => app.id == widget.app.id,
          orElse: () => widget.app,
        );

        if (currentApp.selectedRevisionId != null) {
          try {
            _currentRevision = revisions.firstWhere(
              (r) => r.id == currentApp.selectedRevisionId,
            );
            codeToLoad = _currentRevision!.appCode;
          } catch (e) {
            // If pinned revision not found, use the latest revision
            if (revisions.isNotEmpty) {
              _currentRevision = revisions.last;
              codeToLoad = _currentRevision!.appCode;
            }
          }
        } else if (revisions.isNotEmpty) {
          // If no pinned revision, use the latest revision
          _currentRevision = revisions.last;
          codeToLoad = _currentRevision!.appCode;
        }
      }

      setState(() {
        _originalCode = codeToLoad;
        _codeController.text = codeToLoad;
        _viewController.text = codeToLoad;
        // Ensure view controller is properly initialized
        _viewController.value = CodeLineEditingValue(
          codeLines: CodeLines.fromText(codeToLoad),
        );
      });

      // Load libraries for the current revision
      _loadCurrentLibraries();
    } catch (e) {
      // If there's an error loading revisions, show empty code
      setState(() {
        _originalCode = '';
        _codeController.text = '';
        _viewController.text = '';
        // Ensure view controller is properly initialized
        _viewController.value = CodeLineEditingValue(
          codeLines: CodeLines.fromText(''),
        );
        _currentRevision = null;
      });
    }
  }

  Future<void> _loadCurrentRevisionAttachments() async {
    // Don't auto-load previous revision attachments - images should be for current revision only
    setState(() {
      _attachmentPaths = [];
    });
  }

  Future<void> _loadCurrentLibraries() async {
    if (_currentRevision == null) return;

    setState(() {
      _isLoadingLibraries = true;
    });

    try {
      final libraryService = UserAppLibraryService();
      final libraries = await libraryService.getLibraries(
        widget.app.uuid,
        _currentRevision!.revisionNumber,
      );

      // Load dependencies (links) for each library
      final Map<int, List<String>> libraryLinks = {};
      for (final library in libraries) {
        final dependencies = await libraryService.getDependencies(library.id);
        libraryLinks[library.id] = dependencies
            .map((dep) => dep.originalUrl ?? '')
            .where((url) => url.isNotEmpty)
            .toList();
      }

      setState(() {
        _modifiedLibraries = List.from(libraries);
        _libraryLinks = libraryLinks;
        _isLoadingLibraries = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingLibraries = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading libraries: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    // Reset transition flag to prevent any pending operations
    _isTransitioning = false;

    _editSuggestionController.dispose();
    _codeController.dispose();
    _viewController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _submitEdit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isEditing = true;
    });

    try {
      final appProvider = context.read<AppProvider>();

      // Create a modified app that represents the current revision
      final currentApp = widget.app.copyWith(
        htmlContent: _currentRevision?.appCode ?? widget.app.htmlContent,
        selectedRevisionId:
            _currentRevision?.id ?? widget.app.selectedRevisionId,
      );

      // Convert libraries to UserAppLibraryInfo format for AI prompt
      List<UserAppLibraryInfo>? librariesForAI;
      if (_modifiedLibraries.isNotEmpty) {
        librariesForAI = _modifiedLibraries
            .map((library) {
              final links = _libraryLinks[library.id] ?? [];
              final validLinks = links
                  .where((link) => link.trim().isNotEmpty)
                  .toList();

              return UserAppLibraryInfo(
                name: library.name,
                usage: library.usageInstructions,
                links: validLinks,
              );
            })
            .where((lib) => lib.name.trim().isNotEmpty)
            .toList();

        // If no valid libraries, set to null
        if (librariesForAI.isEmpty) {
          librariesForAI = null;
        }
      }

      // Create the new revision using the existing editUserApp method
      await appProvider.editUserApp(
        originalApp: currentApp,
        editSuggestion: _editSuggestionController.text.trim(),
        attachmentPaths: _attachmentPaths.isNotEmpty ? _attachmentPaths : null,
        contextNotes: _selectedNotes.isNotEmpty
            ? List<Note>.from(_selectedNotes)
            : null,
        libraries: librariesForAI,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('App updated successfully with new revision'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true); // Return true to indicate successful edit
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isEditing = false;
        });

        // Show error dialog instead of snackbar for better visibility
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(AppLocalizations.of(context)!.appEditFailed),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(
                    context,
                  )!.errorCreatingAppFromEdit(e.toString()),
                ),
                const SizedBox(height: 8),
                Text(
                  'Please check your API key and try again.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppLocalizations.of(context)!.close),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _saveCodeDirectly() async {
    if (_codeController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(
              context,
            )!.errorSavingCode('Code cannot be empty'),
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final appProvider = context.read<AppProvider>();

      // Create a modified app that represents the current revision
      final currentApp = widget.app.copyWith(
        htmlContent: _currentRevision?.appCode ?? widget.app.htmlContent,
        selectedRevisionId:
            _currentRevision?.id ?? widget.app.selectedRevisionId,
      );

      // Save manual code edit by creating a new revision
      await appProvider.saveManualCodeEdit(
        originalApp: currentApp,
        newCode: _codeController.text.trim(),
        attachmentPaths: _attachmentPaths.isNotEmpty ? _attachmentPaths : null,
      );

      if (mounted) {
        setState(() {
          _originalCode = _codeController.text.trim();
          _isCodeEditable = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.codeSavedSuccessfully),
            backgroundColor: Colors.green,
          ),
        );

        // Return true to indicate successful save
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.errorSavingCode(e.toString()),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  void _toggleCodeEdit() {
    // Prevent rapid state changes during transitions
    if (_isTransitioning) return;

    if (!_isCodeEditable) {
      // Switching to edit mode - can do immediately
      setState(() {
        _isCodeEditable = true;
      });
    } else {
      // Switching to view mode - add delay to allow rendering to complete
      _isTransitioning = true;
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) {
          setState(() {
            _isCodeEditable = false;
            _isTransitioning = false;
            // Reset to original code if canceling edit
            _codeController.text = _originalCode;
            _viewController.text = _originalCode;
            // Ensure view controller is properly initialized
            _viewController.value = CodeLineEditingValue(
              codeLines: CodeLines.fromText(_originalCode),
            );
          });
        }
      });
    }
  }

  Future<void> _pickImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _attachmentPaths.add(image.path);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking image: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _takePhoto() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _attachmentPaths.add(image.path);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error taking photo: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _removeAttachment(int index) {
    setState(() {
      _attachmentPaths.removeAt(index);
    });
  }

  void _showNoteSelectionDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext)!;
        return NoteSelectionDialog(
          title: l10n.selectNotesToAddToContext,
          onNotesSelected: (notes) {
            Navigator.of(dialogContext).pop();
            if (!mounted) return;
            setState(() {
              final noteMap = {
                for (final note in _selectedNotes) note.id: note,
              };
              for (final note in notes) {
                noteMap[note.id] = note;
              }
              _selectedNotes
                ..clear()
                ..addAll(noteMap.values);
            });
          },
        );
      },
    );
  }

  void _clearSelectedNotes() {
    if (_selectedNotes.isEmpty) return;
    setState(() {
      _selectedNotes.clear();
    });
  }

  void _showImageSourceDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Image Source'),
        content: const Text('Choose how you want to add an image'),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _takePhoto();
            },
            icon: const Icon(Icons.camera_alt),
            label: const Text('Camera'),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _pickImage();
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

  // Library management methods
  void _addLibrary() {
    setState(() {
      final newLibrary = UserAppLibrary(
        id: -1, // Temporary ID for new libraries
        appUuid: widget.app.uuid,
        revisionId: _currentRevision?.revisionNumber ?? 0,
        name: '',
        usageInstructions: '',
      );
      _modifiedLibraries.add(newLibrary);
      _libraryLinks[newLibrary.id] = [''];
    });
  }

  void _removeLibrary(int index) {
    setState(() {
      final library = _modifiedLibraries[index];
      _libraryLinks.remove(library.id);
      _modifiedLibraries.removeAt(index);
    });
  }

  void _updateLibraryName(int index, String name) {
    setState(() {
      _modifiedLibraries[index] = UserAppLibrary(
        id: _modifiedLibraries[index].id,
        appUuid: _modifiedLibraries[index].appUuid,
        revisionId: _modifiedLibraries[index].revisionId,
        name: name,
        usageInstructions: _modifiedLibraries[index].usageInstructions,
      );
    });
  }

  void _updateLibraryUsage(int index, String usage) {
    setState(() {
      _modifiedLibraries[index] = UserAppLibrary(
        id: _modifiedLibraries[index].id,
        appUuid: _modifiedLibraries[index].appUuid,
        revisionId: _modifiedLibraries[index].revisionId,
        name: _modifiedLibraries[index].name,
        usageInstructions: usage.isEmpty ? null : usage,
      );
    });
  }

  void _addLibraryLink(int libraryIndex) {
    setState(() {
      final library = _modifiedLibraries[libraryIndex];
      final currentLinks = List<String>.from(_libraryLinks[library.id] ?? []);
      currentLinks.add('');
      _libraryLinks[library.id] = currentLinks;
    });
  }

  void _removeLibraryLink(int libraryIndex, int linkIndex) {
    setState(() {
      final library = _modifiedLibraries[libraryIndex];
      final currentLinks = List<String>.from(_libraryLinks[library.id] ?? []);
      if (currentLinks.length > 1) {
        currentLinks.removeAt(linkIndex);
        _libraryLinks[library.id] = currentLinks;
      }
    });
  }

  void _updateLibraryLink(int libraryIndex, int linkIndex, String link) {
    setState(() {
      final library = _modifiedLibraries[libraryIndex];
      final currentLinks = List<String>.from(_libraryLinks[library.id] ?? []);
      currentLinks[linkIndex] = link;
      _libraryLinks[library.id] = currentLinks;
    });
  }

  // Toolbar action methods
  void _toggleSearch() {
    setState(() {
      _isSearchVisible = !_isSearchVisible;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.editUserApp),
        actions: [
          if (_isCodeEditable)
            IconButton(
              icon: Icon(_isSearchVisible ? Icons.search_off : Icons.search),
              onPressed: _toggleSearch,
              tooltip: _isSearchVisible ? 'Hide Search' : 'Show Search',
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: l10n.code),
            Tab(text: l10n.libraries),
          ],
        ),
      ),
      body: TabBarView(
        physics: const NeverScrollableScrollPhysics(),
        controller: _tabController,
        children: [
          // Code Tab
          // Code Tab
          CustomScrollView(
            slivers: [
              if (!_isCodeEditable)
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // App Info Section
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Card(
                          elevation: 0,
                          color: theme.colorScheme.surfaceContainerHighest
                              .withOpacity(0.3),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'App Name',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  widget.app.name,
                                  style: theme.textTheme.bodyLarge,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'Description',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  widget.app.description,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // App Code Header and Edit Button
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'App Code',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            FilledButton.icon(
                              onPressed: _toggleCodeEdit,
                              icon: const Icon(Icons.edit, size: 18),
                              label: const Text('Edit Code Directly'),
                              style: FilledButton.styleFrom(
                                backgroundColor:
                                    Colors.blue, // Match screenshot blue
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),

              // Editor Area
              SliverFillRemaining(
                hasScrollBody: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 400),
                        child: Stack(
                          children: [
                            SynapseCodeEditor(
                              controller: _isCodeEditable
                                  ? _codeController
                                  : _viewController,
                              readOnly: !_isCodeEditable,
                              wordWrap: false,
                            ),
                            if (_isSaving)
                              Container(
                                color: Colors.black26,
                                child: const Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                    // Bottom Action Bar (Only visible when editing)
                    if (_isCodeEditable)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          border: Border(
                            top: BorderSide(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _isSaving ? null : _saveCodeDirectly,
                                icon: const Icon(Icons.save),
                                label: Text(l10n.saveCode),
                                style: FilledButton.styleFrom(
                                  backgroundColor:
                                      Colors.green, // Match screenshot green
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            OutlinedButton(
                              onPressed: _toggleCodeEdit,
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ),
                    // AI Edit Section (Always visible, but only interactive when not editing code directly)
                    if (!_isCodeEditable)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          border: Border(
                            top: BorderSide(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  l10n.editSuggestion,
                                  style: theme.textTheme.titleMedium,
                                ),
                                Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.note_add),
                                      onPressed: _showNoteSelectionDialog,
                                      tooltip: l10n.addContextNotes,
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.image),
                                      onPressed: _showImageSourceDialog,
                                      tooltip: l10n.addImage,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Form(
                              key: _formKey,
                              child: TextFormField(
                                controller: _editSuggestionController,
                                decoration: InputDecoration(
                                  hintText: l10n.editSuggestionHint,
                                  border: const OutlineInputBorder(),
                                  suffixIcon: _isEditing
                                      ? const Padding(
                                          padding: EdgeInsets.all(12.0),
                                          child: SizedBox(
                                            width: 24,
                                            height: 24,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ),
                                        )
                                      : IconButton(
                                          icon: const Icon(Icons.send),
                                          onPressed: _submitEdit,
                                        ),
                                ),
                                maxLines: 3,
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return l10n.pleaseEnterSuggestion;
                                  }
                                  return null;
                                },
                              ),
                            ),
                            if (_attachmentPaths.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 100,
                                child: ListView.builder(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: _attachmentPaths.length,
                                  itemBuilder: (context, index) {
                                    return Stack(
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 8.0,
                                          ),
                                          child: Image.file(
                                            File(_attachmentPaths[index]),
                                            height: 100,
                                            width: 100,
                                            fit: BoxFit.cover,
                                          ),
                                        ),
                                        Positioned(
                                          right: 0,
                                          top: 0,
                                          child: IconButton(
                                            icon: const Icon(
                                              Icons.close,
                                              color: Colors.red,
                                            ),
                                            onPressed: () =>
                                                _removeAttachment(index),
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            ],
                            if (_selectedNotes.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Text(
                                    '${_selectedNotes.length} notes selected',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.clear, size: 16),
                                    onPressed: _clearSelectedNotes,
                                    tooltip: 'Clear selected notes',
                                  ),
                                ],
                              ),
                            ],
                            if (_isEditing)
                              const Padding(
                                padding: EdgeInsets.only(top: 16.0),
                                child: LinearProgressIndicator(),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),

          // Libraries Tab
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(l10n.libraries, style: theme.textTheme.titleLarge),
                  FilledButton.icon(
                    onPressed: _addLibrary,
                    icon: const Icon(Icons.add),
                    label: Text(l10n.addLibrary),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_isLoadingLibraries)
                const Center(child: CircularProgressIndicator())
              else if (_modifiedLibraries.isEmpty)
                Center(
                  child: Text(
                    l10n.noLibraries,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                ..._modifiedLibraries.asMap().entries.map((entry) {
                  final index = entry.key;
                  final library = entry.value;
                  final links = _libraryLinks[library.id] ?? [];

                  return Card(
                    margin: const EdgeInsets.only(bottom: 16),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  initialValue: library.name,
                                  decoration: InputDecoration(
                                    labelText: l10n.libraryName,
                                    border: const OutlineInputBorder(),
                                  ),
                                  onChanged: (value) =>
                                      _updateLibraryName(index, value),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete,
                                  color: Colors.red,
                                ),
                                onPressed: () => _removeLibrary(index),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            initialValue: library.usageInstructions,
                            decoration: InputDecoration(
                              labelText: l10n.usageInstructions,
                              border: const OutlineInputBorder(),
                            ),
                            maxLines: 3,
                            onChanged: (value) =>
                                _updateLibraryUsage(index, value),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            l10n.libraryLinks,
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          ...links.asMap().entries.map((linkEntry) {
                            final linkIndex = linkEntry.key;
                            final link = linkEntry.value;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      initialValue: link,
                                      decoration: InputDecoration(
                                        labelText: l10n.libraryLink,
                                        border: const OutlineInputBorder(),
                                      ),
                                      onChanged: (value) => _updateLibraryLink(
                                        index,
                                        linkIndex,
                                        value,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.remove_circle_outline,
                                    ),
                                    onPressed: () =>
                                        _removeLibraryLink(index, linkIndex),
                                  ),
                                ],
                              ),
                            );
                          }),
                          TextButton.icon(
                            onPressed: () => _addLibraryLink(index),
                            icon: const Icon(Icons.add),
                            label: Text(l10n.addLink),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
            ],
          ),
        ],
      ),
    );
  }
}
