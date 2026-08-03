import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../l10n/app_localizations.dart';
import '../models/note.dart';
import '../models/user_app.dart';
import '../providers/app_provider.dart';
import 'note_selection_dialog.dart';
import 'user_app_result_screen.dart';
import '../models/generation_context.dart';
import '../models/model_config.dart';
import '../widgets/model_selector_button.dart';
import '../widgets/drawing_editor.dart';
import '../services/attachment_preprocessor.dart';
import '../services/model_selector.dart';
import '../services/service_locator.dart';

class UserAppCreationScreen extends StatefulWidget {
  const UserAppCreationScreen({
    super.key,
    this.initialName,
    this.initialDescription,
    this.initialSteps = const [],
    this.initialContextNotes = const [],
    this.initialAppType = UserAppType.normal,
  });

  final String? initialName;
  final String? initialDescription;
  final List<String> initialSteps;
  final List<Note> initialContextNotes;
  final UserAppType initialAppType;

  @override
  State<UserAppCreationScreen> createState() => _UserAppCreationScreenState();
}

class _UserAppCreationScreenState extends State<UserAppCreationScreen>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final List<TextEditingController> _stepControllers = [];
  bool _isCreating = false;
  late UserAppType _selectedAppType;
  final List<String> _attachmentPaths = [];
  final List<Note> _selectedNotes = [];
  ModelConfig? _selectedModel;

  // Tab management
  late TabController _tabController;

  // Library management
  final List<UserAppLibraryInfo> _libraries = [];

  @override
  void initState() {
    super.initState();
    _selectedAppType = widget.initialAppType;
    _nameController.text = widget.initialName ?? '';
    _descriptionController.text = widget.initialDescription ?? '';
    _selectedNotes.addAll(widget.initialContextNotes);
    // Initialize tab controller
    _tabController = TabController(length: 2, vsync: this);
    if (widget.initialSteps.isEmpty) {
      _addStep();
    } else {
      for (final step in widget.initialSteps) {
        _addStep(step);
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    for (final controller in _stepControllers) {
      controller.dispose();
    }
    _tabController.dispose();
    super.dispose();
  }

  void _addStep([String initialText = '']) {
    setState(() {
      _stepControllers.add(TextEditingController(text: initialText));
    });
  }

  String _getAppTypeSubtitle(AppLocalizations l10n, UserAppType type) {
    switch (type) {
      case UserAppType.noteAction:
        return l10n.noteActionAppSubtitle;
      case UserAppType.aiTool:
        return l10n.aiToolAppSubtitle;
      case UserAppType.normal:
        return '';
    }
  }

  void _removeStep(int index) {
    if (_stepControllers.length > 1) {
      setState(() {
        _stepControllers[index].dispose();
        _stepControllers.removeAt(index);
      });
    }
  }

  List<String> _getSteps() {
    return _stepControllers
        .map((controller) => controller.text.trim())
        .where((step) => step.isNotEmpty)
        .toList();
  }

  void _addLibrary() {
    setState(() {
      _libraries.add(UserAppLibraryInfo(name: '', usage: '', links: ['']));
    });
  }

  void _removeLibrary(int index) {
    setState(() {
      _libraries.removeAt(index);
    });
  }

  void _updateLibraryName(int index, String name) {
    setState(() {
      _libraries[index] = UserAppLibraryInfo(
        name: name,
        usage: _libraries[index].usage,
        links: _libraries[index].links,
      );
    });
  }

  void _updateLibraryUsage(int index, String usage) {
    setState(() {
      _libraries[index] = UserAppLibraryInfo(
        name: _libraries[index].name,
        usage: usage,
        links: _libraries[index].links,
      );
    });
  }

  void _addLibraryLink(int libraryIndex) {
    setState(() {
      final currentLinks = List<String>.from(_libraries[libraryIndex].links);
      currentLinks.add('');
      _libraries[libraryIndex] = UserAppLibraryInfo(
        name: _libraries[libraryIndex].name,
        usage: _libraries[libraryIndex].usage,
        links: currentLinks,
      );
    });
  }

  void _removeLibraryLink(int libraryIndex, int linkIndex) {
    setState(() {
      final currentLinks = List<String>.from(_libraries[libraryIndex].links);
      if (currentLinks.length > 1) {
        currentLinks.removeAt(linkIndex);
        _libraries[libraryIndex] = UserAppLibraryInfo(
          name: _libraries[libraryIndex].name,
          usage: _libraries[libraryIndex].usage,
          links: currentLinks,
        );
      }
    });
  }

  void _updateLibraryLink(int libraryIndex, int linkIndex, String link) {
    setState(() {
      final currentLinks = List<String>.from(_libraries[libraryIndex].links);
      currentLinks[linkIndex] = link;
      _libraries[libraryIndex] = UserAppLibraryInfo(
        name: _libraries[libraryIndex].name,
        usage: _libraries[libraryIndex].usage,
        links: currentLinks,
      );
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

  Future<void> _openDrawingEditor() async {
    try {
      final File? drawnFile = await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const DrawingEditor()),
      );

      if (drawnFile != null) {
        setState(() {
          _attachmentPaths.add(drawnFile.path);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error adding drawing: $e'),
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

  void _removeSelectedNote(String noteId) {
    setState(() {
      _selectedNotes.removeWhere((note) => note.id == noteId);
    });
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
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _openDrawingEditor();
            },
            icon: const Icon(Icons.brush),
            label: const Text('Draw'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _createApp() async {
    if (!_formKey.currentState!.validate()) return;

    final steps = _getSteps();
    if (steps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.appStepsHint),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _isCreating = true;
    });

    try {
      final appProvider = context.read<AppProvider>();

      final generationContext = GenerationContext();
      if (_selectedModel != null) {
        generationContext.modelOverride = _selectedModel;
      } else {
        // Collect all attachments from paths and potential notes
        final attachmentsToScan = <PlatformFile>[];
        // Loading files from paths for capability check
        for (final path in _attachmentPaths) {
          final file = File(path);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            attachmentsToScan.add(
              PlatformFile(
                name: path.split('/').last,
                size: bytes.length,
                bytes: bytes,
                path: path,
              ),
            );
          }
        }
        final caps = await AttachmentPreprocessor.detectRequiredCapabilities(
          attachmentsToScan,
        );
        if (caps.isNotEmpty) {
          final preferredModel = await getIt<ModelSelector>()
              .selectModelByPreference(caps);
          if (preferredModel != null) {
            generationContext.modelOverride = preferredModel;
          }
        }
      }

      final app = await appProvider.createUserApp(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        steps: steps,
        type: _selectedAppType,
        attachmentPaths: _attachmentPaths.isNotEmpty ? _attachmentPaths : null,
        contextNotes: _selectedNotes.isNotEmpty
            ? List<Note>.from(_selectedNotes)
            : null,
        libraries: _libraries.isNotEmpty ? _libraries : null,
        generationContext: generationContext,
      );

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) =>
                UserAppResultScreen(app: app, isSuccess: true),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
        });

        // Show error screen instead of clarification
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => UserAppResultScreen(
              app: null,
              isSuccess: false,
              errorMessage: e.toString(),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.createNewApp),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: l10n.basic),
            Tab(text: l10n.advanced),
          ],
        ),
      ),
      body: Form(
        key: _formKey,
        child: TabBarView(
          controller: _tabController,
          children: [_buildBasicTab(l10n), _buildAdvancedTab(l10n)],
        ),
      ),
    );
  }

  Widget _buildBasicTab(AppLocalizations l10n) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // App Name
          TextFormField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: l10n.appName,
              hintText: l10n.appNameHint,
              border: const OutlineInputBorder(),
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Please enter an app name';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),

          // App Description
          TextFormField(
            controller: _descriptionController,
            decoration: InputDecoration(
              labelText: l10n.appDescription,
              hintText: l10n.appDescriptionHint,
              border: const OutlineInputBorder(),
            ),
            maxLines: 3,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Please enter an app description';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),

          // App Type Selector
          Builder(
            builder: (context) {
              final subtitle = _getAppTypeSubtitle(l10n, _selectedAppType);
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.appType,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<UserAppType>(
                        initialValue: _selectedAppType,
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          hintText: l10n.appTypeHint,
                        ),
                        items: [
                          DropdownMenuItem(
                            value: UserAppType.normal,
                            child: Text(l10n.appTypeNormal),
                          ),
                          DropdownMenuItem(
                            value: UserAppType.noteAction,
                            child: Text(l10n.appTypeNoteAction),
                          ),
                          DropdownMenuItem(
                            value: UserAppType.aiTool,
                            child: Text(l10n.appTypeAiTool),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _selectedAppType = value;
                          });
                        },
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          subtitle,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.grey[600]),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),

          // Image Attachments Section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l10n.imageAttachmentsOptional,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      IconButton(
                        onPressed: _showImageSourceDialog,
                        icon: const Icon(Icons.add_photo_alternate),
                        tooltip: l10n.addImage,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.imageAttachmentsSubtitle,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                  ),
                  if (_attachmentPaths.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    ...List.generate(_attachmentPaths.length, (index) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8.0),
                              child: Image.file(
                                File(_attachmentPaths[index]),
                                width: 60,
                                height: 60,
                                fit: BoxFit.cover,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _attachmentPaths[index].split('/').last,
                                style: Theme.of(context).textTheme.bodySmall,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              onPressed: () => _removeAttachment(index),
                              icon: const Icon(
                                Icons.remove_circle,
                                color: Colors.red,
                              ),
                              tooltip: 'Remove Image',
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Note Context Section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l10n.addNotes,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_selectedNotes.isNotEmpty)
                            IconButton(
                              onPressed: _clearSelectedNotes,
                              icon: const Icon(Icons.clear_all),
                              tooltip: l10n.clearFilters,
                            ),
                          IconButton(
                            onPressed: _showNoteSelectionDialog,
                            icon: const Icon(Icons.note_add),
                            tooltip: l10n.addNotes,
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.selectNotesToAddToContext,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                  ),
                  if (_selectedNotes.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _selectedNotes.map((note) {
                        return InputChip(
                          label: Text(note.title),
                          avatar: Icon(
                            note.isTask ? Icons.check_circle : Icons.notes,
                            size: 18,
                          ),
                          onDeleted: () => _removeSelectedNote(note.id),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Steps Section
          Text(l10n.appSteps, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),

          // Steps List
          ...List.generate(_stepControllers.length, (index) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _stepControllers[index],
                      decoration: InputDecoration(
                        hintText: '${l10n.stepHint} ${index + 1}',
                        border: const OutlineInputBorder(),
                      ),
                      maxLines: 3,
                      keyboardType: TextInputType.multiline,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Step cannot be empty';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _stepControllers.length > 1
                        ? () => _removeStep(index)
                        : null,
                    icon: const Icon(Icons.remove_circle),
                    tooltip: l10n.removeStep,
                  ),
                ],
              ),
            );
          }),

          // Add Step Button
          OutlinedButton.icon(
            onPressed: _addStep,
            icon: const Icon(Icons.add),
            label: Text(l10n.addStep),
          ),
          const SizedBox(height: 24),

          // Create App Button
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _isCreating ? null : _createApp,
                  child: _isCreating
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 8),
                            Text(l10n.creatingApp),
                          ],
                        )
                      : Text(l10n.createApp),
                ),
              ),
              const SizedBox(width: 8),
              ModelSelectorButton(
                selectedModel: _selectedModel,
                onModelSelected: (model) {
                  setState(() {
                    _selectedModel = model;
                  });
                },
                isSendButton: true,
              ),
            ],
          ),
        ],
      ),
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
          ...List.generate(_libraries.length, (index) {
            return _buildLibraryCard(index, l10n);
          }),

          if (_libraries.isEmpty) ...[
            const SizedBox(height: 32),
            Center(
              child: Text(
                l10n.noLibrariesAddedYet,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: Colors.grey[600]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLibraryCard(int index, AppLocalizations l10n) {
    final library = _libraries[index];

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
              initialValue: library.usage,
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

            ...List.generate(library.links.length, (linkIndex) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: library.links[linkIndex],
                        decoration: InputDecoration(
                          hintText: l10n.libraryLinkHint,
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (value) =>
                            _updateLibraryLink(index, linkIndex, value),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: library.links.length > 1
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
}
