import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';
import '../widgets/interactive_checkbox_markdown.dart';
import '../utils/file_utils.dart';
import 'note_detail_screen.dart';
import 'conversation_chat_screen.dart';
import '../widgets/model_selector_button.dart';
import '../models/generation_context.dart';
import '../models/model_config.dart';
import '../services/skill_service.dart';
import '../services/service_locator.dart';

enum AIInteractionType { noteTransformation, newNoteCreation, aiConversation }

class AIActionScreen extends StatefulWidget {
  final List<Note> selectedNotes;

  const AIActionScreen({super.key, required this.selectedNotes});

  @override
  State<AIActionScreen> createState() => _AIActionScreenState();
}

class _AIActionScreenState extends State<AIActionScreen> {
  final _promptController = TextEditingController();
  AIInteractionType? _selectedAction;
  bool _isProcessing = false;
  String? _response;
  final List<PlatformFile> _attachedFiles = [];
  ModelConfig? _selectedModel;
  bool _skillsEnabled = true;
  int _skillCount = 0;

  @override
  void initState() {
    super.initState();
    _loadSkillCount();
  }

  Future<void> _loadSkillCount() async {
    final index = await getIt<SkillService>().buildSkillIndex();
    if (mounted) setState(() => _skillCount = index.length);
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.aiActions),
        actions: [
          if (_response != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _clearResponse,
              tooltip: l10n.clearResponse,
            ),
        ],
      ),
      body: _response != null
          ? _buildResponseView(l10n)
          : _buildActionSelectionView(l10n),
    );
  }

  Widget _buildActionSelectionView(AppLocalizations l10n) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.selectAIAction,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          if (widget.selectedNotes.length == 1) ...[
            _buildActionCard(
              icon: Icons.transform,
              title: l10n.transformNote,
              description: l10n.transformNoteDescription,
              action: AIInteractionType.noteTransformation,
            ),
            const SizedBox(height: 12),
          ],
          _buildActionCard(
            icon: Icons.add_circle,
            title: l10n.createNewNotes,
            description: l10n.createNewNotesDescription,
            action: AIInteractionType.newNoteCreation,
          ),
          const SizedBox(height: 12),
          _buildActionCard(
            icon: Icons.chat,
            title: l10n.aiConversation,
            description: l10n.aiConversationDescription,
            action: AIInteractionType.aiConversation,
          ),
          const SizedBox(height: 24),
          if (_selectedAction != null) ...[
            if (_selectedAction == AIInteractionType.aiConversation) ...[
              SwitchListTile(
                title: const Text('Agent Skills'),
                subtitle: Text(
                  _skillCount > 0
                      ? '$_skillCount skill${_skillCount == 1 ? '' : 's'} available'
                      : 'No skills found — create a note tagged "agent-skill"',
                ),
                value: _skillsEnabled,
                onChanged: _skillCount > 0
                    ? (val) => setState(() => _skillsEnabled = val)
                    : null,
              ),
              const SizedBox(height: 8),
            ],
            if (_selectedAction != AIInteractionType.aiConversation) ...[
              Text(
                l10n.enterYourPrompt,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _promptController,
                decoration: InputDecoration(
                  hintText: _getPromptHint(l10n),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.edit),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.attach_file),
                        onPressed: _attachFiles,
                        tooltip: l10n.attachFiles,
                      ),
                      IconButton(
                        icon: const Icon(Icons.camera_alt),
                        onPressed: _captureImage,
                        tooltip: 'Take photo',
                      ),
                    ],
                  ),
                ),
                maxLines: 6,
                minLines: 3,
                textInputAction: TextInputAction.newline,
                onSubmitted: (value) {
                  // Only submit if there's content and user presses Enter
                  // For now, we'll rely on the Process button for submission
                  // Ctrl+Enter handling would require more complex keyboard event handling
                },
              ),
              const SizedBox(height: 8),
            ],
            if (_selectedAction != AIInteractionType.aiConversation) ...[
              if (_attachedFiles.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildAttachedFilesSection(),
              ],
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isProcessing ? null : _processAction,
                    style: ElevatedButton.styleFrom(
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.horizontal(
                          left: Radius.circular(20),
                          right: Radius.zero,
                        ),
                      ),
                    ),
                    child: _isProcessing
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _selectedAction == AIInteractionType.aiConversation
                                ? l10n.startConversation
                                : l10n.process,
                          ),
                  ),
                ),
                if (_selectedAction != AIInteractionType.aiConversation) ...[
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
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required String title,
    required String description,
    required AIInteractionType action,
  }) {
    final isSelected = _selectedAction == action;

    return Card(
      elevation: isSelected ? 4 : 2,
      shadowColor: isSelected
          ? Theme.of(context).colorScheme.primary.withOpacity(0.3)
          : null,
      color: isSelected
          ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected
            ? BorderSide(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                width: 2,
              )
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedAction = action;
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isSelected
                      ? Theme.of(context).primaryColor.withOpacity(0.1)
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  icon,
                  size: 24,
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isSelected
                            ? Theme.of(context).primaryColor
                            : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 16),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResponseView(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.response,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  child: SelectionArea(
                    child: InteractiveCheckboxMarkdown(
                      originalContent: _response!,
                      onContentChanged: _updateResponseContent,
                      style: Theme.of(context).textTheme.bodyLarge,
                      textDirection: TextDirection.ltr,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_selectedAction == AIInteractionType.noteTransformation) ...[
            Text(
              'Original Note',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SingleChildScrollView(
                    child: SelectionArea(
                      child: Text(
                        widget.selectedNotes.first.content,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed:
                      _selectedAction == AIInteractionType.newNoteCreation
                      ? () => Navigator.of(context).pop()
                      : _clearResponse,
                  child: Text(
                    _selectedAction == AIInteractionType.newNoteCreation
                        ? l10n.close
                        : l10n.cancel,
                  ),
                ),
              ),
              if (_selectedAction != AIInteractionType.newNoteCreation) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saveResponse,
                    child: Text(
                      _selectedAction == AIInteractionType.noteTransformation
                          ? 'Replace'
                          : 'Save Response',
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

  String _getPromptHint(AppLocalizations l10n) {
    switch (_selectedAction) {
      case AIInteractionType.noteTransformation:
        return l10n.transformNoteHint;
      case AIInteractionType.newNoteCreation:
        return l10n.createNewNotesHint;
      default:
        return 'Enter your prompt...';
    }
  }

  Future<void> _processAction() async {
    if (_selectedAction != AIInteractionType.aiConversation &&
        _promptController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please enter a prompt')));
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      final l10n = AppLocalizations.of(context)!;
      final appProvider = context.read<AppProvider>();
      String response;

      final generationContext = GenerationContext();
      if (_selectedModel != null) {
        generationContext.modelOverride = _selectedModel;
      }
      // Note: No backend auto-selection here.
      // Attachments are passed down, and ModelSelector will handle capability detection
      // centered in generateFromPrompt/generateWithToolsAndMessages.

      switch (_selectedAction) {
        case AIInteractionType.noteTransformation:
          response = await appProvider.transformNote(
            widget.selectedNotes.first,
            _promptController.text.trim(),
            attachedFiles: _attachedFiles,
            generationContext: generationContext,
          );
          break;
        case AIInteractionType.newNoteCreation:
          final newNotes = await appProvider.createNewNotes(
            _promptController.text.trim(),
            widget.selectedNotes,
            attachedFiles: _attachedFiles,
            generationContext: generationContext,
          );
          response = l10n.multipleNotesCreatedSuccessfully(newNotes.length);
          break;
        case AIInteractionType.aiConversation:
          // Navigate to conversation screen with selected notes
          if (mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (context) => ConversationChatScreen(
                  initialNoteIds: widget.selectedNotes
                      .map((note) => note.id)
                      .toList(),
                  initialModelOverride: _selectedModel,
                  skillsEnabled: _skillsEnabled,
                ),
              ),
            );
          }
          return; // Don't process further
        default:
          throw Exception('Invalid action type');
      }

      if (mounted) {
        setState(() {
          _response = response;
          _isProcessing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _clearResponse() {
    setState(() {
      _response = null;
      _selectedAction = null;
      _promptController.clear();
      _attachedFiles.clear();
    });
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

  Widget _buildAttachedFilesSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.attach_file,
                size: 16,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              ),
              const SizedBox(width: 8),
              Text(
                'Attached Files (${_attachedFiles.length})',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withOpacity(0.8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...List.generate(_attachedFiles.length, (index) {
            final file = _attachedFiles[index];
            return InkWell(
              onTap: () => _previewAttachedFile(file),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withOpacity(0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _getFileIcon(file.extension),
                      size: 16,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withOpacity(0.7),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        file.name,
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _removeAttachedFile(index),
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: Colors.red[600],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  IconData _getFileIcon(String? extension) {
    if (extension == null) return Icons.insert_drive_file;

    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'bmp':
      case 'webp':
        return Icons.image;
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'txt':
        return Icons.text_snippet;
      case 'mp4':
      case 'avi':
      case 'mov':
        return Icons.video_file;
      case 'mp3':
      case 'wav':
      case 'aac':
        return Icons.audio_file;
      default:
        return Icons.insert_drive_file;
    }
  }

  Future<void> _previewAttachedFile(PlatformFile file) async {
    await FileUtils.openPlatformFile(file, context);
  }

  void _saveResponse() async {
    if (_response == null || _response!.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No response to save')));
      return;
    }

    try {
      if (_selectedAction == AIInteractionType.noteTransformation) {
        final originalNote = widget.selectedNotes.first;
        final updatedNote = originalNote.copyWith(
          content: _response!,
          updatedAt: DateTime.now(),
        );

        await context.read<AppProvider>().updateNote(updatedNote);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Note updated successfully')),
        );

        if (!mounted) return;
        Navigator.of(context).pop(updatedNote);
      } else {
        // Create a new note from the AI response
        final newNote = Note(
          id: const Uuid().v4(),
          title: _generateNoteTitle(),
          content: _response!,
          type: NoteType.note,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          tags: ['AI Generated'], // Tag to identify AI-generated notes
        );

        // Save the note to the database
        await context.read<AppProvider>().addNote(newNote);

        if (!mounted) return;
        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Response saved as new note')),
        );

        if (!mounted) return;
        // Navigate to the newly created note
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => NoteDetailScreen(note: newNote),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error saving note: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  String _generateNoteTitle() {
    if (_response == null || _response!.trim().isEmpty) {
      return 'AI Response';
    }

    // Take the first line or first 50 characters as title
    final lines = _response!.split('\n');
    final firstLine = lines.first.trim();

    if (firstLine.length > 50) {
      return '${firstLine.substring(0, 47)}...';
    }

    return firstLine.isEmpty ? 'AI Response' : firstLine;
  }

  // Update response content when checkboxes are toggled
  void _updateResponseContent(String newContent) {
    if (mounted) {
      setState(() {
        _response = newContent;
      });
    }
  }
}
