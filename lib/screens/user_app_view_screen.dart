import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/user_app.dart';
import '../models/app_revision.dart';
import '../models/note.dart';
import '../services/service_locator.dart';
import '../services/sync/cloud_sync_service.dart';
import '../services/user_app_service.dart';
import '../services/logger_service.dart';
import '../utils/file_utils.dart';
import '../widgets/user_app_web_view.dart';
import 'user_app_edit_screen.dart';
import 'note_detail_screen.dart';
import 'conversation_chat_screen.dart';
import 'immersive_note_screen.dart';
import 'ai_action_screen.dart';

class UserAppViewScreen extends StatefulWidget {
  final UserApp app;
  final List<Note>? selectedNotes;
  final bool isEmbedded;

  final bool showDeleteAction;
  final bool showEditAction;
  final bool showRevisionHistory;
  final List<Widget>? extraActions;

  const UserAppViewScreen({
    super.key,
    required this.app,
    this.selectedNotes,
    this.isEmbedded = false,
    this.showDeleteAction = true,
    this.showEditAction = true,
    this.showRevisionHistory = true,
    this.extraActions,
  });

  @override
  State<UserAppViewScreen> createState() => UserAppViewScreenState();
}

class UserAppViewScreenState extends State<UserAppViewScreen> {
  final List<String> _consoleOutput = [];
  bool _isLoading = true;
  AppRevision? _selectedRevision;
  bool _showRevisionDetails = false;

  /// Whether cloud sync is actually switched on and set up on THIS device.
  ///
  /// Read once, from [CloudSyncService.status] — which is deliberately
  /// local-only (an auth-token read plus a couple of `sync_state` rows, no
  /// backend call), so this costs no network and works offline. It exists
  /// solely so [_buildNoRevisionState] can tell the two ways of reaching
  /// "this app has no code" apart. Starts `false` so the local-only wording
  /// is what a user sees if the read never completes: claiming "your other
  /// device has it" to someone who has never enabled sync is the worse of
  /// the two possible wrong answers.
  bool _cloudSyncEnabled = false;

  @override
  void initState() {
    super.initState();
    _validateNoteActionApp();
    _loadRevisions();
    _loadCloudSyncEnabled();
  }

  Future<void> _loadCloudSyncEnabled() async {
    if (!getIt.isRegistered<CloudSyncService>()) return;
    try {
      final status = await getIt<CloudSyncService>().status();
      if (!mounted) return;
      setState(() => _cloudSyncEnabled = status.canSync);
    } catch (e) {
      LoggerService.warning(
        'UserAppViewScreen: could not read cloud sync status: $e',
      );
    }
  }

  @override
  void didUpdateWidget(UserAppViewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.app.id != oldWidget.app.id) {
      LoggerService.debug(
        'UserAppViewScreen: App ID changed from ${oldWidget.app.id} to ${widget.app.id}',
      );
      setState(() {
        _consoleOutput.clear();
        _isLoading = true;
        _selectedRevision = null;
        _showRevisionDetails = false;
      });
      _validateNoteActionApp();
      _loadRevisions();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Update selected revision when provider data changes
    final appProvider = context.watch<AppProvider>();
    final currentApp = appProvider.userApps.firstWhere(
      (app) => app.id == widget.app.id,
      orElse: () => widget.app,
    );
    final revisions = appProvider.appRevisions[widget.app.id] ?? [];

    // If the provider's selected revision is different from our local state, update it
    if (currentApp.selectedRevisionId != null &&
        _selectedRevision?.id != currentApp.selectedRevisionId) {
      try {
        final newSelectedRevision = revisions.firstWhere(
          (r) => r.id == currentApp.selectedRevisionId,
        );
        setState(() {
          _selectedRevision = newSelectedRevision;
        });
        LoggerService.debug(
          'Updated selected revision from provider: ${newSelectedRevision.id}',
        );
      } catch (e) {
        LoggerService.warning(
          'Selected revision not found in provider data: ${currentApp.selectedRevisionId}',
        );
      }
    }
  }

  Future<void> _loadRevisions() async {
    try {
      final appProvider = context.read<AppProvider>();
      await appProvider.getAppRevisions(widget.app.id);

      // Get the current app from provider (it will be updated after editing)
      final currentApp = appProvider.userApps.firstWhere(
        (app) => app.id == widget.app.id,
        orElse: () => widget.app,
      );

      // Get revisions from provider (already sorted consistently)
      final revisions = appProvider.appRevisions[widget.app.id] ?? [];

      setState(() {
        if (currentApp.selectedRevisionId != null) {
          try {
            _selectedRevision = revisions.firstWhere(
              (r) => r.id == currentApp.selectedRevisionId,
            );
          } catch (e) {
            LoggerService.warning('Selected revision not found, using latest');
            _selectedRevision = revisions.isNotEmpty
                ? revisions.last
                : null; // Use last (highest revision number)
          }
        } else if (revisions.isNotEmpty) {
          _selectedRevision =
              revisions.last; // Use last (highest revision number)
        } else {
          _selectedRevision = null;
        }
        _isLoading = false;
      });
    } catch (e) {
      LoggerService.error('Error loading revisions: $e', error: e);
      setState(() {
        _selectedRevision = null;
        _isLoading = false;
      });
    }
  }

  Future<void> _refreshAppData() async {
    // Simply reload revisions - the provider handles all state management
    await _loadRevisions();
  }

  void _validateNoteActionApp() {
    if (widget.app.type == UserAppType.noteAction) {
      if (widget.selectedNotes == null || widget.selectedNotes!.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showNoteSelectionDialog();
        });
      }
    }
  }

  void _showNoteSelectionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Note Selection Required'),
        content: const Text(
          'This Note Action App requires at least one note to be selected. Please go back and select notes first.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop(); // Close dialog
              Navigator.of(context).pop(); // Go back to previous screen
            },
            child: const Text('Go Back'),
          ),
        ],
      ),
    );
  }

  void _selectRevision(AppRevision revision) {
    setState(() {
      _selectedRevision = revision;
      _showRevisionDetails = false;
    });
    LoggerService.debug(
      'Selected revision: ${revision.id} (revision ${revision.revisionNumber})',
    );
  }

  void _toggleRevisionDetails(AppRevision revision) {
    setState(() {
      _selectedRevision = revision;
      _showRevisionDetails = true;
    });
  }

  Future<void> _pinRevision(AppRevision revision) async {
    try {
      final appProvider = context.read<AppProvider>();
      await appProvider.setSelectedRevision(widget.app.id, revision.id);

      // The provider will notify listeners and the UI will update automatically
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Revision ${revision.revisionNumber} pinned'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error pinning revision: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteRevision(AppRevision revision) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Revision'),
        content: Text(
          'Are you sure you want to delete revision ${revision.revisionNumber}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final appProvider = context.read<AppProvider>();
        await appProvider.deleteAppRevision(revision.id);

        // The provider will notify listeners and the UI will update automatically

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Revision ${revision.revisionNumber} deleted'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          String errorMessage = 'Error deleting revision: $e';
          if (e.toString().contains(
            'Cannot delete the only remaining revision',
          )) {
            errorMessage =
                'Cannot delete the only remaining revision. At least one revision must exist.';
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(errorMessage), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final appProvider = context.watch<AppProvider>();

    // Get current app and revisions from provider
    final currentApp = appProvider.userApps.firstWhere(
      (app) => app.id == widget.app.id,
      orElse: () => widget.app,
    );
    final revisions = appProvider.appRevisions[widget.app.id] ?? [];

    // Check if WebView is supported
    if (!UserAppService.isWebViewSupported()) {
      return _buildWebViewNotSupportedScreen(context, l10n);
    }

    return Scaffold(
      appBar: widget.isEmbedded
          ? null
          : AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.app.name),
                  if (widget.app.type == UserAppType.noteAction &&
                      widget.selectedNotes != null)
                    Text(
                      '${widget.selectedNotes!.length} notes selected',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                    ),
                ],
              ),
              actions: [
                if (widget.extraActions != null) ...widget.extraActions!,
                IconButton(
                  icon: const Icon(Icons.code),
                  onPressed: () => showConsole(context),
                  tooltip: l10n.console,
                ),
                if (widget.showEditAction)
                  IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () => _navigateToEdit(context),
                    tooltip: l10n.edit,
                  ),
                if (widget.showDeleteAction)
                  IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () => _showDeleteDialog(context, l10n),
                    tooltip: l10n.delete,
                  ),
              ],
            ),
      body: Column(
        children: [
          // Revision tabs
          if (widget.showRevisionHistory && revisions.isNotEmpty)
            Container(
              height: 60,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(context).dividerColor,
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  // Revision numbers on the left
                  Expanded(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(left: 8.0, right: 16.0),
                      itemCount: revisions.length,
                      itemBuilder: (context, index) {
                        final revision = revisions[index];
                        final isSelected = _selectedRevision?.id == revision.id;
                        final isPinned =
                            currentApp.selectedRevisionId == revision.id;

                        return Container(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 4.0,
                            vertical: 8.0,
                          ),
                          child: GestureDetector(
                            onTap: () => _selectRevision(revision),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12.0,
                                vertical: 8.0,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(8.0),
                                border: Border.all(
                                  color: isSelected
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).dividerColor,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${revision.revisionNumber}',
                                    style: TextStyle(
                                      color: isSelected
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.onPrimary
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurface,
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                  if (isPinned) ...[
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.push_pin,
                                      size: 12,
                                      color: isSelected
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.onPrimary
                                          : Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Action buttons on the right
                  if (_selectedRevision != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // AI Response button
                        IconButton(
                          onPressed: () =>
                              _toggleRevisionDetails(_selectedRevision!),
                          icon: Icon(
                            _showRevisionDetails ? Icons.web : Icons.chat,
                            size: 16,
                          ),
                          tooltip: _showRevisionDetails
                              ? 'Show App'
                              : 'Show AI Response',
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                        ),
                        // Pin button
                        IconButton(
                          onPressed: () => _pinRevision(_selectedRevision!),
                          icon: Icon(
                            currentApp.selectedRevisionId ==
                                    _selectedRevision!.id
                                ? Icons.push_pin
                                : Icons.push_pin_outlined,
                            size: 16,
                          ),
                          tooltip:
                              currentApp.selectedRevisionId ==
                                  _selectedRevision!.id
                              ? 'Unpin Revision'
                              : 'Pin Revision',
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                        ),
                        // Delete button
                        IconButton(
                          onPressed: () => _deleteRevision(_selectedRevision!),
                          icon: const Icon(Icons.delete, size: 16),
                          tooltip: 'Delete Revision',
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          // Main content area
          Expanded(
            child: _showRevisionDetails && _selectedRevision != null
                ? _buildRevisionDetailsView()
                : _buildWebView(currentApp),
          ),
        ],
      ),
    );
  }

  /// Shown when the app has no revision at all — so there is no code to run.
  ///
  /// **This used to be `SizedBox.shrink()`: a normal app bar over a
  /// completely blank body, with no message of any kind.** That was already
  /// reachable (an interrupted creation, an import), but M2.14 made it a
  /// routine, expected state rather than a rare one: cloud sync now
  /// replicates a `user_apps` row to a second device while `app_revisions`
  /// stays behind, because a revision's `appCode` is an entire HTML/JS
  /// source and belongs to the content-addressed blob mechanism (M3), not to
  /// inline field sync. A user opening a synced app would have got a silent
  /// white screen. Saying which of the two situations they are in is the
  /// least this can do until the code itself travels.
  ///
  /// The two situations are told apart by [_cloudSyncEnabled]: with sync on
  /// and set up, the app row plausibly arrived from a peer and its code is
  /// still to follow, so the remedy is "open it where you made it". With
  /// sync off there is no peer and no code in flight — the creation simply
  /// never finished — so pointing at another device would be a lie.
  Widget _buildNoRevisionState() {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final title = _cloudSyncEnabled
        ? l10n.userAppNoRunnableCode
        : l10n.userAppNoRunnableCodeLocal;
    final detail = _cloudSyncEnabled
        ? l10n.userAppNoRunnableCodeDetail
        : l10n.userAppNoRunnableCodeLocalDetail;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _cloudSyncEnabled
                  ? Icons.cloud_off_outlined
                  : Icons.code_off_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebView(UserApp currentApp) {
    final revision = _selectedRevision;
    if (revision == null) {
      return _buildNoRevisionState();
    }
    LoggerService.debug(
      'WebView loading data: ${revision.appCode.length} characters',
    );
    LoggerService.debug(
      'Using revision: ${revision.id} (revision ${revision.revisionNumber})',
    );

    return Stack(
      children: [
        UserAppWebView(
          key: ValueKey(revision.id),
          app: currentApp,
          revision: revision,
          selectedNotes: widget.selectedNotes ?? const [],
          sourceLabel: 'App: ${widget.app.name}',
          onOpenNote: (note, replaceWindow) async {
            if (!mounted) return;
            if (replaceWindow) {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (context) => NoteDetailScreen(note: note),
                ),
              );
            } else {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => NoteDetailScreen(note: note),
                ),
              );
            }
          },
          onOpenConversations: (notes, immersiveMode) async {
            if (!mounted) return;
            if (immersiveMode) {
              if (notes.isEmpty) {
                LoggerService.warning(
                  '[UserAppViewScreen] Cannot open immersive mode without notes',
                );
                return;
              }
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => ImmersiveNoteScreen(notes: notes),
                ),
              );
            } else {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => ConversationChatScreen(
                    initialNoteIds: notes.map((note) => note.id).toList(),
                  ),
                ),
              );
            }
          },
          onOpenAIActions: (notes) async {
            if (!mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => AIActionScreen(selectedNotes: notes),
              ),
            );
          },
          onLoadStart: (_, __) {
            setState(() {
              _isLoading = true;
            });
          },
          onLoadStop: (_, __) {
            setState(() {
              _isLoading = false;
            });
          },
          onConsoleMessage: (controller, consoleMessage) {
            setState(() {
              _consoleOutput.add(
                '${consoleMessage.messageLevel}: ${consoleMessage.message}',
              );
            });
          },
          onReceivedError: (controller, request, error) {
            setState(() {
              _consoleOutput.add('ERROR: ${error.toJson()}');
            });
          },
        ),
        if (_isLoading) const Center(child: CircularProgressIndicator()),
      ],
    );
  }

  Widget _buildRevisionDetailsView() {
    if (_selectedRevision == null) return const SizedBox.shrink();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with revision info
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Revision ${_selectedRevision!.revisionNumber}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      Text(
                        '${_selectedRevision!.revisionTimestamp.day}/${_selectedRevision!.revisionTimestamp.month}/${_selectedRevision!.revisionTimestamp.year}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'User Prompt:',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    height: 120, // Fixed height for user prompt
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(4.0),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: SingleChildScrollView(
                        child: Text(
                          _selectedRevision!.userPrompt,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                  // Show attached images below the user prompt
                  if (_selectedRevision!.attachmentPaths.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Attached Images:',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8.0,
                      runSpacing: 8.0,
                      children: _selectedRevision!.attachmentPaths.map((path) {
                        return GestureDetector(
                          onTap: () => FileUtils.openFile(path, context),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8.0),
                              border: Border.all(
                                color: Colors.grey.withOpacity(0.3),
                                width: 1,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(7.0),
                              child: Image.file(
                                File(path),
                                width: 80,
                                height: 80,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // AI Response - Fixed height with scrollable content
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI Response:',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    height: 400, // Fixed height
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(4.0),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: SingleChildScrollView(
                        child: Text(
                          _selectedRevision!.aiResponse,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void showConsole(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.4,
        minChildSize: 0.2,
        maxChildSize: 0.8,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Console Logs',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Row(
                      children: [
                        if (_consoleOutput.isNotEmpty)
                          TextButton.icon(
                            onPressed: () {
                              final text = _consoleOutput.join('\n');
                              Clipboard.setData(ClipboardData(text: text));
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    AppLocalizations.of(
                                      context,
                                    )!.consoleOutputCopied,
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy, size: 16),
                            label: const Text('Copy'),
                          ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SelectionArea(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: _consoleOutput.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: Text(
                          _consoleOutput[index],
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWebViewNotSupportedScreen(
    BuildContext context,
    AppLocalizations l10n,
  ) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.app.name)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.web_asset_off,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                l10n.webViewNotSupported,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.webViewNotSupportedDescription,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _navigateToEdit(BuildContext context) async {
    final appProvider = context.read<AppProvider>();
    final revisions = appProvider.appRevisions[widget.app.id] ?? [];

    // If no revisions exist, create an initial revision first
    if (revisions.isEmpty) {
      try {
        await appProvider.createInitialRevision(widget.app.id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error creating initial revision: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }

    // Get the current app from the provider
    final currentApp = appProvider.userApps.firstWhere(
      (app) => app.id == widget.app.id,
      orElse: () => widget.app,
    );

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => UserAppEditScreen(
          app: currentApp,
          selectedRevision: _selectedRevision,
        ),
      ),
    );

    // If we returned from edit screen, refresh the data to show latest changes
    if (result == true && mounted) {
      await _refreshAppData();
    }
  }

  void _showDeleteDialog(BuildContext context, AppLocalizations l10n) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.delete),
        content: Text(l10n.confirmDeleteApp),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                final appProvider = context.read<AppProvider>();
                await appProvider.deleteUserApp(widget.app.id);
                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n.appDeletedSuccessfully),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n.errorDeletingApp(e.toString())),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }
}
