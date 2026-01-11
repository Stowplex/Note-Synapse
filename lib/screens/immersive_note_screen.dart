import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../models/conversation.dart';
import '../models/mcp_endpoint.dart';
import '../models/note.dart';
import '../models/attachment.dart';
import '../models/tool_iteration_prompt.dart';
import '../models/user_app.dart';
import '../models/generation_context.dart';
import '../models/model_config.dart';
import '../providers/app_provider.dart';
import '../services/ai_tool_service.dart';
import '../services/approval_service.dart';
import '../services/conversation_service.dart';
import '../services/conversation_ai_engine.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import '../services/mcp_service.dart';
import '../services/mcp_tool_integration_service.dart';
import '../services/conversation_settings_service.dart';
import '../services/model_selector.dart';
import '../services/attachment_preprocessor.dart';
import '../services/prompts/ai_prompts.dart';
import '../services/prompts/note_prompt_builder.dart';
import '../services/prompts/prompt_models.dart';
import '../services/prompts/prompt_configuration_service.dart';
import '../services/prompts/registrations/chat_prompt_configuration.dart';
import '../services/prompts/system_prompt_builder.dart';
import '../services/sql_query_service.dart';
import '../services/user_app_service.dart';
import '../utils/file_type_utils.dart';
import '../utils/file_utils.dart';
import '../utils/native_capture_utils.dart';
import '../utils/synapse_temp_utils.dart';
import '../widgets/approval_dialog.dart';
import '../widgets/interactive_checkbox_markdown.dart';
import '../mixins/note_action_mixin.dart';
import '../widgets/chat_message_action_row.dart';
import '../widgets/active_tool_count_badge.dart';
import '../widgets/drawing_editor.dart';
import 'conversation_tree_screen.dart';
import 'conversation_chat_screen.dart';
import '../widgets/pdf_ai_context_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'note_selection_dialog.dart';
import 'note_action_app_selection_screen.dart';
import 'settings_screen.dart';
import '../widgets/model_selector_button.dart';
import '../services/built_in_tools_service.dart';

enum DrawingTool { pen, rectangle }

abstract class DrawingAction {
  final Color color;
  DrawingAction(this.color);
}

class StrokeAction extends DrawingAction {
  final List<Offset> points;
  StrokeAction(this.points, Color color) : super(color);
}

class RectangleAction extends DrawingAction {
  final Rect rect;
  RectangleAction(this.rect, Color color) : super(color);
}

class ImmersiveNoteScreen extends StatefulWidget {
  const ImmersiveNoteScreen({
    super.key,
    required this.notes,
    this.initialAttachmentPath,
    this.initialConversation,
    this.initialMessages = const [],
  }) : assert(notes.length > 0, 'Immersive mode requires at least one note.');

  final List<Note> notes;
  final String? initialAttachmentPath;
  final Conversation? initialConversation;
  final List<ConversationMessage> initialMessages;

  @override
  State<ImmersiveNoteScreen> createState() => _ImmersiveNoteScreenState();
}

class _ImmersiveNoteScreenState extends State<ImmersiveNoteScreen>
    with
        TickerProviderStateMixin,
        NoteActionMixin<ImmersiveNoteScreen>,
        WidgetsBindingObserver {
  final ConversationService _conversationService = ConversationService();
  final DatabaseService _databaseService = DatabaseService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode();
  final GlobalKey _noteBoundaryKey = GlobalKey();

  static const double _strokeCaptureMargin = 16;

  late final Map<String, Note> _initialNotesById;
  late List<String> _noteOrder;
  final List<ConversationMessage> _messages = [];
  final List<PlatformFile> _pendingAttachments = [];
  final Map<String, Future<_AttachmentSource?>> _attachmentSourceFutures = {};
  final Map<String, int> _pdfCurrentPages = {};
  final Map<String, int> _pdfTotalPages = {};
  final Map<String, PdfAiContextConfig> _pdfContextConfigs = {};
  final Map<String, PdfViewerController> _pdfViewerControllers = {};
  final Map<String, PdfDocument> _pdfDocuments = {};
  final Map<String, List<PdfOutlineNode>> _pdfOutlines = {};
  final Map<String, TransformationController> _imageTransforms = {};

  final ConversationAiEngine _aiEngine = const ConversationAiEngine();
  Conversation? _conversation;
  List<Note> _conversationNotes = [];
  bool _hasAssociatedConversations = false;

  bool _isPenMode = false;
  bool _isLoadingConversation = true;
  bool _isSending = false;
  bool _isAborting = false;
  String? _currentRequestId;
  final Set<String> _cancelledRequestIds = {};
  final ValueNotifier<bool> _hasWebViewNotifier = ValueNotifier(false);

  // Scratchpad State
  bool _isScratchpadMode = false;
  final List<ConversationMessage> _scratchpadItems = [];
  bool _includeScratchpadInChat = false;
  int _lastSavedScratchpadCount = 0;

  // PDF State
  bool _isPdfNightMode = false;

  bool get _isScratchpadDirty =>
      _scratchpadItems.length != _lastSavedScratchpadCount;

  // MCP support
  List<McpEndpoint> _availableMcpEndpoints = [];
  final Set<String> _selectedMcpEndpointIds = {};
  final Set<String> _selectedModelFeatures = {};
  Map<String, List<McpTool>> _mcpToolsByEndpoint = {};
  bool _isMcpPanelExpanded = false; // Collapsed by default

  // Scratchpad editing state
  int? _editingScratchpadIndex;
  final TextEditingController _scratchpadEditController =
      TextEditingController();

  // AI tool support
  Map<String, AiToolAppBundle> _aiToolBundles = {};
  Map<String, List<McpTool>> _aiToolMcpMap = {};
  final Set<String> _selectedAiToolServices = {};
  final Map<String, AiToolRuntime> _aiToolRuntimes = {};
  String? _toolExecutionStatus;
  int _maxToolIterations = ConversationSettingsService.defaultMaxToolIterations;
  ToolIterationPrompt? _iterationPrompt;
  final List<Offset> _penStrokePoints = [];

  // Built-in Tools
  final Set<String> _selectedBuiltInTools = {};

  // Drawing State
  List<DrawingAction> _drawingActions = [];
  List<DrawingAction> _redoStack = [];
  DrawingTool _currentTool = DrawingTool.pen;
  Color _currentColor = Colors.redAccent;
  Offset? _currentRectStart;
  Offset? _currentRectEnd;

  int _activeNoteIndex = 0;
  String? _activeAttachmentPath;
  final DateTime _sessionStart = DateTime.now();
  static const double _aiHandleHeight = 76.0;
  static const double _aiHandleWidth = 420.0;
  static const double _aiPanelHeightFraction = 0.45;
  double _aiLandscapePanelFraction = 0.4;
  static const double _aiHandleMargin = 12.0;
  static const double _aiHandlePadding = 12.0;
  static const double _aiHandleControlWidth = 44.0;
  static const double _aiHandleControlGap = 8.0;
  static const double _kMinVerticalHeightForSplit = 600.0;
  double _aiHandleFraction = 0.75;
  bool _isAiPanelExpanded = false;
  _AiPanelSide _aiPanelSide = _AiPanelSide.bottom;
  bool _isHandleDragFromComposerArea = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialNotesById = {for (final note in widget.notes) note.id: note};
    _noteOrder = widget.notes.map((note) => note.id).toList();
    _conversationNotes = List<Note>.from(widget.notes);
    _loadIterationPreference();
    _setupApprovalCallback();

    if (widget.initialConversation != null) {
      _conversation = widget.initialConversation;
      _hasAssociatedConversations = true;
    }

    if (widget.initialMessages.isNotEmpty) {
      _messages.addAll(widget.initialMessages);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }

    if (widget.initialAttachmentPath != null) {
      _activeAttachmentPath = widget.initialAttachmentPath;
      final index = _findNoteIndexForAttachment(
        widget.initialAttachmentPath!,
        widget.notes,
      );
      if (index != null) {
        _activeNoteIndex = index;
      }
      _loadPdfContextConfig(widget.initialAttachmentPath!);
    }

    // Don't create conversation immediately - wait for first message
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.initialConversation != null) {
        _switchConversation(widget.initialConversation!.id);
      } else {
        _loadConversationNotes();
      }
      _loadMcpEndpoints();
      _loadAiTools();
      _loadModelFeatures();
    });
  }

  /// Sets up the unified approval callback for AI tools.
  void _setupApprovalCallback() {
    ApprovalService.onApprovalRequest = (request) async {
      if (!mounted) return ApprovalResult(approved: false);
      return await ApprovalDialog.showWithContext(context, request);
    };
  }

  ModelConfig? _previousModelConfig;
  ModelConfig? _selectedModel;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh model features when app resumes (e.g., after model configuration change)
      // Note: didChangeDependencies will also handle this if the provider updates,
      // but this ensures we catch resume events specifically if needed.
      _loadModelFeatures();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appProvider = context.watch<AppProvider>();
    if (_previousModelConfig != appProvider.modelConfig) {
      _previousModelConfig = appProvider.modelConfig;
      // Refresh model features when model config changes
      _loadModelFeatures();
    }
  }

  Future<void> _loadIterationPreference() async {
    final value = await ConversationSettingsService.getMaxToolIterations();
    if (!mounted) return;
    setState(() {
      _maxToolIterations = value;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resolveIterationPrompt(null);
    _messageController.dispose();
    _chatScrollController.dispose();
    _messageFocusNode.dispose();
    _disposePdfResources();
    _disposeImageResources();
    for (final runtime in _aiToolRuntimes.values) {
      runtime.dispose();
    }
    _aiToolRuntimes.clear();
    super.dispose();
  }

  /// Load conversation notes without creating a conversation
  Future<void> _loadConversationNotes() async {
    setState(() => _isLoadingConversation = true);

    try {
      final noteIds = List<String>.from(_noteOrder);
      final notes = <Note>[];

      for (final noteId in noteIds) {
        final note = await _databaseService.getNote(noteId);
        if (note != null) {
          notes.add(note);
        }
      }

      if (!mounted) return;

      setState(() {
        _conversationNotes = notes;
        for (final note in notes) {
          _initialNotesById[note.id] = note;
        }
      });

      // Check for associated conversations
      await _checkAssociatedConversations();
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to load notes for immersive view: $e',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      if (mounted) {
        setState(() => _isLoadingConversation = false);
      }
    }
  }

  /// Check if there are any conversations associated with the notes
  Future<void> _checkAssociatedConversations() async {
    try {
      // If there's already a conversation, we have associated conversations
      if (_conversation != null) {
        if (mounted) {
          setState(() {
            _hasAssociatedConversations = true;
          });
        }
        return;
      }

      // Check if any notes have associated conversations
      final appProvider = context.read<AppProvider>();
      final noteIds = List<String>.from(_noteOrder);
      bool hasConversations = false;

      for (final noteId in noteIds) {
        final conversationIds = await appProvider.getNoteConversationIds(
          noteId,
        );
        if (conversationIds.isNotEmpty) {
          hasConversations = true;
          break;
        }
      }

      if (mounted) {
        setState(() {
          _hasAssociatedConversations = hasConversations;
        });
      }
    } catch (e) {
      LoggerService.warning('Failed to check associated conversations: $e');
      // On error, default to false to hide the tree icon
      if (mounted) {
        setState(() {
          _hasAssociatedConversations = false;
        });
      }
    }
  }

  void _loadModelFeatures() {
    // Clear selected features when model changes - user must explicitly toggle them on
    if (mounted) {
      setState(() {
        _selectedModelFeatures.clear();
      });
    }
  }

  /// Create conversation when first message is sent
  Future<void> _initializeConversation() async {
    if (_conversation != null) return;

    try {
      final noteIds = List<String>.from(_noteOrder);
      final primaryNote = await _databaseService.getNote(noteIds.first);
      final title = primaryNote?.title ?? 'Immersive Session';
      final conversation = await _conversationService.createConversation(
        title: 'Immersive: $title',
        noteIds: noteIds,
      );

      if (!mounted) return;

      setState(() {
        _conversation = conversation;
        _hasAssociatedConversations = true;
      });
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to create immersive conversation: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
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
      if (mounted) {
        setState(() {
          _availableMcpEndpoints = endpointsWithTools;
        });
      }
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
      LoggerService.info(
        'Updated MCP tools: ${toolsByEndpoint.length} services, ${toolsByEndpoint.values.fold(0, (sum, tools) => sum + tools.length)} tools',
      );
    } catch (e) {
      LoggerService.error('Error updating MCP tools: $e');
    }
  }

  Future<void> _loadAiTools() async {
    final appProvider = context.read<AppProvider>();
    final aiApps = appProvider.userApps
        .where((app) => app.type == UserAppType.aiTool)
        .toList();

    final bundles = <String, AiToolAppBundle>{};
    final mcpMap = <String, List<McpTool>>{};

    for (final app in aiApps) {
      if (app.selectedRevisionId == null) {
        LoggerService.warning(
          'AI tool "${app.name}" has no selected revision.',
        );
        continue;
      }

      try {
        final revision = await UserAppService.getAppRevision(
          app.selectedRevisionId!,
        );
        if (revision == null) {
          LoggerService.warning(
            'AI tool "${app.name}" selected revision not found.',
          );
          continue;
        }

        final bundle = await AiToolService.loadAppBundle(
          app: app,
          revision: revision,
        );
        if (bundle == null || bundle.toolDefinitions.isEmpty) {
          continue;
        }

        bundles[bundle.serviceName] = bundle;
        mcpMap[bundle.serviceName] = bundle.toMcpTools();
      } catch (e) {
        LoggerService.error('Failed to load AI tool "${app.name}": $e');
      }
    }

    final removedServices = _aiToolRuntimes.keys
        .where((service) => !bundles.containsKey(service))
        .toList(growable: false);
    for (final service in removedServices) {
      _aiToolRuntimes.remove(service)?.dispose();
    }

    if (!mounted) return;

    setState(() {
      _aiToolBundles = bundles;
      _aiToolMcpMap = mcpMap;
      _selectedAiToolServices.removeWhere(
        (service) => !mcpMap.containsKey(service),
      );
    });
  }

  bool get _hasAvailableTools =>
      _availableMcpEndpoints.isNotEmpty ||
      _aiToolBundles.isNotEmpty ||
      BuiltInToolsService.tools.isNotEmpty ||
      true; // Model features are always potential candidates

  Map<String, List<McpTool>> _buildActiveToolsMap() {
    final combined = <String, List<McpTool>>{};
    combined.addAll(_mcpToolsByEndpoint);

    for (final service in _selectedAiToolServices) {
      final tools = _aiToolMcpMap[service];
      if (tools != null && tools.isNotEmpty) {
        combined[service] = tools;
      }
    }

    // Add Built-in Tools
    if (_selectedBuiltInTools.isNotEmpty) {
      final builtInTools = _selectedBuiltInTools
          .map((id) => BuiltInToolsService.getToolById(id))
          .where((t) => t != null)
          .map(
            (t) => McpTool(
              name: t!.name,
              description: t.description,
              inputSchema: {},
            ),
          )
          .toList();
      if (builtInTools.isNotEmpty) {
        combined['Built-in'] = builtInTools;
      }
    }

    return combined;
  }

  Future<int?> _handleIterationsExhausted(int exhaustedLimit) async {
    if (!mounted) return null;
    final prompt = ToolIterationPrompt(exhaustedIterations: exhaustedLimit);
    setState(() {
      _iterationPrompt = prompt;
      _toolExecutionStatus = null;
    });

    final result = await prompt.completer.future;
    if (!mounted) return result;
    if (identical(_iterationPrompt, prompt)) {
      setState(() {
        _iterationPrompt = null;
      });
    }
    return result;
  }

  void _resolveIterationPrompt(int? value) {
    final prompt = _iterationPrompt;
    if (prompt == null) return;
    prompt.resolve(value);
    if (mounted && identical(_iterationPrompt, prompt)) {
      setState(() {
        _iterationPrompt = null;
      });
    }
  }

  Future<void> _onIterationPromptContinue() async {
    final prompt = _iterationPrompt;
    if (prompt == null) return;
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final newLimit = await _showIterationLimitDialog(
      prompt.exhaustedIterations,
    );
    if (!mounted) return;
    if (newLimit == null) {
      return;
    }
    if (newLimit <= prompt.exhaustedIterations) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.iterationLimitDialogError(prompt.exhaustedIterations + 1),
          ),
        ),
      );
      return;
    }

    setState(() {
      _maxToolIterations = newLimit;
    });
    _resolveIterationPrompt(newLimit);
  }

  Future<int?> _showIterationLimitDialog(int currentLimit) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(
      text: (currentLimit + 5).toString(),
    );
    try {
      final result = await showDialog<int>(
        context: context,
        builder: (dialogContext) {
          String? errorText;
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                title: Text(l10n.iterationLimitDialogTitle),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.iterationLimitDialogDescription(currentLimit)),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: l10n.iterationLimitInputLabel,
                        helperText: l10n.iterationLimitHelper(currentLimit + 1),
                        errorText: errorText,
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: Text(l10n.cancel),
                  ),
                  FilledButton(
                    onPressed: () {
                      final parsed = int.tryParse(controller.text.trim());
                      if (parsed == null || parsed <= currentLimit) {
                        setDialogState(() {
                          errorText = l10n.iterationLimitDialogError(
                            currentLimit + 1,
                          );
                        });
                        return;
                      }
                      Navigator.of(dialogContext).pop(parsed);
                    },
                    child: Text(l10n.update),
                  ),
                ],
              );
            },
          );
        },
      );
      // Delay disposal to ensure dialog has fully closed
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
      });
      return result;
    } catch (e) {
      controller.dispose();
      rethrow;
    } finally {}
  }

  Future<String> _runWithToolStatus(
    String serviceName,
    String toolName,
    Future<String> Function() action,
  ) async {
    final statusLabel = mounted
        ? _buildToolStatusLabel(serviceName, toolName)
        : '$serviceName -> $toolName';
    if (mounted) {
      setState(() {
        _toolExecutionStatus = statusLabel;
      });
    }

    try {
      return await action();
    } finally {
      if (mounted) {
        setState(() {
          if (_toolExecutionStatus == statusLabel) {
            _toolExecutionStatus = null;
          }
        });
      }
    }
  }

  String _buildToolStatusLabel(String serviceName, String toolName) {
    final l10n = AppLocalizations.of(context)!;
    final serviceLabel = _resolveServiceLabel(serviceName);
    final toolLabel = _resolveToolLabel(serviceName, toolName);
    return l10n.executingToolStatus(serviceLabel, toolLabel);
  }

  String _resolveServiceLabel(String serviceName) {
    final aiBundle = _aiToolBundles[serviceName];
    if (aiBundle != null) {
      return aiBundle.displayName;
    }
    return serviceName;
  }

  String _resolveToolLabel(String serviceName, String toolName) {
    final aiBundle = _aiToolBundles[serviceName];
    if (aiBundle != null) {
      for (final definition in aiBundle.toolDefinitions) {
        if (definition.toolName == toolName) {
          return _prettifyLabel(definition.toolName);
        }
      }
    }

    final tools = _mcpToolsByEndpoint[serviceName];
    if (tools != null) {
      for (final tool in tools) {
        if (tool.name == toolName) {
          return _prettifyLabel(tool.name);
        }
      }
    }

    return _prettifyLabel(toolName);
  }

  String _prettifyLabel(String input) {
    return input.replaceAll(RegExp(r'[_\\-]+'), ' ');
  }

  bool get _hasAnyTools => _buildActiveToolsMap().isNotEmpty;

  void _toggleAiToolService(String serviceName, bool isSelected) {
    setState(() {
      if (isSelected) {
        _selectedAiToolServices.add(serviceName);
      } else {
        _selectedAiToolServices.remove(serviceName);
      }
    });

    if (!isSelected) {
      _aiToolRuntimes.remove(serviceName)?.dispose();
    }
  }

  Future<AiToolRuntime> _getAiToolRuntime(String serviceName) async {
    final existing = _aiToolRuntimes[serviceName];
    if (existing != null) {
      return existing;
    }

    final bundle = _aiToolBundles[serviceName];
    if (bundle == null) {
      throw Exception('AI tool not available: $serviceName');
    }

    final runtime = AiToolRuntime(
      bundle: bundle,
      appProvider: context.read<AppProvider>(),
      onModificationRequest: _handleModificationRequest,
      onSqlWriteApprovalRequest: _handleSqlWriteApprovalRequest,
    );
    _aiToolRuntimes[serviceName] = runtime;
    return runtime;
  }

  /// Handle note modification approval requests from AI tools.
  Future<bool> _handleModificationRequest(
    dynamic source,
    String noteId,
    Map<String, dynamic> modification,
  ) async {
    if (!mounted) return false;
    return await ApprovalService.requestNoteModificationApproval(
      noteId: noteId,
      modification: modification,
      source: 'AI Tool',
    );
  }

  /// Handle SQL write approval requests from AI tools.
  Future<bool> _handleSqlWriteApprovalRequest(
    dynamic source,
    String sql,
    SqlQueryType queryType,
  ) async {
    if (!mounted) return false;
    return await ApprovalService.requestSqlWriteApproval(
      sql: sql,
      queryType: queryType,
      queryTypeDescription: SqlQueryService().getQueryTypeDescription(
        queryType,
      ),
      source: 'AI Tool',
    );
  }

  // --- Bookmark Management ---

  Future<void> _toggleBookmark() async {
    if (_activeAttachmentPath == null) return;

    final attachment = await _resolveAttachment(_activeAttachmentPath!);
    if (attachment == null) return;

    final currentPage = _pdfCurrentPages[_activeAttachmentPath!] ?? 0;
    final bookmarks = attachment.getBookmarks();

    // Check if current page is already bookmarked (compare page numbers)
    final existingBookmarkIndex = bookmarks.indexWhere(
      (b) => b.pageNumber == currentPage,
    );

    if (existingBookmarkIndex != -1) {
      // Remove bookmark
      await _removeBookmark(attachment, currentPage);
      await _loadPdfContextConfig(_activeAttachmentPath!);
    } else {
      // Add bookmark
      await _showAddEditBookmarkDialog(attachment, currentPage);
      await _loadPdfContextConfig(_activeAttachmentPath!);
    }
  }

  Future<Attachment?> _resolveAttachment(String path) async {
    final note = widget.notes[_activeNoteIndex];
    // This is a simplification; ideally we find the attachment object from the note or DB
    final attachments = await _databaseService.getAttachmentsForNote(note.id);
    try {
      // Try to find by direct path match first (handling relative/absolute)
      return attachments.firstWhere(
        (a) => a.filePath == path || a.filePath.endsWith(path.split('/').last),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveBookmark(
    Attachment attachment,
    int page,
    String annotation,
  ) async {
    final bookmarks = attachment.getBookmarks();
    final newBookmark = PdfBookmark(
      title: 'Page ${page + 1}', // Default title
      pageNumber: page,
      createdAt: DateTime.now(),
      annotation: annotation.trim(),
    );

    // Remove existing if updating
    bookmarks.removeWhere((b) => b.pageNumber == page);
    bookmarks.add(newBookmark);
    // Sort by page number
    bookmarks.sort((a, b) => a.pageNumber.compareTo(b.pageNumber));

    final metadata = Map<String, dynamic>.from(attachment.metadata ?? {});
    metadata['bookmarks'] = bookmarks.map((e) => e.toJson()).toList();

    await _databaseService.updateAttachmentMetadata(attachment.id, metadata);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.noteUpdatedSuccessfully),
        ),
      );
      // Force rebuild to update menu state if needed
      setState(() {});
      // Reload config as bookmarks might be part of it, or just to be safe
      await _loadPdfContextConfig(_activeAttachmentPath!);
    }
  }

  Future<void> _removeBookmark(Attachment attachment, int page) async {
    final bookmarks = attachment.getBookmarks();
    bookmarks.removeWhere((b) => b.pageNumber == page);

    final metadata = Map<String, dynamic>.from(attachment.metadata ?? {});
    metadata['bookmarks'] = bookmarks.map((e) => e.toJson()).toList();

    await _databaseService.updateAttachmentMetadata(attachment.id, metadata);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.attachmentRemoved),
        ), // Reusing suitable string or adding new one
      );
      setState(() {});
      await _loadPdfContextConfig(attachment.filePath);
    }
  }

  void _showBookmarksList() async {
    if (_activeAttachmentPath == null) return;
    final attachment = await _resolveAttachment(_activeAttachmentPath!);
    if (attachment == null) return;

    final bookmarks = attachment.getBookmarks();
    final l10n = AppLocalizations.of(context)!;

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.bookmarks),
          content: SizedBox(
            width: double.maxFinite,
            child: bookmarks.isEmpty
                ? Center(child: Text(l10n.noBookmarksYet))
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: bookmarks.length,
                    itemBuilder: (context, index) {
                      final bookmark = bookmarks[index];
                      return ListTile(
                        title: Text('${l10n.page} ${bookmark.pageNumber + 1}'),
                        subtitle:
                            bookmark.annotation != null &&
                                bookmark.annotation!.isNotEmpty
                            ? Text(
                                bookmark.annotation!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
                        onTap: () {
                          Navigator.pop(context);
                          _jumpToPage(bookmark.pageNumber);
                        },
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit),
                              onPressed: () {
                                Navigator.pop(context);
                                _showAddEditBookmarkDialog(
                                  attachment,
                                  bookmark.pageNumber,
                                  existingBookmark: bookmark,
                                );
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete),
                              onPressed: () async {
                                Navigator.pop(context);
                                await _removeBookmark(
                                  attachment,
                                  bookmark.pageNumber,
                                );
                                _showBookmarksList(); // Reopen to show updated list
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.close),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showAddEditBookmarkDialog(
    Attachment attachment,
    int page, {
    PdfBookmark? existingBookmark,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(
      text: existingBookmark?.annotation ?? '',
    );

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text(
                existingBookmark == null ? l10n.addBookmark : l10n.editBookmark,
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${l10n.page} ${page + 1}'),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    maxLength: 200,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: l10n.bookmarkAnnotationHint,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.cancel),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _saveBookmark(attachment, page, controller.text);
                  },
                  child: Text(l10n.save),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _jumpToPage(int page) {
    if (_activeAttachmentPath != null) {
      final controller = _pdfViewerControllers[_activeAttachmentPath!];
      if (controller != null) {
        // pdfrx uses 1-indexed pages
        controller.goToPage(pageNumber: page + 1);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Consumer<AppProvider>(
      builder: (context, appProvider, _) {
        final notes = _resolveNotes(appProvider);
        if (notes.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: Text(l10n.immersiveMode)),
            body: Center(child: Text(l10n.noNotesFound)),
          );
        }

        final activeNote = notes[_activeNoteIndex.clamp(0, notes.length - 1)];

        return Scaffold(
          resizeToAvoidBottomInset: false,
          appBar: AppBar(
            title: Text(l10n.immersiveMode),
            actions: [
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: l10n.addNotes,
                onPressed: _showNoteSelection,
              ),
              IconButton(
                icon: const Icon(Icons.format_list_bulleted),
                tooltip: l10n.outline,
                onPressed: () => _showOutline(notes, l10n),
              ),
              if (_hasAssociatedConversations)
                IconButton(
                  icon: const Icon(Icons.account_tree),
                  tooltip: l10n.viewTree,
                  onPressed: () => _openConversationTree(),
                ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) async {
                  if (value == 'open_chat') {
                    _openConversationInChatMode();
                  } else if (value == 'note_action_apps') {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => NoteActionAppSelectionScreen(
                          selectedNotes: _conversationNotes,
                        ),
                      ),
                    );
                  } else if (value == 'ai_logs') {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => const AIDebugOverlayScreen(),
                      ),
                    );
                  } else if (value == 'configure_pdf_ai_context') {
                    await _showPdfAiContextDialogForActiveAttachment();
                    if (_activeAttachmentPath != null) {
                      await _loadPdfContextConfig(_activeAttachmentPath!);
                    }
                  } else if (value == 'bookmarks') {
                    _showBookmarksList();
                  } else if (value == 'toggle_bookmark') {
                    _toggleBookmark();
                  } else if (value == 'toggle_pdf_night_mode') {
                    setState(() {
                      _isPdfNightMode = !_isPdfNightMode;
                    });
                  }
                },
                itemBuilder: (context) {
                  final l10n = AppLocalizations.of(context)!;
                  final isPdf =
                      _activeAttachmentPath != null &&
                      _activeAttachmentPath!.toLowerCase().endsWith('.pdf');

                  return [
                    if (_conversation != null)
                      PopupMenuItem<String>(
                        value: 'open_chat',
                        child: Row(
                          children: [
                            const Icon(Icons.chat_bubble_outline),
                            const SizedBox(width: 8),
                            Text(l10n.openInChatMode),
                          ],
                        ),
                      ),
                    if (_conversationNotes.isNotEmpty)
                      PopupMenuItem<String>(
                        value: 'note_action_apps',
                        child: Row(
                          children: [
                            const Icon(Icons.apps),
                            const SizedBox(width: 8),
                            Text(l10n.noteActionApps),
                          ],
                        ),
                      ),
                    if (isPdf) ...[
                      const PopupMenuDivider(),
                      PopupMenuItem<String>(
                        value: 'bookmarks',
                        child: Row(
                          children: [
                            const Icon(Icons.bookmarks_outlined),
                            const SizedBox(width: 8),
                            Text(l10n.bookmarks),
                          ],
                        ),
                      ),
                      // We can check if page is bookmarked if we had sync access to it,
                      // but for now generic "Bookmark Page" which toggles is fine.
                      // Or we could try:
                      // final isBookmarked = _isCurrentPageBookmarked(); // helper if we can make it sync
                      PopupMenuItem<String>(
                        value: 'toggle_bookmark',
                        child: Row(
                          children: [
                            const Icon(Icons.bookmark_add_outlined),
                            const SizedBox(width: 8),
                            Text(l10n.bookmarkPage),
                          ],
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'configure_pdf_ai_context',
                        child: Row(
                          children: [
                            Icon(
                              Icons.tune,
                              color:
                                  _hasPdfAiContextConfig(_activeAttachmentPath!)
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_getPdfAiContextLabel(l10n))),
                          ],
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'toggle_pdf_night_mode',
                        child: Row(
                          children: [
                            Icon(
                              _isPdfNightMode
                                  ? Icons.light_mode_outlined
                                  : Icons.dark_mode_outlined,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _isPdfNightMode ? 'Day Mode' : 'Night Mode',
                            ), // TODO: l10n
                          ],
                        ),
                      ),
                    ],
                    PopupMenuItem<String>(
                      value: 'ai_logs',
                      child: Row(
                        children: [
                          const Icon(Icons.bug_report_outlined),
                          const SizedBox(width: 8),
                          Text(l10n.aiLogs),
                        ],
                      ),
                    ),
                  ];
                },
              ),
            ],
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                final overlays = _buildAiOverlays(size, l10n);
                return Stack(
                  children: [
                    Positioned.fill(child: _buildNoteArea(activeNote, l10n)),
                    if (_isPenMode)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: _handlePenPanStart,
                          onPanUpdate: _handlePenPanUpdate,
                          onPanEnd: (_) => _handlePenPanEnd(),
                          onPanCancel: _resetPenStroke,
                          child: CustomPaint(
                            painter: _DrawingLayerPainter(
                              actions: _drawingActions,
                              activeStroke:
                                  _currentTool == DrawingTool.pen &&
                                      _penStrokePoints.isNotEmpty
                                  ? List<Offset>.from(_penStrokePoints)
                                  : null,
                              activeRect:
                                  _currentTool == DrawingTool.rectangle &&
                                      _currentRectStart != null &&
                                      _currentRectEnd != null
                                  ? Rect.fromPoints(
                                      _currentRectStart!,
                                      _currentRectEnd!,
                                    )
                                  : null,
                              activeColor: _currentColor,
                            ),
                            size: Size.infinite,
                          ),
                        ),
                      ),
                    ...overlays,
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  List<Note> _resolveNotes(AppProvider provider) {
    final notesById = {for (final note in provider.notes) note.id: note};

    final resolved = <Note>[];
    for (final id in _noteOrder) {
      final note = notesById[id] ?? _initialNotesById[id];
      if (note != null) {
        resolved.add(note);
      }
    }

    if (resolved.isEmpty && _initialNotesById.isNotEmpty) {
      resolved.addAll(_initialNotesById.values);
    }

    if (_activeNoteIndex >= resolved.length) {
      _activeNoteIndex = resolved.length - 1;
    }

    return resolved;
  }

  List<Widget> _buildAiOverlays(Size size, AppLocalizations l10n) {
    final isLandscape = size.width > size.height;
    // Use horizontal split layout only if we are in landscape AND have limited vertical space (like phones).
    // Tablets in landscape usually have enough height to support the vertical bottom-sheet style,
    // which is often preferred to avoid taking up horizontal space side-by-side.
    if (isLandscape && size.height < _kMinVerticalHeightForSplit) {
      return _buildHorizontalAiOverlays(size, l10n);
    }
    return _buildVerticalAiOverlays(size, l10n);
  }

  List<Widget> _buildVerticalAiOverlays(Size size, AppLocalizations l10n) {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final overlays = <Widget>[];
    final totalHeight = size.height;
    final handleHeight = _currentHandleHeight();
    final panelHeight = _computePanelExtent(totalHeight, handleHeight);

    final effectiveSide = _effectivePanelSide(size);

    final minHandleTop = _aiHandleMargin;
    final maxHandleTop = max(
      _aiHandleMargin,
      totalHeight - handleHeight - _aiHandleMargin - keyboardHeight,
    );

    double handleTop;

    if (_isAiPanelExpanded && panelHeight > 0) {
      if (effectiveSide == _AiPanelSide.top) {
        overlays.add(
          Positioned(
            top: 0,
            left: _aiHandleMargin,
            right: _aiHandleMargin,
            height: panelHeight,
            child: _buildAiPanelContent(l10n),
          ),
        );
        handleTop = panelHeight + _aiHandleMargin;
      } else {
        overlays.add(
          Positioned(
            bottom: keyboardHeight, // Adjusted for keyboard
            left: _aiHandleMargin,
            right: _aiHandleMargin,
            height: panelHeight,
            child: _buildAiPanelContent(l10n),
          ),
        );
        handleTop =
            totalHeight -
            panelHeight -
            handleHeight -
            _aiHandleMargin -
            keyboardHeight; // Adjusted for keyboard
      }
    } else {
      final trackHeight = max(
        0.0,
        totalHeight - handleHeight - keyboardHeight,
      ); // Adjusted for keyboard
      handleTop = trackHeight <= 0
          ? _aiHandleMargin
          : _aiHandleFraction * trackHeight;
    }

    final clampedHandleTop = _clampToRange(
      handleTop,
      minHandleTop,
      maxHandleTop,
    );

    final handleWidth = min(
      size.width - (_aiHandleMargin * 2),
      max(_aiHandleWidth, size.width * 0.8),
    );
    overlays.add(
      Positioned(
        left: _aiHandleMargin,
        right: _aiHandleMargin,
        top: clampedHandleTop,
        child: Center(
          child: SizedBox(
            width: handleWidth,
            child: _buildAiHandle(l10n, size, handleWidth, false),
          ),
        ),
      ),
    );

    return overlays;
  }

  List<Widget> _buildHorizontalAiOverlays(Size size, AppLocalizations l10n) {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final overlays = <Widget>[];
    final totalHeight = size.height;
    final handleHeight = _currentHandleHeight();
    final effectiveSide = _effectivePanelSide(size);

    final minHandleTop = _aiHandleMargin;
    final maxHandleTop = max(
      _aiHandleMargin,
      totalHeight - handleHeight - _aiHandleMargin - keyboardHeight,
    );

    final trackHeight = max(0.0, totalHeight - handleHeight - keyboardHeight);
    double handleTop = trackHeight <= 0
        ? _aiHandleMargin
        : _aiHandleFraction * trackHeight;
    handleTop = _clampToRange(handleTop, minHandleTop, maxHandleTop);

    final handleWidth = min(
      size.width - (_aiHandleMargin * 2),
      max(400.0, size.width * 0.45), // Min 400, max 45% of screen
    );

    double panelWidth = 0.0;
    if (_isAiPanelExpanded) {
      panelWidth = _computeLandscapePanelWidth(size.width, handleWidth);
      if (panelWidth > 0) {
        overlays.add(
          Positioned(
            top: _aiHandleMargin,
            bottom: _aiHandleMargin,
            left: effectiveSide == _AiPanelSide.left ? 0 : null,
            right: effectiveSide == _AiPanelSide.right ? 0 : null,
            width: panelWidth,
            child: _buildAiPanelContent(l10n),
          ),
        );
      }
    }

    double? handleLeft;
    double? handleRight;
    if (effectiveSide == _AiPanelSide.left) {
      handleLeft = (_isAiPanelExpanded && panelWidth > 0)
          ? panelWidth + _aiHandleMargin
          : _aiHandleMargin;
    } else {
      handleRight = (_isAiPanelExpanded && panelWidth > 0)
          ? panelWidth + _aiHandleMargin
          : _aiHandleMargin;
    }

    if (handleLeft != null) {
      handleLeft = min(
        handleLeft,
        max(_aiHandleMargin, size.width - handleWidth - _aiHandleMargin),
      );
    }
    if (handleRight != null) {
      handleRight = min(
        handleRight,
        max(_aiHandleMargin, size.width - handleWidth - _aiHandleMargin),
      );
    }

    overlays.add(
      Positioned(
        top: handleTop,
        left: handleLeft,
        right: handleRight,
        child: SizedBox(
          width: handleWidth,
          child: _buildAiHandle(l10n, size, handleWidth, true),
        ),
      ),
    );

    return overlays;
  }

  double _clampToRange(double value, double minValue, double maxValue) {
    if (maxValue < minValue) {
      maxValue = minValue;
    }
    return value.clamp(minValue, maxValue).toDouble();
  }

  double _computePanelExtent(double totalExtent, double handleExtent) {
    final availableMax = max(
      0.0,
      totalExtent - handleExtent - (_aiHandleMargin * 2),
    );

    if (availableMax <= 0) {
      return 0;
    }

    final minExtent = min(totalExtent * 0.25, availableMax);
    final maxExtent = min(totalExtent * 0.75, availableMax);

    return _clampToRange(
      totalExtent * _aiPanelHeightFraction,
      minExtent,
      maxExtent,
    );
  }

  double _computeLandscapePanelWidth(double totalWidth, double handleWidth) {
    final available = max(
      0.0,
      totalWidth - handleWidth - (_aiHandleMargin * 3),
    );

    if (available <= 0) {
      return 0;
    }

    final minWidth = min(totalWidth * 0.25, available);
    final maxWidth = min(totalWidth * 0.5, available);

    return _clampToRange(
      totalWidth * _aiLandscapePanelFraction,
      minWidth,
      maxWidth,
    );
  }

  bool _isVerticalLayout(Size size) {
    if (size.width <= size.height) return true; // Portrait
    return size.height >= _kMinVerticalHeightForSplit; // Tablet Landscape
  }

  _AiPanelSide _effectivePanelSide(Size size) {
    if (!_isVerticalLayout(size)) {
      if (_aiPanelSide == _AiPanelSide.left ||
          _aiPanelSide == _AiPanelSide.right) {
        return _aiPanelSide;
      }
      return _AiPanelSide.right;
    } else {
      if (_aiPanelSide == _AiPanelSide.top ||
          _aiPanelSide == _AiPanelSide.bottom) {
        return _aiPanelSide;
      }
      return _AiPanelSide.bottom;
    }
  }

  _AiPanelSide _normalizePanelSide(_AiPanelSide side, Size size) {
    if (!_isVerticalLayout(size)) {
      if (side == _AiPanelSide.left || side == _AiPanelSide.right) {
        return side;
      }
      return _AiPanelSide.right;
    }
    if (side == _AiPanelSide.top || side == _AiPanelSide.bottom) {
      return side;
    }
    return _AiPanelSide.bottom;
  }

  double _currentHandleHeight() {
    double height = _aiHandleHeight;
    if (_pendingAttachments.isNotEmpty) {
      final attachmentRows = (_pendingAttachments.length / 2).ceil();
      height += attachmentRows * 32.0;
    }
    if (_isPenMode) {
      height += 48.0; // Toolbar height
    }
    return height;
  }

  Widget _buildAiHandle(
    AppLocalizations l10n,
    Size canvasSize,
    double handleWidth,
    bool isLandscape,
  ) {
    final theme = Theme.of(context);
    final bool expanded = _isAiPanelExpanded;
    final double dynamicHeight = _currentHandleHeight();

    final Widget controlWidget;
    if (expanded) {
      controlWidget = Center(
        child: IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: l10n.collapse,
          onPressed: _collapseAiPanel,
        ),
      );
    } else {
      Widget buildArrowButton(IconData icon, _AiPanelSide side) {
        return SizedBox(
          width: 36,
          height: 36,
          child: IconButton(
            icon: Icon(icon, size: 20),
            padding: EdgeInsets.zero,
            tooltip: l10n.expand,
            onPressed: () => _expandAiPanel(side, canvasSize),
          ),
        );
      }

      if (isLandscape) {
        controlWidget = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            buildArrowButton(Icons.keyboard_arrow_left, _AiPanelSide.left),
            const SizedBox(width: 4),
            buildArrowButton(Icons.keyboard_arrow_right, _AiPanelSide.right),
          ],
        );
      } else {
        controlWidget = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            buildArrowButton(Icons.keyboard_arrow_up, _AiPanelSide.top),
            const SizedBox(height: 4),
            buildArrowButton(Icons.keyboard_arrow_down, _AiPanelSide.bottom),
          ],
        );
      }
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (details) =>
          _onAiHandlePanStart(details.localPosition, handleWidth),
      onPanUpdate: (details) => _onAiHandlePanUpdate(details, canvasSize),
      onPanEnd: (_) => _onAiHandlePanEnd(),
      onPanCancel: _onAiHandlePanEnd,
      child: Material(
        color: theme.colorScheme.surface.withOpacity(0.85),
        elevation: 6,
        borderRadius: BorderRadius.circular(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: dynamicHeight,
            maxWidth: handleWidth,
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: _aiHandleControlWidth,
                      child: controlWidget,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: _buildAiComposer(l10n)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolExecutionIndicator() {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final prompt = _iterationPrompt;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SizeTransition(
          sizeFactor: animation,
          axisAlignment: -1.0,
          child: child,
        ),
      ),
      child: prompt != null
          ? Container(
              key: const ValueKey('tool-iteration-prompt'),
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: theme.colorScheme.outline.withOpacity(0.2),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.loop, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.iterationLimitPrompt(prompt.exhaustedIterations),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.8),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _onIterationPromptContinue,
                    child: Text(l10n.iterationLimitContinue),
                  ),
                  TextButton(
                    onPressed: () => _resolveIterationPrompt(null),
                    child: Text(l10n.iterationLimitAbort),
                  ),
                ],
              ),
            )
          : _toolExecutionStatus == null
          ? const SizedBox.shrink(key: ValueKey('tool-status-empty'))
          : Padding(
              key: ValueKey(_toolExecutionStatus),
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _toolExecutionStatus!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.7),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildAiComposer(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_pendingAttachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _buildPendingAttachmentsPreview(l10n),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildToolExecutionIndicator(),
                Row(
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(
                            Icons.brush,
                            color: _isPenMode
                                ? theme.colorScheme.primary
                                : null,
                          ),
                          tooltip: l10n.annotate,
                          iconSize: 20,
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(),
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () {
                            setState(() {
                              _isPenMode = !_isPenMode;
                              if (!_isPenMode) {
                                // Reset drawing state when exiting without confirming
                                _drawingActions.clear();
                                _redoStack.clear();
                                _penStrokePoints.clear();
                              } else {
                                // Initialize new session
                                _drawingActions.clear();
                                _redoStack.clear();
                                _penStrokePoints.clear();
                              }
                            });
                          },
                        ),
                        const SizedBox(height: 4),
                        IconButton(
                          icon: Badge(
                            isLabelVisible: _isScratchpadDirty,
                            smallSize: 6,
                            child: Icon(
                              _isScratchpadMode
                                  ? Icons.description
                                  : Icons.description_outlined,
                              color: _isScratchpadMode
                                  ? theme.colorScheme.primary
                                  : null,
                            ),
                          ),
                          tooltip: 'Scratchpad', // TODO: l10n
                          iconSize: 20,
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(),
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () {
                            setState(() {
                              _isScratchpadMode = !_isScratchpadMode;
                              // Do not auto-expand panel
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        focusNode: _messageFocusNode,
                        maxLines: 6,
                        minLines: 3,
                        decoration: InputDecoration.collapsed(
                          hintText: _isScratchpadMode
                              ? 'Send to scratchpad' // TODO: l10n
                              : l10n.askAiAboutNoteHint,
                        ),
                        onSubmitted: (_) {
                          if (!_isSending && !_isAborting) {
                            _sendMessage();
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildSendControl(l10n),
                  ],
                ),
                if (_isPenMode) ...[
                  const Divider(height: 12),
                  _buildDrawingToolbar(theme),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDrawingToolbar(ThemeData theme) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tools
          IconButton(
            icon: Icon(
              Icons.edit,
              color: _currentTool == DrawingTool.pen
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface.withOpacity(0.6),
            ),
            tooltip: 'Pen',
            onPressed: () => setState(() => _currentTool = DrawingTool.pen),
            iconSize: 20,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(8),
          ),
          IconButton(
            icon: const Icon(Icons.palette),
            iconSize: 20,
            onPressed: _openDrawingEditor,
            tooltip: 'Advanced Drawing',
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(8),
          ),
          IconButton(
            icon: Icon(
              Icons.crop_square,
              color: _currentTool == DrawingTool.rectangle
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface.withOpacity(0.6),
            ),
            tooltip: 'Rectangle',
            onPressed: () =>
                setState(() => _currentTool = DrawingTool.rectangle),
            iconSize: 20,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(8),
          ),
          const SizedBox(width: 8),
          // Colors
          ...[
            Colors.redAccent,
            Colors.blueAccent,
            Colors.green,
          ].map((color) => _buildColorButton(color)),
          const SizedBox(width: 8),
          // Undo/Redo
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Undo',
            onPressed: _drawingActions.isEmpty ? null : _undoDrawing,
            iconSize: 20,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(8),
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            tooltip: 'Redo',
            onPressed: _redoStack.isEmpty ? null : _redoDrawing,
            iconSize: 20,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(8),
          ),
          const SizedBox(width: 8),
          // Confirm
          IconButton(
            onPressed: _drawingActions.isEmpty ? null : _confirmDrawing,
            icon: Icon(
              Icons.check_circle,
              color: _drawingActions.isEmpty ? null : theme.colorScheme.primary,
            ),
            tooltip: 'Done',
            iconSize: 24,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(8),
          ),
        ],
      ),
    );
  }

  Widget _buildColorButton(Color color) {
    final isSelected = _currentColor == color;
    return GestureDetector(
      onTap: () => setState(() => _currentColor = color),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.withOpacity(0.5),
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: color.withOpacity(0.4),
                    blurRadius: 4,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
      ),
    );
  }

  void _undoDrawing() {
    if (_drawingActions.isEmpty) return;
    setState(() {
      final action = _drawingActions.removeLast();
      _redoStack.add(action);
    });
  }

  void _redoDrawing() {
    if (_redoStack.isEmpty) return;
    setState(() {
      final action = _redoStack.removeLast();
      _drawingActions.add(action);
    });
  }

  Future<void> _confirmDrawing() async {
    if (_drawingActions.isEmpty) return;

    // Calculate bounds of all actions
    Rect? totalBounds;
    for (final action in _drawingActions) {
      Rect actionBounds;
      if (action is StrokeAction) {
        actionBounds = _computeStrokeBounds(action.points);
      } else if (action is RectangleAction) {
        actionBounds = action.rect;
      } else {
        continue;
      }

      if (totalBounds == null) {
        totalBounds = actionBounds;
      } else {
        totalBounds = totalBounds.expandToInclude(actionBounds);
      }
    }

    if (totalBounds == null) return;

    try {
      final imageBytes = await _captureDrawing(_drawingActions, totalBounds);
      final result = await SynapseTempUtils.saveTempData(
        mimeType: 'image/png',
        bytes: imageBytes,
      );

      final platformFile = PlatformFile(
        name: 'annotation_${DateTime.now().millisecondsSinceEpoch}.png',
        path: result.file.path,
        size: imageBytes.length,
        bytes: imageBytes,
      );

      if (mounted) {
        setState(() {
          _pendingAttachments.add(platformFile);
          _drawingActions.clear();
          _redoStack.clear();
          _isPenMode = false; // Optional: exit pen mode after adding?
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Annotation added to attachments.')),
        );
      }
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to capture drawing: $e',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to capture drawing: $e')),
        );
      }
    }
  }

  Widget _buildSendControl(AppLocalizations l10n) {
    // Only show handle if there are tools available
    if (!_hasAvailableTools) {
      return const SizedBox.shrink();
    }
    if (_isAborting) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    if (_isSending) {
      return _buildAbortButtonWithSpinner(l10n);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.send),
          tooltip: l10n.send,
          onPressed: _sendMessage,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
        ModelSelectorButton(
          selectedModel: _selectedModel,
          onModelSelected: (model) {
            setState(() {
              _selectedModel = model;
            });
          },
          isSendButton: true,
        ),
      ],
    );
  }

  Widget _buildAbortButtonWithSpinner(AppLocalizations l10n) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.error.withOpacity(0.3),
              ),
            ),
          ),
          Material(
            color: theme.colorScheme.error,
            shape: const CircleBorder(),
            elevation: 2,
            child: IconButton(
              onPressed: _abortRequest,
              icon: const Icon(Icons.stop, color: Colors.white, size: 18),
              tooltip: l10n.cancelAiRequest,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAiPanelContent(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.95),
      elevation: 10,
      child: Column(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isLoadingConversation)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          // MCP Selection (Only show if not in scratchpad mode)
          if (!_isScratchpadMode &&
              (_availableMcpEndpoints.isNotEmpty || _aiToolBundles.isNotEmpty))
            _buildMcpSelectionSection(l10n),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: _isScratchpadMode
                  ? _buildScratchpadList(l10n)
                  : _buildConversationList(l10n),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMcpSelectionSection(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final combinedTools = _buildActiveToolsMap();
    final activeMcpCount = _selectedMcpEndpointIds.length;
    final activeLocalCount = _selectedAiToolServices.length;
    final activeModelFeaturesCount = _selectedModelFeatures.length;
    final activeBuiltInToolsCount = _selectedBuiltInTools.length;
    final totalActiveCount =
        activeMcpCount +
        activeLocalCount +
        activeModelFeaturesCount +
        activeBuiltInToolsCount;
    final headerTitle = l10n.mcpAndLocalTools;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.3)),
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
                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                ),
                const SizedBox(width: 8),
                Text(
                  headerTitle,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface.withOpacity(0.8),
                  ),
                ),
                if (totalActiveCount > 0) ...[
                  const SizedBox(width: 8),
                  ActiveToolCountBadge(
                    count: totalActiveCount,
                    label: l10n.active,
                  ),
                ],
                const Spacer(),
                // Chevron icon that rotates based on expansion state
                AnimatedRotation(
                  turns: _isMcpPanelExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 20,
                    color: theme.colorScheme.onSurface.withOpacity(0.7),
                  ),
                ),
              ],
            ),
          ),
          // Expandable content
          if (_isMcpPanelExpanded)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.35,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    // Built-in Tools
                    if (BuiltInToolsService.tools.isNotEmpty) ...[
                      Row(
                        children: [
                          Icon(
                            Icons.build,
                            size: 16,
                            color: theme.colorScheme.onSurface.withOpacity(0.7),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.builtInTools,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface.withOpacity(
                                0.8,
                              ),
                            ),
                          ),
                          const Spacer(),
                          if (activeBuiltInToolsCount > 0)
                            ActiveToolCountBadge(
                              count: activeBuiltInToolsCount,
                              label: l10n.active,
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ...BuiltInToolsService.tools.map((tool) {
                        final isSelected = _selectedBuiltInTools.contains(
                          tool.id,
                        );
                        return CheckboxListTile(
                          title: Text(tool.name),
                          subtitle: Text(
                            tool.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          value: isSelected,
                          secondary: Icon(tool.icon, color: tool.color),
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                _selectedBuiltInTools.add(tool.id);
                              } else {
                                _selectedBuiltInTools.remove(tool.id);
                              }
                            });
                          },
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
                          dense: true,
                        );
                      }),
                      const Divider(),
                    ],
                    if (_availableMcpEndpoints.isNotEmpty) ...[
                      Row(
                        children: [
                          Icon(
                            Icons.cloud,
                            size: 16,
                            color: theme.colorScheme.onSurface.withOpacity(0.7),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.mcpTools,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface.withOpacity(
                                0.8,
                              ),
                            ),
                          ),
                          const Spacer(),
                          if (activeMcpCount > 0)
                            ActiveToolCountBadge(
                              count: activeMcpCount,
                              label: l10n.active,
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: _availableMcpEndpoints.map((endpoint) {
                          final isSelected = _selectedMcpEndpointIds.contains(
                            endpoint.id,
                          );
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
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface.withOpacity(
                                      0.6,
                                    ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],

                    if (_aiToolBundles.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Icon(
                            Icons.smart_toy,
                            size: 16,
                            color: theme.colorScheme.onSurface.withOpacity(0.7),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.aiTools,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface.withOpacity(
                                0.8,
                              ),
                            ),
                          ),
                          const Spacer(),
                          if (activeLocalCount > 0)
                            ActiveToolCountBadge(
                              count: activeLocalCount,
                              label: l10n.active,
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: _aiToolBundles.entries.map((entry) {
                          final serviceName = entry.key;
                          final bundle = entry.value;
                          final selected = _selectedAiToolServices.contains(
                            serviceName,
                          );
                          return FilterChip(
                            label: Text(bundle.displayName),
                            selected: selected,
                            onSelected: (value) {
                              _toggleAiToolService(serviceName, value);
                            },
                            avatar: Icon(
                              Icons.smart_toy,
                              size: 16,
                              color: selected
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface.withOpacity(
                                      0.6,
                                    ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                    // Model Features Section
                    if (context
                                .read<AppProvider>()
                                .modelConfig
                                ?.modelFeatures !=
                            null &&
                        context
                            .read<AppProvider>()
                            .modelConfig!
                            .modelFeatures!
                            .isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Icon(
                            Icons.extension,
                            size: 16,
                            color: theme.colorScheme.onSurface.withOpacity(0.7),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.modelFeatures,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface.withOpacity(
                                0.8,
                              ),
                            ),
                          ),
                          const Spacer(),
                          if (_selectedModelFeatures.isNotEmpty)
                            ActiveToolCountBadge(
                              count: _selectedModelFeatures.length,
                              label: l10n.active,
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: context
                            .read<AppProvider>()
                            .modelConfig!
                            .modelFeatures!
                            .map((feature) {
                              final isSelected = _selectedModelFeatures
                                  .contains(feature);
                              return FilterChip(
                                label: Text(
                                  feature
                                      .split('_')
                                      .map(
                                        (word) =>
                                            word[0].toUpperCase() +
                                            word.substring(1),
                                      )
                                      .join(' '),
                                ),
                                selected: isSelected,
                                onSelected: (selected) {
                                  setState(() {
                                    if (selected) {
                                      _selectedModelFeatures.add(feature);
                                    } else {
                                      _selectedModelFeatures.remove(feature);
                                    }
                                  });
                                },
                                avatar: Icon(
                                  Icons.extension,
                                  size: 16,
                                  color: isSelected
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurface.withOpacity(
                                          0.6,
                                        ),
                                ),
                              );
                            })
                            .toList(),
                      ),
                    ],
                    if (combinedTools.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        l10n.toolsAvailable(
                          combinedTools.values.fold<int>(
                            0,
                            (sum, tools) => sum + tools.length,
                          ),
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _expandAiPanel(_AiPanelSide side, Size canvasSize) {
    final normalizedSide = _normalizePanelSide(side, canvasSize);

    setState(() {
      _isAiPanelExpanded = true;
      _aiPanelSide = normalizedSide;

      if (!_isVerticalLayout(canvasSize)) {
        return;
      }

      final totalHeight = canvasSize.height;
      final handleHeight = _currentHandleHeight();
      final handleTravel = max(0.0, totalHeight - handleHeight);
      if (handleTravel <= 0) {
        return;
      }

      final panelHeight = _computePanelExtent(totalHeight, handleHeight);
      final targetTop = normalizedSide == _AiPanelSide.top
          ? panelHeight + _aiHandleMargin
          : totalHeight - panelHeight - handleHeight - _aiHandleMargin;

      final clampedTop = _clampToRange(
        targetTop,
        _aiHandleMargin,
        max(_aiHandleMargin, totalHeight - handleHeight - _aiHandleMargin),
      );

      _aiHandleFraction = (clampedTop / handleTravel)
          .clamp(0.0, 1.0)
          .toDouble();
    });
  }

  void _collapseAiPanel() {
    setState(() {
      _isAiPanelExpanded = false;
    });
  }

  Widget _buildScratchpadList(AppLocalizations l10n) {
    final theme = Theme.of(context);

    if (_scratchpadItems.isEmpty) {
      return Column(
        children: [
          Expanded(
            child: Center(
              child: Text(
                'Scratchpad is empty', // TODO: l10n
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          _buildScratchpadActions(l10n),
        ],
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _chatScrollController,
            padding: const EdgeInsets.only(bottom: 12),
            itemCount: _scratchpadItems.length,
            itemBuilder: (context, index) {
              final item = _scratchpadItems[index];
              final isEditing = _editingScratchpadIndex == index;

              return Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isEditing)
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _scratchpadEditController,
                              maxLines: null,
                              autofocus: true,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.all(8),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.check, color: Colors.green),
                            onPressed: () => _saveScratchpadEdit(index),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: _cancelScratchpadEdit,
                          ),
                        ],
                      )
                    else
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: SelectionArea(
                              child: InteractiveCheckboxMarkdown(
                                originalContent: item.content,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurface,
                                ),
                                onLinkTap: (url, _) =>
                                    _handleMarkdownLinkTap(url, l10n),
                              ),
                            ),
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  Icons.edit,
                                  size: 18,
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.6),
                                ),
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                padding: EdgeInsets.zero,
                                onPressed: () => _startScratchpadEdit(index),
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.close,
                                  size: 18,
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.6),
                                ),
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                padding: EdgeInsets.zero,
                                onPressed: () => _deleteScratchpadItem(index),
                              ),
                            ],
                          ),
                        ],
                      ),
                    if (item.attachmentPaths.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _buildMessageAttachmentChips(item, l10n),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        _buildScratchpadActions(l10n),
      ],
    );
  }

  Widget _buildScratchpadActions(AppLocalizations l10n) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _scratchpadItems.isEmpty ? null : _addScratchpadToNote,
            icon: const Icon(Icons.note_add, size: 18),
            label: const Text('Add to Note'), // TODO: l10n
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _scratchpadItems.isEmpty ? null : _clearScratchpad,
            icon: const Icon(Icons.clear_all, size: 18),
            label: const Text('Clear'), // TODO: l10n
          ),
        ),
        const SizedBox(width: 8),
        // Include in chat toggle
        Tooltip(
          message: 'Include scratchpad in chat context', // TODO: l10n
          child: Switch(
            value: _includeScratchpadInChat,
            onChanged: (value) {
              setState(() {
                _includeScratchpadInChat = value;
              });
            },
          ),
        ),
      ],
    );
  }

  void _startScratchpadEdit(int index) {
    setState(() {
      _editingScratchpadIndex = index;
      _scratchpadEditController.text = _scratchpadItems[index].content;
    });
  }

  void _cancelScratchpadEdit() {
    setState(() {
      _editingScratchpadIndex = null;
      _scratchpadEditController.clear();
    });
  }

  void _saveScratchpadEdit(int index) {
    if (index < 0 || index >= _scratchpadItems.length) return;
    setState(() {
      final oldItem = _scratchpadItems[index];
      _scratchpadItems[index] = ConversationMessage(
        id: oldItem.id,
        conversationId: oldItem.conversationId,
        content: _scratchpadEditController.text,
        type: oldItem.type,
        timestamp: oldItem.timestamp,
        attachmentPaths: oldItem.attachmentPaths,
      );
      _editingScratchpadIndex = null;
      _scratchpadEditController.clear();
    });
  }

  void _deleteScratchpadItem(int index) {
    setState(() {
      _scratchpadItems.removeAt(index);
      if (_editingScratchpadIndex == index) {
        _cancelScratchpadEdit();
      } else if (_editingScratchpadIndex != null &&
          _editingScratchpadIndex! > index) {
        _editingScratchpadIndex = _editingScratchpadIndex! - 1;
      }
    });
  }

  void _clearScratchpad() {
    setState(() {
      _scratchpadItems.clear();
      _lastSavedScratchpadCount = 0; // Reset dirty state baseline
      _cancelScratchpadEdit();
    });
  }

  Future<void> _addScratchpadToNote() async {
    if (_scratchpadItems.isEmpty) return;

    // Construct content with inline attachments
    final content = _scratchpadItems
        .map((item) {
          final text = item.content;
          if (item.attachmentPaths.isEmpty) {
            return text;
          }
          // Add attachments as inline markdown images
          final attachmentsMarkdown = item.attachmentPaths
              .map((path) {
                final fileName = path.split(Platform.pathSeparator).last;
                if (fileName.startsWith('syn_')) {
                  return '![](${SynapseTempUtils.buildUriFromFileName(fileName)})';
                }
                return '![]($path)';
              })
              .join('\n');

          if (text.trim().isEmpty) {
            return attachmentsMarkdown;
          }
          return '$text\n$attachmentsMarkdown';
        })
        .join('\n\n');

    // We pass empty attachmentPaths because we've embedded them in the content
    // and ConversationAttachmentService will process them from there.
    await handleAddContentToNote(
      content: content,
      contextNotes: _conversationNotes,
      attachmentPaths: [],
    );

    // After adding, we update the "last saved" count to mark as clean?
    // Or maybe we don't clear it, just mark as clean.
    setState(() {
      _lastSavedScratchpadCount = _scratchpadItems.length;
    });
  }

  void _onAiHandlePanStart(Offset localPosition, double handleWidth) {
    _isHandleDragFromComposerArea = _isPointInsideComposerArea(
      localPosition,
      handleWidth,
    );
  }

  void _onAiHandlePanUpdate(DragUpdateDetails details, Size canvasSize) {
    if (_isHandleDragFromComposerArea) {
      return;
    }
    _updateHandleDrag(details.delta, canvasSize);
  }

  void _onAiHandlePanEnd() {
    _isHandleDragFromComposerArea = false;
  }

  bool _isPointInsideComposerArea(Offset localPosition, double handleWidth) {
    final double composerLeft =
        _aiHandlePadding + _aiHandleControlWidth + _aiHandleControlGap;
    final double composerRight = handleWidth - _aiHandlePadding;
    if (composerRight <= composerLeft) {
      return false;
    }
    return localPosition.dx >= composerLeft &&
        localPosition.dx <= composerRight;
  }

  void _updateHandleDrag(Offset delta, Size canvasSize) {
    // Handle horizontal resizing in landscape mode when expanded
    if (!_isVerticalLayout(canvasSize) &&
        _isAiPanelExpanded &&
        delta.dx.abs() > delta.dy.abs()) {
      final effectiveSide = _effectivePanelSide(canvasSize);
      double widthDelta = 0;
      if (effectiveSide == _AiPanelSide.right) {
        widthDelta = -delta.dx; // Drag left increases width
      } else if (effectiveSide == _AiPanelSide.left) {
        widthDelta = delta.dx; // Drag right increases width
      }

      if (widthDelta != 0) {
        final totalWidth = canvasSize.width;
        final currentWidth = totalWidth * _aiLandscapePanelFraction;
        final newWidth = currentWidth + widthDelta;

        setState(() {
          _aiLandscapePanelFraction = (newWidth / totalWidth)
              .clamp(0.2, 0.8)
              .toDouble();
        });
        return;
      }
    }

    final totalHeight = canvasSize.height;
    final handleHeight = _currentHandleHeight();
    final handleTravel = max(0.0, totalHeight - handleHeight);
    if (handleTravel <= 0) {
      return;
    }

    final currentTop = _aiHandleFraction * handleTravel;
    final proposedTop = currentTop + delta.dy;
    final newTop = _clampToRange(
      proposedTop,
      _aiHandleMargin,
      max(_aiHandleMargin, totalHeight - handleHeight - _aiHandleMargin),
    );

    setState(() {
      _aiHandleFraction = (newTop / handleTravel).clamp(0.0, 1.0).toDouble();
      _isAiPanelExpanded = false;
    });
  }

  Widget _buildConversationList(AppLocalizations l10n) {
    if (_messages.isEmpty) {
      return Align(
        alignment: Alignment.topCenter,
        child: Text(
          l10n.startConversationHint,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _chatScrollController,
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        final isUser = message.type == MessageType.user;
        final hasTools =
            message.metadata != null &&
            (message.metadata!.containsKey('parts_history') ||
                message.metadata!.containsKey('function_calls'));

        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isUser
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (!isUser) ...[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.smart_toy,
                        size: 16,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        l10n.ai,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.secondary,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const Spacer(),
                      if (hasTools) ...[
                        IconButton(
                          icon: const Icon(
                            Icons.build_circle_outlined,
                            size: 18,
                          ),
                          tooltip: 'View Tool Usage',
                          onPressed: () => _showToolDetailsDialog(message),
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                if (isUser)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: SelectableText(
                          message.content,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: Icon(
                          Icons.edit,
                          size: 16,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.5),
                        ),
                        onPressed: () {
                          _messageController.text = message.content;
                          // Scroll to bottom to show the input field
                          _scrollToBottom();
                          // Focus the text field after a short delay to ensure it's visible
                          Future.delayed(const Duration(milliseconds: 200), () {
                            _messageFocusNode.requestFocus();
                          });
                        },
                        tooltip: 'Use this message',
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  )
                else
                  SelectionArea(
                    child: InteractiveCheckboxMarkdown(
                      originalContent: message.content,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      onLinkTap: (url, _) => _handleMarkdownLinkTap(url, l10n),
                    ),
                  ),
                if (message.attachmentPaths.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _buildMessageAttachmentChips(message, l10n),
                  ),
                if (!isUser) ...[
                  const SizedBox(height: 12),
                  ChatMessageActionRow(
                    onCopy: () => copyContentToClipboard(message.content),
                    onAddNote: () => handleAddContentToNote(
                      content: message.content,
                      contextNotes: _conversationNotes,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showToolDetailsDialog(ConversationMessage message) async {
    if (message.metadata == null) return;

    final partsHistory =
        (message.metadata!['parts_history'] as List?)?.cast<Map>() ?? [];
    final functionCalls =
        (message.metadata!['function_calls'] as List?)?.cast<Map>() ?? [];

    if (partsHistory.isEmpty && functionCalls.isEmpty) return;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Tool Usage & Thoughts'),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: ListView.builder(
                itemCount: partsHistory.isNotEmpty
                    ? partsHistory.length
                    : functionCalls.length,
                itemBuilder: (context, index) {
                  if (partsHistory.isNotEmpty) {
                    final part = partsHistory[index];
                    final type = part['type'];
                    final isIncluded = part['is_included'] ?? true;
                    final thoughtSignature = part['thought_signature'];

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: isIncluded
                          ? null
                          : Theme.of(context).disabledColor.withOpacity(0.1),
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  type == 'tool_call'
                                      ? Icons.build
                                      : type == 'image'
                                      ? Icons.image
                                      : Icons.text_fields,
                                  size: 16,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  type.toString().toUpperCase(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                                const Spacer(),
                                Switch(
                                  value: isIncluded,
                                  onChanged: (value) {
                                    setState(() {
                                      part['is_included'] = value;
                                    });
                                    // Update message metadata immediately (or on save)
                                    // For now, we update the local object and save on close/change
                                    message.metadata!['parts_history'] =
                                        partsHistory;
                                    _conversationService
                                        .updateConversationMessage(message);
                                  },
                                ),
                              ],
                            ),
                            if (thoughtSignature != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                'Thought Signature: ${thoughtSignature.substring(0, 10)}...',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                            if (type == 'tool_call') ...[
                              const SizedBox(height: 4),
                              Text(
                                'Function: ${part['function_call']?['name']}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              Text(
                                'Args: ${part['function_call']?['args']}',
                                style: Theme.of(context).textTheme.bodySmall,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  } else {
                    // Legacy function calls view
                    final call = functionCalls[index];
                    return ListTile(
                      leading: const Icon(Icons.build),
                      title: Text(call['name'] ?? 'Unknown Tool'),
                      subtitle: Text(
                        call['args'].toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMessageAttachmentChips(
    ConversationMessage message,
    AppLocalizations l10n,
  ) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: message.attachmentPaths.map((path) {
        final label = path.split(Platform.pathSeparator).last;
        return ActionChip(
          avatar: Icon(_iconForAttachment(path), size: 18),
          label: Text(label, overflow: TextOverflow.ellipsis),
          onPressed: () => _openAttachment(path, l10n),
        );
      }).toList(),
    );
  }

  Widget _buildPendingAttachmentsPreview(AppLocalizations l10n) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(_pendingAttachments.length, (index) {
        final file = _pendingAttachments[index];
        return InputChip(
          avatar: Icon(_iconForAttachment(file.path ?? file.name), size: 18),
          label: Text(file.name, overflow: TextOverflow.ellipsis),
          showCheckmark: false,
          onSelected: (_) => _previewPendingAttachment(file),
          onDeleted: () => setState(() {
            _pendingAttachments.removeAt(index);
          }),
        );
      }),
    );
  }

  Future<void> _previewPendingAttachment(PlatformFile file) async {
    await FileUtils.openPlatformFile(file, context);
  }

  Widget _buildNoteArea(Note note, AppLocalizations l10n) {
    return RepaintBoundary(
      key: _noteBoundaryKey,
      child: Container(
        color: Theme.of(context).colorScheme.surface,
        child: _activeAttachmentPath == null
            ? _buildNoteContent(note, l10n)
            : _buildAttachmentViewer(_activeAttachmentPath!, l10n),
      ),
    );
  }

  Widget _buildNoteContent(Note note, AppLocalizations l10n) {
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              note.title,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SelectionArea(
              child: InteractiveCheckboxMarkdown(
                key: ValueKey(
                  'immersive_note_${note.id}_${note.updatedAt.toIso8601String()}',
                ),
                noteId: note.id,
                originalContent: note.content,
                hasWebViewNotifier: _hasWebViewNotifier,
                onContentChanged: (newContent) {
                  context.read<AppProvider>().updateNoteContent(
                    note.id,
                    newContent,
                  );
                },
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            // Add subnotes if present
            if (note.subNotes.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(
                l10n.subNotes,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ...note.subNotes.map(
                (subNote) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (subNote.isCompleted)
                                const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                  size: 20,
                                )
                              else
                                const Icon(
                                  Icons.radio_button_unchecked,
                                  size: 20,
                                ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  subNote.name,
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          if (subNote.content.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            SelectionArea(
                              child: InteractiveCheckboxMarkdown(
                                key: ValueKey(
                                  'subnote_${subNote.id}_${subNote.createdAt.toIso8601String()}',
                                ),
                                noteId: note.id,
                                originalContent: subNote.content,
                                hasWebViewNotifier: _hasWebViewNotifier,
                                onContentChanged: (_) {},
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentViewer(String attachmentPath, AppLocalizations l10n) {
    final future = _attachmentSourceFutures.putIfAbsent(
      attachmentPath,
      () => _loadAttachmentSource(attachmentPath),
    );

    return FutureBuilder<_AttachmentSource?>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final source = snapshot.data;
        if (source == null) {
          return Center(child: Text(l10n.attachmentMissing));
        }

        final extension = source.extension;
        if (_isImageExtension(extension)) {
          final transformController = _ensureImageTransformationController(
            source.cacheKey,
          );
          final imageWidget = source.bytes != null
              ? Image.memory(source.bytes!)
              : Image.file(source.file);

          return InteractiveViewer(
            transformationController: transformController,
            minScale: 0.1,
            maxScale: 4,
            constrained: true,
            clipBehavior: Clip.hardEdge,
            child: imageWidget,
          );
        }

        if (extension == 'svg') {
          return _buildSvgViewer(source, l10n);
        }

        if (extension == 'pdf') {
          return LayoutBuilder(
            builder: (context, constraints) {
              final availableHeight =
                  constraints.hasBoundedHeight &&
                      constraints.maxHeight.isFinite &&
                      constraints.maxHeight > 0
                  ? constraints.maxHeight
                  : MediaQuery.of(context).size.height;
              return _PdfDocumentView(
                source: source,
                availableHeight: availableHeight,
                currentPageMap: _pdfCurrentPages,
                totalPageMap: _pdfTotalPages,
                controllerMap: _pdfViewerControllers,
                onError: (message) => LoggerService.error(message),
                onDocumentReady: (cacheKey, document, outline) {
                  _pdfDocuments[cacheKey] = document;
                  if (outline != null && outline.isNotEmpty) {
                    setState(() {
                      _pdfOutlines[cacheKey] = outline;
                    });
                  }
                },
                isNightMode: _isPdfNightMode,
              );
            },
          );
        }

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file, size: 48),
              const SizedBox(height: 12),
              Text(l10n.unsupportedAttachment(extension)),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => _openAttachment(source.originalPath, l10n),
                child: Text(l10n.openAttachment),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSvgViewer(_AttachmentSource source, AppLocalizations l10n) {
    return FutureBuilder<String>(
      future: source.file.readAsString(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.hasError) {
          return Center(child: Text(l10n.failedToLoadAttachment));
        }

        final svgContent = snapshot.data!;
        return InAppWebView(
          initialData: InAppWebViewInitialData(
            data: svgContent,
            mimeType: 'image/svg+xml',
            encoding: 'utf-8',
          ),
          initialSettings: InAppWebViewSettings(
            supportZoom: true,
            builtInZoomControls: true,
            transparentBackground: true,
          ),
        );
      },
    );
  }

  Future<void> _showNoteSelection() async {
    final l10n = AppLocalizations.of(context)!;

    final selectedNotes = await showDialog<List<Note>>(
      context: context,
      builder: (dialogContext) {
        return NoteSelectionDialog(
          onNotesSelected: (notes) => Navigator.of(dialogContext).pop(notes),
          title: l10n.selectNotesToAddToContext,
        );
      },
    );

    if (selectedNotes != null && selectedNotes.isNotEmpty) {
      final existingIds = _noteOrder.toSet();
      final newNotes = selectedNotes
          .where((note) => !existingIds.contains(note.id))
          .toList();

      if (newNotes.isEmpty) {
        // All selected notes are already in the immersive view
        return;
      }

      // Add new notes to the immersive view
      setState(() {
        for (final note in newNotes) {
          _initialNotesById[note.id] = note;
          _noteOrder.add(note.id);
        }
        _conversationNotes.addAll(newNotes);
      });

      // If there's a conversation, add notes to it
      if (_conversation != null) {
        try {
          final noteIds = newNotes.map((note) => note.id).toList();
          await _conversationService.addNotesToConversation(
            _conversation!.id,
            noteIds,
          );
          // Reload conversation notes to ensure consistency
          final updatedNotes = await _conversationService.getConversationNotes(
            _conversation!.id,
          );
          if (mounted) {
            setState(() {
              _conversationNotes = updatedNotes;
            });
          }
        } catch (e) {
          LoggerService.error(
            'Error adding notes to conversation: $e',
            error: e,
          );
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Error adding notes: $e')));
          }
        }
      }
    }
  }

  /// Build an attachment outline item with PDF outline expansion support
  Widget _buildAttachmentOutlineItem({
    required String attachment,
    required int noteIndex,
    required int depth,
    required BuildContext context,
  }) {
    final fileName = attachment.split(Platform.pathSeparator).last;
    final extension = attachment.split('.').last.toLowerCase();
    final isPdf = extension == 'pdf';
    final leftPadding = 16.0 + (depth * 32);

    // Check if this PDF has an outline
    final pdfOutline = isPdf ? _pdfOutlines[attachment] : null;
    final hasOutline = pdfOutline != null && pdfOutline.isNotEmpty;

    if (!hasOutline) {
      // Simple list tile for non-PDF or PDF without outline
      return ListTile(
        contentPadding: EdgeInsets.only(left: leftPadding, right: 16),
        leading: Icon(_iconForAttachment(attachment)),
        title: Text(fileName, overflow: TextOverflow.ellipsis),
        onTap: () {
          setState(() {
            _activeNoteIndex = noteIndex;
            _activeAttachmentPath = attachment;
          });
          Navigator.pop(context);
        },
      );
    }

    // ExpansionTile for PDFs with outline
    return ExpansionTile(
      tilePadding: EdgeInsets.only(left: leftPadding, right: 16),
      leading: Icon(_iconForAttachment(attachment)),
      title: Text(fileName, overflow: TextOverflow.ellipsis),
      initiallyExpanded: false,
      children: [
        // Tap to view PDF button
        ListTile(
          contentPadding: EdgeInsets.only(left: leftPadding + 24, right: 16),
          leading: const Icon(Icons.visibility, size: 20),
          title: Text(
            'View PDF',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          onTap: () {
            setState(() {
              _activeNoteIndex = noteIndex;
              _activeAttachmentPath = attachment;
            });
            Navigator.pop(context);
          },
        ),
        // PDF outline items
        ..._buildPdfOutlineItems(
          attachmentPath: attachment,
          nodes: pdfOutline,
          noteIndex: noteIndex,
          depth: 0,
          context: context,
        ),
      ],
    );
  }

  /// Build PDF outline tree items recursively
  List<Widget> _buildPdfOutlineItems({
    required String attachmentPath,
    required List<PdfOutlineNode> nodes,
    required int noteIndex,
    required int depth,
    required BuildContext context,
  }) {
    final widgets = <Widget>[];
    final leftPadding = 80.0 + (depth * 16);

    for (final node in nodes) {
      widgets.add(
        ListTile(
          contentPadding: EdgeInsets.only(left: leftPadding, right: 16),
          leading: const Icon(Icons.bookmark_outline, size: 18),
          title: Text(
            node.title,
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () {
            setState(() {
              _activeNoteIndex = noteIndex;
              _activeAttachmentPath = attachmentPath;
            });
            Navigator.pop(context);
            // Navigate to the outline destination after the sheet closes
            _navigateToPdfOutlineDestination(attachmentPath, node);
          },
        ),
      );

      // Recursively add children
      if (node.children.isNotEmpty) {
        widgets.addAll(
          _buildPdfOutlineItems(
            attachmentPath: attachmentPath,
            nodes: node.children,
            noteIndex: noteIndex,
            depth: depth + 1,
            context: context,
          ),
        );
      }
    }

    return widgets;
  }

  /// Navigate to a PDF outline destination
  void _navigateToPdfOutlineDestination(
    String attachmentPath,
    PdfOutlineNode node,
  ) {
    final controller = _pdfViewerControllers[attachmentPath];
    if (controller == null) return;

    // Use WidgetsBinding to delay navigation until after the sheet closes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (node.dest != null) {
        controller.goToDest(node.dest!);
      }
    });
  }

  /// Check if a PDF has a custom AI context configuration
  bool _hasPdfAiContextConfig(String attachmentPath) {
    if (_activeAttachmentPath != attachmentPath) return false;
    final config = _pdfContextConfigs[attachmentPath];
    return config != null && config.hasCustomRange;
  }

  /// Get the label for the PDF AI context menu item
  String _getPdfAiContextLabel(AppLocalizations l10n) {
    if (_activeAttachmentPath == null) return l10n.configureAiContext;

    final config = _pdfContextConfigs[_activeAttachmentPath];
    if (config == null || !config.hasCustomRange) {
      return l10n.configureAiContext;
    }

    String modeLabel;
    switch (config.mode) {
      case 'window':
        modeLabel = l10n.aiContextWindow;
        break;
      case 'chapters':
        modeLabel = l10n.aiContextChapters;
        break;
      case 'bookmarks':
        modeLabel = l10n.aiContextBookmarks.replaceAll(
          'AI Context: ',
          '',
        ); // Reuse existing label part or fallback
        // Better to use the new simple labels if possible, but aiContextBookmarks in arb includes prefix.
        // Let's rely on the new pattern:
        // "aiContext": "AI Context: {mode}"
        // But for bookmarks, the existing key "aiContextBookmarks" is "AI Context: Bookmarks".
        // To be consistent with the plan, let's use the new key "aiContext" and pass specific string.
        // Wait, "aiContextBookmarks" is "AI Context: Bookmarks".
        // "aiContext" is "AI Context: {mode}".
        // If I pass "Bookmarks" to the second one, I get "AI Context: Bookmarks".
        // I don't have a "Bookmarks" standalone string key in the plan, I only saw "aiContextBookmarks".
        // Actually, "bookmarks" key exists (line 1104 in original file view shows usage of l10n.bookmarks).
        modeLabel = l10n.bookmarks;
        break;
      default:
        modeLabel = l10n.aiContextFullPdf;
    }

    return l10n.aiContext(modeLabel);
  }

  /// Load and cache the PDF AI context configuration
  Future<void> _loadPdfContextConfig(String path) async {
    if (!path.toLowerCase().endsWith('.pdf')) return;

    final attachment = await _resolveAttachment(path);
    if (attachment == null) return;

    final config = attachment.getAiContextConfig();
    if (mounted) {
      setState(() {
        if (config != null) {
          _pdfContextConfigs[path] = config;
        } else {
          _pdfContextConfigs.remove(path);
        }
      });
    }
  }

  /// Show the PDF AI context dialog for the active attachment
  Future<void> _showPdfAiContextDialogForActiveAttachment() async {
    if (_activeAttachmentPath == null) return;
    if (!_activeAttachmentPath!.toLowerCase().endsWith('.pdf')) return;

    final notes = _resolveNotes(context.read<AppProvider>());
    if (_activeNoteIndex >= notes.length) return;

    final currentNote = notes[_activeNoteIndex];
    final databaseService = DatabaseService();

    // Get attachments for the note
    final attachments = await databaseService.getAttachmentsForNote(
      currentNote.id,
    );

    // Find the attachment that matches the active path
    Attachment? attachment;
    for (final att in attachments) {
      final absPath = await att.getAbsolutePath();
      if (absPath == _activeAttachmentPath) {
        attachment = att;
        break;
      }
    }

    if (attachment == null) return;

    final currentConfig = attachment.getAiContextConfig();

    // Try to get cached outline and page count first
    var outline = _pdfOutlines[_activeAttachmentPath];
    var totalPages = _pdfTotalPages[_activeAttachmentPath] ?? 0;

    // If not cached, load the PDF document
    PdfDocument? loadedDocument;
    if (outline == null || totalPages == 0) {
      try {
        final absPath = await attachment.getAbsolutePath();
        // Check if we have a cached document
        final cachedDoc = _pdfDocuments[_activeAttachmentPath];
        if (cachedDoc != null) {
          totalPages = cachedDoc.pages.length;
          outline = await cachedDoc.loadOutline();
        } else {
          // Ensure Pdfrx cache directory is set (required for programmatic PDF loading)
          Pdfrx.getCacheDirectory ??= () async {
            final tempDir = await getTemporaryDirectory();
            return tempDir.path;
          };

          // Load fresh document
          loadedDocument = await PdfDocument.openFile(absPath);
          totalPages = loadedDocument.pages.length;
          outline = await loadedDocument.loadOutline();
        }
      } catch (e) {
        LoggerService.error('Failed to load PDF for AI context dialog: $e');
      }
    }

    if (!mounted) {
      loadedDocument?.dispose();
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => PdfAiContextDialog(
        attachment: attachment!,
        currentConfig: currentConfig,
        outline: outline,
        totalPages: totalPages,
        onSave: (config) async {
          // Build new metadata
          final currentMetadata = Map<String, dynamic>.from(
            attachment!.metadata ?? {},
          );
          if (config == null) {
            currentMetadata.remove('aiContextConfig');
          } else {
            currentMetadata['aiContextConfig'] = config.toJson();
          }

          // Update database
          await databaseService.updateAttachmentMetadata(
            attachment!.id,
            currentMetadata.isEmpty ? null : currentMetadata,
          );

          if (mounted) {
            ScaffoldMessenger.of(this.context).showSnackBar(
              const SnackBar(
                content: Text('AI context configuration saved'),
                backgroundColor: Colors.green,
              ),
            );
          }
        },
      ),
    );

    // Dispose loaded document if we created one
    loadedDocument?.dispose();
  }

  Future<void> _showOutline(List<Note> notes, AppLocalizations l10n) async {
    // Collect linked notes with circular reference prevention
    final linkedNotesMap = <String, List<Note>>{};
    final appProvider = context.read<AppProvider>();

    for (final note in notes) {
      try {
        final linkedNotes = await _collectLinkedNotes(note.id, appProvider);
        if (linkedNotes.isNotEmpty) {
          linkedNotesMap[note.id] = linkedNotes;
        }
      } catch (e) {
        LoggerService.warning('Failed to load linked notes for ${note.id}: $e');
      }
    }

    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  l10n.outline,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (int i = 0; i < notes.length; i++) ...[
                ListTile(
                  leading: const Icon(Icons.description),
                  title: Text(notes[i].title),
                  onTap: () {
                    setState(() {
                      _activeNoteIndex = i;
                      _activeAttachmentPath = null;
                    });
                    Navigator.pop(context);
                  },
                ),
                for (final attachment in notes[i].attachmentPaths)
                  _buildAttachmentOutlineItem(
                    attachment: attachment,
                    noteIndex: i,
                    depth: 1,
                    context: context,
                  ),
                // Add linked notes section if present
                if (linkedNotesMap.containsKey(notes[i].id)) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 48, top: 8, bottom: 4),
                    child: Text(
                      'Linked Notes',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.grey[600],
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  for (final linkedNote in linkedNotesMap[notes[i].id]!) ...[
                    ListTile(
                      contentPadding: const EdgeInsets.only(
                        left: 64,
                        right: 16,
                      ),
                      leading: const Icon(Icons.link, size: 20),
                      title: Text(
                        linkedNote.title,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      onTap: () {
                        setState(() {
                          // Find if this linked note is already in the notes list
                          final linkedIndex = notes.indexWhere(
                            (n) => n.id == linkedNote.id,
                          );
                          if (linkedIndex >= 0) {
                            // Note already in list, just navigate to it
                            _activeNoteIndex = linkedIndex;
                            _activeAttachmentPath = null;
                          } else {
                            // Add linked note to the notes list
                            _initialNotesById[linkedNote.id] = linkedNote;
                            _noteOrder.add(linkedNote.id);
                            _activeNoteIndex = _noteOrder.length - 1;
                            _activeAttachmentPath = null;
                          }
                        });
                        Navigator.pop(context);
                      },
                    ),
                    // Add attachments for the linked note
                    for (final attachment in linkedNote.attachmentPaths)
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 80,
                          right: 16,
                        ),
                        leading: Icon(_iconForAttachment(attachment), size: 18),
                        title: Text(
                          attachment.split(Platform.pathSeparator).last,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        onTap: () {
                          setState(() {
                            // Find if this linked note is already in the notes list
                            final linkedIndex = notes.indexWhere(
                              (n) => n.id == linkedNote.id,
                            );
                            if (linkedIndex >= 0) {
                              // Note already in list
                              _activeNoteIndex = linkedIndex;
                            } else {
                              // Add linked note to the notes list
                              _initialNotesById[linkedNote.id] = linkedNote;
                              _noteOrder.add(linkedNote.id);
                              _activeNoteIndex = _noteOrder.length - 1;
                            }
                            _activeAttachmentPath = attachment;
                          });
                          Navigator.pop(context);
                        },
                      ),
                  ],
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  /// Collect linked notes with circular reference prevention
  Future<List<Note>> _collectLinkedNotes(
    String noteId,
    AppProvider appProvider,
  ) async {
    final visited = <String>{noteId}; // Start with current note as visited
    final result = <Note>[];

    try {
      final linkedNotes = await appProvider.getLinkedNotes(noteId);
      for (final linkedNote in linkedNotes) {
        if (!visited.contains(linkedNote.id)) {
          visited.add(linkedNote.id);
          result.add(linkedNote);
        }
      }
    } catch (e) {
      LoggerService.warning('Failed to collect linked notes: $e');
    }

    return result;
  }

  Future<void> _openConversationTree() async {
    try {
      final appProvider = context.read<AppProvider>();
      final noteIds = List<String>.from(_noteOrder);
      final conversationIds = <String>{};

      // Add current conversation if it exists
      if (_conversation != null) {
        conversationIds.add(_conversation!.id);
      }

      // Collect all conversations associated with the notes
      for (final noteId in noteIds) {
        final ids = await appProvider.getNoteConversationIds(noteId);
        conversationIds.addAll(ids);
      }

      if (!mounted) return;

      // Navigate to tree view with the current conversation highlighted
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ConversationTreeScreen(
            activeConversationIds: conversationIds.toList(growable: false),
            filterByActiveConversations: conversationIds.isNotEmpty,
            onOpenConversation: _handleConversationOpenedFromTree,
          ),
        ),
      );
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to open conversation tree: $e',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading conversations: $e')),
        );
      }
    }
  }

  void _openConversationInChatMode() {
    final conversation = _conversation;
    if (conversation == null) {
      return;
    }

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) =>
            ConversationChatScreen(conversationId: conversation.id),
      ),
    );
  }

  Future<void> _openAttachment(String path, AppLocalizations l10n) async {
    try {
      await FileUtils.openFile(path, context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.failedToOpenAttachment(e.toString()))),
      );
    }
  }

  Future<void> _handleMarkdownLinkTap(String url, AppLocalizations l10n) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Invalid URL: $url')));
      return;
    }

    try {
      final canLaunchLink = await canLaunchUrl(uri);
      if (!canLaunchLink) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Could not open link: $url')));
        }
        return;
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e, stackTrace) {
      LoggerService.warning(
        'Failed to open link $url: $e',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error opening link: $e')));
      }
    }
  }

  Future<void> _sendMessage() async {
    final trimmed = _messageController.text.trim();
    if (trimmed.isEmpty && _pendingAttachments.isEmpty) {
      return;
    }

    setState(() {
      _isSending = true;
      _isAborting = false;
    });

    final content = trimmed;
    final attachments = List<PlatformFile>.from(_pendingAttachments);
    final generationContext = GenerationContext();
    if (_selectedModel != null) {
      generationContext.modelOverride = _selectedModel;
    } else {
      final caps = await AttachmentPreprocessor.detectRequiredCapabilities(
        attachments,
      );
      if (caps.isNotEmpty) {
        final preferredModel = await ModelSelector.instance
            .selectModelByPreference(caps);
        if (preferredModel != null) {
          generationContext.modelOverride = preferredModel;
        }
      }
    }
    final requestId = generationContext.ensureRequestId();
    _currentRequestId = requestId;

    _messageController.clear();
    setState(() {
      _pendingAttachments.clear();
    });

    try {
      if (_isScratchpadMode) {
        // Add to scratchpad
        final message = ConversationMessage(
          id: const Uuid().v4(), // Need uuid package or generate random string
          conversationId: _conversation?.id ?? 'scratchpad',
          content: content,
          type: MessageType.user,
          timestamp: DateTime.now(),
          attachmentPaths: attachments.map((f) => f.path!).toList(),
        );

        setState(() {
          _scratchpadItems.add(message);
          _isSending = false;
        });

        // Scroll to bottom of scratchpad?
        // We might need a separate scroll controller for scratchpad or reuse _chatScrollController if it's swapped.
        // Since we swap the view, we can reuse _chatScrollController or just let it be.
        // But _chatScrollController is attached to the ListView in _buildConversationList AND _buildScratchpadList?
        // Yes, if we reuse it, we should be careful.
        // Let's check _buildScratchpadList. I didn't assign a controller there.
        // I should assign _chatScrollController to _buildScratchpadList's ListView as well.

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_chatScrollController.hasClients) {
            _chatScrollController.animateTo(
              _chatScrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });

        return;
      }

      // Create conversation on first message if it doesn't exist
      if (_conversation == null) {
        await _initializeConversation();
      }

      if (_conversation == null) {
        throw Exception('Failed to create conversation');
      }

      final attachmentPaths = attachments
          .where((file) => file.path != null)
          .map((file) => file.path!)
          .toList();

      final userMessage = await _conversationService.addUserMessage(
        conversationId: _conversation!.id,
        content: content,
        attachmentPaths: attachmentPaths,
      );

      setState(() {
        _messages.add(userMessage);
      });
      _scrollToBottom();

      final response = await _generateAiResponse(
        content,
        attachments,
        generationContext,
      );
      final aiMessage = await _conversationService.addAIResponse(
        conversationId: _conversation!.id,
        content: response.content,
        metadata: response.metadata,
        modelUsed: response.metadata?['modelUsed'] as String?,
      );

      if (!mounted) return;
      setState(() {
        _messages.add(aiMessage);
      });
      _scrollToBottom();
    } on ConversationCancelledException {
      _cancelledRequestIds.remove(requestId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('AI request cancelled.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e, stackTrace) {
      LoggerService.error(
        'Error sending immersive message: $e',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error sending message: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _isAborting = false;
          _currentRequestId = null;
        });
      }
      _cancelledRequestIds.remove(requestId);
    }
  }

  Future<void> _abortRequest() async {
    if (!_isSending || _currentRequestId == null) return;

    setState(() {
      _isAborting = true;
    });

    if (_iterationPrompt != null) {
      _resolveIterationPrompt(null);
    }

    _cancelledRequestIds.add(_currentRequestId!);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cancelling AI request...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    await Future.delayed(const Duration(milliseconds: 500));

    if (mounted) {
      setState(() {
        _isSending = false;
        _isAborting = false;
        _currentRequestId = null;
      });
    }
  }

  Future<ConversationAiResponse> _generateAiResponse(
    String userMessage,
    List<PlatformFile> latestAttachments,
    GenerationContext generationContext,
  ) async {
    final requestId = generationContext.ensureRequestId();
    final noteBuilder = NotePromptBuilder(_databaseService);
    final systemMessage = _buildSystemPrompt();

    // Get current PDF page for window mode context filtering
    final currentPdfPage = _activeAttachmentPath != null
        ? _pdfCurrentPages[_activeAttachmentPath]
        : null;

    final contextMessage = await noteBuilder.buildContextMessage(
      _conversationNotes,
      currentPdfPage: currentPdfPage,
    );

    final messages = <PromptMessage>[];

    // Inject scratchpad content if enabled
    if (_includeScratchpadInChat && _scratchpadItems.isNotEmpty) {
      final buffer = StringBuffer();
      buffer.writeln('Scratchpad content (user notes/drawings):');
      final scratchpadAttachments = <PlatformFile>[];

      for (final item in _scratchpadItems) {
        buffer.writeln('- ${item.content}');
        if (item.attachmentPaths.isNotEmpty) {
          final itemAttachments = await _loadConversationAttachments(
            item,
            latestAttachments, // Pass latest attachments to resolve if needed, though usually for user message
          );
          scratchpadAttachments.addAll(itemAttachments);
        }
      }

      messages.add(
        PromptMessage(
          role: PromptRole.user,
          content: buffer.toString(),
          attachments: scratchpadAttachments,
          isContext: true,
        ),
      );
    }

    final currentModelId =
        generationContext.modelOverride?.id ??
        ModelSelector.instance.currentModelConfig?.id;

    for (final message in _messages) {
      // Filter out synthesized error messages
      if (message.metadata?['isSynthesized'] == true) {
        continue;
      }

      var role = message.type == MessageType.user
          ? PromptRole.user
          : PromptRole.assistant;
      var content = message.content;

      // If the message was generated by a different model, treat it as a user message
      // to avoid potential format/capability mismatches (e.g. thoughtSignature)
      if (role == PromptRole.assistant) {
        final modelUsed = message.metadata?['modelUsed'] as String?;
        if (currentModelId != null &&
            (modelUsed == null || modelUsed != currentModelId)) {
          role = PromptRole.user;
          final modelLabel = modelUsed ?? 'an earlier model';
          content = '[Response from $modelLabel]:\n$content';
        }
      }

      if (role == PromptRole.user) {
        final messageTimeContext = SystemPromptBuilder.formatTimestamp(
          message.timestamp,
        );
        final perMessageAddOn = PromptConfigurationService.instance.getValue(
          ChatPromptConfiguration.perMessageAddendumId,
        );
        final buffer = StringBuffer()
          ..write('Message created at: $messageTimeContext');
        if (perMessageAddOn != null && perMessageAddOn.trim().isNotEmpty) {
          buffer
            ..writeln()
            ..write(perMessageAddOn.trim());
        }
        messages.add(
          PromptMessage(role: PromptRole.user, content: buffer.toString()),
        );
      }

      final attachments = await _loadConversationAttachments(
        message,
        latestAttachments,
      );

      messages.add(
        PromptMessage(
          role: role,
          content: content,
          attachments: attachments,
          metadata: message.metadata,
        ),
      );

      // Add tool results from previous assistant message
      // Only add tool results if we kept it as an assistant message
      if (role == PromptRole.assistant) {
        final toolCallsWithResults =
            message.metadata?['tool_calls_with_results'] as List?;
        if (toolCallsWithResults != null && toolCallsWithResults.isNotEmpty) {
          for (final entry in toolCallsWithResults) {
            final toolCallId = entry['id'];
            final toolResult = entry['result'] as String? ?? '';
            messages.add(
              PromptMessage(
                role: PromptRole.tool,
                content: toolResult,
                metadata: {
                  if (toolCallId != null) 'tool_call_id': toolCallId,
                  ...((entry is Map<String, dynamic>) ? entry : {}),
                },
              ),
            );
          }
        }
      }
    }

    final request = PromptRequest(
      systemMessage: systemMessage,
      contextMessages:
          contextMessage.content.trim().isEmpty &&
              contextMessage.attachments.isEmpty
          ? const []
          : [contextMessage],
      conversationMessages: messages,
    );

    if (_cancelledRequestIds.contains(requestId)) {
      throw const ConversationCancelledException();
    }

    final activeTools = _buildActiveToolsMap();

    // Add model features to generation context
    if (_selectedModelFeatures.isNotEmpty) {
      generationContext.setValue(
        'modelFeatures',
        _selectedModelFeatures.toList(),
      );
    }

    final response = await _aiEngine.generate(
      request: request,
      activeTools: activeTools,
      enableTools: activeTools.isNotEmpty || _selectedModelFeatures.isNotEmpty,
      executeTool: (serviceName, toolName, params, context) async {
        return _runWithToolStatus(serviceName, toolName, () async {
          if (_aiToolBundles.containsKey(serviceName)) {
            final runtime = await _getAiToolRuntime(serviceName);
            return runtime.invoke(toolName, params, context);
          }

          return McpToolIntegrationService.executeToolCall(
            serviceName: serviceName,
            toolName: toolName,
            parameters: params,
            enabledEndpointIds: _selectedMcpEndpointIds.toList(),
            generationContext: context,
          );
        });
      },
      isCancelled: () => _cancelledRequestIds.contains(requestId),
      generationContext: generationContext,
      maxToolIterations: _maxToolIterations,
      onIterationsExhausted: _handleIterationsExhausted,
    );

    if (_cancelledRequestIds.contains(requestId)) {
      throw const ConversationCancelledException();
    }

    return response;
  }

  PromptMessage _buildSystemPrompt() {
    final lines = <String>[
      'Engage in a focused conversation grounded in the selected notes and attachments.',
      'Reference the note titles when citing content and prefer concise, direct answers.',
      'Format your responses using markdown.',
    ];

    if (_hasAnyTools) {
      lines.add(
        'The user has enabled external tools (MCP services or user-defined AI tools). Prefer calling them when they can improve accuracy before responding.',
      );
    }

    if (_conversationNotes.isEmpty) {
      lines.add(
        'No note context is currently attached. Rely on the conversation history.',
      );
    }

    final taskContext = lines.join('\n');

    final combinedTools = _buildActiveToolsMap();
    final mcpToolsPrompt = McpToolIntegrationService.buildMcpSystemPrompt(
      combinedTools,
    );

    final systemAddOn = PromptConfigurationService.instance.getValue(
      ChatPromptConfiguration.systemAddendumId,
    );
    final contextBuffer = StringBuffer(taskContext);
    if (systemAddOn != null && systemAddOn.trim().isNotEmpty) {
      contextBuffer
        ..writeln()
        ..writeln('User-defined conversation guidance:')
        ..writeln(systemAddOn.trim());
    }
    if (mcpToolsPrompt.trim().isNotEmpty) {
      contextBuffer
        ..writeln()
        ..writeln(mcpToolsPrompt.trim());
    }

    return SystemPromptBuilder.build(
      taskContext: contextBuffer.toString(),
      guidelines: [
        'Highlight referenced note sections explicitly when possible.',
        AIPrompts.mathFormulaGuidelines,
        AIPrompts.relationshipGuidelines,
        AIPrompts.promptInjectionProtectionGuidelines,
      ],
      now: _sessionStart,
      needTimeInContext: false,
    );
  }

  Future<List<PlatformFile>> _loadConversationAttachments(
    ConversationMessage message,
    List<PlatformFile> latestUserAttachments,
  ) async {
    if (message.type != MessageType.user) {
      return const [];
    }

    final isMostRecent =
        _messages.isNotEmpty && identical(message, _messages.last);
    if (isMostRecent && latestUserAttachments.isNotEmpty) {
      return latestUserAttachments;
    }

    if (message.attachmentPaths.isEmpty) {
      return const [];
    }

    final files = <PlatformFile>[];
    for (final path in message.attachmentPaths) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        files.add(
          PlatformFile(
            name: path.split(Platform.pathSeparator).last,
            path: file.path,
            size: bytes.length,
            bytes: bytes,
          ),
        );
      } catch (e) {
        LoggerService.warning('Failed to load attachment $path: $e');
      }
    }
    return files;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScrollController.hasClients) return;
      _chatScrollController.animateTo(
        _chatScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  void _handlePenPanStart(DragStartDetails details) {
    final renderObject = _noteBoundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return;
    final localPosition = renderObject.globalToLocal(details.globalPosition);

    setState(() {
      if (_currentTool == DrawingTool.pen) {
        _penStrokePoints
          ..clear()
          ..add(localPosition);
      } else if (_currentTool == DrawingTool.rectangle) {
        _currentRectStart = localPosition;
        _currentRectEnd = localPosition;
      }
    });
  }

  void _handlePenPanUpdate(DragUpdateDetails details) {
    final renderObject = _noteBoundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return;
    final localPosition = renderObject.globalToLocal(details.globalPosition);

    setState(() {
      if (_currentTool == DrawingTool.pen) {
        final lastPoint = _penStrokePoints.isEmpty
            ? null
            : _penStrokePoints.last;
        if (lastPoint == null ||
            (lastPoint - localPosition).distanceSquared > 1) {
          _penStrokePoints.add(localPosition);
        }
      } else if (_currentTool == DrawingTool.rectangle) {
        _currentRectEnd = localPosition;
      }
    });
  }

  void _handlePenPanEnd() {
    setState(() {
      if (_currentTool == DrawingTool.pen) {
        if (_penStrokePoints.length >= 2) {
          final points = List<Offset>.from(_penStrokePoints);
          _drawingActions.add(StrokeAction(points, _currentColor));
          _redoStack.clear();
        }
        _penStrokePoints.clear();
      } else if (_currentTool == DrawingTool.rectangle) {
        if (_currentRectStart != null && _currentRectEnd != null) {
          final rect = Rect.fromPoints(_currentRectStart!, _currentRectEnd!);
          if (rect.width > 0 && rect.height > 0) {
            _drawingActions.add(RectangleAction(rect, _currentColor));
            _redoStack.clear();
          }
        }
        _currentRectStart = null;
        _currentRectEnd = null;
      }
    });
  }

  void _resetPenStroke() {
    if (_penStrokePoints.isEmpty) {
      return;
    }
    setState(() {
      _penStrokePoints.clear();
    });
  }

  void _disposePdfResources() {
    // Dispose PDF documents
    for (final doc in _pdfDocuments.values) {
      doc.dispose();
    }
    _pdfDocuments.clear();
    _pdfViewerControllers.clear();
    _pdfOutlines.clear();
    _pdfCurrentPages.clear();
    _pdfTotalPages.clear();
    _attachmentSourceFutures.clear();
  }

  void _disposeImageResources() {
    for (final controller in _imageTransforms.values) {
      controller.dispose();
    }
    _imageTransforms.clear();
  }

  void _resetPdfState() {
    _disposePdfResources();
  }

  TransformationController _ensureImageTransformationController(String path) {
    return _imageTransforms.putIfAbsent(path, () => TransformationController());
  }

  Future<bool> _switchConversation(String conversationId) async {
    setState(() => _isLoadingConversation = true);

    try {
      final result = await _conversationService.getConversationWithFullHistory(
        conversationId,
      );

      if (result == null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Conversation not found.')));
        }
        return false;
      }

      final conversationNotes = await _conversationService.getConversationNotes(
        conversationId,
      );

      if (!mounted) return false;

      setState(() {
        _resetPdfState();
        _disposeImageResources();
        _conversation = result.conversation;
        _hasAssociatedConversations = true;
        _messages
          ..clear()
          ..addAll(result.messages);
        _conversationNotes = conversationNotes;
        for (final note in conversationNotes) {
          _initialNotesById[note.id] = note;
        }
        if (conversationNotes.isNotEmpty) {
          _noteOrder = conversationNotes.map((note) => note.id).toList();
          _activeNoteIndex = min(
            _activeNoteIndex,
            conversationNotes.length - 1,
          );
        } else if (_noteOrder.isNotEmpty) {
          _activeNoteIndex = min(_activeNoteIndex, _noteOrder.length - 1);
        } else if (_initialNotesById.isNotEmpty) {
          _noteOrder = _initialNotesById.keys.toList();
          _activeNoteIndex = 0;
        } else {
          _activeNoteIndex = 0;
        }
        _activeAttachmentPath = null;
      });

      _scrollToBottom();
      return true;
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to load conversation $conversationId: $e',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to open conversation: $e')),
        );
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _isLoadingConversation = false);
      }
    }
  }

  Future<bool> _handleConversationOpenedFromTree(
    BuildContext treeContext,
    String conversationId,
  ) async {
    final success = await _switchConversation(conversationId);
    if (success) {
      final navigator = Navigator.of(treeContext);
      if (navigator.canPop()) {
        await navigator.maybePop();
      }
    }
    return success;
  }

  Rect _computeStrokeBounds(List<Offset> points) {
    double minX = points.first.dx;
    double maxX = points.first.dx;
    double minY = points.first.dy;
    double maxY = points.first.dy;

    for (final point in points.skip(1)) {
      if (point.dx < minX) minX = point.dx;
      if (point.dx > maxX) maxX = point.dx;
      if (point.dy < minY) minY = point.dy;
      if (point.dy > maxY) maxY = point.dy;
    }

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  Rect _clampRectToSize(Rect rect, Size size) {
    final double left = rect.left.clamp(0.0, size.width).toDouble();
    final double top = rect.top.clamp(0.0, size.height).toDouble();
    final double right = rect.right.clamp(0.0, size.width).toDouble();
    final double bottom = rect.bottom.clamp(0.0, size.height).toDouble();
    final double width = max(0.0, right - left);
    final double height = max(0.0, bottom - top);
    return Rect.fromLTWH(left, top, width, height);
  }

  Future<Uint8List> _captureDrawing(
    List<DrawingAction> actions,
    Rect bounds,
  ) async {
    final renderObject = _noteBoundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      throw Exception('Note view unavailable for capture.');
    }

    final Rect cappedRect = _clampRectToSize(
      bounds.inflate(_strokeCaptureMargin),
      renderObject.size,
    );

    if (cappedRect.width <= 0 || cappedRect.height <= 0) {
      throw Exception('Failed to determine annotation bounds.');
    }

    final double devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    Uint8List? regionBytes;
    if (Platform.isIOS || (Platform.isAndroid && _hasWebViewNotifier.value)) {
      final Offset boundaryOrigin = renderObject.localToGlobal(Offset.zero);
      final Offset captureOrigin =
          boundaryOrigin + Offset(cappedRect.left, cappedRect.top);
      regionBytes = await NativeCaptureUtils.captureRegion(
        x: captureOrigin.dx,
        y: captureOrigin.dy,
        width: cappedRect.width,
        height: cappedRect.height,
        devicePixelRatio: devicePixelRatio,
      );
      if (regionBytes != null && regionBytes.isEmpty) {
        regionBytes = null;
      }
    }

    ui.Image baseImage;
    Rect sourceRect;
    late int outputWidth;
    late int outputHeight;

    if (regionBytes != null) {
      final ui.Codec codec = await ui.instantiateImageCodec(regionBytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      codec.dispose();
      baseImage = frame.image;
      sourceRect = Rect.fromLTWH(
        0,
        0,
        baseImage.width.toDouble(),
        baseImage.height.toDouble(),
      );
      outputWidth = baseImage.width;
      outputHeight = baseImage.height;
    } else {
      baseImage = await renderObject.toImage(pixelRatio: devicePixelRatio);
      sourceRect = Rect.fromLTWH(
        cappedRect.left * devicePixelRatio,
        cappedRect.top * devicePixelRatio,
        cappedRect.width * devicePixelRatio,
        cappedRect.height * devicePixelRatio,
      );
      outputWidth = max(1, sourceRect.width.round());
      outputHeight = max(1, sourceRect.height.round());
    }

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final Paint paint = Paint();

    final Rect targetRect = Rect.fromLTWH(
      0,
      0,
      outputWidth.toDouble(),
      outputHeight.toDouble(),
    );
    canvas.drawImageRect(baseImage, sourceRect, targetRect, paint);

    // Scale context for drawing
    canvas.save();
    canvas.scale(devicePixelRatio, devicePixelRatio);
    canvas.translate(-cappedRect.left, -cappedRect.top);

    for (final action in actions) {
      if (action is StrokeAction) {
        if (action.points.length >= 2) {
          final Path strokePath = _DrawingLayerPainter.buildStrokePath(
            action.points,
          );

          final Paint glowPaint = Paint()
            ..color = action.color.withOpacity(0.18)
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = 8;

          final Paint strokePaint = Paint()
            ..color = action.color
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = 3;

          canvas.drawPath(strokePath, glowPaint);
          canvas.drawPath(strokePath, strokePaint);
        }
      } else if (action is RectangleAction) {
        final Paint glowPaint = Paint()
          ..color = action.color.withOpacity(0.18)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = 8;

        final Paint strokePaint = Paint()
          ..color = action.color
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = 3;

        canvas.drawRect(action.rect, glowPaint);
        canvas.drawRect(action.rect, strokePaint);
      }
    }

    canvas.restore();

    final ui.Picture picture = recorder.endRecording();
    final ui.Image croppedImage = await picture.toImage(
      outputWidth,
      outputHeight,
    );
    baseImage.dispose();

    final ByteData? byteData = await croppedImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    croppedImage.dispose();

    if (byteData == null) {
      throw Exception('Failed to encode annotation.');
    }

    return byteData.buffer.asUint8List();
  }

  Future<_AttachmentSource?> _loadAttachmentSource(String path) async {
    try {
      if (SynapseTempUtils.isSynapseTempUri(path)) {
        final tempFile = await SynapseTempUtils.loadFile(path);
        return _AttachmentSource(
          file: tempFile.file,
          bytes: tempFile.bytes,
          extension: FileTypeUtils.getFileExtension(tempFile.fileName),
          originalPath: tempFile.file.path,
        );
      }

      final file = File(path);
      if (!await file.exists()) {
        return null;
      }
      final extension = FileTypeUtils.getFileExtension(file.path);

      // For PDFs, look up the attachment to get ID and last page
      String? attachmentId;
      int? initialPage;
      if (extension == 'pdf') {
        final attachment = await _findAttachmentByPath(path);
        if (attachment != null) {
          attachmentId = attachment.id;
          initialPage = attachment.getLastViewedPage();
          LoggerService.debug(
            'PDF attachment loaded: id=$attachmentId, initialPage=$initialPage, path=$path',
          );
        } else {
          LoggerService.debug('PDF attachment not found for path: $path');
        }
      }

      return _AttachmentSource(
        file: file,
        extension: extension,
        originalPath: file.path,
        attachmentId: attachmentId,
        initialPage: initialPage,
      );
    } catch (e) {
      LoggerService.warning('Failed to load attachment $path: $e');
      return null;
    }
  }

  /// Finds attachment by absolute path across all notes
  Future<Attachment?> _findAttachmentByPath(String path) async {
    final databaseService = DatabaseService();
    for (final note in widget.notes) {
      final attachments = await databaseService.getAttachmentsForNote(note.id);
      for (final attachment in attachments) {
        final absPath = await attachment.getAbsolutePath();
        if (absPath == path) {
          return attachment;
        }
      }
    }
    return null;
  }

  IconData _iconForAttachment(String path) {
    final extension = FileTypeUtils.getFileExtension(path);
    switch (extension) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'svg':
        return Icons.photo_size_select_large;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
      case 'bmp':
        return Icons.image;
      default:
        return Icons.insert_drive_file;
    }
  }

  int? _findNoteIndexForAttachment(String attachmentPath, List<Note> notes) {
    for (var i = 0; i < notes.length; i++) {
      if (notes[i].attachmentPaths.contains(attachmentPath)) {
        return i;
      }
    }
    return null;
  }

  bool _isImageExtension(String extension) {
    return const {
      'png',
      'jpg',
      'jpeg',
      'gif',
      'bmp',
      'webp',
    }.contains(extension);
  }

  Future<void> _openDrawingEditor() async {
    try {
      final File? drawnFile = await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const DrawingEditor()),
      );

      if (drawnFile != null) {
        final bytes = await drawnFile.readAsBytes();
        final platformFile = PlatformFile(
          name: drawnFile.path.split('/').last,
          size: bytes.length,
          bytes: bytes,
          path: drawnFile.path,
        );

        if (mounted) {
          setState(() {
            _pendingAttachments.add(platformFile);
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Drawing added to attachments.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error adding drawing: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }
}

class _AttachmentSource {
  _AttachmentSource({
    required this.file,
    required this.extension,
    required this.originalPath,
    this.bytes,
    this.attachmentId,
    this.initialPage,
  });

  final File file;
  final Uint8List? bytes;
  final String extension;
  final String originalPath;
  final String? attachmentId; // For saving page position
  final int? initialPage; // Last viewed page from DB

  String get cacheKey => originalPath;
}

class _PdfDocumentView extends StatefulWidget {
  const _PdfDocumentView({
    required this.source,
    required this.availableHeight,
    required this.currentPageMap,
    required this.totalPageMap,
    required this.controllerMap,
    required this.onError,
    this.onDocumentReady,
    this.isNightMode = false,
  });

  final _AttachmentSource source;
  final double availableHeight;
  final Map<String, int> currentPageMap;
  final Map<String, int> totalPageMap;
  final Map<String, PdfViewerController> controllerMap;
  final void Function(String message) onError;
  final void Function(
    String cacheKey,
    PdfDocument document,
    List<PdfOutlineNode>? outline,
  )?
  onDocumentReady;
  final bool isNightMode;

  @override
  State<_PdfDocumentView> createState() => _PdfDocumentViewState();
}

class _PdfDocumentViewState extends State<_PdfDocumentView>
    with AutomaticKeepAliveClientMixin {
  late Future<String> _pdfPathFuture;
  String? _resolvedPath;
  PdfViewerController? _controller;
  bool _documentReady = false;

  String get _cacheKey => widget.source.cacheKey;

  @override
  void initState() {
    super.initState();
    _pdfPathFuture = _resolvePdfPath();
    _controller = PdfViewerController();
    widget.controllerMap[_cacheKey] = _controller!;
  }

  @override
  void didUpdateWidget(covariant _PdfDocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.cacheKey != widget.source.cacheKey) {
      _pdfPathFuture = _resolvePdfPath();
      _resolvedPath = null;
      _documentReady = false;
      _controller = PdfViewerController();
      widget.controllerMap[_cacheKey] = _controller!;
    }
  }

  Future<String> _resolvePdfPath() async {
    final file = widget.source.file;
    if (await file.exists()) {
      return file.path;
    }

    final bytes = widget.source.bytes ?? await file.readAsBytes();
    final result = await SynapseTempUtils.saveTempData(
      mimeType: 'application/pdf',
      bytes: bytes,
    );
    return result.file.path;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<String>(
      future: _pdfPathFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.hasError) {
          return const Center(child: Text('Failed to load PDF'));
        }

        final filePath = snapshot.data!;
        _resolvedPath = filePath;
        return _buildPdfView(filePath);
      },
    );
  }

  Widget _buildPdfView(String filePath) {
    // Use initialPage from source (database) if runtime map doesn't have it
    final storedPage = widget.source.initialPage ?? 0;
    widget.currentPageMap.putIfAbsent(_cacheKey, () => storedPage);
    final initialPage = widget.currentPageMap[_cacheKey] ?? storedPage;

    return ColorFiltered(
      colorFilter: ColorFilter.mode(
        Colors.white,
        widget.isNightMode ? BlendMode.difference : BlendMode.dst,
      ),
      child: PdfViewer.file(
        filePath,
        key: ValueKey('${_cacheKey}_pdf_view'),
        controller: _controller,
        params: PdfViewerParams(
          textSelectionParams: const PdfTextSelectionParams(),
          pageDropShadow: null,
          onViewerReady: (document, controller) async {
            if (_documentReady) return;
            _documentReady = true;

            // Store total pages
            widget.totalPageMap[_cacheKey] = document.pages.length;

            // Load outline
            List<PdfOutlineNode>? outline;
            try {
              outline = await document.loadOutline();
            } catch (e) {
              // Outline loading failed, not critical
            }

            // Notify parent
            widget.onDocumentReady?.call(_cacheKey, document, outline);

            // Navigate to stored page
            if (initialPage > 0 && initialPage < document.pages.length) {
              try {
                await controller.goToPage(
                  pageNumber: initialPage + 1,
                ); // pdfrx uses 1-indexed pages
              } catch (e) {
                widget.onError('Unable to set initial PDF page: $e');
              }
            }
          },
          onPageChanged: (pageNumber) {
            if (pageNumber != null) {
              // pdfrx uses 1-indexed page numbers, convert to 0-indexed for storage
              widget.currentPageMap[_cacheKey] = pageNumber - 1;
            }
          },
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    // Save current page to database before disposing
    final attachmentId = widget.source.attachmentId;
    final currentPage = widget.currentPageMap[_cacheKey];
    if (attachmentId != null && currentPage != null && currentPage > 0) {
      DatabaseService().updateLastViewedPage(attachmentId, currentPage);
    }

    widget.controllerMap.remove(_cacheKey);
    super.dispose();
  }
}

class _DrawingLayerPainter extends CustomPainter {
  _DrawingLayerPainter({
    required this.actions,
    this.activeStroke,
    this.activeRect,
    this.activeColor = Colors.redAccent,
  });

  final List<DrawingAction> actions;
  final List<Offset>? activeStroke;
  final Rect? activeRect;
  final Color activeColor;

  @override
  void paint(Canvas canvas, Size size) {
    // Draw committed actions
    for (final action in actions) {
      _paintAction(canvas, action);
    }

    // Draw active stroke
    if (activeStroke != null && activeStroke!.length >= 2) {
      _paintStroke(canvas, activeStroke!, activeColor);
    }

    // Draw active rect
    if (activeRect != null) {
      _paintRect(canvas, activeRect!, activeColor);
    }
  }

  void _paintAction(Canvas canvas, DrawingAction action) {
    if (action is StrokeAction) {
      _paintStroke(canvas, action.points, action.color);
    } else if (action is RectangleAction) {
      _paintRect(canvas, action.rect, action.color);
    }
  }

  void _paintStroke(Canvas canvas, List<Offset> points, Color color) {
    final path = buildStrokePath(points);

    final glowPaint = Paint()
      ..color = color.withOpacity(0.18)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 8;

    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 3;

    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, strokePaint);
  }

  void _paintRect(Canvas canvas, Rect rect, Color color) {
    final glowPaint = Paint()
      ..color = color.withOpacity(0.18)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 8;

    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 3;

    canvas.drawRect(rect, glowPaint);
    canvas.drawRect(rect, strokePaint);
  }

  static Path buildStrokePath(List<Offset> points) {
    final path = Path();
    if (points.isEmpty) return path;
    path.moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      final prev = points[i - 1];
      final current = points[i];
      final midPoint = Offset(
        (prev.dx + current.dx) / 2,
        (prev.dy + current.dy) / 2,
      );
      path.quadraticBezierTo(prev.dx, prev.dy, midPoint.dx, midPoint.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }

  @override
  bool shouldRepaint(covariant _DrawingLayerPainter oldDelegate) {
    // Basic optimization: if list references changed, rebuild.
    // Deep equality check might be expensive if many strokes.
    return oldDelegate.actions != actions ||
        oldDelegate.activeStroke != activeStroke ||
        oldDelegate.activeRect != activeRect ||
        oldDelegate.activeColor != activeColor;
  }
}

enum _AiPanelSide { top, bottom, left, right }
