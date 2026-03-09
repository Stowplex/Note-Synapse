import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import '../models/attachment.dart';
import '../models/in_note_marker.dart';
import '../models/note.dart';
import '../screens/note_selection_dialog.dart';
import '../services/attachment_link_service.dart';
import '../services/database_service.dart';
import '../services/note_marker_service.dart';
import '../services/service_locator.dart';
import '../widgets/attachment_picker_widget.dart';
import '../widgets/pdf_location_picker.dart';

enum _Step { selectAttachment, selectLocation, confirm }

/// A multi-step wizard dialog that guides the user through:
/// 1. Select a note (via NoteSelectionDialog sub-dialog)
/// 2. Select an attachment from that note
/// 3. (PDF) Visual page picker with preview, or (non-PDF) confirm link text
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
  _Step _currentStep = _Step.selectAttachment;

  // Note state (selected via sub-dialog)
  Note? _selectedNote;

  // Attachment state
  Attachment? _selectedAttachment;

  // PDF loading state
  bool _loadingPdf = false;
  int? _pdfTotalPages;
  List<PdfOutlineNode>? _pdfOutline;
  String? _pdfAbsPath;
  List<InNoteMarker> _markers = [];

  // Confirm state (non-PDF)
  final TextEditingController _linkTextController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showNoteSelectionDialog();
    });
  }

  @override
  void dispose() {
    _linkTextController.dispose();
    super.dispose();
  }

  Future<void> _showNoteSelectionDialog() async {
    if (!mounted) return;
    final selectedNotes = await showDialog<List<Note>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => NoteSelectionDialog(
        singleSelection: true,
        title: 'Select Note',
        onNotesSelected: (notes) =>
            Navigator.of(dialogContext).pop(notes),
      ),
    );

    if (!mounted) return;
    if (selectedNotes == null || selectedNotes.isEmpty) {
      // User cancelled note selection → close main dialog
      Navigator.of(context).pop(null);
      return;
    }

    setState(() {
      _selectedNote = selectedNotes.first;
      _currentStep = _Step.selectAttachment;
    });
  }

  void _goBack() {
    setState(() {
      switch (_currentStep) {
        case _Step.selectAttachment:
          // Go back to note selection
          _selectedNote = null;
          _showNoteSelectionDialog();
        case _Step.selectLocation:
          _selectedAttachment = null;
          _pdfTotalPages = null;
          _pdfOutline = null;
          _pdfAbsPath = null;
          _currentStep = _Step.selectAttachment;
        case _Step.confirm:
          _selectedAttachment = null;
          _currentStep = _Step.selectAttachment;
      }
    });
  }

  void _onAttachmentSelected(Attachment attachment) async {
    if (attachment.fileName.endsWith('.pdf')) {
      setState(() {
        _selectedAttachment = attachment;
        _loadingPdf = true;
        _currentStep = _Step.selectLocation;
      });
      await _loadPdfData(attachment);
    } else {
      setState(() {
        _selectedAttachment = attachment;
        _prepareConfirmStep();
      });
    }
  }

  Future<void> _loadPdfData(Attachment attachment) async {
    try {
      final absPath = await attachment.getAbsolutePath();

      pdfrx.Pdfrx.getCacheDirectory ??= () async {
        final tempDir = await getTemporaryDirectory();
        return tempDir.path;
      };

      final document = await pdfrx.PdfDocument.openFile(absPath);
      final totalPages = document.pages.length;
      final rawOutline = await document.loadOutline();
      document.dispose();

      final outline = rawOutline.isNotEmpty
          ? _convertOutline(rawOutline, totalPages)
          : <PdfOutlineNode>[];

      if (mounted) {
        setState(() {
          _pdfTotalPages = totalPages;
          _pdfOutline = outline;
          _pdfAbsPath = absPath;
          _loadingPdf = false;
        });
      }

      // Load markers for the attachment
      try {
        final markerService = getIt<NoteMarkerService>();
        final markers = await markerService.getMarkersForAttachment(
          attachment.id,
        );
        if (mounted) {
          setState(() {
            _markers = markers;
          });
        }
      } catch (_) {
        // Non-critical — markers are optional
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingPdf = false;
        });
      }
    }
  }

  List<PdfOutlineNode> _convertOutline(
      List<pdfrx.PdfOutlineNode> nodes, int totalPages) {
    return nodes.map((node) {
      final pageNum = node.dest?.pageNumber != null
          ? (node.dest!.pageNumber + 1).clamp(1, totalPages)
          : 1;
      return PdfOutlineNode(
        title: node.title,
        page: pageNum,
        children: node.children.isNotEmpty
            ? _convertOutline(node.children, totalPages)
            : const [],
      );
    }).toList();
  }

  void _prepareConfirmStep() {
    final attachment = _selectedAttachment!;
    final linkService = AttachmentLinkService(getIt<DatabaseService>());
    final defaultText = linkService.defaultLinkText(
      fileName: attachment.fileName,
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
    );
    Navigator.of(context).pop(markdownLink);
  }

  String _stepTitle() {
    switch (_currentStep) {
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
    // Don't render the dialog body until we have a note selected
    if (_selectedNote == null) {
      return const SizedBox.shrink();
    }

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
      case _Step.selectAttachment:
        return _buildAttachmentSelection();
      case _Step.selectLocation:
        return _buildLocationSelection();
      case _Step.confirm:
        return _buildConfirmation();
    }
  }

  Widget _buildAttachmentSelection() {
    return AttachmentPickerWidget(
      noteId: _selectedNote!.id,
      onSelected: _onAttachmentSelected,
    );
  }

  Widget _buildLocationSelection() {
    if (_loadingPdf) {
      return const Center(child: CircularProgressIndicator());
    }

    final attachment = _selectedAttachment!;
    return PdfLocationPicker(
      totalPages: _pdfTotalPages,
      bookmarks: attachment.getBookmarks(),
      outline: _pdfOutline,
      markers: _markers,
      pdfPath: _pdfAbsPath,
      attachmentId: attachment.id,
      fileName: attachment.fileName,
      onInsert: (markdownLink) {
        Navigator.of(context).pop(markdownLink);
      },
      onCancel: () => Navigator.of(context).pop(null),
    );
  }

  Widget _buildConfirmation() {
    final attachment = _selectedAttachment!;
    final linkService = AttachmentLinkService(getIt<DatabaseService>());
    final preview = linkService.generateMarkdownLink(
      attachmentId: attachment.id,
      linkText: _linkTextController.text,
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
