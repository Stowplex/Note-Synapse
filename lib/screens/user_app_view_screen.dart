import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/user_app.dart';
import '../models/app_revision.dart';
import '../models/note.dart';
import '../services/user_app_service.dart';
import '../services/user_app_session_service.dart';
import '../services/service_locator.dart';
import '../services/logger_service.dart';
import '../utils/file_utils.dart';
import '../utils/global_keys.dart';
import '../utils/user_app_localization.dart';
import '../widgets/user_app_web_view.dart';
import 'user_app_edit_screen.dart';
import 'note_detail_screen.dart';
import 'conversation_chat_screen.dart';
import 'immersive_note_screen.dart';
import 'ai_action_screen.dart';
import 'note_merge_screen.dart';

class UserAppViewScreen extends StatefulWidget {
  final UserApp app;
  final List<Note>? selectedNotes;
  final bool isEmbedded;

  final bool showDeleteAction;
  final bool showEditAction;
  final bool showRevisionHistory;
  final List<Widget>? extraActions;

  /// Whether this instance may be backgrounded — kept alive under a freshly
  /// pushed Home screen and returned to via the floating pill.
  ///
  /// False where the screen is a *tab body* rather than a pushed route
  /// (`MultiFunctionScreen`): there is no route of our own to keep alive, and
  /// the app is already permanently reachable through its tab.
  final bool canRunInBackground;

  const UserAppViewScreen({
    super.key,
    required this.app,
    this.selectedNotes,
    this.isEmbedded = false,
    this.showDeleteAction = true,
    this.showEditAction = true,
    this.showRevisionHistory = true,
    this.extraActions,
    this.canRunInBackground = true,
  });

  @override
  State<UserAppViewScreen> createState() => UserAppViewScreenState();
}

class UserAppViewScreenState extends State<UserAppViewScreen> with RouteAware {
  final List<String> _consoleOutput = [];
  bool _isLoading = true;
  AppRevision? _selectedRevision;
  bool _showRevisionDetails = false;

  /// The route this screen owns, once registered as a backgroundable session.
  /// Null when the screen is embedded, opted out, or not hosted by a route.
  ModalRoute<void>? _sessionRoute;

  /// Set once the app has been seen in [AppProvider]; guards the
  /// "deleted while backgrounded" check against a not-yet-loaded provider.
  bool _appSeenInProvider = false;

  UserAppSessionService? get _sessionService =>
      getIt.isRegistered<UserAppSessionService>()
      ? getIt<UserAppSessionService>()
      : null;

  @override
  void initState() {
    super.initState();
    _validateNoteActionApp();
    _loadRevisions();
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
    _maybeRegisterSession();
    // Update selected revision when provider data changes
    final appProvider = context.watch<AppProvider>();
    _checkAppStillExists(appProvider);
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

  /// Records this screen's route with [UserAppSessionService] so it can be kept
  /// alive under a pushed Home screen, and subscribes to [appRouteObserver] to
  /// track whether it is the visible route.
  ///
  /// Only pushed [PageRoute]s qualify: an embedded/tab-body instance would pick
  /// up whatever route happens to host it, which is not ours to background.
  void _maybeRegisterSession() {
    if (_sessionRoute != null) return;
    if (!widget.canRunInBackground || widget.isEmbedded) return;
    if (!UserAppService.isWebViewSupported()) return;

    final route = ModalRoute.of(context);
    if (route is! PageRoute<void>) return;

    final service = _sessionService;
    if (service == null) return;

    _sessionRoute = route;
    appRouteObserver.subscribe(this, route);
    service.register(widget.app, route);
  }

  /// Closes the session if the app was deleted while it was backgrounded, so
  /// the pill never points at an app that no longer exists.
  void _checkAppStillExists(AppProvider appProvider) {
    if (_sessionRoute == null) return;
    final exists = appProvider.userApps.any((a) => a.id == widget.app.id);
    if (exists) {
      _appSeenInProvider = true;
      return;
    }
    if (!_appSeenInProvider) return;
    _appSeenInProvider = false;
    final service = _sessionService;
    if (service == null) return;
    final route = _sessionRoute;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // By the time the frame ends the tracked session may be someone else's
      // (a second app launched in between); never tear down a stranger.
      if (!identical(service.session?.route, route)) return;
      // `discard`, not `close`: the user is looking at whichever screen they
      // deleted the app from, so walking them back to the app route just to
      // pop it again would be two page transitions they did not ask for.
      service.discard();
    });
  }

  /// Covered by another route — the app is no longer in the foreground.
  ///
  /// Passes our own route: a second app screen may be alive further up the
  /// stack (app A → in-app note link → app B), and only the screen that owns
  /// the session is allowed to move it.
  @override
  void didPushNext() {
    final route = _sessionRoute;
    if (route != null) _sessionService?.setForeground(route, false);
  }

  /// Uncovered again. Fires whether the user came back via the pill or the
  /// system back gesture, so the pill hides either way.
  ///
  /// Re-registers rather than just flipping the flag: if another app screen was
  /// opened above this one it took the session, so becoming visible again means
  /// taking it back — otherwise this screen's "run in background" button would
  /// be a silent no-op, or worse, act on a stranger's route.
  @override
  void didPopNext() {
    final route = _sessionRoute;
    if (route != null) _sessionService?.register(widget.app, route);
  }

  Future<void> _moveToBackground() async {
    final route = _sessionRoute;
    final service = _sessionService;
    if (route == null || service == null) return;
    // This screen is the visible one, so it should already own the session;
    // claim it first regardless so the button can never be a no-op because the
    // session drifted to another app screen.
    service.register(widget.app, route);
    await service.moveToBackground();
  }

  @override
  void dispose() {
    final route = _sessionRoute;
    if (route != null) {
      appRouteObserver.unsubscribe(this);
      _sessionService?.unregister(route);
      _sessionRoute = null;
    }
    super.dispose();
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
                  Text(currentApp.displayName(context)),
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
                if (_sessionRoute != null)
                  IconButton(
                    icon: const Icon(Icons.picture_in_picture_alt_outlined),
                    onPressed: _moveToBackground,
                    tooltip: l10n.runInBackground,
                  ),
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

  Widget _buildWebView(UserApp currentApp) {
    final revision = _selectedRevision;
    if (revision == null) {
      return const SizedBox.shrink();
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
          sourceLabel: 'App: ${currentApp.displayName(context)}',
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
          onOpenMerge: (notes) async {
            // Throw rather than return null: null is how the bridge reports the
            // user cancelling the merge, and being unmounted is not that.
            if (!mounted) {
              throw StateError('user app screen is no longer mounted');
            }
            return Navigator.of(context).push<Note>(
              MaterialPageRoute(
                builder: (context) => NoteMergeScreen(notes: notes),
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
      appBar: AppBar(title: Text(widget.app.displayName(context))),
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
