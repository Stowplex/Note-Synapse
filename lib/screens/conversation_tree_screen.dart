import 'package:flutter/material.dart';
import 'package:graphview/GraphView.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import '../models/conversation.dart';
import '../models/note.dart';
import '../services/conversation_service.dart';
import '../services/database_service.dart';
import '../services/fork_service.dart';
import '../services/logger_service.dart';
import '../l10n/app_localizations.dart';
import 'conversation_chat_screen.dart';
import '../widgets/add_note_dialog.dart';
import '../widgets/linear_history_dialog.dart';

class ConversationTreeScreen extends StatefulWidget {
  final List<String>? activeConversationIds;
  /// When true, activeConversationIds are used to filter the tree (from note detail view)
  /// When false, activeConversationIds are only used for highlighting (from conversation view)
  final bool filterByActiveConversations;

  const ConversationTreeScreen({
    super.key,
    this.activeConversationIds,
    this.filterByActiveConversations = false,
  });

  @override
  State<ConversationTreeScreen> createState() => _ConversTreeScreenState();
}

class _ConversTreeScreenState extends State<ConversationTreeScreen> {
  final ConversationService _conversationService = ConversationService();
  final DatabaseService _databaseService = DatabaseService();
  final ForkService _forkService = ForkService();
  final GraphViewController _graphController = GraphViewController();

  ConversationTree? _tree;
  final List<String> _selectedNodes = [];
  bool _isLoading = true;
  String? _selectedConversationId;
  ConversationMessage? _selectedMessage;
  bool _isMultiSelectMode = false;
  bool _hasRefreshedOnce = false;
  Duration _selectedTimeRange = const Duration(days: 3);
  List<String> _selectedFilterTags = [];
  List<String> _highlightedConversationIds =
      []; // Conversation IDs to highlight
  Map<String, List<String>> _nodeToConversationIds = {};

  @override
  void initState() {
    super.initState();
    // Set highlighted conversation from widget parameter
    // Only highlight if NOT filtering (when filtering, we don't want highlights)
    if (widget.activeConversationIds != null && !widget.filterByActiveConversations) {
      _highlightedConversationIds = widget.activeConversationIds!;
    }
    _loadTree();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Refresh tree when screen becomes visible (but only once per mount)
    if (!_hasRefreshedOnce) {
      _hasRefreshedOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          // Don't clear highlight on automatic refresh when first entering the screen
          _refreshTree(clearHighlight: false);
        }
      });
    }
  }

  Future<void> _fetchNodeConversationIds() async {
    if (_tree == null) return;

    final newMap = <String, List<String>>{};
    for (final node in _tree!.nodes.values) {
      if (node.messageId != null) {
        final conversationIds = await _databaseService
            .getConversationsContainingMessage(node.messageId!);
        newMap[node.id] = conversationIds;
      }
    }

    if (mounted) {
      setState(() {
        _nodeToConversationIds = newMap;
      });
    }
  }

  Future<void> _loadTree() async {
    setState(() => _isLoading = true);

    try {
      // If filterByActiveConversations is true, use activeConversationIds as a filter
      // This overrides the default time range and tag filters
      final bool hasActiveConversationFilter = widget.filterByActiveConversations &&
          widget.activeConversationIds != null &&
          widget.activeConversationIds!.isNotEmpty;
      
      _tree = await _conversationService.refreshConversationTree(
        maxAge: hasActiveConversationFilter ? null : _selectedTimeRange,
        conversationIds: hasActiveConversationFilter
            ? widget.activeConversationIds
            : null,
        tagNames: hasActiveConversationFilter
            ? null
            : (_selectedFilterTags.isEmpty ? null : _selectedFilterTags),
      );
      await _fetchNodeConversationIds();
      if (_tree == null) {
        if (mounted) {
          try {
            final l10n = AppLocalizations.of(context)!;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.noConversationsFound),
                duration: const Duration(seconds: 3),
              ),
            );
          } catch (contextError) {
            LoggerService.warning(
              'Could not show info SnackBar: $contextError',
            );
          }
        }
      }
    } catch (e) {
      LoggerService.error('Error loading conversation tree: $e', error: e);
      if (mounted) {
        try {
          final l10n = AppLocalizations.of(context)!;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.errorRefreshingTree(e.toString())),
              backgroundColor: Theme.of(context).colorScheme.error,
              action: SnackBarAction(label: l10n.retry, onPressed: _loadTree),
            ),
          );
        } catch (contextError) {
          LoggerService.warning('Could not show error SnackBar: $contextError');
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _refreshTree({bool clearHighlight = true}) async {
    setState(() {
      _isLoading = true;
      // Clear highlighted conversation only when manually refreshed
      if (clearHighlight) {
        _highlightedConversationIds = [];
      }
    });

    try {
      // If filterByActiveConversations is true, use activeConversationIds as a filter
      // This overrides the default time range and tag filters
      // Don't clear the filter when clearHighlight is false (automatic refresh)
      final bool hasActiveConversationFilter = widget.filterByActiveConversations &&
          widget.activeConversationIds != null &&
          widget.activeConversationIds!.isNotEmpty;
      
      _tree = await _conversationService.refreshConversationTree(
        maxAge: hasActiveConversationFilter ? null : _selectedTimeRange,
        conversationIds: hasActiveConversationFilter
            ? widget.activeConversationIds
            : null,
        tagNames: hasActiveConversationFilter
            ? null
            : (_selectedFilterTags.isEmpty ? null : _selectedFilterTags),
      );
      await _fetchNodeConversationIds();
      if (_tree == null) {
        if (mounted) {
          try {
            final l10n = AppLocalizations.of(context)!;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.noConversationsFound),
                duration: const Duration(seconds: 3),
              ),
            );
          } catch (contextError) {
            LoggerService.warning(
              'Could not show info SnackBar: $contextError',
            );
          }
        }
      }
    } catch (e) {
      LoggerService.error('Error refreshing conversation tree: $e', error: e);
      if (mounted) {
        try {
          final l10n = AppLocalizations.of(context)!;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.errorRefreshingTree(e.toString())),
              backgroundColor: Theme.of(context).colorScheme.error,
              action: SnackBarAction(
                label: l10n.retry,
                onPressed: _refreshTree,
              ),
            ),
          );
        } catch (contextError) {
          LoggerService.warning('Could not show error SnackBar: $contextError');
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _toggleNodeSelection(String nodeId) {
    setState(() {
      if (_selectedNodes.contains(nodeId)) {
        _selectedNodes.remove(nodeId);
      } else {
        _selectedNodes.add(nodeId);
      }
    });
  }

  void _toggleNodeExpansion(String nodeId) {
    if (_tree == null) return;

    final node = _tree!.getNode(nodeId);
    if (node == null || node.id == 'root') return; // Don't allow toggling root

    setState(() {
      final updatedNode = node.copyWith(isExpanded: !node.isExpanded);
      final updatedNodes = Map<String, ConversationTreeNode>.from(_tree!.nodes);
      updatedNodes[nodeId] = updatedNode;
      _tree = _tree!.copyWith(nodes: updatedNodes);
    });
  }

  void _selectInteraction(ConversationTreeNode node) async {
    if (node.messageId == null) return;

    try {
      final message = await _conversationService.getConversationMessage(
        node.messageId!,
      );
      if (message != null) {
        setState(() {
          _selectedMessage = message;
          _selectedConversationId = node.conversationId;
        });
      }
    } catch (e) {
      LoggerService.error('Error loading interaction message: $e', error: e);
      if (mounted) {
        try {
          final l10n = AppLocalizations.of(context)!;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.errorForkingConversation(e.toString())),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        } catch (contextError) {
          LoggerService.warning('Could not show error SnackBar: $contextError');
        }
      }
    }
  }

  void _deleteInteraction(ConversationTreeNode node) {
    if (_tree == null) return;

    final currentContext = context;

    showDialog(
      context: currentContext,
      builder: (dialogContext) {
        final dialogL10n = AppLocalizations.of(dialogContext)!;
        return AlertDialog(
          title: Text(dialogL10n.deleteInteraction),
          content: Text(dialogL10n.deleteInteractionWhatToDelete),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(dialogL10n.cancel),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                try {
                  if (node.messageId != null) {
                    final messageIdsToDelete = await _conversationService
                        .getMessageIdsFromTreeNode(node);
                    await _conversationService.deleteMessagesFromTreeNodes(
                      messageIdsToDelete,
                    );
                  }
                  _refreshTree();
                } catch (e) {
                  LoggerService.error(
                    'Error deleting interaction: $e',
                    error: e,
                  );
                }
              },
              child: Text(dialogL10n.deleteOnlyNodesInFilter),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                try {
                  if (node.messageId != null) {
                    final messageIdsToDelete = await _conversationService
                        .getAllMessageIdsInSubtree(node.messageId!);
                    await _conversationService.deleteMessagesFromTreeNodes(
                      messageIdsToDelete,
                    );
                  }
                  _refreshTree();
                } catch (e) {
                  LoggerService.error(
                    'Error deleting interaction: $e',
                    error: e,
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(currentContext).colorScheme.error,
                foregroundColor: Theme.of(currentContext).colorScheme.onError,
              ),
              child: Text(dialogL10n.deleteNodeAndDescendants),
            ),
          ],
        );
      },
    );
  }

  void _forkInteraction(ConversationTreeNode node) async {
    if (node.messageId == null) return;

    // Capture the context safely before the async operation
    final currentContext = context;

    try {
      LoggerService.info('Starting fork from interaction: ${node.id}');

      // Use the new fork service with context selection
      final newConversation = await _forkService.forkFromMessage(
        context: currentContext,
        forkFromMessageId: node.messageId!,
        suggestedTitle: 'Forked conversation',
      );

      if (newConversation != null) {
        LoggerService.info(
          'Forked conversation created: ${newConversation.id}',
        );

        if (mounted) {
          try {
            final l10n = AppLocalizations.of(currentContext)!;
            ScaffoldMessenger.of(currentContext).showSnackBar(
              SnackBar(
                content: Text(l10n.forkedConversationSuccess),
                duration: const Duration(seconds: 2),
              ),
            );
          } catch (contextError) {
            LoggerService.warning(
              'Could not show success SnackBar: $contextError',
            );
          }

          // Navigate to the new conversation, replacing the tree view
          await Navigator.of(currentContext).pushReplacement(
            MaterialPageRoute(
              builder: (context) =>
                  ConversationChatScreen(conversationId: newConversation.id),
            ),
          );
        }
      }
    } catch (e) {
      LoggerService.error('Error forking interaction: $e', error: e);
      if (mounted) {
        try {
          final l10n = AppLocalizations.of(currentContext)!;
          ScaffoldMessenger.of(currentContext).showSnackBar(
            SnackBar(
              content: Text(l10n.errorForkingConversation(e.toString())),
              backgroundColor: Theme.of(currentContext).colorScheme.error,
            ),
          );
        } catch (contextError) {
          LoggerService.warning('Could not show error SnackBar: $contextError');
        }
      }
    }
  }

  void _createConversationFromSelected() async {
    if (_selectedNodes.isEmpty) return;

    // Capture the context safely before the async operation
    final currentContext = context;

    try {
      // Create conversation directly with auto-generated title
      final newConversation = await _conversationService
          .createConversationFromSelectedNodes(
            selectedNodeIds: _selectedNodes,
            title: 'Conversation from ${_selectedNodes.length} selected nodes',
          );

      // Clear selected nodes and exit multi-select mode
      setState(() {
        _selectedNodes.clear();
        _isMultiSelectMode = false;
      });

      // Navigate directly to the new conversation, replacing the tree view
      Navigator.of(currentContext).pushReplacement(
        MaterialPageRoute(
          builder: (context) =>
              ConversationChatScreen(conversationId: newConversation.id),
        ),
      );
    } catch (e) {
      if (mounted) {
        try {
          final l10n = AppLocalizations.of(currentContext)!;
          ScaffoldMessenger.of(currentContext).showSnackBar(
            SnackBar(
              content: Text(l10n.errorForkingConversation(e.toString())),
            ),
          );
        } catch (contextError) {
          LoggerService.warning('Could not show error SnackBar: $contextError');
        }
      }
    }
  }

  void _toggleMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = !_isMultiSelectMode;
      if (!_isMultiSelectMode) {
        _selectedNodes.clear();
      }
    });
  }

  Future<void> _showSaveOptionsDialog() async {
    // Capture the context safely before the async operation
    final currentContext = context;
    final l10n = AppLocalizations.of(currentContext)!;

    if (_selectedNodes.isEmpty) {
      if (mounted) {
        try {
          ScaffoldMessenger.of(currentContext).showSnackBar(
            SnackBar(
              content: Text(l10n.pleaseSelectNodesFirst),
              duration: const Duration(seconds: 2),
            ),
          );
        } catch (contextError) {
          LoggerService.warning('Could not show info SnackBar: $contextError');
        }
      }
      return;
    }

    try {
      // Collect conversation context from selected nodes
      final conversationContent = await _buildConversationContentFromNodes();
      final contextNotes = await _collectContextNotesFromNodes();

      // Show the unified add note dialog
      final createdNotes = await AddNoteDialog.show(
        context: currentContext,
        content: conversationContent,
        contextNotes: contextNotes,
      );

      // If notes were created, show success message
      if (createdNotes != null && createdNotes.isNotEmpty && mounted) {
        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(
            content: Text(
              createdNotes.length == 1
                  ? l10n.noteCreatedSuccessfully(createdNotes.first.title)
                  : l10n.multipleNotesCreatedSuccessfully(createdNotes.length),
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      LoggerService.error('Error saving nodes as note: $e', error: e);
      if (mounted) {
        try {
          ScaffoldMessenger.of(currentContext).showSnackBar(
            SnackBar(
              content: Text(l10n.errorSavingNodes(e.toString())),
              backgroundColor: Theme.of(currentContext).colorScheme.error,
            ),
          );
        } catch (contextError) {
          LoggerService.warning('Could not show error SnackBar: $contextError');
        }
      }
    }
  }

  /// Build conversation content from selected nodes
  Future<String> _buildConversationContentFromNodes() async {
    if (_tree == null || _selectedNodes.isEmpty) return '';

    final conversationIds = <String>{};

    for (final nodeId in _selectedNodes) {
      final node = _tree!.nodes[nodeId];
      if (node != null && node.conversationId.isNotEmpty) {
        conversationIds.add(node.conversationId);
      }
    }

    if (conversationIds.isEmpty) {
      return '';
    }

    // Build context messages from conversations
    final contextMessages = <String>[];

    for (final sourceConvId in conversationIds) {
      final messages = await _databaseService.getConversationMessages(
        sourceConvId,
      );
      if (messages.isNotEmpty) {
        // Add a header for this conversation's context
        contextMessages.add(
          '--- Context from conversation: ${sourceConvId.substring(0, 8)}... ---',
        );

        // Add key messages (first few and last few)
        final keyMessages = <ConversationMessage>[];
        if (messages.length <= 4) {
          keyMessages.addAll(messages);
        } else {
          // First 2 and last 2 messages
          keyMessages.addAll(messages.take(2));
          keyMessages.addAll(messages.skip(messages.length - 2));
        }

        for (final message in keyMessages) {
          final prefix = message.type == MessageType.user ? 'User: ' : 'AI: ';
          contextMessages.add('$prefix${message.content}');
        }
        contextMessages.add(''); // Empty line between conversations
      }
    }

    return contextMessages.join('\n');
  }

  /// Collect context notes from selected nodes
  Future<List<Note>> _collectContextNotesFromNodes() async {
    if (_tree == null || _selectedNodes.isEmpty) return [];

    final allNoteIds = <String>{};

    for (final nodeId in _selectedNodes) {
      final node = _tree!.nodes[nodeId];
      if (node != null && node.conversationId.isNotEmpty) {
        // Get notes from this conversation
        final noteIds = await _databaseService.getConversationNoteIds(
          node.conversationId,
        );
        allNoteIds.addAll(noteIds);
      }
    }

    // Load the notes
    final notes = <Note>[];
    for (final noteId in allNoteIds) {
      final note = await _databaseService.getNote(noteId);
      if (note != null) {
        notes.add(note);
      }
    }

    return notes;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_tree == null) {
      final bool hasActiveConversationFilter = widget.filterByActiveConversations &&
          widget.activeConversationIds != null &&
          widget.activeConversationIds!.isNotEmpty;
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.conversationTree),
          actions: [
            if (!hasActiveConversationFilter) _buildTimeRangeFilter(l10n),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _refreshTree,
              tooltip: l10n.refreshTree,
            ),
          ],
        ),
        body: Center(child: Text(l10n.noConversationsFound)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: _isMultiSelectMode
            ? Text(
                l10n.selected.replaceAll(
                  '{count}',
                  _selectedNodes.length.toString(),
                ),
              )
            : Text(l10n.conversationTree),
        actions: [
          if (_isMultiSelectMode) ...[
            IconButton(
              icon: const Icon(Icons.note_add),
              onPressed: _showSaveOptionsDialog,
              tooltip: l10n.saveSelectedNodesAsNote,
            ),
            if (_selectedNodes.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: _createConversationFromSelected,
                tooltip: l10n.createFromSelected,
              ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _toggleMultiSelectMode,
              tooltip: l10n.exitMultiSelect,
            ),
          ] else ...[
            // Hide filter button when filtering by activeConversationIds (from note detail view)
            if (!widget.filterByActiveConversations)
              _buildTimeRangeFilter(l10n),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _refreshTree,
              tooltip: l10n.refreshTree,
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // Tree view
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.all(16.0),
              child: _buildTreeView(),
            ),
          ),
          // Conversation details
          if (_selectedConversationId != null)
            Expanded(
              flex: 2,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(
                        context,
                      ).colorScheme.outline.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(
                        context,
                      ).colorScheme.shadow.withOpacity(0.1),
                      blurRadius: 4,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: _buildConversationDetails(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTimeRangeFilter(AppLocalizations l10n) {
    return IconButton(
      icon: const Icon(Icons.filter_list),
      onPressed: _showLinearHistoryDialog,
      tooltip: 'Filters',
    );
  }

  void _showLinearHistoryDialog() {
    showDialog(
      context: context,
      builder: (context) => LinearHistoryDialog(
        initialTimeRange: _selectedTimeRange,
        initialSelectedTags: _selectedFilterTags,
        onTimeRangeChanged: (newTimeRange) {
          setState(() {
            _selectedTimeRange = newTimeRange;
          });
          _refreshTree();
        },
        onTagsChanged: (tags) {
          setState(() {
            _selectedFilterTags = tags;
          });
          _refreshTree();
        },
        onConversationDeleted: () {
          // Refresh the tree when a conversation is deleted
          _refreshTree();
        },
      ),
    );
  }

  Widget _buildTreeView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return InteractiveViewer(
          constrained: false,
          child: SizedBox(
            width: constraints.maxWidth > 1000 ? constraints.maxWidth : 1000,
            height: constraints.maxHeight > 500 ? constraints.maxHeight : 500,
            child: GraphView.builder(
              graph: _buildGraph(),
              algorithm: BuchheimWalkerAlgorithm(
                BuchheimWalkerConfiguration(
                  orientation:
                      BuchheimWalkerConfiguration.ORIENTATION_TOP_BOTTOM,
                  siblingSeparation: 80,
                  levelSeparation: 120,
                  subtreeSeparation: 60,
                ),
                TreeEdgeRenderer(BuchheimWalkerConfiguration()),
              ),
              controller: _graphController,
              builder: (Node node) {
                final nodeId = (node.key?.value as String?) ?? '';
                final treeNode = _tree!.getNode(nodeId);
                if (treeNode == null) return const SizedBox.shrink();

                return _buildTreeNode(treeNode);
              },
            ),
          ),
        );
      },
    );
  }

  Graph _buildGraph() {
    final graph = Graph();

    if (_tree == null) return graph;

    // Get visible nodes based on expansion state
    final visibleNodes = _getVisibleNodes();

    // Add visible nodes
    for (final nodeId in visibleNodes) {
      graph.addNode(Node.Id(nodeId));
    }

    // Add edges for visible nodes
    for (final nodeId in visibleNodes) {
      final node = _tree!.getNode(nodeId);
      if (node != null &&
          node.parentId != null &&
          visibleNodes.contains(node.parentId)) {
        graph.addEdge(Node.Id(node.parentId!), Node.Id(nodeId));
      }
    }

    return graph;
  }

  // Get list of visible node IDs based on expansion state
  List<String> _getVisibleNodes() {
    if (_tree == null) return [];

    final visibleNodes = <String>{};
    final toProcess = <String>['root']; // Start with root

    while (toProcess.isNotEmpty) {
      final nodeId = toProcess.removeAt(0);
      final node = _tree!.getNode(nodeId);

      if (node == null) continue;

      visibleNodes.add(nodeId);

      // If node is expanded (or is root), add its children to be processed
      if (node.isExpanded || node.id == 'root') {
        toProcess.addAll(node.children);
      }
    }

    return visibleNodes.toList();
  }

  Widget _buildTreeNode(ConversationTreeNode node) {
    final isSelected = _selectedNodes.contains(node.id);
    final isExpanded = node.isExpanded;
    final hasChildren = node.children.isNotEmpty;
    // All non-root nodes are interaction nodes (they represent User-AI message pairs)
    final isInteraction = node.id != 'root';
    final isRoot = node.id == 'root';
    // Check if this node belongs to the highlighted conversation
    final isHighlighted =
        _highlightedConversationIds.isNotEmpty &&
        (_nodeToConversationIds[node.id]?.any(
              (id) => _highlightedConversationIds.contains(id),
            ) ??
            false);

    return Material(
      color: isSelected
          ? Theme.of(context).colorScheme.primaryContainer
          : isHighlighted
          ? Theme.of(context).colorScheme.primaryContainer
          : isRoot
          ? Theme.of(context).colorScheme.surfaceContainerHighest
          : Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      elevation: isSelected || isHighlighted ? 4 : 1,
      child: GestureDetector(
        onTap: () {
          if (_isMultiSelectMode && !isRoot) {
            _toggleNodeSelection(node.id);
          } else if (isInteraction) {
            _selectInteraction(node);
          }
        },
        onLongPress: () {
          if (isInteraction && !isRoot) {
            if (!_isMultiSelectMode) {
              _toggleMultiSelectMode();
            }
            _toggleNodeSelection(node.id);
          }
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 220, // Slightly wider for better text display
            minWidth: 140, // Minimum width to ensure readability
          ),
          child: Container(
            padding: const EdgeInsets.all(3.0),
            decoration: BoxDecoration(
              border: Border.all(
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : isHighlighted
                    ? Theme.of(context).colorScheme.primary.withOpacity(0.5)
                    : isRoot
                    ? Theme.of(context).colorScheme.outline
                    : Theme.of(context).colorScheme.outline.withOpacity(0.3),
                width: isSelected ? 2 : (isHighlighted ? 1.5 : 1),
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : isHighlighted
                  ? [
                      BoxShadow(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withOpacity(0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top row: Icons only
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Left side icons
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Expand/collapse button
                        if (hasChildren && !isRoot)
                          IconButton(
                            icon: Icon(
                              isExpanded
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: 14,
                            ),
                            onPressed: () => _toggleNodeExpansion(node.id),
                            constraints: const BoxConstraints(
                              minWidth: 20,
                              minHeight: 20,
                            ),
                            padding: EdgeInsets.zero,
                          )
                        else if (!isRoot)
                          const SizedBox(width: 20),
                        // Node type icon
                        Icon(
                          isRoot
                              ? Icons.account_tree
                              : isInteraction
                              ? Icons.chat_bubble_outline
                              : Icons.folder_outlined,
                          size: 14,
                          color: isRoot
                              ? Theme.of(context).colorScheme.primary
                              : isInteraction
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.secondary,
                        ),
                      ],
                    ),
                    // Right side: Menu button
                    if (isInteraction && !isRoot)
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, size: 14),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 20,
                          minHeight: 20,
                        ),
                        onSelected: (value) {
                          if (value == 'delete') {
                            _deleteInteraction(node);
                          } else if (value == 'fork') {
                            _forkInteraction(node);
                          }
                        },
                        itemBuilder: (popupContext) {
                          final popupL10n = AppLocalizations.of(popupContext)!;
                          return [
                            PopupMenuItem(
                              value: 'fork',
                              child: Row(
                                children: [
                                  const Icon(Icons.call_split, size: 16),
                                  const SizedBox(width: 8),
                                  Text(popupL10n.forkFromHere),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  const Icon(Icons.delete, size: 16),
                                  const SizedBox(width: 8),
                                  Text(popupL10n.deleteInteractionAction),
                                ],
                              ),
                            ),
                          ];
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                // Bottom row: Text content
                Padding(
                  padding: const EdgeInsets.only(left: 10, right: 2),
                  child: Text(
                    node.summary,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: isRoot ? FontWeight.bold : FontWeight.normal,
                    ),
                    softWrap: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConversationDetails() {
    final l10n = AppLocalizations.of(context)!;

    if (_selectedConversationId == null) {
      return Container(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.chat_bubble_outline,
                size: 48,
                color: Colors.grey,
              ),
              const SizedBox(height: 16),
              Text(
                l10n.selectInteractionToViewDetails,
                style: const TextStyle(fontSize: 16, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    // If a specific message is selected, show just that message
    if (_selectedMessage != null) {
      return _buildMessageDetails(_selectedMessage!);
    }

    return FutureBuilder<ConversationWithMessages?>(
      future: _conversationService.getConversationWithFullHistory(
        _selectedConversationId!,
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData) {
          return Center(child: Text(l10n.errorLoadingData));
        }

        final conversationWithMessages = snapshot.data!;
        final conversation = conversationWithMessages.conversation;
        final messages = conversationWithMessages.messages;

        return Column(
          children: [
            // Sticky Header with title, actions, and close button
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8.0,
                vertical: 4.0,
              ),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withOpacity(0.3),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      conversation.title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () async {
                      await Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (context) => ConversationChatScreen(
                            conversationId: conversation.id,
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.chat, size: 14),
                    label: Text(
                      l10n.open,
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(
                    onPressed: () async {
                      // Find the node for this conversation to fork from
                      if (_selectedMessage != null) {
                        final tempNode = ConversationTreeNode(
                          id: 'temp_${_selectedMessage!.id}',
                          conversationId: _selectedMessage!.conversationId,
                          messageId: _selectedMessage!.id,
                          summary: l10n.forkFromHere,
                          level: 1,
                          createdAt: _selectedMessage!.timestamp,
                        );
                        _forkInteraction(tempNode);
                      }
                    },
                    icon: const Icon(Icons.call_split, size: 14),
                    label: Text(
                      l10n.fork,
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () {
                      setState(() {
                        _selectedConversationId = null;
                        _selectedMessage = null;
                      });
                    },
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    padding: EdgeInsets.zero,
                    tooltip: l10n.close,
                  ),
                ],
              ),
            ),
            // Scrollable content
            Expanded(
              child: ListView.builder(
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index];
                  final isSelected = _selectedMessage?.id == message.id;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8.0),
                    color: isSelected
                        ? Theme.of(context).colorScheme.primaryContainer
                        : null,
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          _selectedMessage = message;
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  message.type == MessageType.user
                                      ? Icons.person
                                      : Icons.smart_toy,
                                  size: 16,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  message.type == MessageType.user
                                      ? l10n.user
                                      : l10n.ai,
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                                const Spacer(),
                                Text(
                                  _formatTimestamp(message.timestamp),
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            message.type == MessageType.user
                                ? Text(
                                    message.content,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                    maxLines: isSelected ? null : 3,
                                    overflow: isSelected
                                        ? null
                                        : TextOverflow.ellipsis,
                                  )
                                : GptMarkdown(message.content),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMessageDetails(ConversationMessage message) {
    return FutureBuilder<List<ConversationMessage>>(
      future: _getInteractionMessages(_selectedConversationId!, message.id),
      builder: (futureContext, snapshot) {
        final futureL10n = AppLocalizations.of(futureContext)!;

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return Center(child: Text(futureL10n.errorLoadingData));
        }

        final messages = snapshot.data!;
        final userMessage = messages.firstWhere(
          (m) => m.type == MessageType.user,
        );
        final aiMessage = messages.firstWhere((m) => m.type == MessageType.ai);

        return Column(
          children: [
            // Sticky Header
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8.0,
                vertical: 4.0,
              ),
              decoration: BoxDecoration(
                color: Theme.of(
                  futureContext,
                ).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(
                      futureContext,
                    ).colorScheme.outline.withOpacity(0.3),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.chat,
                    size: 16,
                    color: Theme.of(futureContext).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      futureL10n.interaction,
                      style: Theme.of(futureContext).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () async {
                      await Navigator.of(futureContext).pushReplacement(
                        MaterialPageRoute(
                          builder: (context) => ConversationChatScreen(
                            conversationId: message.conversationId,
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.chat, size: 14),
                    label: Text(
                      futureL10n.open,
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(
                    onPressed: () {
                      final tempNode = ConversationTreeNode(
                        id: 'temp_${message.id}',
                        conversationId: message.conversationId,
                        messageId: message.id,
                        summary: futureL10n.forkFromHere,
                        level: 1,
                        createdAt: message.timestamp,
                      );
                      _forkInteraction(tempNode);
                    },
                    icon: const Icon(Icons.call_split, size: 14),
                    label: Text(
                      futureL10n.fork,
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _selectedConversationId = null;
                        _selectedMessage = null;
                      });
                    },
                    icon: const Icon(Icons.close, size: 16),
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    padding: EdgeInsets.zero,
                    tooltip: futureL10n.close,
                  ),
                ],
              ),
            ),
            // Scrollable content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // User Question Card
                    Card(
                      margin: const EdgeInsets.only(bottom: 12.0),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.person,
                                  size: 20,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'User',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                ),
                                const Spacer(),
                                Text(
                                  _formatTimestamp(userMessage.timestamp),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              userMessage.content,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ],
                        ),
                      ),
                    ),

                    // AI Answer Card
                    Card(
                      margin: const EdgeInsets.only(bottom: 16.0),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.smart_toy,
                                  size: 20,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.secondary,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'AI',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.secondary,
                                      ),
                                ),
                                const Spacer(),
                                Text(
                                  _formatTimestamp(aiMessage.timestamp),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            GptMarkdown(aiMessage.content),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // Helper method to get both user and AI messages for an interaction
  Future<List<ConversationMessage>> _getInteractionMessages(
    String conversationId,
    String aiMessageId,
  ) async {
    final messages = await _databaseService.getConversationMessages(
      conversationId,
    );
    final aiMessage = messages.firstWhere((m) => m.id == aiMessageId);

    // Find the user message that precedes this AI message
    final aiIndex = messages.indexOf(aiMessage);
    if (aiIndex > 0) {
      final userMessage = messages[aiIndex - 1];
      if (userMessage.type == MessageType.user) {
        return [userMessage, aiMessage];
      }
    }

    // Fallback: return just the AI message
    return [aiMessage];
  }

  String _formatTimestamp(DateTime timestamp) {
    final l10n = AppLocalizations.of(context)!;
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return l10n.justNow;
    }
  }
}
