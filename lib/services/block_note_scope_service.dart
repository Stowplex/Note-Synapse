import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/note.dart';
import '../utils/file_utils.dart';
import 'conversation_attachment_service.dart';
import 'data_change_notifier.dart';
import 'database_service.dart';
import 'logger_service.dart';
import 'note_modification_service.dart';
import 'service_locator.dart';
import 'tag_workflow_service.dart';

/// A transient, in-memory "note" that stands for a range of blocks inside a
/// real (parent) note.
///
/// Created when the user runs a Note Action App on a block selection. The app
/// sees an ordinary note object whose `content` is just the selected block
/// text; anything it writes through the bridge is spliced back over
/// `[spanStart, spanEnd)` of the parent note's content.
///
/// Scopes are never persisted. They exist only for as long as the plugin
/// screen is on top, so a virtual id can never leak into note lists, search,
/// tags, recovery or sync.
class BlockNoteScope {
  BlockNoteScope({
    required this.tempNoteId,
    required this.parentNoteId,
    required this.spanStart,
    required this.spanEnd,
    required this.text,
    required this.anchorBefore,
    required this.anchorAfter,
    required this.parentTitle,
    required this.parentTags,
    required this.parentAttachmentPaths,
    required this.parentCreatedAt,
    required this.parentUpdatedAt,
    required this.parentPinned,
    required this.parentIsArchived,
  });

  /// Generated id handed to the plugin. Not a database key.
  final String tempNoteId;

  /// The real note this block belongs to.
  final String parentNoteId;

  /// Character range of the block(s) within the parent's content. Mutable:
  /// every successful write moves [spanEnd] and may move [spanStart] if the
  /// span had to be re-located.
  int spanStart;
  int spanEnd;

  /// The block text as it currently stands in the parent note. Kept in sync
  /// after each write so the next write can verify/re-locate its span.
  String text;

  /// Text immediately before/after the span, used to validate a zero-width
  /// span (an emptied block) where [text] carries no positional signal.
  String anchorBefore;
  String anchorAfter;

  final String parentTitle;
  final List<String> parentTags;
  final List<String> parentAttachmentPaths;
  final DateTime parentCreatedAt;
  final DateTime parentUpdatedAt;
  final bool parentPinned;
  final bool parentIsArchived;
}

/// Outcome of a write against a [BlockNoteScope].
class BlockWriteResult {
  const BlockWriteResult.success() : ok = true, error = null;
  const BlockWriteResult.failure(this.error) : ok = false;

  final bool ok;
  final String? error;
}

/// Tracks the [BlockNoteScope]s that are currently open and applies plugin
/// writes back onto the parent note.
class BlockNoteScopeService {
  BlockNoteScopeService(this._db, {DataChangeNotifier? changeNotifier})
    : _changeNotifier = changeNotifier ?? DataChangeNotifier.shared();

  final DatabaseService _db;
  final DataChangeNotifier _changeNotifier;
  final Uuid _uuid = const Uuid();

  final Map<String, BlockNoteScope> _scopes = {};

  /// Serializes writes per parent note id (see [writeBack]).
  final Map<String, Future<void>> _writeQueue = {};

  /// Relative attachment paths promoted by block writes, per parent note id.
  ///
  /// Only these may be pruned when a later write stops referencing them.
  /// Ownership must never be inferred from the filename: user-driven flows
  /// (e.g. RemoteImageStorage for fetched images) produce the identical
  /// `<noteId>_<sha256>` shape, and pruning those would delete the user's own
  /// attachment rows.
  ///
  /// Held on the service rather than the scope because the screen opens a FRESH
  /// scope every time the user runs an app: per-scope tracking meant re-running
  /// a renderer never reclaimed the previous render, which is the whole point of
  /// the prune.
  final Map<String, Set<String>> _promotedByParent = {};

  /// Opens a scope over `[spanStart, spanEnd)` of [parent]'s content.
  ///
  /// [text] is the block text as sliced from the parent content by the caller;
  /// it becomes the transient note's `content`.
  BlockNoteScope open({
    required Note parent,
    required int spanStart,
    required int spanEnd,
    required String text,
  }) {
    final scope = BlockNoteScope(
      tempNoteId: _uuid.v4(),
      parentNoteId: parent.id,
      spanStart: spanStart,
      spanEnd: spanEnd,
      text: text,
      anchorBefore: _anchorBefore(parent.content, spanStart),
      anchorAfter: _anchorAfter(parent.content, spanEnd),
      parentTitle: parent.title,
      parentTags: List<String>.unmodifiable(parent.tags),
      parentAttachmentPaths: List<String>.unmodifiable(parent.attachmentPaths),
      parentCreatedAt: parent.createdAt,
      parentUpdatedAt: parent.updatedAt,
      parentPinned: parent.pinned,
      parentIsArchived: parent.isArchived,
    );
    _scopes[scope.tempNoteId] = scope;
    LoggerService.debug(
      '[BlockNoteScope] Opened ${scope.tempNoteId} over '
      '${parent.id}[$spanStart, $spanEnd)',
    );
    return scope;
  }

  /// Returns the scope for [noteId], or null when [noteId] is an ordinary note.
  BlockNoteScope? lookup(String noteId) => _scopes[noteId];

  /// True when any scope is open. Used by tests to assert that scopes are
  /// released; production code looks up specific ids via [lookup].
  @visibleForTesting
  bool get hasOpenScopes => _scopes.isNotEmpty;

  void close(String tempNoteId) {
    if (_scopes.remove(tempNoteId) != null) {
      LoggerService.debug('[BlockNoteScope] Closed $tempNoteId');
    }
  }

  /// Synthesizes the note object handed to the plugin.
  ///
  /// Inherits the parent's attachment paths so `Synapse.readAttachment` and
  /// `chatAI` attachment resolution keep working unchanged — this is what makes
  /// the transient note "reference the parent" for attachment purposes.
  Note asNote(BlockNoteScope scope) {
    return Note(
      id: scope.tempNoteId,
      title: scope.parentTitle,
      content: scope.text,
      type: NoteType.note,
      createdAt: scope.parentCreatedAt,
      updatedAt: scope.parentUpdatedAt,
      tags: List<String>.from(scope.parentTags),
      attachmentPaths: List<String>.from(scope.parentAttachmentPaths),
      pinned: scope.parentPinned,
      isArchived: scope.parentIsArchived,
    );
  }

  /// Splices [newText] over the scope's span in the parent note and saves.
  ///
  /// Pass an empty [newText] to delete the block.
  Future<BlockWriteResult> writeBack(String tempNoteId, String newText) =>
      _serialized(tempNoteId, (_) => newText);

  /// Applies an `append` / `prepend` / `replace` action to the block's CURRENT
  /// text and writes the result back.
  ///
  /// Prefer this over computing the new text yourself and calling [writeBack]:
  /// the action is applied to `scope.text` read INSIDE the write lock. Deriving
  /// it beforehand reintroduces the lost update the lock exists to prevent —
  /// two overlapping appends would both start from the same pre-write text, and
  /// the second would silently drop the first while both reported success.
  Future<BlockWriteResult> applyContentAction(
    String tempNoteId,
    String action,
    String text,
  ) => _serialized(
    tempNoteId,
    (scope) => NoteModificationService.applyWholeContentAction(
      scope.text,
      action,
      text,
    ),
  );

  /// Runs [computeNewText] and the resulting write under a per-parent-note lock.
  ///
  /// Serialized because the body is a read-modify-write with awaits in the
  /// middle: two overlapping plugin calls would otherwise both read the same
  /// content and the second would discard the first.
  Future<BlockWriteResult> _serialized(
    String tempNoteId,
    String Function(BlockNoteScope scope) computeNewText,
  ) async {
    final scope = _scopes[tempNoteId];
    if (scope == null) {
      return const BlockWriteResult.failure('Block scope is no longer open.');
    }

    final previous = _writeQueue[scope.parentNoteId];
    final completer = Completer<void>();
    _writeQueue[scope.parentNoteId] = completer.future;
    try {
      if (previous != null) await previous;
      return await _writeBackLocked(tempNoteId, computeNewText);
    } finally {
      completer.complete();
      if (_writeQueue[scope.parentNoteId] == completer.future) {
        _writeQueue.remove(scope.parentNoteId);
      }
    }
  }

  Future<BlockWriteResult> _writeBackLocked(
    String tempNoteId,
    String Function(BlockNoteScope scope) computeNewText,
  ) async {
    // Re-read: the scope may have been closed while queued behind another write.
    final scope = _scopes[tempNoteId];
    if (scope == null) {
      return const BlockWriteResult.failure('Block scope is no longer open.');
    }

    // Computed here, under the lock, so an append/prepend sees the text this
    // block actually holds right now rather than a pre-queue snapshot.
    final newText = computeNewText(scope);

    final parent = await _db.getNote(scope.parentNoteId);
    if (parent == null) {
      return BlockWriteResult.failure(
        'Parent note ${scope.parentNoteId} no longer exists.',
      );
    }

    // Same policy NoteModificationService._enforceImmutableBinding applies to
    // note-level content writes: a block scope must not be a way around it.
    if (await getIt<TagWorkflowService>().hasImmutableBinding(parent.tags)) {
      return const BlockWriteResult.failure(
        'Cannot modify content: this note has a tag with an immutable '
        'workflow binding.',
      );
    }

    final content = parent.content;
    final range = _resolveSpan(content, scope);
    if (range == null) {
      return const BlockWriteResult.failure(
        'The selected block could no longer be found in the note; '
        'it may have been edited or deleted. No changes were made.',
      );
    }

    // Promote any synapsetemp:/// files the plugin embedded in the text so the
    // images survive the temp cache being cleared. This names them
    // `attachments/<parentId>_<sha256><ext>`, which is the form the note
    // renderer resolves by hash, and leaves the URI in the text.
    //
    // allowLocalFilePaths is false because `newText` is PLUGIN-authored: the
    // local-path pass would otherwise let a plugin attach any file the app can
    // read (and then read it back, or have it uploaded as AI context).
    final processed =
        await ConversationAttachmentService.processContentForAttachments(
          content: newText,
          noteId: scope.parentNoteId,
          allowLocalFilePaths: false,
        );

    final replacement = processed.content;

    // Refuse to commit a block that references a temp file we could not
    // promote and that has no already-promoted copy: it would render now and
    // break for good once the OS purges the cache.
    final dangling = await _unresolvableTempUris(
      replacement,
      scope.parentNoteId,
      processed.attachmentPaths,
      content,
    );
    if (dangling.isNotEmpty) {
      return BlockWriteResult.failure(
        'This write adds a temporary file reference that no longer exists '
        '(${dangling.first}), so it would show now and break permanently once '
        'the cache is cleared. Nothing was written - regenerate the file and '
        'try again.',
      );
    }

    final updatedContent =
        content.substring(0, range.start) +
        replacement +
        content.substring(range.end);

    // Mirrors the append path in add_note_dialog.dart: new attachment paths are
    // merged onto the note and DatabaseService.updateNote inserts the rows.
    // Compared on relative form, since the parent's paths come back absolute.
    final existingRelative = parent.attachmentPaths
        .map(_relativeAttachmentPath)
        .toSet();
    final mergedAttachments = <String>[
      ...parent.attachmentPaths,
      ...processed.attachmentPaths.where((p) => !existingRelative.contains(p)),
    ];

    // Drop earlier renders that the note no longer references, so re-rendering
    // does not pile up unused attachments that still get uploaded as AI
    // context.
    //
    // Strictly limited to paths this service promoted for this parent note.
    // Ownership must not be inferred from the `<noteId>_<sha256>` filename
    // shape: user flows such as RemoteImageStorage produce the same shape but
    // reference the file by URL or relative path rather than a synapsetemp URI,
    // so a pattern-based prune would delete the user's own attachment rows.
    final promoted = _promotedByParent.putIfAbsent(
      scope.parentNoteId,
      () => <String>{},
    )..addAll(processed.attachmentPaths);
    final referencedHashes = _tempUriHashes(updatedContent);
    mergedAttachments.removeWhere((path) {
      final relative = _relativeAttachmentPath(path);
      if (!promoted.contains(relative)) return false;
      // "Referenced" covers BOTH forms the file can be linked by: its original
      // synapsetemp URI (what this service leaves in the text) and the promoted
      // relative path or bare filename (what other flows rewrite links to).
      // Counting only the URI would delete the attachment row of a file the
      // content still points at.
      if (updatedContent.contains(relative) ||
          updatedContent.contains(p.basename(relative))) {
        return false;
      }
      final hash = _promotedAttachmentHash(relative, scope.parentNoteId);
      return hash != null && !referencedHashes.contains(hash);
    });

    await _db.updateNote(
      parent.copyWith(
        content: updatedContent,
        attachmentPaths: mergedAttachments,
        updatedAt: DateTime.now(),
      ),
    );

    // Advance the span so a second write in the same session targets the text
    // this write just produced rather than the original block.
    scope.spanStart = range.start;
    scope.spanEnd = range.start + replacement.length;
    scope.text = replacement;
    scope.anchorBefore = _anchorBefore(updatedContent, scope.spanStart);
    scope.anchorAfter = _anchorAfter(updatedContent, scope.spanEnd);

    _changeNotifier.publish(DataChangeEvent(noteIds: {scope.parentNoteId}));

    LoggerService.debug(
      '[BlockNoteScope] Wrote ${replacement.length} chars back to '
      '${scope.parentNoteId}[${range.start}, ${scope.spanEnd})',
    );
    return const BlockWriteResult.success();
  }

  /// How much surrounding text is remembered to validate a zero-width span.
  static const int _anchorLength = 40;

  /// True when the text immediately surrounding the span `[start, end)` still
  /// matches the anchors recorded for this scope.
  ///
  /// Essential for a zero-width span (an emptied block), where the block text
  /// carries no positional signal at all, and a useful disambiguator for a
  /// normal span when the note contains several identical blocks.
  bool _anchorsMatch(String content, int start, int end, BlockNoteScope scope) {
    final before = scope.anchorBefore;
    final after = scope.anchorAfter;
    if (start - before.length < 0) return false;
    if (content.substring(start - before.length, start) != before) return false;
    final afterEnd = end + after.length;
    if (afterEnd > content.length) return false;
    return content.substring(end, afterEnd) == after;
  }

  /// True when at least one NON-EMPTY anchor still matches around
  /// `[start, end)`.
  ///
  /// Either side alone is enough: an edit to one neighbour changes that anchor
  /// while the block itself has not moved, so requiring both would reject good
  /// writes. An empty anchor (block at the very start/end of the note) matches
  /// at every offset and therefore never counts as evidence.
  bool _hasAnchorSupport(
    String content,
    int start,
    int end,
    BlockNoteScope scope,
  ) {
    final before = scope.anchorBefore;
    if (before.isNotEmpty &&
        start - before.length >= 0 &&
        content.substring(start - before.length, start) == before) {
      return true;
    }
    final after = scope.anchorAfter;
    if (after.isNotEmpty &&
        end + after.length <= content.length &&
        content.substring(end, end + after.length) == after) {
      return true;
    }
    return false;
  }

  static String _anchorBefore(String content, int at) =>
      content.substring(math.max(0, at - _anchorLength), at);

  static String _anchorAfter(String content, int at) =>
      content.substring(at, math.min(content.length, at + _anchorLength));

  static final RegExp _tempUriPattern = RegExp(r'synapsetemp://[^\s)\]]+');

  /// sha256 of every `synapsetemp:///` URI in [content], matching the naming
  /// scheme used by [ConversationAttachmentService.processContentForAttachments].
  static Set<String> _tempUriHashes(String content) => _tempUriPattern
      .allMatches(content)
      .map((m) => sha256.convert(utf8.encode(m.group(0)!)).toString())
      .toSet();

  /// The hash embedded in a promoted attachment filename
  /// (`attachments/<noteId>_<sha256>.<ext>`), or null when [path] is not one of
  /// this promoter's files.
  static String? _promotedAttachmentHash(String path, String noteId) {
    final base = p.basenameWithoutExtension(path);
    final prefix = '${noteId}_';
    if (!base.startsWith(prefix)) return null;
    final hash = base.substring(prefix.length);
    if (hash.length != 64 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      return null;
    }
    return hash;
  }

  /// The extension a promoted copy of [uri] would carry.
  ///
  /// Must mirror [ConversationAttachmentService.processContentForAttachments]
  /// exactly (sanitized to `[a-zA-Z0-9.]`, lowercased, leading dot forced), or
  /// this probe looks for a filename the promoter never wrote.
  static String _promotedExtension(String uri) {
    final raw = p.extension(Uri.parse(uri).path);
    final sanitized = raw
        .replaceAll(RegExp(r'[^a-zA-Z0-9.]'), '')
        .toLowerCase();
    if (sanitized.isEmpty) return '.';
    return sanitized.startsWith('.') ? sanitized : '.$sanitized';
  }

  static String _relativeAttachmentPath(String path) =>
      path.startsWith('attachments/')
      ? path
      : 'attachments/${p.basename(path)}';

  /// `synapsetemp:///` URIs that this write would NEWLY introduce and that
  /// neither were promoted by it nor already have a promoted copy on disk. Such
  /// a URI renders only until the OS purges its cache directory, so committing
  /// one is a silent data-loss bug.
  ///
  /// [preExisting] is the note's current content: a URI already in the note (for
  /// example text the user pasted from another note, promoted under that other
  /// note's id) is not this write's doing. Refusing those would make such a
  /// block permanently uneditable by any plugin.
  Future<List<String>> _unresolvableTempUris(
    String content,
    String noteId,
    List<String> promoted,
    String preExisting,
  ) async {
    final promotedHashes = promoted
        .map((path) => _promotedAttachmentHash(path, noteId))
        .whereType<String>()
        .toSet();
    final alreadyInNote = _tempUriPattern
        .allMatches(preExisting)
        .map((m) => m.group(0)!)
        .toSet();

    final unresolvable = <String>[];
    Directory? attachmentsDir;
    for (final match in _tempUriPattern.allMatches(content)) {
      final uri = match.group(0)!;
      if (alreadyInNote.contains(uri)) continue;
      final hash = sha256.convert(utf8.encode(uri)).toString();
      if (promotedHashes.contains(hash)) continue;

      // Not promoted just now: accept it only if an earlier write already
      // promoted the same URI (re-inserting an unchanged image).
      //
      // Probes the one filename it could be rather than listing the directory:
      // attachments/ is flat and shared by every note, so a listSync() here is
      // a stat storm on the UI isolate once per URI per write.
      var existing = false;
      try {
        attachmentsDir ??= await FileUtils.getPrivateStorageDirectory();
        existing = await File(
          p.join(
            attachmentsDir.path,
            '${noteId}_$hash${_promotedExtension(uri)}',
          ),
        ).exists();
      } catch (e) {
        // Cannot verify, so stay conservative and treat it as unresolvable
        // rather than committing a link that may already be dead.
        LoggerService.warning(
          '[BlockNoteScope] Could not check for a promoted copy of $uri: $e',
        );
      }
      if (!existing) unresolvable.add(uri);
    }
    return unresolvable;
  }

  /// Locates the scope's span in [content].
  ///
  /// The stored offsets can go stale between writes (autosave, an agent, a
  /// concurrent plugin, or our own previous write), so verify them and fall
  /// back to searching for the known block text. Returns null when the block
  /// text is gone entirely — better to refuse the write than to splice over
  /// an unrelated part of the note.
  _Span? _resolveSpan(String content, BlockNoteScope scope) {
    final start = scope.spanStart;
    final end = scope.spanEnd;

    // Empty span (the block was deleted, so this is an insertion point) must be
    // checked FIRST and against its surrounding anchors: `substring(i, i)` is
    // '' for every in-bounds i, so comparing the text would accept any offset
    // and happily splice into the middle of unrelated content.
    if (scope.text.isEmpty) {
      // Anchors are the only signal here, so when BOTH are empty (the block was
      // the note's entire content) they match anywhere — require the content to
      // still be empty too, or an out-of-band rewrite would be spliced into.
      final anchorless =
          scope.anchorBefore.isEmpty && scope.anchorAfter.isEmpty;
      if (start >= 0 &&
          start <= content.length &&
          _anchorsMatch(content, start, start, scope) &&
          (!anchorless || content.isEmpty)) {
        return _Span(start, start);
      }
      LoggerService.warning(
        '[BlockNoteScope] Stale empty span for ${scope.tempNoteId}; '
        'refusing write',
      );
      return null;
    }

    final matches = <int>[];
    for (var i = content.indexOf(scope.text); i >= 0;) {
      matches.add(i);
      i = content.indexOf(scope.text, i + 1);
    }

    if (matches.isEmpty) {
      LoggerService.warning(
        '[BlockNoteScope] Block text for ${scope.tempNoteId} not found in '
        'parent ${scope.parentNoteId}; refusing write',
      );
      return null;
    }

    // Anchors PICK among candidates rather than merely vetoing the stored
    // offsets: with duplicated blocks (repeated list rows, several `---`) the
    // text alone cannot say which copy is ours, but the surrounding text can.
    //
    // Only anchor evidence that is actually informative counts. An EMPTY anchor
    // matches at every offset, so a block at the very start or end of a note has
    // just one informative side — treating a one-sided match as conclusive let a
    // freshly inserted duplicate win over the still-correct stored span.
    final anchored = matches
        .where(
          (i) => _hasAnchorSupport(content, i, i + scope.text.length, scope),
        )
        .toList();
    final storedValid =
        start >= 0 &&
        end >= start &&
        end <= content.length &&
        content.substring(start, end) == scope.text;

    // Stored offsets still slice our text AND the surroundings agree: certain.
    if (storedValid && anchored.contains(start)) {
      return _Span(start, end);
    }

    // The block moved and exactly one candidate's surroundings match ours.
    if (!storedValid && anchored.length == 1) {
      final at = anchored.first;
      LoggerService.debug(
        '[BlockNoteScope] Re-located span for ${scope.tempNoteId} by anchor: '
        '$start -> $at',
      );
      return _Span(at, at + scope.text.length);
    }

    // Conflicting evidence: our offsets still slice the text, but some OTHER
    // copy is the one the surroundings point at. Cannot tell whether the block
    // moved or was duplicated, so refuse rather than rewrite the wrong one.
    if (storedValid && anchored.isNotEmpty) {
      LoggerService.warning(
        '[BlockNoteScope] Ambiguous span for ${scope.tempNoteId}: stored '
        'offsets and anchors disagree; refusing write',
      );
      return null;
    }

    // No informative anchor evidence at all. A single occurrence is
    // unambiguous; more than one cannot be told apart, and trusting the stored
    // offsets there would make the outcome hinge on coincidence.
    if (matches.length > 1) {
      LoggerService.warning(
        '[BlockNoteScope] Block text for ${scope.tempNoteId} is ambiguous '
        '(${matches.length} matches) after an external edit; refusing write',
      );
      return null;
    }

    if (storedValid) return _Span(start, end);

    final found = matches.first;

    LoggerService.debug(
      '[BlockNoteScope] Re-located span for ${scope.tempNoteId}: '
      '$start -> $found',
    );
    return _Span(found, found + scope.text.length);
  }
}

class _Span {
  const _Span(this.start, this.end);
  final int start;
  final int end;
}
