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
  int _selectedTabIndex = 0;
  
  // Library management
  List<UserAppLibrary> _currentLibraries = [];
  List<UserAppLibrary> _modifiedLibraries = [];
  bool _isLoadingLibraries = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      setState(() {
        _selectedTabIndex = _tabController.index;
      });
    });
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
      
      setState(() {
        _currentLibraries = libraries;
        _modifiedLibraries = List.from(libraries);
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
      
      // Create the new revision using the existing editUserApp method
      final newRevision = await appProvider.editUserApp(
        originalApp: currentApp,
        editSuggestion: _editSuggestionController.text.trim(),
        attachmentPaths: _attachmentPaths.isNotEmpty ? _attachmentPaths : null,
      );
      
      // Handle library changes if we're in Advanced mode and libraries were modified
      if (_selectedTabIndex == 1 && _hasLibraryChanges()) {
        await _processLibraryChanges(newRevision);
      }
      
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

  bool _hasLibraryChanges() {
    if (_currentLibraries.length != _modifiedLibraries.length) return true;
    
    for (int i = 0; i < _currentLibraries.length; i++) {
      final current = _currentLibraries[i];
      final modified = _modifiedLibraries[i];
      
      if (current.name != modified.name || 
          current.usageInstructions != modified.usageInstructions) {
        return true;
      }
    }
    
    return false;
  }

  Future<void> _processLibraryChanges(AppRevision newRevision) async {
    try {
      final libraryService = UserAppLibraryService();
      final newRevisionNumber = newRevision.revisionNumber;
      
      // Get the current libraries from the source revision
      final sourceLibraries = _currentLibraries;
      final targetLibraries = _modifiedLibraries;
      
      // Find libraries to add (new libraries or libraries not in source)
      final librariesToAdd = targetLibraries.where((target) => 
        !sourceLibraries.any((source) => source.name == target.name)
      ).toList();
      
      // Find libraries to remove (libraries in source but not in target)
      // Note: We don't actually delete libraries from the source revision
      // as they might be needed for other revisions. The removal only affects
      // the new revision.
      // final librariesToRemove = sourceLibraries.where((source) => 
      //   !targetLibraries.any((target) => target.name == source.name)
      // ).toList();
      
      // Find libraries to update (libraries that exist in both but have different properties)
      final librariesToUpdate = targetLibraries.where((target) {
        final source = sourceLibraries.firstWhere(
          (s) => s.name == target.name,
          orElse: () => UserAppLibrary(id: -1, appUuid: '', revisionId: 0, name: ''),
        );
        return source.id != -1 && 
               (source.usageInstructions != target.usageInstructions);
      }).toList();
      
      // Process additions
      for (final library in librariesToAdd) {
        if (library.id == -1) {
          // This is a new library - we need to download it
          // For now, we'll just create the library entry without dependencies
          // In a real implementation, you'd need to provide URLs or files for the library
          await libraryService.addLibrary(
            appUuid: widget.app.uuid,
            revisionId: newRevisionNumber,
            name: library.name,
            usageInstructions: library.usageInstructions,
            dependencies: [], // Empty dependencies for now
          );
        } else {
          // This is an existing library being copied
          final sourceLibrary = sourceLibraries.firstWhere((s) => s.name == library.name);
          final dependencies = await libraryService.getDependencies(sourceLibrary.id);
          
          await libraryService.addLibrary(
            appUuid: widget.app.uuid,
            revisionId: newRevisionNumber,
            name: library.name,
            usageInstructions: library.usageInstructions,
            dependencies: dependencies.map((d) => LibraryDependency(
              originalUrl: d.originalUrl,
              localPath: d.localPath,
              bytes: d.bytes,
            )).toList(),
          );
        }
      }
      
      // Process updates
      for (final library in librariesToUpdate) {
        final sourceLibrary = sourceLibraries.firstWhere((s) => s.name == library.name);
        final dependencies = await libraryService.getDependencies(sourceLibrary.id);
        
        await libraryService.addLibrary(
          appUuid: widget.app.uuid,
          revisionId: newRevisionNumber,
          name: library.name,
          usageInstructions: library.usageInstructions,
          dependencies: dependencies.map((d) => LibraryDependency(
            originalUrl: d.originalUrl,
            localPath: d.localPath,
            bytes: d.bytes,
          )).toList(),
        );
      }
      
    } catch (e) {
      // Log the error but don't fail the entire edit operation
      print('Error processing library changes: $e');
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
    showDialog(
      context: context,
      builder: (context) => _LibraryEditDialog(
        onSave: (name, usageInstructions) {
          final newLibrary = UserAppLibrary(
            id: -1, // Temporary ID for new libraries
            appUuid: widget.app.uuid,
            revisionId: _currentRevision?.revisionNumber ?? 0,
            name: name,
            usageInstructions: usageInstructions,
          );
          setState(() {
            _modifiedLibraries.add(newLibrary);
          });
        },
      ),
    );
  }

  void _editLibrary(UserAppLibrary library) {
    showDialog(
      context: context,
      builder: (context) => _LibraryEditDialog(
        initialName: library.name,
        initialUsageInstructions: library.usageInstructions,
        onSave: (name, usageInstructions) {
          setState(() {
            final index = _modifiedLibraries.indexWhere((l) => l.id == library.id);
            if (index != -1) {
              _modifiedLibraries[index] = library.copyWith(
                name: name,
                usageInstructions: usageInstructions,
              );
            }
          });
        },
      ),
    );
  }

  void _deleteLibrary(UserAppLibrary library) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Library'),
        content: Text('Are you sure you want to delete "${library.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _modifiedLibraries.removeWhere((l) => l.id == library.id);
              });
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
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
                                    color: Colors.grey.withOpacity(0.3),
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
    return Column(
      children: [
        // Libraries header
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Libraries',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              ElevatedButton.icon(
                onPressed: _addLibrary,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Library'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
        
        // Libraries list
        Expanded(
          child: _isLoadingLibraries
              ? const Center(child: CircularProgressIndicator())
              : _modifiedLibraries.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.library_books_outlined,
                            size: 64,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No libraries found',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Colors.grey[600],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Add libraries to enhance your app functionality',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      itemCount: _modifiedLibraries.length,
                      itemBuilder: (context, index) {
                        final library = _modifiedLibraries[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8.0),
                          child: ListTile(
                            leading: const Icon(Icons.library_books),
                            title: Text(library.name),
                            subtitle: library.usageInstructions != null
                                ? Text(
                                    library.usageInstructions!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : null,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: () => _editLibrary(library),
                                  icon: const Icon(Icons.edit),
                                  tooltip: 'Edit Library',
                                ),
                                IconButton(
                                  onPressed: () => _deleteLibrary(library),
                                  icon: const Icon(Icons.delete),
                                  tooltip: 'Delete Library',
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
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

class _LibraryEditDialog extends StatefulWidget {
  final String? initialName;
  final String? initialUsageInstructions;
  final Function(String name, String? usageInstructions) onSave;

  const _LibraryEditDialog({
    this.initialName,
    this.initialUsageInstructions,
    required this.onSave,
  });

  @override
  State<_LibraryEditDialog> createState() => _LibraryEditDialogState();
}

class _LibraryEditDialogState extends State<_LibraryEditDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _usageController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.initialName ?? '';
    _usageController.text = widget.initialUsageInstructions ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initialName == null ? 'Add Library' : 'Edit Library'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Library Name',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Please enter a library name';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _usageController,
              decoration: const InputDecoration(
                labelText: 'Usage Instructions (Optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              widget.onSave(
                _nameController.text.trim(),
                _usageController.text.trim().isEmpty 
                    ? null 
                    : _usageController.text.trim(),
              );
              Navigator.pop(context);
            }
          },
          child: Text(widget.initialName == null ? 'Add' : 'Save'),
        ),
      ],
    );
  }
}
