import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
import '../services/logger_service.dart';
import '../utils/file_utils.dart';

class ImportStats {
  int processed = 0;
  int imported = 0;
  int updated = 0;
  int skipped = 0;
  int errors = 0;

  @override
  String toString() {
    return 'Imported: $imported, Updated: $updated, Skipped: $skipped, Errors: $errors';
  }
}

class ImportService {
  static final ImportService _instance = ImportService._internal();
  factory ImportService() => _instance;
  ImportService._internal();

  Future<ImportStats> importFromMarkdownZip(
    File zipFile,
    AppProvider appProvider,
  ) async {
    final stats = ImportStats();
    final tempDir = await getTemporaryDirectory();
    final importId = const Uuid().v4();
    final unzipDir = Directory(p.join(tempDir.path, 'import_$importId'));

    try {
      if (!await unzipDir.exists()) {
        await unzipDir.create(recursive: true);
      }

      LoggerService.info('Extracting zip to ${unzipDir.path}');
      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final data = file.content as List<int>;
          File(p.join(unzipDir.path, filename))
            ..createSync(recursive: true)
            ..writeAsBytesSync(data);
        } else {
          Directory(
            p.join(unzipDir.path, filename),
          ).createSync(recursive: true);
        }
      }

      final files = unzipDir.listSync(recursive: false);
      final attachmentDir = Directory(p.join(unzipDir.path, 'attachments'));

      for (final file in files) {
        if (file is File && p.extension(file.path).toLowerCase() == '.md') {
          stats.processed++;
          try {
            await _processMarkdownFile(file, attachmentDir, appProvider, stats);
          } catch (e) {
            LoggerService.error('Error processing file ${file.path}', error: e);
            stats.errors++;
          }
        }
      }
    } catch (e) {
      LoggerService.error('Import failed', error: e);
      rethrow;
    } finally {
      if (await unzipDir.exists()) {
        await unzipDir.delete(recursive: true);
      }
    }

    return stats;
  }

  Future<void> _processMarkdownFile(
    File file,
    Directory attachmentDir,
    AppProvider appProvider,
    ImportStats stats,
  ) async {
    final content = await file.readAsString();
    final noteData = _parseNoteMarkdown(content);

    if (noteData == null) {
      LoggerService.warning('Failed to parse markdown file: ${file.path}');
      stats.errors++;
      return;
    }

    final String? existingNoteId = noteData.id;
    final DateTime? updatedAt = noteData.updatedAt;

    if (existingNoteId != null) {
      // Check if note exists
      try {
        final existingNote = appProvider.notes
            .where((n) => n.id == existingNoteId)
            .firstOrNull;

        if (existingNote != null) {
          // Compare dates
          if (updatedAt != null && updatedAt.isAfter(existingNote.updatedAt)) {
            // Update
            LoggerService.info(
              'Updating note ${existingNote.title} ($existingNoteId)',
            );
            await _updateNote(
              existingNote,
              noteData,
              attachmentDir,
              appProvider,
            );
            stats.updated++;
          } else {
            // Skip
            LoggerService.info(
              'Skipping older/same version of note ${existingNote.title} ($existingNoteId)',
            );
            stats.skipped++;
          }
        } else {
          // New Note with specified ID
          LoggerService.info(
            'Importing new note ${noteData.title} ($existingNoteId)',
          );
          await _createNote(noteData, attachmentDir, appProvider);
          stats.imported++;
        }
      } catch (e) {
        LoggerService.error('Error checking existing note', error: e);
        rethrow;
      }
    } else {
      // No ID found, create as new note with new ID
      LoggerService.info('Importing new note without ID: ${noteData.title}');
      await _createNote(
        noteData,
        attachmentDir,
        appProvider,
        generateNewId: true,
      );
      stats.imported++;
    }
  }

  Future<void> _createNote(
    _ParsedNoteData data,
    Directory attachmentDir,
    AppProvider appProvider, {
    bool generateNewId = false,
  }) async {
    final noteId = generateNewId ? const Uuid().v4() : data.id!;

    // Process Attachments first
    final attachmentPaths = <String>[];
    for (final att in data.attachments) {
      final savedPath = await _saveAttachment(att, attachmentDir, noteId);
      if (savedPath != null) {
        attachmentPaths.add(savedPath);
      }
    }

    final newNote = Note(
      id: noteId,
      title: data.title,
      content: data.content,
      type: data.type,
      status: data.status, // Use parsed status
      createdAt: data.createdAt ?? DateTime.now(),
      updatedAt: data.updatedAt ?? DateTime.now(),
      tags: data.tags,
      scheduledAt: data.scheduledAt,
      completeBy: data.completeBy,
      subNotes: data.subNotes
          .map(
            (sn) => sn.copyWith(id: generateNewId ? const Uuid().v4() : sn.id),
          )
          .toList(),
      attachmentPaths: attachmentPaths,
      // recurrenceRule? pinned? isArchived? not in parsing logic yet but good to defaults.
    );

    await appProvider.addNote(newNote);
  }

  Future<void> _updateNote(
    Note existingNote,
    _ParsedNoteData data,
    Directory attachmentDir,
    AppProvider appProvider,
  ) async {
    // Process Attachments (merge?)
    final currentPaths = List<String>.from(existingNote.attachmentPaths);

    for (final att in data.attachments) {
      final savedPath = await _saveAttachment(
        att,
        attachmentDir,
        existingNote.id,
      );
      if (savedPath != null && !currentPaths.contains(savedPath)) {
        currentPaths.add(savedPath);
      }
    }

    final updatedNote = existingNote.copyWith(
      title: data.title,
      content: data.content,
      type: data.type,
      status: data.status, // Update status
      updatedAt: data.updatedAt,
      tags: data.tags,
      scheduledAt: data.scheduledAt,
      completeBy: data.completeBy,
      subNotes: data.subNotes,
      attachmentPaths: currentPaths,
    );

    await appProvider.updateNote(updatedNote);
  }

  Future<String?> _saveAttachment(
    _ParsedAttachment att,
    Directory sourceDir,
    String noteId,
  ) async {
    final fileName = p.basename(att.path);
    final sourceFile = File(p.join(sourceDir.path, fileName));
    if (!await sourceFile.exists()) {
      LoggerService.warning('Attachment not found in zip: $fileName');
      return null;
    }

    final bytes = await sourceFile.readAsBytes();
    return await FileUtils.saveImportedFile(bytes, fileName);
  }

  _ParsedNoteData? _parseNoteMarkdown(String content) {
    String? id;
    String title = 'Untitled';
    String body = '';
    NoteType type = NoteType.note;
    TaskStatus? status;
    DateTime? createdAt;
    DateTime? updatedAt;
    String? scheduledAt;
    String? completeBy;
    List<String> tags = [];
    List<SubNote> subNotes = [];
    List<_ParsedAttachment> attachments = [];

    final lines = content.split('\n');
    int i = 0;

    // Parse Title (First H1)
    if (i < lines.length && lines[i].startsWith('# ')) {
      title = lines[i].substring(2).trim();
      i++;
    }

    // Skip blanks
    while (i < lines.length && lines[i].trim().isEmpty) i++;

    // Metadata Block
    for (; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      if (line.startsWith('**ID:**')) {
        id = line.substring(7).trim();
      } else if (line.startsWith('**Type:**')) {
        // Standard English check
        final val = line.split('**').last.substring(1).trim().toLowerCase();
        if (val == 'task') {
          type = NoteType.task;
        }
      } else if (line.startsWith('**Status:**')) {
        final val = line.split('**').last.substring(1).trim().toLowerCase();
        if (val == 'todo')
          status = TaskStatus.todo;
        else if (val == 'in progress')
          status = TaskStatus.inProgress;
        else if (val == 'done')
          status = TaskStatus.complete;
        else if (val == 'abandoned')
          status = TaskStatus.abandoned;
        // Fallback or legacy check could be added here if needed
      } else if (line.startsWith('**Tags:**')) {
        final val = line.split(':**').last.trim();
        tags = val
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      } else if (line.startsWith('**Created:**')) {
        final val = line.split(':**').last.trim();
        createdAt = DateTime.tryParse(val);
        if (createdAt == null) {
          try {
            final parts = val.split('/');
            if (parts.length == 3) {
              createdAt = DateTime(
                int.parse(parts[2]),
                int.parse(parts[0]),
                int.parse(parts[1]),
              );
            }
          } catch (_) {}
        }
      } else if (line.startsWith('**Updated:**')) {
        final val = line.split(':**').last.trim();
        updatedAt = DateTime.tryParse(val);
        if (updatedAt == null) {
          try {
            final parts = val.split('/');
            if (parts.length == 3) {
              updatedAt = DateTime(
                int.parse(parts[2]),
                int.parse(parts[0]),
                int.parse(parts[1]),
              );
            }
          } catch (_) {}
        }
      } else if (line.startsWith('**Scheduled:**')) {
        final val = line.split(':**').last.trim();
        final date = DateTime.tryParse(val);
        if (date != null) {
          scheduledAt = date.toIso8601String();
        } else {
          try {
            final parts = val.split('/');
            if (parts.length == 3) {
              scheduledAt = DateTime(
                int.parse(parts[2]),
                int.parse(parts[0]),
                int.parse(parts[1]),
              ).toIso8601String();
            } else {
              scheduledAt = val;
            }
          } catch (_) {
            scheduledAt = val;
          }
        }
      } else if (line.startsWith('**Due:**')) {
        final val = line.split(':**').last.trim();
        final date = DateTime.tryParse(val);
        if (date != null) {
          completeBy = date.toIso8601String();
        } else {
          try {
            final parts = val.split('/');
            if (parts.length == 3) {
              completeBy = DateTime(
                int.parse(parts[2]),
                int.parse(parts[0]),
                int.parse(parts[1]),
              ).toIso8601String();
            } else {
              completeBy = val;
            }
          } catch (_) {
            completeBy = val;
          }
        }
      } else {
        // Stop if not a metadata line
        if (!line.startsWith('**')) break;
      }
    }

    // Content
    StringBuffer contentBuffer = StringBuffer();
    for (; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('## Attachments') ||
          line.startsWith('## Sub-notes')) {
        break;
      }
      contentBuffer.writeln(line);
    }
    body = contentBuffer.toString().trim();

    // Sections
    for (; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('## Attachments')) {
        i++;
        while (i < lines.length && !lines[i].startsWith('## ')) {
          final attLine = lines[i].trim();
          if (attLine.startsWith('- **Name:**')) {
            String name = attLine.split(':**').last.trim();
            String path = '';
            String type = '';

            while (i + 1 < lines.length &&
                (lines[i + 1].trim().startsWith('- **Path:**') ||
                    lines[i + 1].trim().startsWith('- **Type:**'))) {
              i++;
              final subLine = lines[i].trim();
              if (subLine.startsWith('- **Path:**'))
                path = subLine.split(':**').last.trim();
              if (subLine.startsWith('- **Type:**'))
                type = subLine.split(':**').last.trim();
            }
            attachments.add(_ParsedAttachment(name, path, type));
          }
          i++;
        }
        i--;
      } else if (line.startsWith('## Sub-notes')) {
        i++;
        while (i < lines.length && !lines[i].startsWith('## ')) {
          final subLine = lines[i].trim();

          if (subLine.startsWith('### ')) {
            // New Subnote
            final snName = subLine.substring(4).trim();
            String snId = const Uuid().v4();
            bool snCompleted = false;
            DateTime snCreated = DateTime.now();
            final snContent = StringBuffer();

            int j = i + 1;
            while (j < lines.length &&
                !lines[j].startsWith('## ') &&
                !lines[j].startsWith('### ')) {
              final propLine = lines[j].trim();
              if (propLine.startsWith('**ID:**')) {
                snId = propLine.substring(7).trim();
              } else if (propLine.contains('✅ **Completed**')) {
                snCompleted = true;
              } else if (propLine.startsWith('**Created:**')) {
                try {
                  final val = propLine.split(':**').last.trim();
                  final parts = val.split('/');
                  if (parts.length == 3) {
                    snCreated = DateTime(
                      int.parse(parts[2]),
                      int.parse(parts[0]),
                      int.parse(parts[1]),
                    );
                  }
                } catch (_) {}
              } else {
                if (propLine.isNotEmpty) {
                  snContent.writeln(lines[j]);
                }
              }
              j++;
            }

            subNotes.add(
              SubNote(
                id: snId,
                name: snName,
                isCompleted: snCompleted,
                createdAt: snCreated,
                content: snContent.toString().trim(),
              ),
            );

            i = j - 1;
          }
          i++;
        }
        i--;
      }
    }

    return _ParsedNoteData(
      id: id,
      title: title,
      content: body,
      type: type,
      status: status,
      createdAt: createdAt,
      updatedAt: updatedAt,
      tags: tags,
      scheduledAt: scheduledAt,
      completeBy: completeBy,
      subNotes: subNotes,
      attachments: attachments,
    );
  }
}

class _ParsedNoteData {
  final String? id;
  final String title;
  final String content;
  final NoteType type;
  final TaskStatus? status;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? scheduledAt;
  final String? completeBy;
  final List<String> tags;
  final List<SubNote> subNotes;
  final List<_ParsedAttachment> attachments;

  _ParsedNoteData({
    this.id,
    required this.title,
    required this.content,
    required this.type,
    this.status,
    this.createdAt,
    this.updatedAt,
    this.scheduledAt,
    this.completeBy,
    this.tags = const [],
    this.subNotes = const [],
    this.attachments = const [],
  });
}

class _ParsedAttachment {
  final String name;
  final String path;
  final String type;
  _ParsedAttachment(this.name, this.path, this.type);
}
