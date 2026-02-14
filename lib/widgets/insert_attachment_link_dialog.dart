import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/attachment.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
import '../services/attachment_link_service.dart';
import '../services/database_service.dart';
import '../services/service_locator.dart';
import '../widgets/attachment_picker_widget.dart';
import '../widgets/pdf_location_picker.dart';

enum _Step { selectNote, selectAttachment, selectLocation, confirm }

/// A multi-step wizard dialog that guides the user through:
/// 1. Select a note
/// 2. Select an attachment from that note
/// 3. (PDF only) Select a page/location
/// 4. Confirm link text
///
/// Returns the generated markdown link string, or null if cancelled.
class InsertAttachmentLinkDialog extends StatefulWidget {
  const InsertAttachmentLinkDialog({super.key});

  @override
  State<InsertAttachmentLinkDialog> createState() =>
      _InsertAttachmentLinkDialogState();
}

class _InsertAttachmentLinkDialogState
    extends State<InsertAttachmentLinkDialog> {
  _Step _currentStep = _Step.selectNote;

  // Step 1 state
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // Step 2 state
  Note? _selectedNote;

  // Step 3 state
  Attachment? _selectedAttachment;
  PdfLocationSelection? _pdfLocation;

  // Step 4 state
  final TextEditingController _linkTextController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    _linkTextController.dispose();
    super.dispose();
  }

  void _goBack() {
    setState(() {
      switch (_currentStep) {
        case _Step.selectNote:
          Navigator.of(context).pop(null);
          return;
        case _Step.selectAttachment:
          _selectedNote = null;
          _currentStep = _Step.selectNote;
        case _Step.selectLocation:
          _selectedAttachment = null;
          _pdfLocation = null;
          _currentStep = _Step.selectAttachment;
        case _Step.confirm:
          if (_selectedAttachment != null &&
              _selectedAttachment!.fileName.endsWith('.pdf')) {
            _pdfLocation = null;
            _currentStep = _Step.selectLocation;
          } else {
            _selectedAttachment = null;
            _currentStep = _Step.selectAttachment;
          }
      }
    });
  }

  void _onNoteSelected(Note note) {
    setState(() {
      _selectedNote = note;
      _currentStep = _Step.selectAttachment;
    });
  }

  void _onAttachmentSelected(Attachment attachment) {
    setState(() {
      _selectedAttachment = attachment;
      if (attachment.fileName.endsWith('.pdf')) {
        _currentStep = _Step.selectLocation;
      } else {
        _prepareConfirmStep();
      }
    });
  }

  void _onLocationSelected(PdfLocationSelection? location) {
    setState(() {
      _pdfLocation = location;
      _prepareConfirmStep();
    });
  }

  void _prepareConfirmStep() {
    final attachment = _selectedAttachment!;
    final linkService = AttachmentLinkService(getIt<DatabaseService>());
    final defaultText = linkService.defaultLinkText(
      fileName: attachment.fileName,
      page: _pdfLocation?.page,
      bookmarkTitle: null,
      chapterTitle: _pdfLocation?.displayText != null &&
              _pdfLocation!.displayText != 'Page ${_pdfLocation!.page}'
          ? _pdfLocation!.displayText
          : null,
    );
    _linkTextController.text = defaultText;
    _currentStep = _Step.confirm;
  }

  void _insertLink() {
    final attachment = _selectedAttachment!;
    final linkService = AttachmentLinkService(getIt<DatabaseService>());
    final markdownLink = linkService.generateMarkdownLink(
      attachmentId: attachment.id,
      linkText: _linkTextController.text,
      page: _pdfLocation?.page,
    );
    Navigator.of(context).pop(markdownLink);
  }

  String _stepTitle() {
    switch (_currentStep) {
      case _Step.selectNote:
        return 'Select Note';
      case _Step.selectAttachment:
        return 'Select Attachment';
      case _Step.selectLocation:
        return 'Select Location';
      case _Step.confirm:
        return 'Confirm Link';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: MediaQuery.of(context).size.width * 0.8,
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  if (_currentStep != _Step.selectNote)
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _goBack,
                      tooltip: 'Back',
                    ),
                  Expanded(
                    child: Text(
                      _stepTitle(),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(null),
                    tooltip: 'Cancel',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Body
            Expanded(child: _buildStepContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildStepContent() {
    switch (_currentStep) {
      case _Step.selectNote:
        return _buildNoteSelection();
      case _Step.selectAttachment:
        return _buildAttachmentSelection();
      case _Step.selectLocation:
        return _buildLocationSelection();
      case _Step.confirm:
        return _buildConfirmation();
    }
  }

  Widget _buildNoteSelection() {
    final notes = context.watch<AppProvider>().notes;
    final filteredNotes = _searchQuery.isEmpty
        ? notes
        : notes.where((note) {
            final query = _searchQuery.toLowerCase();
            return note.title.toLowerCase().contains(query) ||
                note.content.toLowerCase().contains(query);
          }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              hintText: 'Search notes...',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
          ),
        ),
        Expanded(
          child: filteredNotes.isEmpty
              ? const Center(child: Text('No notes found'))
              : ListView.builder(
                  itemCount: filteredNotes.length,
                  itemBuilder: (context, index) {
                    final note = filteredNotes[index];
                    return ListTile(
                      leading: const Icon(Icons.note),
                      title: Text(note.title),
                      subtitle: Text(
                        note.content,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _onNoteSelected(note),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildAttachmentSelection() {
    return AttachmentPickerWidget(
      noteId: _selectedNote!.id,
      onSelected: _onAttachmentSelected,
    );
  }

  Widget _buildLocationSelection() {
    final attachment = _selectedAttachment!;
    final bookmarks = attachment.getBookmarks();

    return PdfLocationPicker(
      bookmarks: bookmarks,
      onSelected: _onLocationSelected,
    );
  }

  Widget _buildConfirmation() {
    final attachment = _selectedAttachment!;
    final linkService = AttachmentLinkService(getIt<DatabaseService>());
    final preview = linkService.generateMarkdownLink(
      attachmentId: attachment.id,
      linkText: _linkTextController.text,
      page: _pdfLocation?.page,
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Link Text',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _linkTextController,
            decoration: const InputDecoration(
              hintText: 'Enter link text',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Text(
            'Preview',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              preview,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _linkTextController.text.isNotEmpty
                    ? _insertLink
                    : null,
                child: const Text('Insert'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
