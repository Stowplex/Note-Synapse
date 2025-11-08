import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../models/note.dart';
import '../services/logger_service.dart';
import '../widgets/add_note_dialog.dart';
import '../screens/note_detail_screen.dart';

mixin NoteActionMixin<T extends StatefulWidget> on State<T> {
  Future<void> handleAddContentToNote({
    required String content,
    List<Note> contextNotes = const [],
  }) async {
    try {
      final result = await AddNoteDialog.show(
        context: context,
        content: content,
        contextNotes: contextNotes,
      );

      if (!mounted || result == null) return;

      final l10n = AppLocalizations.of(context)!;

      if (result.isAppend) {
        final appendedNote = result.appendedNote!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${l10n.contentAppendedSuccessfully} "${appendedNote.title}"',
            ),
            backgroundColor: Colors.green,
            action: SnackBarAction(
              label: l10n.view,
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => NoteDetailScreen(note: appendedNote),
                  ),
                );
              },
            ),
          ),
        );
        return;
      }

      if (result.hasCreatedNotes) {
        final createdNotes = result.createdNotes;
        final firstNote = createdNotes.first;
        final message = createdNotes.length == 1
            ? l10n.noteCreatedSuccessfully(firstNote.title)
            : l10n.multipleNotesCreatedSuccessfully(createdNotes.length);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.green,
            action: SnackBarAction(
              label: l10n.view,
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => NoteDetailScreen(note: firstNote),
                  ),
                );
              },
            ),
          ),
        );
      }
    } catch (e, stackTrace) {
      LoggerService.error(
        'Error creating note from content: $e',
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;

      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.errorCreatingNote(e)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void copyContentToClipboard(String content) {
    Clipboard.setData(ClipboardData(text: content));
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.messageCopiedToClipboard),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
