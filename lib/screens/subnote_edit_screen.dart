import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';

class SubNoteEditScreen extends StatefulWidget {
  final Note parentNote;
  final SubNote? subNote; // null for new subnote, existing subnote for editing
  final bool isNewSubNote;

  const SubNoteEditScreen({
    super.key,
    required this.parentNote,
    this.subNote,
  }) : isNewSubNote = subNote == null;

  @override
  State<SubNoteEditScreen> createState() => _SubNoteEditScreenState();
}

class _SubNoteEditScreenState extends State<SubNoteEditScreen> {
  late TextEditingController _nameController;
  late TextEditingController _contentController;
  bool _hasChanges = false;
  bool _hasBeenSaved = false; // Track if subnote has 1been saved to database
  Timer? _autoSaveTimer;
  String? _currentSubNoteId; // Track the current subnote ID for upsert operations

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.subNote?.name ?? '');
    _contentController = TextEditingController(text: widget.subNote?.content ?? '');
    
    _nameController.addListener(_onTextChanged);
    _contentController.addListener(_onTextChanged);
    
    // Set up subnote ID and save state
    if (widget.isNewSubNote) {
      _hasBeenSaved = false;
      _currentSubNoteId = DateTime.now().millisecondsSinceEpoch.toString();
    } else {
      _hasBeenSaved = true;
      _currentSubNoteId = widget.subNote!.id;
    }
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _nameController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (!_hasChanges) {
      setState(() {
        _hasChanges = true;
      });
    }
    
    // Auto-save after 2 seconds of no typing
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () {
      if (_hasChanges) {
        _autoSave();
      }
    });
  }

  void _autoSave() {
    if (_nameController.text.trim().isEmpty && _contentController.text.trim().isEmpty) {
      return; // Don't save empty subnotes
    }
    
    final appProvider = context.read<AppProvider>();
    
    // Create subnote with current ID (stable for new subnotes, original for existing)
    final subNote = SubNote(
      id: _currentSubNoteId!,
      name: _nameController.text.trim().isEmpty ? 'Untitled' : _nameController.text.trim(),
      content: _contentController.text.trim(),
      createdAt: widget.isNewSubNote ? DateTime.now() : widget.subNote!.createdAt,
    );
    
    // Use upsert to either add new or update existing
    appProvider.upsertSubNoteInNote(widget.parentNote.id, subNote);
    
    setState(() {
      _hasBeenSaved = true; // Mark as saved
      _hasChanges = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNewSubNote ? l10n.addNewSubNote : l10n.editSubNote),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _hasChanges ? _saveChanges : null,
            tooltip: l10n.saveChanges,
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: _cancelEditing,
            tooltip: l10n.close,
          ),
        ],
      ),
      body: _buildEditingView(l10n),
    );
  }

  Widget _buildEditingView(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: l10n.subNote,
              border: const OutlineInputBorder(),
              hintText: 'Enter a brief name for this sub-note',
            ),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: TextField(
              controller: _contentController,
              decoration: InputDecoration(
                labelText: l10n.title,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
                hintText: 'Enter the sub-note content...',
              ),
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
            ),
          ),
          const SizedBox(height: 8),
          _buildMarkdownButtons(),
        ],
      ),
    );
  }

  Widget _buildMarkdownButtons() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildMarkdownButton(
            icon: Icons.check_box_outline_blank,
            label: 'Checkbox',
            onPressed: _insertCheckbox,
          ),
          _buildMarkdownButton(
            icon: Icons.title,
            label: 'Title',
            onPressed: _insertTitle,
          ),
          _buildMarkdownButton(
            icon: Icons.format_bold,
            label: 'Bold',
            onPressed: _insertBold,
          ),
        ],
      ),
    );
  }

  Widget _buildMarkdownButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(icon),
          onPressed: onPressed,
          tooltip: label,
        ),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  void _insertCheckbox() {
    final text = _contentController.text;
    final selection = _contentController.selection;
    final newText = text.replaceRange(
      selection.start,
      selection.end,
      '- [ ] ',
    );
    _contentController.text = newText;
    _contentController.selection = TextSelection.fromPosition(
      TextPosition(offset: selection.start + 6),
    );
  }

  void _insertTitle() {
    final text = _contentController.text;
    final selection = _contentController.selection;
    final newText = text.replaceRange(
      selection.start,
      selection.end,
      '## ',
    );
    _contentController.text = newText;
    _contentController.selection = TextSelection.fromPosition(
      TextPosition(offset: selection.start + 3),
    );
  }

  void _insertBold() {
    final text = _contentController.text;
    final selection = _contentController.selection;
    final newText = text.replaceRange(
      selection.start,
      selection.end,
      '**bold text**',
    );
    _contentController.text = newText;
    _contentController.selection = TextSelection.fromPosition(
      TextPosition(offset: selection.start + 2),
    );
  }

  void _saveChanges() {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a name for the sub-note'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Cancel any pending auto-save
    _autoSaveTimer?.cancel();
    
    // Force save immediately
    _autoSave();
    
    Navigator.pop(context);
  }

  void _cancelEditing() {
    // Cancel any pending auto-save
    _autoSaveTimer?.cancel();
    
    if (_hasChanges) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard Changes'),
          content: const Text('Are you sure you want to discard your changes?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context); // Close dialog
                Navigator.pop(context); // Close edit screen
              },
              child: const Text('Discard'),
            ),
          ],
        ),
      );
    } else {
      Navigator.pop(context);
    }
  }
}
