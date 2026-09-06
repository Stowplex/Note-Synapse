import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/attachment.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import '../utils/file_utils.dart';
import '../utils/remote_image_storage.dart';
import '../utils/synapse_temp_utils.dart';
import 'database_service.dart';
import 'logger_service.dart';
import 'media_attachment_service.dart';

/// Downloads [imageUrls] for [noteId] and returns the relative paths of the
/// files it created. Injected so tests can avoid the network.
typedef RemoteImageFetcher =
    Future<List<String>> Function({
      required String noteId,
      required Iterable<String> imageUrls,
    });

Future<List<String>> _defaultRemoteImageFetcher({
  required String noteId,
  required Iterable<String> imageUrls,
}) async {
  final report = await MediaAttachmentService.downloadRemoteImages(
    noteId: noteId,
    imageUrls: imageUrls,
  );
  return report.downloadedRelativePaths;
}

/// Persistence side of the note merge editor: everything that turns a merged
/// markdown string into a real note. The in-memory editing model lives in
/// `MergeDocument`; the screen calls into this once the user taps Save.
class NoteMergeService {
  NoteMergeService(
    this._db, {
    Future<Directory> Function()? storageDirectory,
    RemoteImageFetcher? remoteImageFetcher,
  }) : _storageDirectory =
           storageDirectory ?? FileUtils.getPrivateStorageDirectory,
       _remoteImageFetcher = remoteImageFetcher ?? _defaultRemoteImageFetcher;

  final DatabaseService _db;
  final Future<Directory> Function() _storageDirectory;
  final RemoteImageFetcher _remoteImageFetcher;

  static final RegExp _markdownImage = RegExp(r'!\[[^\]]*\]\(\s*([^)\s]+)');

  /// Image targets referenced by `![](...)` in [content], in order, deduped.
  static List<String> imageTargets(String content) {
    final seen = <String>{};
    final out = <String>[];
    for (final m in _markdownImage.allMatches(content)) {
      var target = m.group(1)!;
      if (target.startsWith('<') && target.endsWith('>')) {
        target = target.substring(1, target.length - 1);
      }
      if (seen.add(target)) out.add(target);
    }
    return out;
  }

  /// A bare file name (no scheme, no directory) resolves against the shared
  /// private storage directory, so it can be carried over as-is.
  static bool isBareFileName(String target) =>
      !target.contains(':') && !target.contains('/') && !target.contains('\\');

  /// Turns any attachment path form into the `attachments/<name>` form the
  /// database stores.
  static String relativeAttachmentPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    const marker = 'attachments/';
    final index = normalized.lastIndexOf(marker);
    if (index != -1) return normalized.substring(index);
    return 'attachments/${p.basename(normalized)}';
  }

  /// Attachment paths the merged note should own: every bare-file-name image
  /// in [content], plus every source attachment whose file name appears in
  /// [content] (links written as `[name](attachments/name)` or by file name).
  ///
  /// Source attachments that the merged content never mentions are left out;
  /// the user can keep them explicitly via [extraAttachmentPaths].
  static List<String> referencedAttachmentPaths(
    String content,
    Iterable<Note> sources, {
    Iterable<String> extraAttachmentPaths = const [],
  }) {
    final out = <String>[];
    final seen = <String>{};
    void addPath(String path) {
      final rel = relativeAttachmentPath(path);
      if (seen.add(rel)) out.add(rel);
    }

    for (final target in imageTargets(content)) {
      if (isBareFileName(target)) addPath(target);
    }
    for (final note in sources) {
      for (final path in note.attachmentPaths) {
        final name = p.basename(path);
        if (name.isEmpty) continue;
        if (mentionsFileName(content, name)) addPath(path);
      }
    }
    for (final path in extraAttachmentPaths) {
      addPath(path);
    }
    return out;
  }

  /// True if [name] occurs in [content] as a whole token: `1.png` must not
  /// match `11.png` or `v1.png`, and `image.png` must not match `my-image.png`.
  static bool mentionsFileName(String content, String name) => RegExp(
    '(?<![\\w.-])${RegExp.escape(name)}(?![\\w-]|\\.\\w)',
  ).hasMatch(content);

  /// Source attachments that [content] does not mention, in `attachments/`
  /// form: the candidates for the save sheet's "other attachments" list.
  static List<String> unreferencedAttachmentPaths(
    String content,
    Iterable<Note> sources, {
    Iterable<String> alsoReferenced = const [],
  }) {
    final referenced = {
      ...referencedAttachmentPaths(content, sources),
      ...alsoReferenced.map(relativeAttachmentPath),
    };
    final out = <String>[];
    final seen = <String>{};
    for (final note in sources) {
      for (final path in note.attachmentPaths) {
        final rel = relativeAttachmentPath(path);
        if (referenced.contains(rel)) continue;
        if (seen.add(rel)) out.add(rel);
      }
    }
    return out;
  }

  /// Union of the sources' tags, first occurrence wins the order.
  static List<String> unionTags(Iterable<Note> sources) {
    final seen = <String>{};
    return [
      for (final note in sources)
        for (final tag in note.tags)
          if (seen.add(tag)) tag,
    ];
  }

  /// Builds a fresh note ready for `AppProvider.addNote`.
  Note buildNewNote({
    required String title,
    required String content,
    required List<String> tags,
    required List<String> attachmentPaths,
    String? id,
  }) {
    final now = DateTime.now();
    return Note(
      id: id ?? const Uuid().v4(),
      title: title.trim().isEmpty ? 'Untitled' : title.trim(),
      content: content,
      type: NoteType.note,
      createdAt: now,
      updatedAt: now,
      tags: tags,
      attachmentPaths: attachmentPaths,
    );
  }

  /// Replaces [target]'s title and content, keeping everything else and
  /// adding [attachmentPaths] it did not already have.
  Note buildReplacement(
    Note target, {
    required String title,
    required String content,
    required List<String> tags,
    required List<String> attachmentPaths,
  }) {
    final existing = target.attachmentPaths
        .map(relativeAttachmentPath)
        .toSet();
    final merged = [
      ...target.attachmentPaths,
      for (final path in attachmentPaths)
        if (!existing.contains(relativeAttachmentPath(path))) path,
    ];
    return target.copyWith(
      title: title.trim().isEmpty ? target.title : title.trim(),
      content: content,
      tags: tags,
      attachmentPaths: merged,
      updatedAt: DateTime.now(),
    );
  }

  /// Fetched remote images and `synapsetemp://` images are stored under a
  /// `<noteId>_<sha256(url)>` file name and resolved by scanning for the
  /// *current* note's prefix. Copying content between notes therefore loses
  /// them unless the file is duplicated under the new id, which is what this
  /// does. Returns the relative paths of the files it created.
  Future<List<String>> copyNoteScopedImages({
    required String content,
    required Iterable<String> sourceNoteIds,
    required String targetNoteId,
  }) async {
    final targets = imageTargets(content).where(_isNoteScoped).toList();
    if (targets.isEmpty) return const [];

    final Directory dir;
    try {
      dir = await _storageDirectory();
    } catch (e) {
      LoggerService.error('Merge: cannot open private storage: $e', error: e);
      return const [];
    }
    if (!await dir.exists()) return const [];

    final files = <String>[];
    await for (final entity in dir.list()) {
      if (entity is File) files.add(p.basename(entity.path));
    }

    final created = <String>[];
    for (final url in targets) {
      final hash = sha256.convert(utf8.encode(url)).toString();
      final targetPrefix = '${targetNoteId}_$hash';
      if (files.any((f) => f.startsWith(targetPrefix))) continue;

      String? sourceName;
      for (final sourceId in sourceNoteIds) {
        final prefix = '${sourceId}_$hash';
        sourceName = files.cast<String?>().firstWhere(
          (f) => f!.startsWith(prefix),
          orElse: () => null,
        );
        if (sourceName != null) break;
      }
      if (sourceName == null) continue;

      final ext = p.extension(sourceName);
      final targetName = '$targetPrefix$ext';
      try {
        await File(
          p.join(dir.path, sourceName),
        ).copy(p.join(dir.path, targetName));
        files.add(targetName);
        created.add('attachments/$targetName');
      } catch (e) {
        LoggerService.error(
          'Merge: failed to copy $sourceName to $targetName: $e',
          error: e,
        );
      }
    }
    if (created.isNotEmpty) RemoteImageStorage.invalidate(targetNoteId);
    return created;
  }

  /// Remote images that [copyNoteScopedImages] could not find under any
  /// source id (the source never fetched them) are fetched for the merged
  /// note instead, exactly as the "Fetch remote images" menu action would.
  /// Best effort: a failed download leaves the URL in the content, where it
  /// still renders from the network. Returns the relative paths created.
  Future<List<String>> fetchMissingRemoteImages({
    required String content,
    required String targetNoteId,
  }) async {
    final urls = imageTargets(content).where(_isHttpUrl).toList();
    if (urls.isEmpty) return const [];
    try {
      final created = await _remoteImageFetcher(
        noteId: targetNoteId,
        imageUrls: urls,
      );
      if (created.isNotEmpty) RemoteImageStorage.invalidate(targetNoteId);
      return created;
    } catch (e) {
      LoggerService.error('Merge: remote image fetch failed: $e', error: e);
      return const [];
    }
  }

  static bool _isHttpUrl(String target) {
    final lower = target.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  static bool _isNoteScoped(String target) {
    final lower = target.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        SynapseTempUtils.isSynapseTempUri(target);
  }

  static final RegExp _attachmentLink = RegExp(
    r'synapseresource://attachment/([A-Za-z0-9\-]+)',
  );

  /// Ids of `synapseresource://attachment/<id>` links in [content].
  static Set<String> linkedAttachmentIds(String content) =>
      _attachmentLink.allMatches(content).map((m) => m.group(1)!).toSet();

  /// File paths of source attachment rows that [content] links to by id.
  /// Such a link may use any label, so the file name alone is not enough to
  /// know the merged note needs the file.
  Future<List<String>> linkedSourceAttachmentPaths(
    String content,
    Iterable<String> sourceNoteIds,
  ) async {
    final ids = linkedAttachmentIds(content);
    if (ids.isEmpty) return const [];
    final out = <String>[];
    for (final sourceId in sourceNoteIds) {
      for (final row in await _db.getAttachmentsForNote(sourceId)) {
        if (ids.contains(row.id)) out.add(relativeAttachmentPath(row.filePath));
      }
    }
    return out;
  }

  /// Re-points `synapseresource://attachment/<id>` links that still name a
  /// *source* note's attachment row at the merged note's own row for the same
  /// file, carrying the row's metadata (PDF bookmarks, AI-context choice)
  /// across. Attachment rows cascade-delete with their note, so without this
  /// deleting a source after the merge would break the merged note's links.
  ///
  /// Returns the rewritten content (identical to [content] when there was
  /// nothing to do). The caller persists it.
  Future<String> adoptSourceAttachments({
    required String mergedNoteId,
    required Iterable<String> sourceNoteIds,
    required String content,
  }) async {
    final ids = linkedAttachmentIds(content);
    if (ids.isEmpty) return content;

    final ownRows = <String, Attachment>{
      for (final row in await _db.getAttachmentsForNote(mergedNoteId))
        relativeAttachmentPath(row.filePath): row,
    };
    if (ownRows.isEmpty) return content;

    var out = content;
    // Two sources may both carry a file of the same name; the first one
    // wins the metadata so a later source cannot overwrite it.
    final adopted = <String>{};
    for (final sourceId in sourceNoteIds) {
      if (sourceId == mergedNoteId) continue;
      for (final row in await _db.getAttachmentsForNote(sourceId)) {
        if (!ids.contains(row.id)) continue;
        final own = ownRows[relativeAttachmentPath(row.filePath)];
        if (own == null || own.id == row.id) continue;
        out = out.replaceAll(
          'synapseresource://attachment/${row.id}',
          'synapseresource://attachment/${own.id}',
        );
        if (!adopted.add(own.id)) continue;
        if (row.metadata != null && own.metadata == null) {
          await _db.updateAttachmentMetadata(own.id, row.metadata);
        }
        if (row.includeInAIContext != own.includeInAIContext) {
          await _db.updateAttachmentAIContext(
            mergedNoteId,
            own.filePath,
            row.includeInAIContext,
          );
        }
      }
    }
    return out;
  }

  /// A `references` relationship from the merged note to each source, so the
  /// merged note's linked-notes section answers "where did this come from?".
  Future<void> linkToSources(
    String mergedNoteId,
    Iterable<String> sourceNoteIds,
  ) async {
    for (final sourceId in sourceNoteIds) {
      if (sourceId == mergedNoteId) continue;
      final exists = await _db.relationshipExists(
        mergedNoteId,
        sourceId,
        RelationshipType.references,
      );
      if (exists) continue;
      await _db.insertRelationship(
        Relationship(
          id: const Uuid().v4(),
          fromNoteId: mergedNoteId,
          toNoteId: sourceId,
          type: RelationshipType.references,
          createdAt: DateTime.now(),
        ),
      );
    }
  }
}
