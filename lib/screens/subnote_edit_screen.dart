import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';
import '../widgets/synapse_note_editor.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/note.dart';

class SubNoteEditScreen extends StatefulWidget {
  final Note parentNote;
  final SubNote? subNote; // null for new subnote, existing subnote for editing
  final bool isNewSubNote;

  const SubNoteEditScreen({super.key, required this.parentNote, this.subNote})
    : isNewSubNote = subNote == null;

  @override
  State<SubNoteEditScreen> createState() => _SubNoteEditScreenState();
}

class _SubNoteEditScreenState extends State<SubNoteEditScreen> {
  late TextEditingController _nameController;
  late CodeLineEditingController _contentController;
  late FocusNode _contentFocusNode;
  bool _hasChanges = false;
  Timer? _autoSaveTimer;
  String?
  _currentSubNoteId; // Track the current subnote ID for upsert operations

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.subNote?.name ?? '');
    _contentController = CodeLineEditingController.fromText(
      widget.subNote?.content ?? '',
    );
    _contentFocusNode = FocusNode();

    _nameController.addListener(_onTextChanged);
    _contentController.addListener(_onTextChanged);

    // Set up subnote ID
    if (widget.isNewSubNote) {
      _currentSubNoteId = DateTime.now().millisecondsSinceEpoch.toString();
    } else {
      _currentSubNoteId = widget.subNote!.id;
    }
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _nameController.dispose();
    _contentController.dispose();
    _contentFocusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (!_hasChanges) {
      // Defer setState to avoid "setState during build" error from re_editor's initial notification
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_hasChanges) {
          setState(() {
            _hasChanges = true;
          });
        }
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
    if (_nameController.text.trim().isEmpty &&
        _contentController.text.trim().isEmpty) {
      return; // Don't save empty subnotes
    }

    final appProvider = context.read<AppProvider>();

    // Create subnote with current ID (stable for new subnotes, original for existing)
    final subNote = SubNote(
      id: _currentSubNoteId!,
      name: _nameController.text.trim().isEmpty
          ? 'Untitled'
          : _nameController.text.trim(),
      content: _contentController.text.trim(),
      createdAt: widget.isNewSubNote
          ? DateTime.now()
          : widget.subNote!.createdAt,
    );

    // Use upsert to either add new or update existing
    appProvider.upsertSubNoteInNote(widget.parentNote.id, subNote);

    setState(() {
      _hasChanges = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isNewSubNote ? l10n.addNewSubNote : l10n.editSubNote,
        ),
        actions: [
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            child: Chip(
              label: Text(_hasChanges ? l10n.unsaved : l10n.saved),
              backgroundColor: _hasChanges
                  ? Colors.orange.withOpacity(0.1)
                  : Colors.green.withOpacity(0.1),
              labelStyle: TextStyle(
                color: _hasChanges ? Colors.orange : Colors.green,
                fontWeight: FontWeight.w500,
              ),
              avatar: Icon(
                _hasChanges ? Icons.edit : Icons.check,
                size: 16,
                color: _hasChanges ? Colors.orange : Colors.green,
              ),
            ),
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
            child: SynapseNoteEditor(
              controller: _contentController,
              focusNode: _contentFocusNode,
              onPickImage: null, // No image picker for subnotes
            ),
          ),
        ],
      ),
    );
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
