import 'package:flutter/material.dart';

import '../models/app_revision.dart';
import '../models/note.dart';
import '../models/user_app.dart';
import '../screens/ai_action_screen.dart';
import '../screens/conversation_chat_screen.dart';
import '../screens/immersive_note_screen.dart';
import '../screens/note_detail_screen.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import 'user_app_web_view.dart';

/// Renders a User App inline inside markdown (notes, chat messages).
///
/// Resolves the app and revision from the database, then delegates to the
/// shared [UserAppWebView] for the actual WebView + bridge wiring. Wraps the
/// result in a fixed-size rounded card matching the other embedded-webview
/// styling in [InteractiveCheckboxMarkdown].
class EmbeddedUserAppView extends StatefulWidget {
  const EmbeddedUserAppView({
    super.key,
    required this.appUuid,
    required this.selectedNotes,
    required this.params,
    required this.width,
    required this.height,
    this.revisionNumber,
    this.parentNoteId,
  });

  /// UUID from the `synapseresource://app/<uuid>` URI.
  final String appUuid;

  /// Optional specific revision number. Defaults to `app.selectedRevisionId`
  /// then to the highest revisionNumber.
  final int? revisionNumber;

  /// Notes passed to the app via `window.Synapse.Notes`.
  final List<Note> selectedNotes;

  /// Parameters passed to the app via `window.Synapse.Params`.
  final Map<String, dynamic> params;

  final double width;
  final double height;

  /// Id of the note whose markdown contains this embed, used for logging and
  /// approval-dialog source strings. Null when the embed renders inside a
  /// chat message.
  final String? parentNoteId;

  @override
  State<EmbeddedUserAppView> createState() => _EmbeddedUserAppViewState();
}

class _EmbeddedUserAppViewState extends State<EmbeddedUserAppView> {
  late Future<_ResolvedApp> _resolveFuture;

  @override
  void initState() {
    super.initState();
    _resolveFuture = _resolve();
  }

  @override
  void didUpdateWidget(covariant EmbeddedUserAppView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appUuid != widget.appUuid ||
        oldWidget.revisionNumber != widget.revisionNumber) {
      setState(() {
        _resolveFuture = _resolve();
      });
    }
  }

  Future<_ResolvedApp> _resolve() async {
    final db = DatabaseService();
    final app = await db.getUserAppByUuid(widget.appUuid);
    if (app == null) {
      return _ResolvedApp.error('App not found: ${widget.appUuid}');
    }

    AppRevision? revision;
    if (widget.revisionNumber != null) {
      final all = await db.getAppRevisions(app.id);
      for (final r in all) {
        if (r.revisionNumber == widget.revisionNumber) {
          revision = r;
          break;
        }
      }
    }
    if (revision == null && app.selectedRevisionId != null) {
      revision = await db.getAppRevision(app.selectedRevisionId!);
    }
    revision ??= await db.getLatestAppRevision(app.id);

    if (revision == null) {
      return _ResolvedApp.error('No revision available for ${app.name}');
    }
    return _ResolvedApp.ok(app, revision);
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = Theme.of(context).colorScheme.outlineVariant;
    final fadedBorderColor = borderColor.withValues(
      alpha: (borderColor.a * 0.6).clamp(0.0, 1.0),
    );

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: fadedBorderColor),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: FutureBuilder<_ResolvedApp>(
            future: _resolveFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              if (snapshot.hasError || snapshot.data == null) {
                return _EmbeddedAppErrorCard(
                  message: snapshot.error?.toString() ??
                      'Unable to load embedded app',
                );
              }
              final resolved = snapshot.data!;
              if (!resolved.ok) {
                return _EmbeddedAppErrorCard(message: resolved.error!);
              }
              return _buildWebView(resolved.app!, resolved.revision!);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildWebView(UserApp app, AppRevision revision) {
    return UserAppWebView(
      app: app,
      revision: revision,
      selectedNotes: widget.selectedNotes,
      params: widget.params,
      sourceLabel: 'Embedded app: ${app.name}',
      onOpenNote: (note, replaceWindow) async {
        if (!mounted) return;
        if (replaceWindow) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => NoteDetailScreen(note: note),
            ),
          );
        } else {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => NoteDetailScreen(note: note),
            ),
          );
        }
      },
      onOpenConversations: (notes, immersiveMode) async {
        if (!mounted) return;
        if (immersiveMode) {
          if (notes.isEmpty) {
            LoggerService.warning(
              '[EmbeddedUserAppView] Cannot open immersive mode without notes',
            );
            return;
          }
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ImmersiveNoteScreen(notes: notes),
            ),
          );
        } else {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ConversationChatScreen(
                initialNoteIds: notes.map((n) => n.id).toList(),
              ),
            ),
          );
        }
      },
      onOpenAIActions: (notes) async {
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AIActionScreen(selectedNotes: notes),
          ),
        );
      },
    );
  }
}

class _ResolvedApp {
  const _ResolvedApp._(this.app, this.revision, this.error);

  factory _ResolvedApp.ok(UserApp app, AppRevision revision) =>
      _ResolvedApp._(app, revision, null);
  factory _ResolvedApp.error(String message) =>
      _ResolvedApp._(null, null, message);

  final UserApp? app;
  final AppRevision? revision;
  final String? error;

  bool get ok => error == null && app != null && revision != null;
}

class _EmbeddedAppErrorCard extends StatelessWidget {
  const _EmbeddedAppErrorCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error, size: 28),
            const SizedBox(height: 8),
            Text(
              message,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
