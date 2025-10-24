import 'package:flutter/material.dart';
import 'package:graphview/GraphView.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import '../models/conversation.dart';
import '../models/note.dart';
import '../services/conversation_service.dart';
import '../services/database_service.dart';
import '../services/fork_service.dart';
import '../services/logger_service.dart';
import '../services/ai_service.dart';
import 'conversation_chat_screen.dart';

class ConversationTreeScreen extends StatefulWidget {
  const ConversationTreeScreen({Key? key}) : super(key: key);

  @override
  State<ConversationTreeScreen> createState() => _ConversTreeScreenState();
}

class _ConversTreeScreenState extends State<ConversationTreeScreen> {
  final ConversationService _conversationService = ConversationService();
  final DatabaseService _databaseService = DatabaseService();
  final ForkService _forkService = ForkService();
  final GraphViewController _graphController = GraphViewController();
  
  ConversationTree? _tree;
  List<String> _selectedNodes = [];
  bool _isLoading = true;
  String? _selectedConversationId;
  ConversationMessage? _selectedMessage;
  bool _isMultiSelectMode = false;
  bool _hasRefreshedOnce = false;

  @override
  void initState() {
    super.initState();
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
          _refreshTree();
        }
      });
    }
  }

  Future<void> _loadTree() async {
    setState(() => _isLoading = true);
    
    try {
      _tree = await _conversationService.refreshConversationTree();
      if (_tree == null) {
        if (mounted) {
          try {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No conversations found. Start a new conversation to see the tree.'),
              duration: Duration(seconds: 3),
            ),
          );
          } catch (contextError) {
            LoggerService.warning('Could not show info SnackBar: $contextError');
          }
        }
      }
    } catch (e) {
      LoggerService.error('Error loading conversation tree: $e', error: e);
      if (mounted) {
        try {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading tree: ${e.toString()}'),
            backgroundColor: Theme.of(context).colorScheme.error,
            action: SnackBarAction(
              label: 'Retry',
              onPressed: _loadTree,
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

  Future<void> _refreshTree() async {
    setState(() => _isLoading = true);
    
    try {
      _tree = await _conversationService.refreshConversationTree();
      if (_tree == null) {
        if (mounted) {
          try {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No conversations found. Start a new conversation to see the tree.'),
              duration: Duration(seconds: 3),
            ),
          );
          } catch (contextError) {
            LoggerService.warning('Could not show info SnackBar: $contextError');
          }
        }
      } else {
        if (mounted) {
          try {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Tree refreshed successfully'),
              duration: Duration(seconds: 2),
            ),
          );
          } catch (contextError) {
            LoggerService.warning('Could not show success SnackBar: $contextError');
          }
        }
      }
    } catch (e) {
      LoggerService.error('Error refreshing conversation tree: $e', error: e);
      if (mounted) {
        try {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error refreshing tree: ${e.toString()}'),
            backgroundColor: Theme.of(context).colorScheme.error,
            action: SnackBarAction(
              label: 'Retry',
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

    // Update in database
    _conversationService.updateTreeNode(
      nodeId: nodeId,
      isExpanded: !node.isExpanded,
    );
  }


  void _selectInteraction(ConversationTreeNode node) async {
    if (node.messageId == null) return;
    
    try {
      final message = await _conversationService.getConversationMessage(node.messageId!);
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error loading interaction: ${e.toString()}'),
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

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Interaction'),
        content: const Text('Are you sure you want to delete this interaction and all its descendants? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                if (node.messageId != null) {
                  // Get all message IDs in the subtree using tree traversal
                  final messageIdsToDelete = await _conversationService.getMessageIdsFromTreeNode(node);
                  LoggerService.info('Deleting ${messageIdsToDelete.length} messages from tree node: ${node.id}');
                  
                  // Delete all messages in the subtree efficiently
                  await _conversationService.deleteMessagesFromTreeNodes(messageIdsToDelete);
                } else {
                  // Fallback: delete the entire conversation
                  await _conversationService.deleteConversation(node.conversationId);
                }
                // Refresh the tree to reflect the deletion
                _tree = await _conversationService.refreshConversationTree();
                if (mounted) {
                  setState(() {
                    _selectedConversationId = null;
                    _selectedMessage = null;
                  });
                  // Safe to show SnackBar only if widget is still mounted
                  try {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Interaction deleted successfully'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  } catch (contextError) {
                    LoggerService.warning('Could not show success SnackBar: $contextError');
                  }
                }
              } catch (e) {
                LoggerService.error('Error deleting interaction: $e', error: e);
                if (mounted) {
                  // Safe to show SnackBar only if widget is still mounted
                  try {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Error deleting interaction: ${e.toString()}'),
                        backgroundColor: Theme.of(context).colorScheme.error,
                      ),
                    );
                  } catch (contextError) {
                    LoggerService.warning('Could not show error SnackBar: $contextError');
                  }
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _forkInteraction(ConversationTreeNode node) async {
    if (node.messageId == null) return;
    
    try {
      LoggerService.info('Starting fork from interaction: ${node.id}');
      
      // Use the new fork service with context selection
      final newConversation = await _forkService.forkFromMessage(
        context: context,
        forkFromMessageId: node.messageId!,
        suggestedTitle: 'Forked conversation',
      );
      
      if (newConversation != null) {
        LoggerService.info('Forked conversation created: ${newConversation.id}');
        
        if (mounted) {
        try {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Conversation forked successfully'),
              duration: Duration(seconds: 2),
            ),
          );
        } catch (contextError) {
          LoggerService.warning('Could not show success SnackBar: $contextError');
        }
        
        // Navigate to the new conversation
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ConversationChatScreen(conversationId: newConversation.id),
          ),
        );
        
        // Refresh tree when returning from conversation
        if (mounted) {
          LoggerService.info('Refreshing tree after fork');
          await _refreshTree();
        }
        }
      }
    } catch (e) {
      LoggerService.error('Error forking interaction: $e', error: e);
      if (mounted) {
        try {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error forking interaction: ${e.toString()}'),
              backgroundColor: Theme.of(context).colorScheme.error,
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

    try {
      // Create conversation directly with auto-generated title
        final newConversation = await _conversationService.createConversationFromSelectedNodes(
          selectedNodeIds: _selectedNodes,
        title: 'Conversation from ${_selectedNodes.length} selected nodes',
        );

      // Clear selected nodes and exit multi-select mode
        setState(() {
          _selectedNodes.clear();
        _isMultiSelectMode = false;
        });

      // Navigate directly to the new conversation
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ConversationChatScreen(
              conversationId: newConversation.id,
            ),
          ),
        );
      } catch (e) {
      if (mounted) {
        try {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating conversation: $e')),
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

  void _showSaveOptionsDialog() {
    if (_selectedNodes.isEmpty) {
      if (mounted) {
        try {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please select nodes first'),
              duration: Duration(seconds: 2),
            ),
          );
        } catch (contextError) {
          LoggerService.warning('Could not show info SnackBar: $contextError');
        }
      }
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Selected Nodes'),
        content: Text('You have selected ${_selectedNodes.length} node(s). How would you like to save them?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _saveSelectedNodesAsNote();
            },
            child: const Text('Save to Note'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _aiSummarizeAndSaveAsNote();
            },
            child: const Text('AI Summarize and Save to Note'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveSelectedNodesAsNote() async {
    if (_tree == null || _selectedNodes.isEmpty) return;

    try {
      // Collect conversation context from selected nodes (same as createConversationFromSelectedNodes)
      final conversationIds = <String>{};
      final allNoteIds = <String>{};
      
      for (final nodeId in _selectedNodes) {
        final node = _tree!.nodes[nodeId];
        if (node != null && node.conversationId.isNotEmpty) {
          conversationIds.add(node.conversationId);
          
          // Get notes from this conversation
          final conversation = await _databaseService.getConversation(node.conversationId);
          if (conversation != null) {
            allNoteIds.addAll(conversation.noteIds);
          }
        }
      }

      if (conversationIds.isEmpty) {
        throw Exception('No valid conversations selected');
      }

      // Build context messages from conversations (same as _addConversationContext)
      final contextMessages = <String>[];
      
      for (final sourceConvId in conversationIds) {
        final messages = await _databaseService.getConversationMessages(sourceConvId);
        if (messages.isNotEmpty) {
          // Add a header for this conversation's context
          contextMessages.add('--- Context from conversation: ${sourceConvId.substring(0, 8)}... ---');
          
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

      final fullContext = contextMessages.join('\n');

      // Create note with full conversation context
      final note = Note(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: 'Conversation Tree Selection - ${DateTime.now().toString().substring(0, 19)}',
        content: fullContext,
        type: NoteType.note,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        tags: ['conversation-tree'],
      );

      // Save to database
      await _databaseService.insertNote(note);

      if (mounted) {
        try {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Note created successfully'),
              duration: Duration(seconds: 2),
            ),
          );
        } catch (contextError) {
          LoggerService.warning('Could not show success SnackBar: $contextError');
        }
      }
    } catch (e) {
      LoggerService.error('Error creating note: $e', error: e);
      if (mounted) {
        try {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error creating note: ${e.toString()}'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        } catch (contextError) {
          LoggerService.warning('Could not show error SnackBar: $contextError');
        }
      }
    }
  }

  Future<void> _aiSummarizeAndSaveAsNote() async {
    if (_tree == null || _selectedNodes.isEmpty) return;

    try {
      // Show loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('AI is summarizing the selected nodes...'),
            ],
          ),
        ),
      );

      // Collect conversation context from selected nodes (same as createConversationFromSelectedNodes)
      final conversationIds = <String>{};
      final allNoteIds = <String>{};
      
      for (final nodeId in _selectedNodes) {
        final node = _tree!.nodes[nodeId];
        if (node != null && node.conversationId.isNotEmpty) {
          conversationIds.add(node.conversationId);
          
          // Get notes from this conversation
          final conversation = await _databaseService.getConversation(node.conversationId);
          if (conversation != null) {
            allNoteIds.addAll(conversation.noteIds);
          }
        }
      }

      if (conversationIds.isEmpty) {
        throw Exception('No valid conversations selected');
      }

      // Build context messages from conversations (same as _addConversationContext)
      final contextMessages = <String>[];
      
      for (final sourceConvId in conversationIds) {
        final messages = await _databaseService.getConversationMessages(sourceConvId);
        if (messages.isNotEmpty) {
          // Add a header for this conversation's context
          contextMessages.add('--- Context from conversation: ${sourceConvId.substring(0, 8)}... ---');
          
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

      final fullContext = contextMessages.join('\n');

      // Use AI to summarize with full conversation context
      final summarizedContent = await AIService.createNewNotes(
        'Please summarize and organize the following conversation context into a concise, well-structured note. Focus on the key insights, decisions, and important information from these conversations:\n\n$fullContext',
        [], // No context notes needed
      );

      // Close loading dialog
      if (mounted) {
        Navigator.of(context).pop();
      }

      if (summarizedContent.isNotEmpty) {
        final note = summarizedContent.first;
        
        // Add conversation tree tag
        final updatedNote = Note(
          id: note.id,
          title: note.title,
          content: note.content,
          type: note.type,
          createdAt: note.createdAt,
          updatedAt: note.updatedAt,
          subNotes: note.subNotes,
          tags: [...note.tags, 'conversation-tree', 'ai-summarized'],
          attachmentPaths: note.attachmentPaths,
          scheduledAt: note.scheduledAt,
          completeBy: note.completeBy,
          status: note.status,
          completionPercentage: note.completionPercentage,
          pinned: note.pinned,
          isArchived: note.isArchived,
        );

        // Save to database
        await _databaseService.insertNote(updatedNote);

        if (mounted) {
          try {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('AI-summarized note created successfully'),
                duration: Duration(seconds: 2),
              ),
            );
          } catch (contextError) {
            LoggerService.warning('Could not show success SnackBar: $contextError');
          }
        }
      } else {
        throw Exception('AI failed to generate summary');
      }
    } catch (e) {
      // Close loading dialog if still open
      if (mounted) {
        Navigator.of(context).pop();
      }
      
      LoggerService.error('Error creating AI-summarized note: $e', error: e);
      if (mounted) {
        try {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error creating AI-summarized note: ${e.toString()}'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        } catch (contextError) {
          LoggerService.warning('Could not show error SnackBar: $contextError');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_tree == null) {
      return const Scaffold(
        body: Center(child: Text('No conversation tree found')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: _isMultiSelectMode
            ? Text('${_selectedNodes.length} selected')
            : const Text('Conversation Tree'),
        actions: [
          if (_isMultiSelectMode) ...[
          IconButton(
              icon: const Icon(Icons.note_add),
              onPressed: _showSaveOptionsDialog,
              tooltip: 'Save selected nodes as note',
          ),
          if (_selectedNodes.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: _createConversationFromSelected,
                tooltip: 'Create from selected',
              ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _toggleMultiSelectMode,
              tooltip: 'Exit multi-select',
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _refreshTree,
              tooltip: 'Refresh tree',
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
              flex: 1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(context).colorScheme.shadow.withOpacity(0.1),
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
              orientation: BuchheimWalkerConfiguration.ORIENTATION_TOP_BOTTOM,
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
      if (node != null && node.parentId != null && visibleNodes.contains(node.parentId)) {
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

    return GestureDetector(
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
          maxWidth: 200, // Reasonable max width for tree nodes
          minWidth: 120, // Minimum width to ensure readability
        ),
      child: Container(
        padding: const EdgeInsets.all(12.0),
        decoration: BoxDecoration(
          color: isSelected 
              ? Theme.of(context).colorScheme.primaryContainer
              : isRoot
                  ? Theme.of(context).colorScheme.surfaceVariant
                  : Theme.of(context).colorScheme.surface,
          border: Border.all(
            color: isSelected 
                ? Theme.of(context).colorScheme.primary
                : isRoot
                    ? Theme.of(context).colorScheme.outline
                    : Theme.of(context).colorScheme.outline.withOpacity(0.3),
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: isSelected ? [
            BoxShadow(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ] : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // First row: Control widgets (expand, icon, menu)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasChildren && !isRoot)
                  IconButton(
                    icon: Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                    onPressed: () => _toggleNodeExpansion(node.id),
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    padding: EdgeInsets.zero,
                  )
                    else
                  const SizedBox(width: 28),
                Icon(
                  isRoot 
                      ? Icons.account_tree
                          : isInteraction 
                          ? Icons.chat_bubble_outline
                          : Icons.folder_outlined,
                  size: 18,
                  color: isRoot
                      ? Theme.of(context).colorScheme.primary
                          : isInteraction 
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.secondary,
                ),
                  ],
                ),
                if (isInteraction && !isRoot)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 16),
                    onSelected: (value) {
                      if (value == 'delete') {
                        _deleteInteraction(node);
                      } else if (value == 'fork') {
                        _forkInteraction(node);
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'fork',
                        child: Row(
                          children: [
                            Icon(Icons.call_split, size: 16),
                            SizedBox(width: 8),
                            Text('Fork from here'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete, size: 16),
                            SizedBox(width: 8),
                            Text('Delete interaction'),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // Second row: Pure text, left-aligned, multi-line wrapped
            Text(
              node.summary,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: isRoot ? FontWeight.bold : FontWeight.normal,
              ),
              textAlign: TextAlign.left,
              softWrap: true,
              overflow: TextOverflow.visible,
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildConversationDetails() {
    if (_selectedConversationId == null) {
      return Container(
        padding: const EdgeInsets.all(16.0),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                'Select an interaction to view details',
                style: TextStyle(fontSize: 16, color: Colors.grey),
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
      future: _conversationService.getConversationWithFullHistory(_selectedConversationId!),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData) {
          return const Center(child: Text('Conversation not found'));
        }

        final conversationWithMessages = snapshot.data!;
        final conversation = conversationWithMessages.conversation;
        final messages = conversationWithMessages.messages;

        return SingleChildScrollView(
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with close button
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
              conversation.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
            ),
                    ),
                  ),
            Text(
              '${messages.length} messages',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () {
                      setState(() {
                        _selectedConversationId = null;
                        _selectedMessage = null;
                      });
                    },
                    tooltip: 'Close conversation details',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
              ElevatedButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => ConversationChatScreen(
                      conversationId: conversation.id,
                    ),
                  ),
                );
                // Refresh tree when returning from conversation
                if (mounted) {
                  await _refreshTree();
                }
              },
              child: const Text('Open Conversation'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => ConversationChatScreen(
                          conversationId: conversation.id,
                        ),
                      ),
                    );
                    // Refresh tree when returning from conversation
                    if (mounted) {
                      await _refreshTree();
                    }
                  },
                  child: const Text('Fork Conversation'),
                ),
              ],
            ),
            const SizedBox(height: 16),
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
                                message.type == MessageType.user ? Icons.person : Icons.smart_toy,
                                size: 16,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                message.type == MessageType.user ? 'User' : 'AI',
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
                                  style: Theme.of(context).textTheme.bodySmall,
                                  maxLines: isSelected ? null : 3,
                                  overflow: isSelected ? null : TextOverflow.ellipsis,
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
          ),
        );
      },
    );
  }

  Widget _buildMessageDetails(ConversationMessage message) {
    return FutureBuilder<List<ConversationMessage>>(
      future: _getInteractionMessages(_selectedConversationId!, message.id),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No interaction found'));
        }

        final messages = snapshot.data!;
        final userMessage = messages.firstWhere((m) => m.type == MessageType.user);
        final aiMessage = messages.firstWhere((m) => m.type == MessageType.ai);

        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _selectedConversationId = null;
                        _selectedMessage = null;
                      });
                    },
                    icon: const Icon(Icons.close),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Interaction Details',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  Text(
                    _formatTimestamp(aiMessage.timestamp),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              
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
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
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
                            color: Theme.of(context).colorScheme.secondary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'AI',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context).colorScheme.secondary,
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
              
              // Action Buttons
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => ConversationChatScreen(
                            conversationId: message.conversationId,
                          ),
                        ),
                      );
                      // Refresh tree when returning from conversation
                      if (mounted) {
                        await _refreshTree();
                      }
                    },
                    icon: const Icon(Icons.chat),
                    label: const Text('Open Conversation'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () {
                      // Create a temporary node for forking
                      final tempNode = ConversationTreeNode(
                        id: 'temp_${message.id}',
                        conversationId: message.conversationId,
                        messageId: message.id,
                        summary: 'Fork from here',
                        level: 1,
                        createdAt: message.timestamp,
                      );
                      _forkInteraction(tempNode);
                    },
                    icon: const Icon(Icons.call_split),
                    label: const Text('Fork from here'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // Helper method to get both user and AI messages for an interaction
  Future<List<ConversationMessage>> _getInteractionMessages(String conversationId, String aiMessageId) async {
    final messages = await _databaseService.getConversationMessages(conversationId);
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
    final now = DateTime.now();
    final difference = now.difference(timestamp);
    
    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }
}
