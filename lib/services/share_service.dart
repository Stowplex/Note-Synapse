import 'dart:collection';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
import '../l10n/app_localizations.dart';

class ShareService {
  
  /// Generates markdown text from a list of notes with optional sub-notes and linked notes
  static Future<String> generateMarkdownText({
    required List<Note> notes,
    required bool includeSubNotesAndLinkedNotes,
    required AppProvider appProvider,
    required AppLocalizations l10n,
  }) async {
    final buffer = StringBuffer();
    final Set<String> visitedNoteIds = <String>{};
    final Queue<Note> noteQueue = Queue<Note>();
    
    // Add root notes to the queue
    for (final note in notes) {
      noteQueue.add(note);
    }
    
    // Breadth-first traversal
    while (noteQueue.isNotEmpty) {
      final currentNote = noteQueue.removeFirst();
      
      // Skip if already processed
      if (visitedNoteIds.contains(currentNote.id)) {
        continue;
      }
      
      // Mark as visited
      visitedNoteIds.add(currentNote.id);
      
      // Add current note to buffer
      await _addNoteToBuffer(
        note: currentNote,
        buffer: buffer,
        processedNoteIds: visitedNoteIds,
        includeSubNotesAndLinkedNotes: includeSubNotesAndLinkedNotes,
        appProvider: appProvider,
        l10n: l10n,
        level: 0,
      );
      
      // If including linked notes, add them to the queue for processing
      if (includeSubNotesAndLinkedNotes) {
        try {
          final relationships = await appProvider.getNoteRelationships(currentNote.id);
          final linkedNotes = await appProvider.getLinkedNotes(currentNote.id);
          
          for (final relationship in relationships) {
            final linkedNote = linkedNotes.firstWhere(
              (n) => n.id == (relationship.fromNoteId == currentNote.id ? relationship.toNoteId : relationship.fromNoteId),
              orElse: () => Note(
                id: 'unknown',
                title: 'Unknown Note',
                content: '',
                type: NoteType.note,
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
              ),
            );
            
            // Add to queue if not already visited and not unknown
            if (linkedNote.id != 'unknown' && !visitedNoteIds.contains(linkedNote.id)) {
              noteQueue.add(linkedNote);
            }
          }
        } catch (e) {
          // If there's an error loading relationships, just continue
          // Silently handle relationship loading errors
        }
      }
    }
    
    return buffer.toString();
  }
  
  /// Adds a note to the buffer with proper markdown formatting
  static Future<void> _addNoteToBuffer({
    required Note note,
    required StringBuffer buffer,
    required Set<String> processedNoteIds,
    required bool includeSubNotesAndLinkedNotes,
    required AppProvider appProvider,
    required AppLocalizations l10n,
    required int level,
  }) async {
    // Note: We don't need to check for duplicates here since the main BFS loop
    // already handles the visited check before calling this method
    
    // Add note header
    final headerPrefix = '#${'#' * level}';
    buffer.writeln('$headerPrefix ${note.title}');
    buffer.writeln();
    
    // Add note metadata
    buffer.writeln('**${l10n.type}:** ${note.isTask ? l10n.task : l10n.note}');
    if (note.isTask && note.status != null) {
      buffer.writeln('**${l10n.status}:** ${_getStatusText(note.status!, l10n)}');
    }
    if (note.tags.isNotEmpty) {
      buffer.writeln('**${l10n.tags}:** ${note.tags.join(', ')}');
    }
    buffer.writeln('**${l10n.created}:** ${_formatDateTime(note.createdAt)}');
    if (note.updatedAt != note.createdAt) {
      buffer.writeln('**${l10n.updated}:** ${_formatDateTime(note.updatedAt)}');
    }
    buffer.writeln();
    
    // Add note content
    if (note.content.isNotEmpty) {
      buffer.writeln(note.content);
      buffer.writeln();
    }
    
    // Add sub-notes if requested
    if (includeSubNotesAndLinkedNotes && note.subNotes.isNotEmpty) {
      buffer.writeln('## ${l10n.subNotes}');
      buffer.writeln();
      
      for (final subNote in note.subNotes) {
        buffer.writeln('### ${subNote.name}');
        if (subNote.isCompleted) {
          buffer.writeln('✅ **${l10n.completed}**');
        }
        buffer.writeln('**${l10n.created}:** ${_formatDateTime(subNote.createdAt)}');
        buffer.writeln();
        if (subNote.content.isNotEmpty) {
          buffer.writeln(subNote.content);
          buffer.writeln();
        }
      }
    }
    
    // Add separator between notes
    if (level == 0) {
      buffer.writeln('---');
      buffer.writeln();
    }
  }
  
  /// Copies text to clipboard
  static Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }
  
  /// Shares text as a file (platform-specific)
  static Future<void> shareAsText(String text, BuildContext context) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await _shareAsTextMobile(text, context);
    } else if (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      await _shareAsTextDesktop(text, context);
    } else {
      // Fallback: copy to clipboard
      await copyToClipboard(text);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Text copied to clipboard (sharing not supported on this platform)'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }
  
  /// Mobile sharing using share_plus (Android and iOS)
  static Future<void> _shareAsTextMobile(String text, BuildContext context) async {
    try {
      await Share.share(
        text,
        subject: 'Shared Notes',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sharing: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
  
  /// Desktop sharing (Linux, Windows, macOS) - Save as file
  static Future<void> _shareAsTextDesktop(String text, BuildContext context) async {
    try {
      // Use file_picker to let user choose where to save
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Notes as Markdown',
        fileName: 'notes_${DateTime.now().millisecondsSinceEpoch}.md',
        type: FileType.custom,
        allowedExtensions: ['md'],
      );
      
      if (result != null) {
        final file = File(result);
        await file.writeAsString(text);
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Notes saved successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving file: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
  
  /// Helper method to get status text
  static String _getStatusText(TaskStatus status, AppLocalizations l10n) {
    switch (status) {
      case TaskStatus.complete:
        return l10n.completed;
      case TaskStatus.inProgress:
        return l10n.inProgress;
      case TaskStatus.abandoned:
        return l10n.cancelled;
      case TaskStatus.todo:
        return l10n.toDo;
    }
  }
  
  /// Helper method to format DateTime
  static String _formatDateTime(DateTime dateTime) {
    return '${dateTime.day}/${dateTime.month}/${dateTime.year} at ${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
  }
}