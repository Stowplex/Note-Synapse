import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/user_app.dart';
import '../models/app_revision.dart';
import '../models/user_app_library.dart';
import '../services/user_app_library_service.dart';
import '../utils/file_utils.dart';

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

class _UserAppEditScreenState extends State<UserAppEditScreen> with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _editSuggestionController = TextEditingController();
  final _codeController = TextEditingController();
  bool _isEditing = false;
  bool _isSaving = false;
  bool _isCodeEditable = false;
  String _originalCode = '';
  List<String> _attachmentPaths = [];
  
  // Tab management
  late TabController _tabController;
  
  // Library management
  List<UserAppLibrary> _modifiedLibraries = [];
  Map<int, List<String>> _libraryLinks = {}; // libraryId -> list of links
  bool _isLoadingLibraries = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadCurrentRevisionCode();
    _loadCurrentRevisionAttachments();
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
      });
      
      // Load libraries for the current revision
      _loadCurrentLibraries();
    } catch (e) {
      // If there's an error loading revisions, show empty code
      setState(() {
        _originalCode = '';
        _codeController.text = '';
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
    _editSuggestionController.dispose();
    _codeController.dispose();
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
        selectedRevisionId: _currentRevision?.id ?? widget.app.selectedRevisionId,
      );
      
      // Convert libraries to UserAppLibraryInfo format for AI prompt
      List<UserAppLibraryInfo>? librariesForAI;
      if (_modifiedLibraries.isNotEmpty) {
        librariesForAI = _modifiedLibraries.map((library) {
          final links = _libraryLinks[library.id] ?? [];
          final validLinks = links.where((link) => link.trim().isNotEmpty).toList();
          
          return UserAppLibraryInfo(
            name: library.name,
            usage: library.usageInstructions,
            links: validLinks,
          );
        }).where((lib) => lib.name.trim().isNotEmpty).toList();
        
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
        libraries: librariesForAI,
      );
      
      if (mounted) {
        Navigator.pop(context, true); // Return true to indicate successful edit
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('App updated successfully with new revision'),
            backgroundColor: Colors.green,
          ),
        );
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
                Text(AppLocalizations.of(context)!.errorCreatingAppFromEdit(e.toString())),
                const SizedBox(height: 8),
                Text(
                  'Please check your API key and try again.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
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
          content: Text(AppLocalizations.of(context)!.errorSavingCode('Code cannot be empty')),
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
        selectedRevisionId: _currentRevision?.id ?? widget.app.selectedRevisionId,
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
        
        // Return true to indicate successful save
        Navigator.pop(context, true);
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.codeSavedSuccessfully),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.errorSavingCode(e.toString())),
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
    setState(() {
      _isCodeEditable = !_isCodeEditable;
      if (!_isCodeEditable) {
        // Reset to original code if canceling edit
        _codeController.text = _originalCode;
      }
    });
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      resizeToAvoidBottomInset: !_isCodeEditable,
      appBar: AppBar(
        title: Text(l10n.editApp),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Basic'),
            Tab(text: 'Advanced'),
          ],
        ),
      ),
      body: Form(
        key: _formKey,
        child: _isCodeEditable ? _buildEditModeLayout(l10n) : _buildViewModeLayout(l10n),
      ),
    );
  }

  Widget _buildViewModeLayout(AppLocalizations l10n) {
    return TabBarView(
      controller: _tabController,
      children: [
        _buildBasicTab(l10n),
        _buildAdvancedTab(l10n),
      ],
    );
  }

  Widget _buildBasicTab(AppLocalizations l10n) {
    return Column(
      children: [
        // App Info Card
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.appName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.app.name,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.appDescription,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.app.description,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              ),
            ),
          ),
        ),
        
        // App Code Section - Takes up remaining space
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      l10n.appCode,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    ElevatedButton.icon(
                      onPressed: _toggleCodeEdit,
                      icon: const Icon(Icons.edit, size: 16),
                      label: Text(l10n.editCodeDirectly),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Card(
                    child: Container(
                      padding: const EdgeInsets.all(12.0),
                      child: SingleChildScrollView(
                        child: Text(
                          _codeController.text,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        
        // Bottom section with suggestion input and submit button
        Container(
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            border: Border(
              top: BorderSide(
                color: Theme.of(context).dividerColor,
                width: 1,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    l10n.editSuggestion,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  IconButton(
                    onPressed: _showImageSourceDialog,
                    icon: const Icon(Icons.add_photo_alternate),
                    tooltip: 'Add Image',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _editSuggestionController,
                decoration: InputDecoration(
                  hintText: l10n.editSuggestionHint,
                  border: const OutlineInputBorder(),
                ),
                maxLines: 3,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter your edit suggestion';
                  }
                  return null;
                },
              ),
              // Show attached images below the edit box
              if (_attachmentPaths.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Attached Images:',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8.0,
                  runSpacing: 8.0,
                      children: _attachmentPaths.asMap().entries.map((entry) {
                        final index = entry.key;
                        final path = entry.value;
                        return Stack(
                          children: [
                            GestureDetector(
                              onTap: () => FileUtils.openFile(path, context),
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8.0),
                                  border: Border.all(
                                    color: Colors.grey.withValues(alpha: 0.3),
                                    width: 1,
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(7.0),
                                  child: Image.file(
                                    File(path),
                                    width: 80,
                                    height: 80,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: GestureDetector(
                                onTap: () => _removeAttachment(index),
                                child: Container(
                                  decoration: const BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.close,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                ),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _isEditing ? null : _submitEdit,
                child: _isEditing
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(l10n.editingApp),
                        ],
                      )
                    : Text(l10n.submitEdit),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAdvancedTab(AppLocalizations l10n) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Add Library Button
          OutlinedButton.icon(
            onPressed: _addLibrary,
            icon: const Icon(Icons.add),
            label: Text(l10n.addLibrary),
          ),
          const SizedBox(height: 16),
          
          // Libraries List
          if (_isLoadingLibraries)
            const Center(child: CircularProgressIndicator())
          else
            ...List.generate(_modifiedLibraries.length, (index) {
              return _buildLibraryCard(index, l10n);
            }),
          
          if (_modifiedLibraries.isEmpty && !_isLoadingLibraries) ...[
            const SizedBox(height: 32),
            Center(
              child: Text(
                'No libraries added yet. Click "Add Library" to get started.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLibraryCard(int index, AppLocalizations l10n) {
    final library = _modifiedLibraries[index];
    final links = _libraryLinks[library.id] ?? [];
    
    return Card(
      margin: const EdgeInsets.only(bottom: 16.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Library Header
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Library ${index + 1}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: () => _removeLibrary(index),
                  icon: const Icon(Icons.delete),
                  tooltip: l10n.removeLibrary,
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Library Name
            TextFormField(
              initialValue: library.name,
              decoration: InputDecoration(
                labelText: l10n.libraryName,
                hintText: l10n.libraryNameHint,
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => _updateLibraryName(index, value),
            ),
            const SizedBox(height: 16),
            
            // Library Usage
            TextFormField(
              initialValue: library.usageInstructions ?? '',
              decoration: InputDecoration(
                labelText: l10n.libraryUsage,
                hintText: l10n.libraryUsageHint,
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
              onChanged: (value) => _updateLibraryUsage(index, value),
            ),
            const SizedBox(height: 16),
            
            // Library Links
            Text(
              l10n.libraryLink,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            
            ...List.generate(links.length, (linkIndex) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: links[linkIndex],
                        decoration: InputDecoration(
                          hintText: l10n.libraryLinkHint,
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (value) => _updateLibraryLink(index, linkIndex, value),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: links.length > 1
                          ? () => _removeLibraryLink(index, linkIndex)
                          : null,
                      icon: const Icon(Icons.remove_circle),
                      tooltip: l10n.removeLink,
                    ),
                  ],
                ),
              );
            }),
            
            // Add Link Button
            OutlinedButton.icon(
              onPressed: () => _addLibraryLink(index),
              icon: const Icon(Icons.add),
              label: Text(l10n.addLink),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditModeLayout(AppLocalizations l10n) {
    return Column(
      children: [
        // App Info Card (smaller in edit mode)
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.app.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          widget.app.description,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _isSaving ? null : _saveCodeDirectly,
                        icon: _isSaving 
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save, size: 16),
                        label: Text(l10n.saveCode),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _isSaving ? null : _toggleCodeEdit,
                        icon: const Icon(Icons.cancel, size: 16),
                        label: Text(l10n.cancel),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        
        // Full-screen code editor
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Card(
              child: Container(
                padding: const EdgeInsets.all(12.0),
                child: TextFormField(
                  controller: _codeController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Enter your HTML code here...',
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

