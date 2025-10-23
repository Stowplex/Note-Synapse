import 'package:flutter/material.dart';
import 'package:graphview/GraphView.dart';
import '../models/conversation.dart';
import '../services/conversation_service.dart';
import '../services/logger_service.dart';
import 'conversation_chat_screen.dart';

class ConversationTreeScreen extends StatefulWidget {
  const ConversationTreeScreen({Key? key}) : super(key: key);

  @override
  State<ConversationTreeScreen> createState() => _ConversTreeScreenState();
}

class _ConversTreeScreenState extends State<ConversationTreeScreen> {
  final ConversationService _conversationService = ConversationService();
  final GraphViewController _graphController = GraphViewController();
  
  ConversationTree? _tree;
  List<String> _selectedNodes = [];
  bool _isLoading = true;
  String? _selectedConversationId;

  @override
  void initState() {
    super.initState();
    _loadTree();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Refresh tree when screen becomes visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshTree();
      }
    });
  }

  Future<void> _loadTree() async {
    setState(() => _isLoading = true);
    
    try {
      _tree = await _conversationService.getConversationTree();
      if (_tree == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No conversations found. Start a new conversation to see the tree.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      LoggerService.error('Error loading conversation tree: $e', error: e);
      if (mounted) {
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No conversations found. Start a new conversation to see the tree.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Tree refreshed successfully'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      LoggerService.error('Error refreshing conversation tree: $e', error: e);
      if (mounted) {
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
    if (node == null) return;

    setState(() {
      final updatedNode = node.copyWith(isExpanded: !node.isExpanded);
      final updatedNodes = Map<String, ConversationTreeNode>.from(_tree!.nodes);
      updatedNodes[nodeId] = updatedNode;
      _tree = _tree!.copyWith(nodes: updatedNodes);
    });

    _conversationService.updateTreeNode(
      nodeId: nodeId,
      isExpanded: !node.isExpanded,
    );
  }

  void _deleteNode(String nodeId) {
    if (_tree == null) return;
    
    final node = _tree!.getNode(nodeId);
    if (node == null || node.conversationId.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Conversation'),
        content: const Text('Are you sure you want to delete this conversation and all its descendants?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _conversationService.deleteConversation(node.conversationId);
              await _loadTree();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _createConversationFromSelected() async {
    if (_selectedNodes.isEmpty) return;

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create New Conversation'),
        content: TextField(
          decoration: const InputDecoration(
            labelText: 'Conversation title',
            hintText: 'Enter a title for the new conversation',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final controller = TextEditingController();
              Navigator.of(context).pop(controller.text);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      try {
        final newConversation = await _conversationService.createConversationFromSelectedNodes(
          selectedNodeIds: _selectedNodes,
          title: result,
        );

        // Clear selected nodes
        setState(() {
          _selectedNodes.clear();
        });

        // Navigate to the new conversation
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ConversationChatScreen(
              conversationId: newConversation.id,
            ),
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating conversation: $e')),
        );
      }
    }
  }

  void _selectConversation(String conversationId) {
    setState(() {
      _selectedConversationId = conversationId;
    });
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
        title: const Text('Conversation Tree'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshTree,
            tooltip: 'Refresh tree',
          ),
          if (_selectedNodes.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: _createConversationFromSelected,
              tooltip: 'Create conversation from selected',
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => const ConversationChatScreen(),
            ),
          );
        },
        child: const Icon(Icons.add),
        tooltip: 'Start new conversation',
      ),
      body: Row(
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
              child: Container(
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                    ),
                  ),
                ),
                child: _buildConversationDetails(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTreeView() {
    return InteractiveViewer(
      constrained: false,
      child: SizedBox(
        width: 1000,
        height: 700,
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
  }

  Graph _buildGraph() {
    final graph = Graph();
    
    if (_tree == null) return graph;

    // Add all nodes
    for (final node in _tree!.nodes.values) {
      graph.addNode(Node.Id(node.id));
    }

    // Add edges
    for (final node in _tree!.nodes.values) {
      if (node.parentId != null) {
        graph.addEdge(Node.Id(node.parentId!), Node.Id(node.id));
      }
    }

    return graph;
  }

  Widget _buildTreeNode(ConversationTreeNode node) {
    final isSelected = _selectedNodes.contains(node.id);
    final isExpanded = node.isExpanded;
    final hasChildren = node.children.isNotEmpty;
    final isConversation = node.conversationId.isNotEmpty;
    final isRoot = node.id == 'root';

    return GestureDetector(
      onTap: () {
        if (isConversation) {
          _selectConversation(node.conversationId);
        }
        if (!isRoot) {
          _toggleNodeSelection(node.id);
        }
      },
      onLongPress: () {
        if (isConversation && !isRoot) {
          _toggleNodeSelection(node.id);
        }
      },
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
                else if (!isRoot)
                  const SizedBox(width: 28),
                Icon(
                  isRoot 
                      ? Icons.account_tree
                      : isConversation 
                          ? Icons.chat_bubble_outline
                          : Icons.folder_outlined,
                  size: 18,
                  color: isRoot
                      ? Theme.of(context).colorScheme.primary
                      : isConversation 
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.secondary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    node.summary,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: isRoot ? FontWeight.bold : FontWeight.normal,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
                if (isConversation && !isRoot) ...[
                  const SizedBox(width: 8),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 16),
                    onSelected: (value) {
                      if (value == 'delete') {
                        _deleteNode(node.id);
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete, size: 16),
                            SizedBox(width: 8),
                            Text('Delete'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            if (isConversation && !isRoot) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Level ${node.level}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
            if (isSelected && !isRoot)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'SELECTED',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationDetails() {
    if (_selectedConversationId == null) {
      return const Center(
        child: Text('Select a conversation to view details'),
      );
    }

    return FutureBuilder<ConversationWithMessages?>(
      future: _conversationService.getConversationWithMessages(_selectedConversationId!),
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

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              conversation.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '${messages.length} messages',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => ConversationChatScreen(
                      conversationId: conversation.id,
                    ),
                  ),
                );
              },
              child: const Text('Open Conversation'),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8.0),
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
                          Text(
                            message.content,
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
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
