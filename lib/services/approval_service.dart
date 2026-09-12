import 'dart:async';
import 'dart:convert';

import 'logger_service.dart';
import 'sql_query_service.dart';
import 'database_service.dart';
import 'service_locator.dart';

/// Type of approval being requested.
enum ApprovalType { sqlWrite, noteModification, noteDeletion, sessionAccess }

/// Encapsulates details of an approval request.
class ApprovalRequest {
  /// Keys the plugin bridge may add to a note-modification payload so the
  /// approval dialog can show WHICH scope a write applies to. Without this a
  /// change to one selected block and a rewrite of the whole note render
  /// identically, letting a plugin launched on a block get a note-wide change
  /// approved by looking exactly like the block edit the user asked for.
  /// Ignored when formatting the modification's fields.
  static const String scopeBlockKey = '__scopeBlock';
  static const String scopeWholeNoteKey = '__scopeWholeNote';

  ApprovalRequest({
    required this.type,
    required this.title,
    required this.description,
    required this.details,
    this.source,
    this.warningMessage,
    this.sessionApprovalLabel,
  });

  /// The type of approval (SQL write or note modification).
  final ApprovalType type;

  /// Title for the approval dialog.
  final String title;

  /// Description of what's being requested.
  final String description;

  /// The details to display (SQL query string or modification map).
  final dynamic details;

  /// User-visible identity of the operation requesting access.
  ///
  /// Kept separately from [description] so the dialog can build the sentence
  /// in the active locale instead of trying to translate preformatted text.
  final String? source;

  /// Optional warning message to display.
  final String? warningMessage;

  /// Label for the "allow for session" checkbox.
  final String? sessionApprovalLabel;

  /// Format details as a JSON string for display.
  String get formattedDetails {
    if (details is String) {
      return details;
    }
    try {
      return const JsonEncoder.withIndent('  ').convert(details);
    } catch (_) {
      return details.toString();
    }
  }

  /// Create a SQL write approval request.
  factory ApprovalRequest.sqlWrite({
    required String sql,
    required SqlQueryType queryType,
    required String queryTypeDescription,
    String? source,
  }) {
    return ApprovalRequest(
      type: ApprovalType.sqlWrite,
      title: 'Allow SQL Write Operation?',
      description: source != null
          ? '$source wants to execute a $queryTypeDescription operation:'
          : 'The operation wants to execute a $queryTypeDescription query:',
      details: sql,
      source: source,
      warningMessage: 'This query will modify the database.',
      sessionApprovalLabel: 'Allow for this session',
    );
  }

  /// Create a note modification approval request.
  factory ApprovalRequest.noteModification({
    String? noteId,
    Map<String, dynamic>? modification,
    List<Map<String, dynamic>>? modifications,
    String? source,
    String? noteTitle,
    String? noteSnippet,
    List<Map<String, String>>? noteDetails,
  }) {
    final isBatch = modifications != null;
    final batchMods = modifications ?? const <Map<String, dynamic>>[];
    return ApprovalRequest(
      type: ApprovalType.noteModification,
      title: isBatch
          ? 'Allow Batched Note Modification?'
          : 'Allow Note Modification?',
      description: source != null
          ? '$source wants to modify ${isBatch ? '${batchMods.length} notes' : 'note'}:'
          : 'The operation wants to modify ${isBatch ? '${batchMods.length} notes' : 'note'}:',
      details: isBatch
          ? {
              'noteIds': batchMods.map((m) => m['note_id']).toList(),
              'noteDetails': noteDetails,
              'modification': {
                'isBatch': true,
                'count': batchMods.length,
                'updates': batchMods.take(5).map((entry) {
                  final currentNoteId = entry['note_id']?.toString() ?? '';
                  final noteMeta = noteDetails?.firstWhere(
                    (detail) => detail['id'] == currentNoteId,
                    orElse: () => const <String, String>{},
                  );
                  return {
                    'id': currentNoteId,
                    if (noteMeta != null && noteMeta.isNotEmpty)
                      'title': noteMeta['title'],
                    'changes': entry['modification'],
                  };
                }).toList(),
              },
            }
          : {
              'noteId': noteId,
              'modification': modification,
              if (noteTitle != null) 'noteTitle': noteTitle,
              if (noteSnippet != null) 'noteSnippet': noteSnippet,
            },
      source: source,
      warningMessage: null,
      sessionApprovalLabel: 'Allow for this session',
    );
  }

  /// Create a note deletion approval request.
  factory ApprovalRequest.noteDeletion({
    required List<String> noteIds,
    String? source,
    List<Map<String, String>>? noteDetails,
  }) {
    final isBatch = noteIds.length > 1;
    final details = <String, dynamic>{
      'noteIds': noteIds,
      'count': noteIds.length,
    };
    if (noteDetails != null) {
      details['noteDetails'] = noteDetails;
    }

    return ApprovalRequest(
      type: ApprovalType.noteDeletion,
      title: isBatch ? 'Allow Note Deletion?' : 'Allow Note Deletion?',
      description: source != null
          ? '$source wants to delete ${isBatch ? '${noteIds.length} notes' : 'a note'}:'
          : 'The operation wants to delete ${isBatch ? '${noteIds.length} notes' : 'a note'}:',
      details: details,
      source: source,
      warningMessage: 'This action cannot be undone.',
      sessionApprovalLabel: 'Allow for this session',
    );
  }

  /// Create a request to let an app use a saved web-login session for [domain].
  factory ApprovalRequest.sessionAccess({
    required String domain,
    String? source,
  }) {
    return ApprovalRequest(
      type: ApprovalType.sessionAccess,
      title: 'Allow use of your $domain login?',
      description: source != null
          ? '$source wants to use your saved login for:'
          : 'This app wants to use your saved login for:',
      details: domain,
      source: source,
      warningMessage:
          'The app will be able to make requests as you on $domain and any of '
          'its subdomains, and to read that login’s cookies. Access lasts '
          'until you revoke it in Web Logins settings, delete the saved '
          '$domain login, or uninstall the app.',
    );
  }
}

/// Result of an approval request.
class ApprovalResult {
  ApprovalResult({required this.approved, this.approvedForSession = false});

  /// Whether the request was approved.
  final bool approved;

  /// Whether the user chose to approve for the entire session.
  final bool approvedForSession;
}

/// Centralized service for managing approval dialogs and session state.
///
/// UI screens register their approval callback via [onApprovalRequest].
/// Native tools and runtime bridges use [requestSqlWriteApproval] and
/// [requestNoteModificationApproval] to request approval.
class ApprovalService {
  ApprovalService._();

  /// Static callback for UI to handle approval requests.
  ///
  /// UI screens should set this to show an approval dialog using
  /// [ApprovalDialog.show] with a stable NavigatorState.
  static Future<ApprovalResult> Function(ApprovalRequest)? onApprovalRequest;

  /// Root-level fallback callback for approval requests.
  ///
  /// This stays available even when route-specific widgets are disposed, so
  /// background workflows can still surface approval dialogs.
  static Future<ApprovalResult> Function(ApprovalRequest)?
  fallbackApprovalRequest;

  /// Whether note modifications have been approved for this session.
  static bool sessionApprovedNoteModifications = false;

  /// Whether note deletions have been approved for this session.
  static bool sessionApprovedNoteDeletions = false;

  /// Whether SQL writes have been approved for this session.
  static bool sessionApprovedSqlWrites = false;

  /// Reset all session approvals.
  static void resetSession() {
    sessionApprovedNoteModifications = false;
    sessionApprovedNoteDeletions = false;
    sessionApprovedSqlWrites = false;
    LoggerService.debug('[ApprovalService] Session approvals reset');
  }

  static Future<ApprovalResult?> _dispatchApprovalRequest(
    ApprovalRequest request,
  ) async {
    final primary = onApprovalRequest;
    final fallback = fallbackApprovalRequest;

    if (primary == null && fallback == null) {
      LoggerService.warning(
        '[ApprovalService] No approval callback registered for ${request.type}',
      );
      return null;
    }

    if (primary != null) {
      try {
        return await primary(request);
      } catch (e) {
        LoggerService.warning(
          '[ApprovalService] Primary approval callback unavailable: $e',
        );
      }
    }

    if (fallback != null && !identical(primary, fallback)) {
      try {
        return await fallback(request);
      } catch (e) {
        LoggerService.error(
          '[ApprovalService] Fallback approval callback failed: $e',
        );
      }
    }

    return null;
  }

  /// Request approval for a SQL write operation.
  ///
  /// Returns true if approved, false if denied.
  /// Automatically approves if [sessionApprovedSqlWrites] is true.
  static Future<bool> requestSqlWriteApproval({
    required String sql,
    required SqlQueryType queryType,
    required String queryTypeDescription,
    String? source,
  }) async {
    // Check session approval first
    if (sessionApprovedSqlWrites) {
      LoggerService.debug(
        '[ApprovalService] SQL write auto-approved (session)',
      );
      return true;
    }

    final result = await _dispatchApprovalRequest(
      ApprovalRequest.sqlWrite(
        sql: sql,
        queryType: queryType,
        queryTypeDescription: queryTypeDescription,
        source: source,
      ),
    );
    if (result == null) {
      return false;
    }

    if (result.approved) {
      if (result.approvedForSession) {
        sessionApprovedSqlWrites = true;
        LoggerService.debug(
          '[ApprovalService] SQL writes approved for session',
        );
      }
      return true;
    }
    return false;
  }

  /// Request approval for a note modification.
  ///
  /// Returns true if approved, false if denied.
  /// Automatically approves if [sessionApprovedNoteModifications] is true.
  static Future<bool> requestNoteModificationApproval({
    required String noteId,
    required Map<String, dynamic> modification,
    String? source,
  }) async {
    // Check session approval first
    if (sessionApprovedNoteModifications) {
      LoggerService.debug(
        '[ApprovalService] Note modification auto-approved (session)',
      );
      return true;
    }

    // Fetch note details for better context
    String? title;
    String? snippet;
    try {
      final db = getIt<DatabaseService>();
      final note = await db.getNote(noteId);
      if (note != null) {
        title = note.title;
        final content = note.content;
        snippet = content.length > 200
            ? '${content.substring(0, 200)}...'
            : content;
      }
    } catch (e) {
      LoggerService.warning(
        '[ApprovalService] Failed to fetch note details: $e',
      );
    }

    final result = await _dispatchApprovalRequest(
      ApprovalRequest.noteModification(
        noteId: noteId,
        modification: modification,
        source: source,
        noteTitle: title,
        noteSnippet: snippet,
      ),
    );

    if (result == null) {
      return false;
    }

    if (result.approved) {
      if (result.approvedForSession) {
        sessionApprovedNoteModifications = true;
        LoggerService.debug(
          '[ApprovalService] Note modifications approved for session',
        );
      }
      return true;
    }
    return false;
  }

  /// Request approval for a batched note modification.
  static Future<bool> requestBatchNoteModificationApproval({
    required List<Map<String, dynamic>> modifications,
    String? source,
  }) async {
    if (sessionApprovedNoteModifications) {
      LoggerService.debug(
        '[ApprovalService] Note modification auto-approved (session)',
      );
      return true;
    }

    final noteIds = modifications
        .map((modification) => modification['note_id']?.toString())
        .whereType<String>()
        .toList();

    final noteDetails = <Map<String, String>>[];
    try {
      final db = getIt<DatabaseService>();
      final notes = await db.getNotesByIds(noteIds);
      for (final note in notes) {
        final content = note.content;
        final snippet = content.length > 100
            ? '${content.substring(0, 100)}...'
            : content;
        noteDetails.add({
          'id': note.id,
          'title': note.title,
          'snippet': snippet,
        });
      }
    } catch (e) {
      LoggerService.warning(
        '[ApprovalService] Failed to fetch batch note details: $e',
      );
    }

    final result = await _dispatchApprovalRequest(
      ApprovalRequest.noteModification(
        modifications: modifications,
        source: source,
        noteDetails: noteDetails,
      ),
    );

    if (result == null) {
      return false;
    }

    if (result.approved) {
      if (result.approvedForSession) {
        sessionApprovedNoteModifications = true;
        LoggerService.debug(
          '[ApprovalService] Note modifications approved for session',
        );
      }
      return true;
    }
    return false;
  }

  /// Request approval for note deletion.
  ///
  /// Returns true if approved, false if denied.
  /// Automatically approves if [sessionApprovedNoteDeletions] is true.
  static Future<bool> requestNoteDeletionApproval({
    required List<String> noteIds,
    String? source,
  }) async {
    // Check session approval first
    if (sessionApprovedNoteDeletions) {
      LoggerService.debug(
        '[ApprovalService] Note deletion auto-approved (session)',
      );
      return true;
    }

    // Fetch note details
    final noteDetails = <Map<String, String>>[];
    try {
      final db = getIt<DatabaseService>();
      final notes = await db.getNotesByIds(noteIds);
      for (final note in notes) {
        final content = note.content;
        final snippet = content.length > 100
            ? '${content.substring(0, 100)}...'
            : content;
        noteDetails.add({
          'id': note.id,
          'title': note.title,
          'snippet': snippet,
        });
      }
    } catch (e) {
      LoggerService.warning(
        '[ApprovalService] Failed to fetch note details: $e',
      );
    }

    // Request approval
    // noteDeletion factory creates details: {'noteIds': noteIds, 'count': noteIds.length}
    // I need to inject noteDetails.
    // I will modify the factory to accept it.
    final result = await _dispatchApprovalRequest(
      ApprovalRequest.noteDeletion(
        noteIds: noteIds,
        source: source,
        noteDetails: noteDetails,
      ),
    );

    if (result == null) {
      return false;
    }

    if (result.approved) {
      if (result.approvedForSession) {
        sessionApprovedNoteDeletions = true;
        LoggerService.debug(
          '[ApprovalService] Note deletions approved for session',
        );
      }
      return true;
    }
    return false;
  }
}
