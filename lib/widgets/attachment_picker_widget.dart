import 'package:flutter/material.dart';
import '../models/attachment.dart';
import '../services/database_service.dart';
import '../services/service_locator.dart';

class AttachmentPickerWidget extends StatefulWidget {
  final String noteId;
  final Function(Attachment) onSelected;

  const AttachmentPickerWidget({
    super.key,
    required this.noteId,
    required this.onSelected,
  });

  @override
  State<AttachmentPickerWidget> createState() => _AttachmentPickerWidgetState();
}

class _AttachmentPickerWidgetState extends State<AttachmentPickerWidget> {
  List<Attachment>? _attachments;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAttachments();
  }

  Future<void> _loadAttachments() async {
    final attachments =
        await getIt<DatabaseService>().getAttachmentsForNote(widget.noteId);
    if (mounted) {
      setState(() {
        _attachments = attachments;
        _loading = false;
      });
    }
  }

  IconData _iconForAttachment(Attachment attachment) {
    if (attachment.fileName.endsWith('.pdf')) {
      return Icons.picture_as_pdf;
    } else if (attachment.fileType.startsWith('image/')) {
      return Icons.image;
    }
    return Icons.insert_drive_file;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final attachments = _attachments;
    if (attachments == null || attachments.isEmpty) {
      return const Center(child: Text('No attachments'));
    }

    return ListView.builder(
      itemCount: attachments.length,
      itemBuilder: (context, index) {
        final attachment = attachments[index];
        return ListTile(
          leading: Icon(_iconForAttachment(attachment)),
          title: Text(attachment.fileName),
          subtitle: Text(attachment.fileType),
          onTap: () => widget.onSelected(attachment),
        );
      },
    );
  }
}
