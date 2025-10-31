import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../models/conversation.dart';
import '../models/note.dart';
import '../models/mcp_endpoint.dart';
import '../services/conversation_service.dart';
import '../services/ai_service.dart';
import '../services/logger_service.dart';
import '../services/prompts/ai_prompts.dart';
import '../services/mcp_service.dart';
import '../services/mcp_tool_integration_service.dart';
import '../services/model_selector.dart';
import '../models/model_type.dart';
import '../l10n/app_localizations.dart';
import 'note_selection_dialog.dart';
import 'note_detail_screen.dart';
import 'conversation_tree_screen.dart';
import 'note_action_app_selection_screen.dart';
import '../widgets/add_note_dialog.dart';

class ConversationChatScreen extends StatefulWidget {
  final String? conversationId;
  final List<String>? initialNoteIds;

  const ConversationChatScreen({
    Key? key,
    this.conversationId,
    this.initialNoteIds,
  }) : super(key: key);

  @override
  State<ConversationChatScreen> createState() => _ConversationChatScreenState();
}

class _ConversationChatScreenState extends State<ConversationChatScreen> {
  final ConversationService _conversationService = ConversationService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  Conversation? _conversation;
  List<ConversationMessage> _messages = [];
  List<Note> _notes = [];
  bool _isLoading = false;
  bool _isSending = false;
  bool _isAborting = false;
  String? _currentRequestId;
  Set<String> _cancelledRequestIds = {};
  List<PlatformFile> _attachedFiles = [];
  
  // MCP support
  List<McpEndpoint> _availableMcpEndpoints = [];
  Set<String> _selectedMcpEndpointIds = {};
  Map<String, List<McpTool>> _mcpToolsByEndpoint = {};
  bool _isMcpPanelExpanded = false; // Collapsed by default

  bool _hasInitialized = false;

  @override
  void initState() {
    super.initState();
    _loadMcpEndpoints();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasInitialized) {
      _hasInitialized = true;
      _initializeConversation();
    }
  }



  Future<void> _initializeConversation() async {
    setState(() => _isLoading = true);

    try {
      if (widget.conversationId != null) {
        // Load existing conversation
        final conversationWithMessages = await _conversationService.getConversationWithFullHistory(widget.conversationId!);
        if (conversationWithMessages != null) {
          _conversation = conversationWithMessages.conversation;
          _messages = conversationWithMessages.messages;
          _notes = await _conversationService.getConversationNotes(widget.conversationId!);
          
          // Validate note references and show alert if any are missing
          final missingNoteIds = await _conversationService.validateConversationNotes(widget.conversationId!);
          if (missingNoteIds.isNotEmpty && mounted) {
            _showMissingNotesAlert(missingNoteIds);
          }
        }
      } else {
        // This is a new conversation, so we'll load any initial notes but not create the
        // conversation entity until the first message is sent.
        if (widget.initialNoteIds != null && widget.initialNoteIds!.isNotEmpty) {
          _notes = await _conversationService.getNotesByIds(widget.initialNoteIds!);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error initializing conversation: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadMcpEndpoints() async {
    try {
      final endpoints = await McpService.getEndpoints();
      // Only show endpoints that have cached tools
      final endpointsWithTools = <McpEndpoint>[];
      for (final endpoint in endpoints) {
        final cache = await McpService.getCachedTools(endpoint.id);
        if (cache != null && cache.tools.isNotEmpty) {
          endpointsWithTools.add(endpoint);
        }
      }
      setState(() {
        _availableMcpEndpoints = endpointsWithTools;
      });
    } catch (e) {
      LoggerService.error('Error loading MCP endpoints: $e');
    }
  }

  Future<void> _updateMcpTools() async {
    if (_selectedMcpEndpointIds.isEmpty) {
      setState(() {
        _mcpToolsByEndpoint = {};
      });
      return;
    }

    try {
      final toolsByEndpoint = await McpToolIntegrationService.getAvailableTools(
        _selectedMcpEndpointIds.toList(),
      );
      setState(() {
        _mcpToolsByEndpoint = toolsByEndpoint;
      });
      LoggerService.info('Updated MCP tools: ${toolsByEndpoint.length} services, ${toolsByEndpoint.values.fold(0, (sum, tools) => sum + tools.length)} tools');
    } catch (e) {
      LoggerService.error('Error updating MCP tools: $e');
    }
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.isEmpty && _attachedFiles.isEmpty) return;

    final content = _messageController.text;
    final attachments = List<PlatformFile>.from(_attachedFiles);
    _messageController.clear();
    setState(() {
      _attachedFiles.clear();
      _isSending = true;
    });

    try {
      // If this is the first message, create the conversation
      if (_conversation == null) {
        final l10n = AppLocalizations.of(context)!;
        final title = content.isNotEmpty ? content : l10n.newConversation;
        final newConversation = await _conversationService.createConversation(
          title: title.length > 50 ? '${title.substring(0, 50)}...' : title,
          noteIds: widget.initialNoteIds ?? [],
        );
        if (!mounted) return;
        setState(() {
          _conversation = newConversation;
        });
      }

      // Add the user's message
      final userMessage = await _conversationService.addUserMessage(
        conversationId: _conversation!.id,
        content: content,
        attachmentPaths: attachments.map((f) => f.path!).toList(),
      );
      if (!mounted) return;

      setState(() {
        _messages.add(userMessage);
      });
      _scrollToBottom();

      // Generate AI response
      final requestId = DateTime.now().millisecondsSinceEpoch.toString();
      _currentRequestId = requestId;

      final aiResponseContent = await _generateAIResponse(content, attachments, requestId);

      if (_cancelledRequestIds.contains(requestId)) {
        _cancelledRequestIds.remove(requestId);
        return; // Stop processing if the request was cancelled
      }

      final aiMessage = await _conversationService.addAIResponse(
        conversationId: _conversation!.id,
        content: aiResponseContent,
      );
      if (!mounted) return;

      setState(() {
        _messages.add(aiMessage);
      });
      _scrollToBottom();

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error sending message: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _currentRequestId = null;
        });
      }
    }
  }

  Future<void> _startNewConversation() async {
    final l10n = AppLocalizations.of(context)!;
    final newConversation = await _conversationService.createConversation(
      title: l10n.newConversation,
    );
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => ConversationChatScreen(
            conversationId: newConversation.id,
          ),
        ),
      );
    }
  }

  Future<void> _abortRequest() async {
    if (!_isSending || _currentRequestId == null) return;
    
    setState(() {
      _isAborting = true;
    });
    
    // Mark the current request as cancelled
    _cancelledRequestIds.add(_currentRequestId!);
    
    // Show feedback to user
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cancelling AI request...'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    
    // Wait a moment for the request to be cancelled
    await Future.delayed(const Duration(milliseconds: 500));
    
    setState(() {
      _isSending = false;
      _isAborting = false;
      _currentRequestId = null;
    });
  }

  Future<String> _generateAIResponse(String userMessage, List<PlatformFile> attachedFiles, String requestId) async {
    try {
      // Check if this specific request was cancelled before starting
      if (_cancelledRequestIds.contains(requestId)) {
        throw Exception('Request cancelled by user');
      }

      // Build messages array with system, user, and assistant roles
      final messages = <Map<String, dynamic>>[];
      
      // Build system message with note context
      final systemContent = await _buildSystemMessage(_notes);
      if (systemContent.isNotEmpty) {
        messages.add({
          'role': 'system',
          'content': systemContent,
        });
      }
      
      // Add conversation history (_messages already includes the current user message)
      // since it was added to _messages before calling _generateAIResponse
      for (final msg in _messages) {
        messages.add({
          'role': msg.type == MessageType.user ? 'user' : 'assistant',
          'content': msg.content,
        });
      }

      // Check if this specific request was cancelled before AI generation
      if (_cancelledRequestIds.contains(requestId)) {
        throw Exception('Request cancelled by user');
      }

      // Check if MCP tools are available
      if (_mcpToolsByEndpoint.isNotEmpty) {
        return await _generateWithMcpTools(messages, attachedFiles, requestId);
      } else {
        // Use AI service's answerNoteQuestion method which handles note context and attachments
        final response = await AIService.answerNoteQuestionWithMessages(
          messages,
          _notes,
          attachedFiles: attachedFiles.isNotEmpty ? attachedFiles : null,
          useOwnKnowledge: true,
        );
        
        // Check if this specific request was cancelled after AI response
        if (_cancelledRequestIds.contains(requestId)) {
          throw Exception('Request cancelled by user');
        }
        
        return response;
      }
    } catch (e) {
      if (_cancelledRequestIds.contains(requestId)) {
        // Don't show error for cancelled requests
        rethrow;
      }
      LoggerService.error('Error generating AI response: $e', error: e);
      return 'I apologize, but I encountered an error while generating a response. Please try again.';
    }
  }

  Future<String> _buildSystemMessage(List<Note> notes) async {
    if (notes.isEmpty) {
      return '''You are a helpful assistant that can answer questions and help with tasks.

${AIPrompts.mathFormulaGuidelines}

''';
    }
    
    // Build note context for system message
    final contextText = await AIService.buildContextFromNotes(notes);
    
    // Build system message from context (without a specific question)
    return '''You are a helpful assistant that can answer questions and help with tasks.

Based on the following notes and their linked relationships, please answer user questions.

Context Notes (including linked notes and their relationships):
$contextText

Please provide comprehensive answers using both the information in the notes and your own knowledge.
Consider the relationships between the NOTES in the context:
- The hierarchical structure shown (indented linked notes)
- The relationship types between notes (answers, causality, related, subnote, parent, references, expands, contradicts, supports)
- How linked notes might provide additional context or clarification
- The direction of relationships (→ for outgoing, ← for incoming)

${AIPrompts.mathFormulaGuidelines}

You may supplement the information from the notes with your own knowledge to provide a more complete and helpful answer.
''';
  }

  Future<String> _generateWithMcpTools(List<Map<String, dynamic>> messages, List<PlatformFile> attachedFiles, String requestId) async {
    try {
      // Check if this specific request was cancelled before starting
      if (_cancelledRequestIds.contains(requestId)) {
        throw Exception('Request cancelled by user');
      }

      // Add MCP tool information to system message if present, otherwise create one
      final mcpPrompt = McpToolIntegrationService.buildMcpSystemPrompt(_mcpToolsByEndpoint);
      final messagesWithMcp = <Map<String, dynamic>>[];
      
      // Find or create system message
      bool hasSystemMessage = false;
      for (final msg in messages) {
        if (msg['role'] == 'system') {
          // Append MCP prompt to existing system message
          messagesWithMcp.add({
            'role': 'system',
            'content': '${msg['content']}\n\n$mcpPrompt',
          });
          hasSystemMessage = true;
        } else {
          messagesWithMcp.add(msg);
        }
      }
      
      // If no system message exists, add one with MCP prompt
      if (!hasSystemMessage) {
        messagesWithMcp.insert(0, {
          'role': 'system',
          'content': mcpPrompt,
        });
      }
      
      // Get call_tool function definition based on current model type
      final currentModelType = ModelSelector.instance.currentModelType;
      final callToolFunction = currentModelType == ModelType.openaiCompatible
          ? McpToolIntegrationService.getCallToolFunctionForOpenAI(_mcpToolsByEndpoint)
          : McpToolIntegrationService.getCallToolFunctionForGemini(_mcpToolsByEndpoint);
      
      LoggerService.info('Starting MCP-enabled conversation with ${_mcpToolsByEndpoint.length} services');
      
      // Tool calling loop - max 5 iterations to prevent infinite loops
      const maxIterations = 10;
      List<Map<String, dynamic>> currentMessages = List.from(messagesWithMcp);
      final conversationParts = <String>[];
      
      for (int iteration = 0; iteration < maxIterations; iteration++) {
        // Check if this specific request was cancelled before each iteration
        if (_cancelledRequestIds.contains(requestId)) {
          throw Exception('Request cancelled by user');
        }

        LoggerService.debug('MCP iteration ${iteration + 1}/$maxIterations');
        
        // Call AI with tools
        final response = await ModelSelector.instance.generateWithToolsAndMessages(
          currentMessages,
          attachedFiles,
          [callToolFunction],
        );
        
        // Check if this specific request was cancelled after AI response
        if (_cancelledRequestIds.contains(requestId)) {
          throw Exception('Request cancelled by user');
        }
        
        final textResponse = response['text'] as String?;
        final functionCalls = response['function_calls'] as List?;
        
        if (functionCalls != null && functionCalls.isNotEmpty) {
          LoggerService.info('AI requested ${functionCalls.length} tool call(s)');
          
          // Execute all function calls
          final toolResults = <String>[];
          for (final functionCall in functionCalls) {
            // Check if this specific request was cancelled before each tool execution
            if (_cancelledRequestIds.contains(requestId)) {
              throw Exception('Request cancelled by user');
            }

            final functionName = functionCall['name'] as String;
            final args = functionCall['args'] as Map<String, dynamic>;
            
            LoggerService.debug('Processing function call', error: {
              'functionName': functionName,
              'args': args,
            });
            
            if (functionName == 'call_tool') {
              final parsedArgs = McpToolIntegrationService.parseCallToolArguments(args);
              if (parsedArgs != null) {
                final serviceName = parsedArgs['service_name'] as String;
                final toolName = parsedArgs['tool_name'] as String;
                final params = parsedArgs['params'] as Map<String, dynamic>;
                
                LoggerService.info('Executing: $serviceName.$toolName');
                LoggerService.debug('Tool parameters', error: params);
                
                try {
                  final result = await McpToolIntegrationService.executeToolCall(
                    serviceName: serviceName,
                    toolName: toolName,
                    parameters: params,
                    enabledEndpointIds: _selectedMcpEndpointIds.toList(),
                  );
                  
                  toolResults.add('Tool: $serviceName.$toolName\nResult: $result');
                  conversationParts.add('[Tool executed: $serviceName.$toolName]');
                } catch (e) {
                  LoggerService.error('Tool execution failed: $e');
                  toolResults.add('Tool: $serviceName.$toolName\nError: $e');
                }
              } else {
                LoggerService.error('Failed to parse call_tool arguments', error: {'args': args});
              }
            }
          }
          
          // If we have tool results, continue the conversation with them
          if (toolResults.isNotEmpty) {
            // Add assistant response with function call
            currentMessages = List.from(currentMessages);
            
            // Add tool results - format depends on model type
            final currentModelType = ModelSelector.instance.currentModelType;
            if (currentModelType == ModelType.openaiCompatible) {
              // OpenAI format: assistant message with tool_calls, then tool messages with results
              // Store function calls with their results for proper ID mapping
              final toolCallsWithResults = <Map<String, dynamic>>[];
              for (int i = 0; i < functionCalls.length && i < toolResults.length; i++) {
                final functionCall = functionCalls[i];
                final functionName = functionCall['name'] as String;
                final toolCallId = 'call_${DateTime.now().millisecondsSinceEpoch}_${functionName}_$i';
                
                toolCallsWithResults.add({
                  'id': toolCallId,
                  'function_call': functionCall,
                  'result': toolResults[i],
                });
              }
              
              // Add assistant message with tool calls
              currentMessages.add({
                'role': 'assistant',
                'content': textResponse ?? '',
                'function_calls': functionCalls,
                'tool_calls_with_results': toolCallsWithResults, // Store for ID mapping
              });
              
              // Add tool result messages
              for (final toolCallWithResult in toolCallsWithResults) {
                currentMessages.add({
                  'role': 'tool',
                  'tool_call_id': toolCallWithResult['id'],
                  'name': toolCallWithResult['function_call']['name'],
                  'content': toolCallWithResult['result'],
                });
              }
            } else {
              // Gemini format: tool results are included differently
              // For Gemini, we add tool results as a continuation in the user role
              currentMessages.add({
                'role': 'assistant',
                'content': textResponse ?? '',
                'function_calls': functionCalls,
              });
              final toolResultsText = toolResults.join('\n\n');
              currentMessages.add({
                'role': 'user',
                'content': 'Tool execution results:\n\n$toolResultsText\n\nBased on these results, provide your response.',
              });
            }
            continue; // Go to next iteration
          }
        }
        
        // If we get here, either no function calls or we have a text response
        if (textResponse != null && textResponse.isNotEmpty) {
          if (conversationParts.isNotEmpty) {
            return '${conversationParts.join('\n')}\n\n$textResponse';
          }
          return textResponse;
        }
        
        // If no text and no function calls, something went wrong
        LoggerService.warning('No text response and no function calls in iteration ${iteration + 1}');
        break;
      }
      
      // If we exhausted iterations, return what we have
      LoggerService.warning('Reached maximum tool calling iterations');
      return conversationParts.isEmpty 
          ? 'I apologize, but I was unable to complete the task after multiple attempts.'
          : conversationParts.join('\n');
          
    } catch (e) {
      if (_cancelledRequestIds.contains(requestId)) {
        // Don't show error for cancelled requests
        rethrow;
      }
      LoggerService.error('Error in MCP tool calling: $e', error: e);
      return 'I apologize, but I encountered an error while using external tools. Error: $e';
    }
  }

  Future<void> _attachFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: true, // Load file data into memory
      );

      if (result != null) {
        setState(() {
          _attachedFiles.addAll(result.files);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking files: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _captureImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      
      final XFile? image = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        // Convert XFile to PlatformFile for consistency with existing attachment system
        final file = File(image.path);
        final bytes = await file.readAsBytes();
        
        final platformFile = PlatformFile(
          name: image.name,
          size: bytes.length,
          bytes: bytes,
          path: image.path,
        );
        
        setState(() {
          _attachedFiles.add(platformFile);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error capturing image: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _removeAttachedFile(int index) {
    setState(() {
      _attachedFiles.removeAt(index);
    });
  }

  IconData _getFileIcon(String? extension) {
    if (extension == null) return Icons.insert_drive_file;
    
    switch (extension.toLowerCase()) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'txt':
        return Icons.text_snippet;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'bmp':
      case 'webp':
        return Icons.image;
      case 'mp4':
      case 'avi':
      case 'mov':
      case 'wmv':
        return Icons.videocam;
      case 'mp3':
      case 'wav':
      case 'flac':
        return Icons.audiotrack;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.archive;
      default:
        return Icons.insert_drive_file;
    }
  }

  Widget _buildAttachedFilesSection() {
    if (_attachedFiles.isEmpty) return const SizedBox.shrink();
    
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.attach_file, size: 16, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
              const SizedBox(width: 8),
              Text(
                'Attached Files (${_attachedFiles.length})',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...List.generate(_attachedFiles.length, (index) {
            final file = _attachedFiles[index];
            return Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(
                    _getFileIcon(file.extension),
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      file.name,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.close, 
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                    ),
                    onPressed: () => _removeAttachedFile(index),
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildMcpSelectionSection() {
    final l10n = AppLocalizations.of(context)!;
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header - clickable to toggle expansion
          InkWell(
            onTap: () {
              setState(() {
                _isMcpPanelExpanded = !_isMcpPanelExpanded;
              });
            },
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                Icon(
                  Icons.cloud_sync,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                ),
                const SizedBox(width: 8),
                  Text(
                    l10n.mcpTools,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                    ),
                  ),
                if (_selectedMcpEndpointIds.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${_selectedMcpEndpointIds.length} ${l10n.active}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                // Chevron icon that rotates based on expansion state
                AnimatedRotation(
                  turns: _isMcpPanelExpanded ? 0 : 0.5,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                  ),
                ),
              ],
            ),
          ),
          // Expandable content
          if (_isMcpPanelExpanded) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _availableMcpEndpoints.map((endpoint) {
                final isSelected = _selectedMcpEndpointIds.contains(endpoint.id);
                return FilterChip(
                  label: Text(endpoint.name),
                  selected: isSelected,
                  onSelected: (selected) async {
                    setState(() {
                      if (selected) {
                        _selectedMcpEndpointIds.add(endpoint.id);
                      } else {
                        _selectedMcpEndpointIds.remove(endpoint.id);
                      }
                    });
                    await _updateMcpTools();
                  },
                  avatar: Icon(
                    Icons.cloud,
                    size: 16,
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                  ),
                );
              }).toList(),
            ),
            if (_mcpToolsByEndpoint.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                l10n.toolsAvailable(_mcpToolsByEndpoint.values.fold<int>(0, (sum, tools) => sum + tools.length)),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _addResponseToNote(String responseContent) async {
    try {
      // Show the unified add note dialog
      final createdNotes = await AddNoteDialog.show(
        context: context,
        content: responseContent,
        contextNotes: _notes,
      );
      
      // If notes were created through AI, show success message with view action
      if (createdNotes != null && createdNotes.isNotEmpty && mounted) {
        final firstNote = createdNotes.first;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              createdNotes.length == 1
                  ? 'Note "${firstNote.title}" created successfully'
                  : '${createdNotes.length} notes created successfully',
            ),
            backgroundColor: Colors.green,
            action: SnackBarAction(
              label: 'View',
              onPressed: () {
                // Navigate to the first created note
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => NoteDetailScreen(note: firstNote),
                  ),
                );
              },
            ),
          ),
        );
      }
    } catch (e) {
      LoggerService.error('Error creating note from AI response: $e', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating note: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _forkConversation(String messageId) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fork Conversation'),
        content: const Text('Fork this conversation?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Fork'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        final forkedConversation = await _conversationService.forkConversation(
          originalConversationId: _conversation!.id,
          forkFromMessageId: messageId,
          newTitle: 'Forked conversation',
        );

        // Navigate to the forked conversation
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ConversationChatScreen(
              conversationId: forkedConversation.id,
            ),
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error forking conversation: $e')),
        );
      }
    }
  }

  Future<void> _showNoteSelection() async {
    final l10n = AppLocalizations.of(context)!;
    final selectedNotes = await showDialog<List<Note>>(
      context: context,
      builder: (context) => NoteSelectionDialog(
        onNotesSelected: (notes) => Navigator.of(context).pop(notes),
        title: l10n.selectNotesToAddToContext,
      ),
    );

    if (selectedNotes != null && selectedNotes.isNotEmpty) {
      final noteIds = selectedNotes.map((note) => note.id).toList();
      await _conversationService.addNotesToConversation(_conversation!.id, noteIds);
      // Reload all notes from the conversation to ensure we have the complete list
      final updatedNotes = await _conversationService.getConversationNotes(_conversation!.id);
      setState(() {
        _notes = updatedNotes;
      });
    }
  }

  Future<void> _showNotesAndContext() async {
    final l10n = AppLocalizations.of(context)!;
    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, dialogSetState) => AlertDialog(
          title: Text(l10n.notesAndContext),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Notes section
                Text(
                  '${l10n.notes} (${_notes.length})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: _notes.length,
                    itemBuilder: (context, index) {
                      final note = _notes[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: const Icon(Icons.note, size: 20),
                          title: Text(
                            note.title,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          subtitle: Text(
                            note.content.length > 100 
                                ? '${note.content.substring(0, 100)}...'
                                : note.content,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () async {
                              // Optimistically update UI
                              setState(() {
                                _notes.removeWhere((n) => n.id == note.id);
                              });
                              dialogSetState(() {});
                              try {
                                await _conversationService.removeNotesFromConversation(
                                  _conversation!.id,
                                  [note.id],
                                );
                              } catch (_) {
                                // If removal fails, refresh from service to reflect truth
                                final updatedNotes = await _conversationService.getConversationNotes(_conversation!.id);
                                if (mounted) {
                                  setState(() {
                                    _notes = updatedNotes;
                                  });
                                  dialogSetState(() {});
                                }
                              }
                            },
                          ),
                          onTap: () {
                            Navigator.of(dialogContext).pop();
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => NoteDetailScreen(note: note),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                // Action buttons
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        _showNoteSelection();
                      },
                      icon: const Icon(Icons.add, size: 16),
                      label: Text(l10n.addNotes),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () async {
                        if (_notes.isEmpty) return;
                        // Optimistic clear
                        setState(() {
                          _notes.clear();
                        });
                        dialogSetState(() {});
                        await _clearAllNotes();
                      },
                      icon: const Icon(Icons.clear_all, size: 16),
                      label: Text(l10n.clearAllNotes),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.close),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _removeNote(Note note) async {
    await _conversationService.removeNotesFromConversation(_conversation!.id, [note.id]);
    setState(() {
      _notes.removeWhere((n) => n.id == note.id);
    });
  }

  Future<void> _clearAllNotes() async {
    if (_notes.isEmpty) return;
    
    final noteIds = _notes.map((note) => note.id).toList();
    await _conversationService.removeNotesFromConversation(_conversation!.id, noteIds);
    setState(() {
      _notes.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.newConversation),
        ),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_conversation?.title ?? l10n.newConversation),
        actions: [
          IconButton(
            icon: const Icon(Icons.library_books),
            onPressed: _showNoteSelection,
            tooltip: l10n.manageNotes,
          ),
          IconButton(
            icon: const Icon(Icons.account_tree),
            onPressed: () {
              // Navigate to tree view, replacing the chat view, passing current conversation ID for highlighting
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (context) => ConversationTreeScreen(
                    activeConversationId: _conversation?.id,
                  ),
                ),
              );
            },
            tooltip: l10n.viewTree,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'new_conversation') {
                _startNewConversation();
              }
            },
            itemBuilder: (context) => [
              if (_messages.isNotEmpty)
                PopupMenuItem<String>(
                  value: 'new_conversation',
                  child: Text(l10n.newConversation),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Notes summary
          if (_notes.isNotEmpty)
            GestureDetector(
              onTap: () => _showNotesAndContext(),
              child: Container(
                padding: const EdgeInsets.all(8.0),
                color: Theme.of(context).colorScheme.surfaceVariant,
                child: Row(
                  children: [
                    const Icon(Icons.note, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.noteIncluded(_notes.length),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios, size: 12),
                  ],
                ),
              ),
            ),
          // Messages
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16.0),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return _buildMessageCard(message);
              },
            ),
          ),
          // Attached files section
          _buildAttachedFilesSection(),
          // MCP selection section
          if (_availableMcpEndpoints.isNotEmpty) _buildMcpSelectionSection(),
          // Input area
          Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                ),
              ),
            ),
            child: Row(
              children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      enabled: !_isSending || _isAborting,
                      decoration: InputDecoration(
                        hintText: _isAborting ? l10n.cancellingRequest : l10n.typeYourMessage,
                        border: const OutlineInputBorder(),
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.attach_file),
                              onPressed: _isSending ? null : _attachFiles,
                              tooltip: l10n.attachFiles,
                            ),
                            IconButton(
                              icon: const Icon(Icons.camera_alt),
                              onPressed: _isSending ? null : _captureImage,
                              tooltip: l10n.takePhotoAttachment,
                            ),
                          ],
                        ),
                      ),
                      maxLines: null,
                      onSubmitted: (_) => _isSending ? null : _sendMessage(),
                    ),
                  ),
                const SizedBox(width: 8),
                if (_isSending && !_isAborting)
                  _buildAbortButtonWithSpinner()
                else if (_isAborting)
                  IconButton(
                    onPressed: null,
                    icon: const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    tooltip: 'Cancelling...',
                  )
                else
                  IconButton(
                    onPressed: _isSending ? null : _sendMessage,
                    icon: _isSending 
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAbortButtonWithSpinner() {
    final l10n = AppLocalizations.of(context)!;
    
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Rotating border spinner
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.error.withOpacity(0.3),
              ),
            ),
          ),
          // Stop button in the center
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.error,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.error.withOpacity(0.3),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: IconButton(
              onPressed: _abortRequest,
                              icon: const Icon(
                                Icons.stop,
                                color: Colors.white,
                                size: 16,
                              ),
                              tooltip: l10n.cancelAiRequest,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageCard(ConversationMessage message) {
    final l10n = AppLocalizations.of(context)!;
    final isUser = message.type == MessageType.user;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 8.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isUser ? Icons.person : Icons.smart_toy,
                  size: 20,
                  color: isUser 
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.secondary,
                ),
                const SizedBox(width: 8),
                Text(
                  isUser ? l10n.you : l10n.ai,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: isUser 
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.secondary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  _formatTimestamp(message.timestamp),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (!isUser) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.call_split, size: 16),
                    onPressed: () => _forkConversation(message.id),
                    tooltip: l10n.forkConversation,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            if (isUser)
              SelectableText(
                message.content,
                style: Theme.of(context).textTheme.bodyMedium,
              )
            else ...[
              SelectionArea(
                child: GptMarkdown(
                  message.content,
                  onLinkTap: (url, _) {
                    final uri = Uri.tryParse(url);
                    if (uri != null) {
                      canLaunchUrl(uri).then((canLaunch) {
                        if (canLaunch) {
                          launchUrl(uri, mode: LaunchMode.externalApplication);
                        } else {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Could not open link: $url')),
                            );
                          }
                        }
                      });
                    } else {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Invalid URL: $url')),
                        );
                      }
                    }
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  // Bottom-left subtle note action app icon button
                  IconButton(
                    icon: Icon(
                      Icons.apps_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                    ),
                    tooltip: 'Run Note Action App',
                    onPressed: () => _openNoteActionAppsForContent(message.content),
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    padding: EdgeInsets.zero,
                  ),
                  const Spacer(),
                  // Existing right-side actions
                  OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: message.content));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(l10n.messageCopiedToClipboard),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: Text(l10n.copy),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _addResponseToNote(message.content),
                    icon: const Icon(Icons.note_add, size: 16),
                    label: Text(l10n.addToNote),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _openNoteActionAppsForContent(String content) {
    final now = DateTime.now();
    // Create a temporary Note object (not saved to DB)
    final tempNote = Note(
      id: 'temp_${now.millisecondsSinceEpoch}',
      title: content.trim().isEmpty
          ? 'AI Message'
          : (content.trim().split('\n').first.length > 60
              ? content.trim().split('\n').first.substring(0, 60)
              : content.trim().split('\n').first),
      content: content,
      type: NoteType.note,
      createdAt: now,
      updatedAt: now,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => NoteActionAppSelectionScreen(
          selectedNotes: [tempNote],
        ),
      ),
    );
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

  void _showMissingNotesAlert(List<String> missingNoteIds) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Missing Notes'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('This conversation references notes that no longer exist:'),
              const SizedBox(height: 8),
              ...missingNoteIds.map((noteId) => Text(
                '• $noteId',
                style: const TextStyle(fontFamily: 'monospace'),
              )),
              const SizedBox(height: 8),
              const Text('These references will be automatically cleaned up.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                // Clean up invalid note references
                await _conversationService.cleanupInvalidNoteReferences();
                // Refresh the conversation to reflect the cleanup
                await _initializeConversation();
              },
              child: const Text('Clean Up'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }



  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

