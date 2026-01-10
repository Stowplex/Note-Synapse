import 'dart:async';
import 'dart:convert';

import 'logger_service.dart';
import 'sql_query_service.dart';

/// Type of approval being requested.
enum ApprovalType { sqlWrite, noteModification, noteDeletion }

/// Encapsulates details of an approval request.
class ApprovalRequest {
  ApprovalRequest({
    required this.type,
    required this.title,
    required this.description,
    required this.details,
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
      warningMessage: 'This query will modify the database.',
      sessionApprovalLabel: 'Allow for this session',
    );
  }

  /// Create a note modification approval request.
  factory ApprovalRequest.noteModification({
    required String noteId,
    required Map<String, dynamic> modification,
    String? source,
  }) {
    return ApprovalRequest(
      type: ApprovalType.noteModification,
      title: 'Allow Note Modification?',
      description: source != null
          ? '$source wants to modify note:'
          : 'The operation wants to modify note:',
      details: {'noteId': noteId, 'modification': modification},
      warningMessage: null,
      sessionApprovalLabel: 'Allow for this session',
    );
  }

  /// Create a note deletion approval request.
  factory ApprovalRequest.noteDeletion({
    required List<String> noteIds,
    String? source,
  }) {
    final isBatch = noteIds.length > 1;
    return ApprovalRequest(
      type: ApprovalType.noteDeletion,
      title: isBatch ? 'Allow Note Deletion?' : 'Allow Note Deletion?',
      description: source != null
          ? '$source wants to delete ${isBatch ? '${noteIds.length} notes' : 'a note'}:'
          : 'The operation wants to delete ${isBatch ? '${noteIds.length} notes' : 'a note'}:',
      details: {'noteIds': noteIds, 'count': noteIds.length},
      warningMessage: 'This action cannot be undone.',
      sessionApprovalLabel: 'Allow for this session',
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

    // Check if approval callback is registered
    if (onApprovalRequest == null) {
      LoggerService.warning(
        '[ApprovalService] No approval callback registered for SQL write',
      );
      return false;
    }

    // Request approval
    final request = ApprovalRequest.sqlWrite(
      sql: sql,
      queryType: queryType,
      queryTypeDescription: queryTypeDescription,
      source: source,
    );

    try {
      final result = await onApprovalRequest!(request);
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
    } catch (e) {
      LoggerService.error('[ApprovalService] Error requesting approval: $e');
      return false;
    }
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

    // Check if approval callback is registered
    if (onApprovalRequest == null) {
      LoggerService.warning(
        '[ApprovalService] No approval callback registered for note modification',
      );
      return false;
    }

    // Request approval
    final request = ApprovalRequest.noteModification(
      noteId: noteId,
      modification: modification,
      source: source,
    );

    try {
      final result = await onApprovalRequest!(request);
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
    } catch (e) {
      LoggerService.error('[ApprovalService] Error requesting approval: $e');
      return false;
    }
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

    // Check if approval callback is registered
    if (onApprovalRequest == null) {
      LoggerService.warning(
        '[ApprovalService] No approval callback registered for note deletion',
      );
      return false;
    }

    // Request approval
    final request = ApprovalRequest.noteDeletion(
      noteIds: noteIds,
      source: source,
    );

    try {
      final result = await onApprovalRequest!(request);
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
    } catch (e) {
      LoggerService.error('[ApprovalService] Error requesting approval: $e');
      return false;
    }
  }
}
