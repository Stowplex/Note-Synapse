import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../models/conversation.dart';
import '../models/note.dart';
import '../l10n/app_localizations.dart';
import '../screens/note_selection_dialog.dart';
import '../services/ai_service.dart';
import '../services/conversation_service.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';

/// Dialog for creating a conversation using AI with customizable prompt
/// Similar to AINoteCreatorDialog, but creates a conversation instead
class AIConversationCreatorDialog extends StatefulWidget {
  final List<String> selectedNodeIds;
  final String conversationContent;
  final List<Note> contextNotes;
  
  const AIConversationCreatorDialog({
    super.key,
    required this.selectedNodeIds,
    required this.conversationContent,
    this.contextNotes = const [],
  });
  
  /// Show the dialog and return the created conversation if any
  static Future<Conversation?> show({
    required BuildContext context,
    required List<String> selectedNodeIds,
    required String conversationContent,
    List<Note> contextNotes = const [],
  }) async {
    return await showDialog<Conversation?>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AIConversationCreatorDialog(
        selectedNodeIds: selectedNodeIds,
        conversationContent: conversationContent,
        contextNotes: contextNotes,
      ),
    );
  }
  
  @override
  State<AIConversationCreatorDialog> createState() => _AIConversationCreatorDialogState();
}

class _AIConversationCreatorDialogState extends State<AIConversationCreatorDialog> {
  final TextEditingController _promptController = TextEditingController(text: 'Summarize');
  final List<PlatformFile> _attachedFiles = [];
  List<Note> _selectedNotes = [];
  bool _isProcessing = false;
  
  @override
  void initState() {
    super.initState();
    // Start with context notes already selected
    _selectedNotes = List.from(widget.contextNotes);
  }
  
  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Dialog(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
          maxWidth: 600,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(28),
                  topRight: Radius.circular(28),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.psychology,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.aiConversationCreator,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  if (!_isProcessing)
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                ],
              ),
            ),
            
            // Content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Instruction text
                    Text(
                      l10n.aiConversationCreatorInstructions,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                    const SizedBox(height: 16),
                    
                    // Prompt input
                    Text(
                      l10n.prompt,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _promptController,
                      decoration: InputDecoration(
                        hintText: l10n.promptHint,
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
                              tooltip: l10n.takePhotoAttachment,
                            ),
                          ],
                        ),
                      ),
                      maxLines: 4,
                      minLines: 2,
                      enabled: !_isProcessing,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.promptTip,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    
                    // Attached files section
                    if (_attachedFiles.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _buildAttachedFilesSection(),
                    ],
                    
                    // Additional notes section
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          l10n.additionalContextNotes(_selectedNotes.length),
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _isProcessing ? null : _selectAdditionalNotes,
                          icon: const Icon(Icons.add),
                          label: Text(l10n.addNotes),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_selectedNotes.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _selectedNotes.map((note) {
                            return Chip(
                              label: Text(note.title),
                              onDeleted: _isProcessing
                                  ? null
                                  : () {
                                      setState(() {
                                        _selectedNotes.remove(note);
                                      });
                                    },
                            );
                          }).toList(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            
            // Footer with action buttons
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(28),
                  bottomRight: Radius.circular(28),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_isProcessing)
                    const Padding(
                      padding: EdgeInsets.only(right: 16),
                      child: CircularProgressIndicator(),
                    )
                  else ...[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.cancel),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _proceed,
                      child: Text(l10n.createConversation),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildAttachedFilesSection() {
    final l10n = AppLocalizations.of(context)!;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.attachedFiles(_attachedFiles.length),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _attachedFiles.map((file) {
            return Chip(
              avatar: Icon(_getFileIcon(file.extension)),
              label: Text(
                file.name,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              onDeleted: _isProcessing
                  ? null
                  : () {
                      setState(() {
                        _attachedFiles.remove(file);
                      });
                    },
            );
          }).toList(),
        ),
      ],
    );
  }
  
  IconData _getFileIcon(String? extension) {
    switch (extension?.toLowerCase()) {
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.gif':
      case '.webp':
        return Icons.image;
      case '.pdf':
        return Icons.picture_as_pdf;
      case '.txt':
        return Icons.text_snippet;
      case '.doc':
      case '.docx':
        return Icons.description;
      case '.xls':
      case '.xlsx':
        return Icons.table_chart;
      default:
        return Icons.attach_file;
    }
  }
  
  Future<void> _attachFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );
    
    if (result != null && result.files.isNotEmpty) {
      setState(() {
        _attachedFiles.addAll(result.files);
      });
    }
  }
  
  Future<void> _captureImage() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.camera);
    
    if (image != null) {
      final file = File(image.path);
      final size = await file.length();
      setState(() {
        _attachedFiles.add(PlatformFile(
          path: image.path,
          name: image.name,
          size: size,
        ));
      });
    }
  }
  
  Future<void> _selectAdditionalNotes() async {
    final selectedNotes = await showDialog<List<Note>>(
      context: context,
      builder: (context) => NoteSelectionDialog(
        onNotesSelected: (notes) => Navigator.of(context).pop(notes),
      ),
    );
    
    if (selectedNotes != null && selectedNotes.isNotEmpty) {
      // Filter out notes already selected to avoid duplicates
      final newNotes = selectedNotes
          .where((note) => !_selectedNotes.any((n) => n.id == note.id))
          .toList();
      setState(() {
        _selectedNotes.addAll(newNotes);
      });
    }
  }
  
  Future<void> _proceed() async {
    final l10n = AppLocalizations.of(context)!;
    
    if (_promptController.text.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.pleaseEnterPrompt)),
        );
      }
      return;
    }
    
    setState(() {
      _isProcessing = true;
    });
    
    try {
      // Build the complete prompt with conversation content
      final fullPrompt = '''
${_promptController.text.trim()}

Conversation content to process:
${widget.conversationContent}
''';
      
      // Use AI service to process the conversation content
      final processedContent = await AIService.answerNoteQuestion(
        fullPrompt,
        _selectedNotes,
        attachedFiles: _attachedFiles.isNotEmpty ? _attachedFiles : null,
        useOwnKnowledge: true,
      );
      
      // Get conversation IDs and note IDs from selected nodes
      final conversationService = ConversationService();
      final databaseService = DatabaseService();
      final tree = await conversationService.getConversationTree();
      
      if (tree == null) {
        throw Exception('No conversation tree found');
      }
      
      final conversationIds = <String>{};
      final allNoteIds = <String>{};
      
      for (final nodeId in widget.selectedNodeIds) {
        final node = tree.nodes[nodeId];
        if (node != null && node.conversationId.isNotEmpty) {
          conversationIds.add(node.conversationId);
          final noteIds = await databaseService.getConversationNoteIds(
            node.conversationId,
          );
          allNoteIds.addAll(noteIds);
        }
      }
      
      // Check mounted after async operations
      if (!mounted) return;
      
      // Use processed content as title (or extract a summary title)
      final title = processedContent.length > 100
          ? '${processedContent.substring(0, 97)}...'
          : processedContent;
      
      // Create conversation with all notes
      final newConversation = await conversationService.createConversation(
        title: title,
        noteIds: allNoteIds.toList(),
      );
      
      if (!mounted) return;
      
      // Add only the AI's processed response as the starting context
      // This serves as the initial context for the conversation without showing
      // the user prompt or intermediate context messages
      if (processedContent.isNotEmpty) {
        await conversationService.addAIResponse(
          conversationId: newConversation.id,
          content: processedContent,
        );
      }
      
      if (!mounted) return;
      
      // Return the created conversation - let the caller show success messages
      Navigator.of(context).pop(newConversation);
    } catch (e) {
      if (!mounted) return;
      
      setState(() {
        _isProcessing = false;
      });
      
      LoggerService.error('Error creating conversation: $e', error: e);
      
      // Show error message before popping
      try {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorCreatingConversation(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      } catch (_) {
        // Context may be deactivated, skip snackbar
      }
      
      // Pop with null to indicate error
      if (mounted) {
        Navigator.of(context).pop(null);
      }
    }
  }
}
