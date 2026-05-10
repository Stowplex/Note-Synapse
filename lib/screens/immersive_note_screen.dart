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
import '../services/context_manager_service.dart';
import '../services/model_selector.dart';
import '../services/service_locator.dart';
import '../services/attachment_preprocessor.dart';
import '../services/local_model_attachment_constraint_service.dart';
import '../services/conversation_attachment_service.dart';
import '../services/conversation_prompt_builder.dart';
import '../services/marker_cluster_service.dart';
import '../services/prompts/ai_prompts.dart';
import '../services/prompts/note_prompt_builder.dart';
import '../services/prompts/prompt_models.dart';
import '../services/prompts/prompt_configuration_service.dart';
import '../services/prompts/registrations/chat_prompt_configuration.dart';
import '../services/prompts/system_prompt_builder.dart';
import '../services/sql_query_service.dart';
import '../services/user_app_service.dart';
import '../services/agent_service.dart';
import '../services/chat_tool_session.dart';
import '../utils/file_type_utils.dart';
import '../utils/file_utils.dart';
import '../utils/conversation_title_directive.dart';
import '../utils/native_capture_utils.dart';
import '../utils/synapse_temp_utils.dart';
import '../widgets/approval_dialog.dart';
import '../widgets/heading_anchor_registry.dart';
import '../widgets/interactive_checkbox_markdown.dart';
import '../mixins/note_action_mixin.dart';
import '../widgets/chat_panel.dart';
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
import '../widgets/attachment_preview_tile.dart';
import '../services/built_in_tools_service.dart';
import '../services/skill_service.dart';
import '../models/in_note_marker.dart';
import '../models/note_annotation.dart';
import '../services/note_marker_service.dart';
import '../services/note_annotation_service.dart';
import '../widgets/in_note_marker_badge.dart';
import '../widgets/in_note_marker_preview.dart';
import '../widgets/tool_orchestration_warning_dialog.dart';
import '../widgets/local_model_attachment_warning_dialog.dart';
import '../widgets/in_note_annotation_preview.dart';

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
    this.initialPage,
    this.initialConversation,
    this.initialMessages = const [],
  }) : assert(notes.length > 0, 'Immersive mode requires at least one note.');

  final List<Note> notes;
  final String? initialAttachmentPath;
  final int? initialPage;
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
  ConversationService get _conversationService => getIt<ConversationService>();
  final DatabaseService _databaseService = DatabaseService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode();
  final GlobalKey _noteBoundaryKey = GlobalKey();
  final GlobalKey _noteContentKey = GlobalKey();
  final GlobalKey<ChatPanelState> _chatPanelKey = GlobalKey<ChatPanelState>();

  static const double _strokeCaptureMargin = 16;

  late final Map<String, Note> _initialNotesById;
  late List<String> _noteOrder;
  final List<ConversationMessage> _messages = [];
  final List<PlatformFile> _pendingAttachments = [];
  InNoteMarkerPosition? _pendingMarkerPosition;
  final Map<String, List<InNoteMarker>> _attachmentMarkers = {};
  final Map<String, List<InNoteMarker>> _noteMarkers = {};
  late final NoteMarkerService _noteMarkerService = getIt<NoteMarkerService>();
  late final NoteAnnotationService _noteAnnotationService =
      getIt<NoteAnnotationService>();
  final Map<String, Future<_AttachmentSource?>> _attachmentSourceFutures = {};
  final Map<String, int> _pdfCurrentPages = {};
  final Map<String, int> _pdfTotalPages = {};
  final Map<String, PdfAiContextConfig> _pdfContextConfigs = {};
  final Map<String, PdfViewerController> _pdfViewerControllers = {};
  final Map<String, PdfDocument> _pdfDocuments = {};
  final Map<String, List<PdfOutlineNode>> _pdfOutlines = {};
  final Map<String, TransformationController> _imageTransforms = {};
  TransformationController? _activeImageTransform;

  final ConversationAiEngine _aiEngine = const ConversationAiEngine();
  Conversation? _conversation;
  List<Note> _conversationNotes = [];
  bool _hasAssociatedConversations = false;

  bool _isPenMode = false;
  bool _isLoadingConversation = true;
  bool _isSending = false;
  String _streamingContent = '';
  bool _isStreaming = false;
  bool _isAborting = false;
  String? _initialMessageIdForBranchSwitch;
  String? _currentRequestId;
  final Set<String> _cancelledRequestIds = {};
  final ValueNotifier<bool> _hasWebViewNotifier = ValueNotifier(false);

  /// Registry that powers GitHub-style `[text](#section)` anchor links inside
  /// the main note's rendered markdown. Owned by this state and reused across
  /// builds; `InteractiveCheckboxMarkdown` clears it on each render pass so
  /// duplicate-slug counters stay deterministic.
  final HeadingAnchorRegistry _noteAnchorRegistry = HeadingAnchorRegistry();

  // Scratchpad State
  bool _isScratchpadMode = false;
  final List<ConversationMessage> _scratchpadItems = [];
  bool _includeScratchpadInChat = false;
  int _lastSavedScratchpadCount = 0;
  final List<NormalizedRect> _pendingMarkerRawRects = [];
  MarkerPlacementMode _pendingMarkerPlacementMode = MarkerPlacementMode.auto;
  bool _pendingMarkerSupportsSplit = false;
  int? _pendingMarkerPage;

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

  // System Tools (native tools from AgentService)
  final Set<String> _selectedSystemTools = {};

  // Agent Skills
  bool _skillsEnabled = false;
  int _skillCount = 0;

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
    getIt<SkillService>().buildSkillIndex().then((index) {
      if (mounted) setState(() => _skillCount = index.length);
    });

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
      if (widget.initialPage != null) {
        _pdfCurrentPages[widget.initialAttachmentPath!] = widget.initialPage!;
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
      // Load markers for the initial content.
      if (_activeAttachmentPath != null) {
        _loadMarkersForAttachment(_activeAttachmentPath!);
      } else {
        _loadMarkersForNote(widget.notes[_activeNoteIndex].id);
      }
    });
  }

  /// Sets up the unified approval callback for AI tools.
  void _setupApprovalCallback() {
    ApprovalService.onApprovalRequest = (request) async {
      if (!mounted) {
        throw StateError('Immersive note screen is not mounted');
      }
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
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingConversation = false;
        });
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
      final endpoints = await getIt<McpService>().getEndpoints();
      // Only show endpoints that have cached tools
      final endpointsWithTools = <McpEndpoint>[];
      for (final endpoint in endpoints) {
        final cache = await getIt<McpService>().getCachedTools(endpoint.id);
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
        final revision = await getIt<UserAppService>().getAppRevision(
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

    // Add System Tools (native tools from AgentService)
    if (_selectedSystemTools.isNotEmpty) {
      final agentService = context.read<AgentService>();
      final systemTools = _selectedSystemTools
          .map((id) {
            final nativeTool = agentService.nativeTools
                .where((t) => t.name == id)
                .firstOrNull;
            if (nativeTool == null) return null;
            return McpTool(
              name: nativeTool.name,
              description: nativeTool.description,
              inputSchema: nativeTool.inputSchema,
            );
          })
          .where((t) => t != null)
          .cast<McpTool>()
          .toList();
      if (systemTools.isNotEmpty) {
        combined[BuiltInToolsService.systemToolsServiceKey] = systemTools;
      }
    }

    if (_conversationService.skillsEnabled) {
      final skillTools = <McpTool>[
        McpTool(
          name: _conversationService.loadSkillTool.name,
          description: _conversationService.loadSkillTool.description,
          inputSchema: _conversationService.loadSkillTool.inputSchema,
        ),
      ];
      for (final tool in _conversationService.skillDiscoveredTools) {
        if (!skillTools.any((existing) => existing.name == tool.name)) {
          skillTools.add(tool);
        }
      }
      combined[ChatToolSession.skillToolsServiceKey] = skillTools;
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

  Future<AiToolRuntime> _getSkillAiToolRuntime(
    String serviceName,
    AiToolAppBundle bundle,
  ) async {
    final existing = _aiToolRuntimes[serviceName];
    if (existing != null) return existing;
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
      queryTypeDescription: getIt<SqlQueryService>().getQueryTypeDescription(
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
                              _isPdfNightMode ? l10n.dayMode : l10n.nightMode,
                            ),
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
        if (_pendingAttachments.isNotEmpty || _pendingMarkerSupportsSplit)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_pendingAttachments.isNotEmpty)
                  _buildPendingAttachmentsPreview(l10n),
                if (_pendingMarkerSupportsSplit) ...[
                  if (_pendingAttachments.isNotEmpty) const SizedBox(height: 8),
                  _buildMarkerPlacementModeSelector(theme),
                ],
              ],
            ),
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
                                // Only reset marker position if nothing has been queued yet
                                if (_pendingAttachments.isEmpty) {
                                  _clearPendingMarkerState();
                                }
                              } else {
                                // Initialize new drawing session
                                _drawingActions.clear();
                                _redoStack.clear();
                                _penStrokePoints.clear();
                                // Do NOT reset _pendingMarkerPosition here;
                                // previously confirmed rects must be preserved
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
                          tooltip: l10n.scratchpad,
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
                              ? l10n.sendToScratchpad
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

  Future<void> _confirmDrawing({bool silent = false}) async {
    if (_drawingActions.isEmpty) return;

    // Calculate bounds of all actions individually
    final List<Rect> actionBoundsList = [];
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
      actionBoundsList.add(actionBounds);

      if (totalBounds == null) {
        totalBounds = actionBounds;
      } else {
        totalBounds = totalBounds.expandToInclude(actionBounds);
      }
    }

    if (totalBounds == null || actionBoundsList.isEmpty) return;
    final newRects = _computeMarkerRects(actionBoundsList, totalBounds);
    if (newRects != null) {
      if (_pendingMarkerRawRects.isEmpty) {
        _pendingMarkerPlacementMode = MarkerPlacementMode.auto;
      }
      _pendingMarkerRawRects.addAll(newRects.rects);
      _pendingMarkerPage ??= newRects.page;
      _pendingMarkerSupportsSplit =
          MarkerClusterService.shouldOfferSplitOverride(_pendingMarkerRawRects);
      if (!_pendingMarkerSupportsSplit &&
          _pendingMarkerPlacementMode == MarkerPlacementMode.split) {
        _pendingMarkerPlacementMode = MarkerPlacementMode.auto;
      }
      _rebuildPendingMarkerPosition();
    }

    try {
      final imageBytes = await _captureDrawing(_drawingActions, totalBounds);
      final result = await SynapseTempUtils.saveTempData(
        mimeType: 'image/png',
        bytes: imageBytes,
      );

      final platformFile = PlatformFile(
        name: 'annotation_${DateTime.now().millisecondsSinceEpoch}.png',
        path: result.uri,
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
        if (!silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Annotation added to attachments.')),
          );
        }
      }
    } catch (e, stackTrace) {
      _clearPendingMarkerState();
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

  _MarkerRectComputation? _computeMarkerRects(
    List<Rect> drawBoundsList,
    Rect totalBounds,
  ) {
    if (_activeAttachmentPath != null) {
      final path = _activeAttachmentPath!;
      final extension = path.split('.').last.toLowerCase();
      if (extension == 'pdf') {
        final controller = _pdfViewerControllers[path];
        final currentPage = _pdfCurrentPages[path] ?? 0; // 0-indexed
        if (controller != null && controller.isReady) {
          try {
            final pageLayouts = controller.layout.pageLayouts;
            if (currentPage < pageLayouts.length) {
              final visibleRect = controller.visibleRect;
              final viewSize = controller.viewSize;
              final scaleX = viewSize.width / visibleRect.width;
              final scaleY = viewSize.height / visibleRect.height;
              final pageDocRect = pageLayouts[currentPage];
              final pageScreenLeft =
                  (pageDocRect.left - visibleRect.left) * scaleX;
              final pageScreenTop =
                  (pageDocRect.top - visibleRect.top) * scaleY;
              final pageScreenW = pageDocRect.width * scaleX;
              final pageScreenH = pageDocRect.height * scaleY;
              if (pageScreenW > 0 && pageScreenH > 0) {
                final norms = drawBoundsList.map((drawBounds) {
                  return NormalizedRect(
                    x: ((drawBounds.left - pageScreenLeft) / pageScreenW).clamp(
                      0.0,
                      1.0,
                    ),
                    y: ((drawBounds.top - pageScreenTop) / pageScreenH).clamp(
                      0.0,
                      1.0,
                    ),
                    w: (drawBounds.width / pageScreenW).clamp(0.0, 1.0),
                    h: (drawBounds.height / pageScreenH).clamp(0.0, 1.0),
                  );
                }).toList();
                return _MarkerRectComputation(rects: norms, page: currentPage);
              }
            }
          } catch (_) {
            // fall through to widget-size fallback
          }
        }
        // Fallback: normalize by widget size (used if controller not ready)
        final renderObject = _noteBoundaryKey.currentContext
            ?.findRenderObject();
        if (renderObject is! RenderRepaintBoundary || renderObject.size.isEmpty)
          return null;
        final size = renderObject.size;
        final norms = drawBoundsList
            .map(
              (drawBounds) => NormalizedRect(
                x: (drawBounds.left / size.width).clamp(0.0, 1.0),
                y: (drawBounds.top / size.height).clamp(0.0, 1.0),
                w: (drawBounds.width / size.width).clamp(0.0, 1.0),
                h: (drawBounds.height / size.height).clamp(0.0, 1.0),
              ),
            )
            .toList();
        return _MarkerRectComputation(rects: norms);
      } else {
        // Non-PDF attachment (image, etc.).
        // Drawing coordinates are in viewport space.  When the image is
        // zoomed/panned via InteractiveViewer, we must apply the INVERSE of
        // the current transform to map viewport coords → image-space coords
        // before normalising.
        final renderObject = _noteBoundaryKey.currentContext
            ?.findRenderObject();
        if (renderObject is! RenderBox || renderObject.size.isEmpty) {
          return null;
        }
        final size = renderObject.size;
        final matrix = _activeImageTransform?.value ?? Matrix4.identity();
        final inverseMatrix = Matrix4.inverted(matrix);
        final norms = drawBoundsList.map((drawBounds) {
          final topLeft = MatrixUtils.transformPoint(
            inverseMatrix,
            Offset(drawBounds.left, drawBounds.top),
          );
          final bottomRight = MatrixUtils.transformPoint(
            inverseMatrix,
            Offset(drawBounds.right, drawBounds.bottom),
          );
          return NormalizedRect(
            x: (topLeft.dx / size.width).clamp(0.0, 1.0),
            y: (topLeft.dy / size.height).clamp(0.0, 1.0),
            w: ((bottomRight.dx - topLeft.dx) / size.width).clamp(0.0, 1.0),
            h: ((bottomRight.dy - topLeft.dy) / size.height).clamp(0.0, 1.0),
          );
        }).toList();
        return _MarkerRectComputation(rects: norms);
      }
    } else {
      // Text note mode
      final contentRenderObject = _noteContentKey.currentContext
          ?.findRenderObject();
      final boundaryRenderObject = _noteBoundaryKey.currentContext
          ?.findRenderObject();
      if (contentRenderObject is! RenderBox ||
          boundaryRenderObject is! RenderBox ||
          contentRenderObject.size.isEmpty) {
        return null;
      }
      final size = contentRenderObject.size;
      final contentOriginInBoundary = contentRenderObject.localToGlobal(
        Offset.zero,
        ancestor: boundaryRenderObject,
      );

      final norms = drawBoundsList.map((drawBounds) {
        final localLeft = drawBounds.left - contentOriginInBoundary.dx;
        final localTop = drawBounds.top - contentOriginInBoundary.dy;
        return NormalizedRect(
          x: (localLeft / size.width).clamp(0.0, 1.0),
          y: (localTop / size.height).clamp(0.0, 1.0),
          w: (drawBounds.width / size.width).clamp(0.0, 1.0),
          h: (drawBounds.height / size.height).clamp(0.0, 1.0),
        );
      }).toList();
      return _MarkerRectComputation(rects: norms);
    }
  }

  MarkerPlacementMode _effectivePendingMarkerPlacementMode() {
    if (_pendingMarkerPlacementMode == MarkerPlacementMode.auto) {
      return MarkerPlacementMode.split;
    }
    return _pendingMarkerPlacementMode;
  }

  void _rebuildPendingMarkerPosition() {
    if (_pendingMarkerRawRects.isEmpty) {
      _pendingMarkerPosition = null;
      _pendingMarkerSupportsSplit = false;
      return;
    }

    final rects = MarkerClusterService.buildPlacementRects(
      _pendingMarkerRawRects,
      mode: _effectivePendingMarkerPlacementMode(),
    );
    if (rects.isEmpty) {
      _pendingMarkerPosition = null;
      return;
    }

    _pendingMarkerPosition = InNoteMarkerPosition(
      normalizedRect: rects.first,
      normalizedRects: rects,
      page: _pendingMarkerPage,
    );
  }

  void _clearPendingMarkerState() {
    _pendingMarkerPosition = null;
    _pendingMarkerRawRects.clear();
    _pendingMarkerPlacementMode = MarkerPlacementMode.auto;
    _pendingMarkerSupportsSplit = false;
    _pendingMarkerPage = null;
  }

  String get _currentNoteIdForAnnotationSave {
    if (_activeAttachmentPath != null) {
      final noteIndex = _findNoteIndexForAttachment(
        _activeAttachmentPath!,
        _conversationNotes,
      );
      if (noteIndex != null &&
          noteIndex >= 0 &&
          noteIndex < _conversationNotes.length) {
        return _conversationNotes[noteIndex].id;
      }
    }
    return _conversationNotes[_activeNoteIndex].id;
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
                  // Use _isStreaming (live-text flag) rather than _isSending
                  // so chip/strip taps re-enable as soon as the stream
                  // finishes — _isSending stays true through tool calls.
                  : (_conversation == null
                        ? const SizedBox.shrink()
                        : ChatPanel(
                            key: _chatPanelKey,
                            conversationId: _conversation!.id,
                            initialMessageId: _initialMessageIdForBranchSwitch,
                            isStreaming: _isStreaming,
                            streamingContent: _isStreaming
                                ? _streamingContent
                                : null,
                            onActiveConversationChanged:
                                (newConvId, forkPointMessageId) async {
                                  setState(() {
                                    _initialMessageIdForBranchSwitch =
                                        forkPointMessageId;
                                  });
                                  await _switchConversation(
                                    newConvId,
                                    preserveDocumentState: true,
                                  );
                                },
                            onSendUserPrompt: (convId, prompt) async {
                              await _continueAfterExistingUserPrompt(convId);
                            },
                            onUserMessageEdit: (msg) {
                              _messageController.text = msg.content;
                              _scrollToBottom();
                              Future.delayed(
                                const Duration(milliseconds: 200),
                                () {
                                  if (mounted) {
                                    _messageFocusNode.requestFocus();
                                  }
                                },
                              );
                            },
                            onShowToolDetails: _showToolDetailsDialog,
                            onCopyAiMessage: (msg) =>
                                copyContentToClipboard(msg.content),
                            onAddAiMessageToNote: (msg) =>
                                handleAddContentToNote(
                                  content: msg.content,
                                  contextNotes: _conversationNotes,
                                ),
                          )),
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
    final activeSystemToolsCount = _selectedSystemTools.length;
    final totalActiveCount =
        activeMcpCount +
        activeLocalCount +
        activeModelFeaturesCount +
        activeBuiltInToolsCount +
        activeSystemToolsCount +
        (_skillsEnabled ? 1 : 0);
    final headerTitle = l10n.mcpAndLocalTools;
    final modelConfig = context.read<AppProvider>().modelConfig;
    final supportsToolOrchestration =
        (_selectedModel ?? modelConfig)
            ?.customCapabilitiesObject
            ?.supportsToolOrchestration ??
        true;

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
                    // TODO(kkspeed): Built-in Tools section is hidden because agentic mode
                    // is not yet implemented in immersive mode. The checkbox does nothing
                    // and won't spawn the agent mode widget like in conversation_chat_screen.
                    // Re-enable this section when agentic UX for immersive mode is defined.
                    // ignore: dead_code
                    if (false && BuiltInToolsService.tools.isNotEmpty) ...[
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
                      if (!supportsToolOrchestration) ...[
                        const SizedBox(height: 4),
                        buildToolOrchestrationWarningRow(context),
                      ],
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
                    // System Tools (native tools from AgentService)
                    if (BuiltInToolsService.systemTools.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Icon(
                            Icons.memory,
                            size: 16,
                            color: theme.colorScheme.onSurface.withOpacity(0.7),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'System Tools',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface.withOpacity(
                                0.8,
                              ),
                            ),
                          ),
                          const Spacer(),
                          if (activeSystemToolsCount > 0)
                            ActiveToolCountBadge(
                              count: activeSystemToolsCount,
                              label: l10n.active,
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: BuiltInToolsService.systemTools.map((tool) {
                          final isSelected = _selectedSystemTools.contains(
                            tool.id,
                          );
                          return FilterChip(
                            label: Text(tool.name),
                            selected: isSelected,
                            onSelected: (selected) {
                              setState(() {
                                if (selected) {
                                  _selectedSystemTools.add(tool.id);
                                } else {
                                  _selectedSystemTools.remove(tool.id);
                                }
                              });
                            },
                            avatar: Icon(
                              tool.icon,
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
                    // Agent Skills
                    if (_skillCount > 0) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Icon(
                            Icons.auto_awesome,
                            size: 16,
                            color: theme.colorScheme.onSurface.withOpacity(0.7),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Agent Skills',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface.withOpacity(
                                0.8,
                              ),
                            ),
                          ),
                          const Spacer(),
                          if (_skillsEnabled)
                            ActiveToolCountBadge(count: 1, label: l10n.active),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          FilterChip(
                            label: Text('$_skillCount available'),
                            selected: _skillsEnabled,
                            onSelected: (selected) {
                              setState(() => _skillsEnabled = selected);
                              if (selected) {
                                _conversationService.enableSkills().then((_) {
                                  if (mounted) {
                                    setState(
                                      () => _skillCount = _conversationService
                                          .skillIndex
                                          .length,
                                    );
                                  }
                                });
                              } else {
                                _conversationService.disableSkills();
                              }
                            },
                            avatar: Icon(
                              Icons.auto_awesome,
                              size: 16,
                              color: _skillsEnabled
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface.withOpacity(
                                      0.6,
                                    ),
                            ),
                          ),
                        ],
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
                l10n.scratchpadEmpty,
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

  Future<void> _showRecallDialog() async {
    List<NoteAnnotation> annotations;
    if (_activeAttachmentPath != null) {
      final attachment = await _resolveAttachment(_activeAttachmentPath!);
      if (attachment == null) return;
      annotations = await _noteAnnotationService.getAnnotationsForAttachment(
        attachment.id,
      );
    } else {
      final note = widget.notes[_activeNoteIndex];
      annotations = await _noteAnnotationService.getAnnotationsForNote(note.id);
    }

    if (!mounted) return;

    if (annotations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No past annotations for this note.')),
      );
      return;
    }

    final selected = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _RecallAnnotationsDialog(
        annotations: annotations,
        scratchpadIds: _scratchpadItems.map((m) => m.id).toSet(),
      ),
    );

    if (selected == null || selected.isEmpty || !mounted) return;

    setState(() {
      for (final annotation in annotations) {
        if (selected.contains(annotation.id) &&
            !_scratchpadItems.any((m) => m.id == annotation.id)) {
          _scratchpadItems.add(
            ConversationMessage(
              id: annotation.id,
              conversationId: 'scratchpad',
              content: annotation.content,
              type: MessageType.user,
              timestamp: annotation.createdAt,
              attachmentPaths: annotation.attachmentPaths,
            ),
          );
        }
      }
    });
  }

  Widget _buildScratchpadActions(AppLocalizations l10n) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _scratchpadItems.isEmpty ? null : _addScratchpadToNote,
            icon: const Icon(Icons.note_add, size: 18),
            label: Text(l10n.addToNote),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _scratchpadItems.isEmpty ? null : _clearScratchpad,
            icon: const Icon(Icons.clear_all, size: 18),
            label: Text(l10n.clear),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: _showRecallDialog,
          icon: const Icon(Icons.history, size: 20),
          tooltip: l10n.recallAnnotations,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(width: 4),
        // Include in chat toggle
        Tooltip(
          message: l10n.includeScratchpadInChat,
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
      spacing: 10,
      runSpacing: 10,
      children: message.attachmentPaths.map((path) {
        return AttachmentPreviewTile(
          key: ValueKey('${message.id}:$path'),
          attachmentPath: path,
          onTap: () => _openAttachment(path, l10n),
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

  Widget _buildMarkerPlacementModeSelector(ThemeData theme) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 8,
      children: [
        Text(
          'Marker placement',
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        SegmentedButton<MarkerPlacementMode>(
          segments: const [
            ButtonSegment<MarkerPlacementMode>(
              value: MarkerPlacementMode.single,
              label: Text('Single'),
              icon: Icon(Icons.filter_1),
            ),
            ButtonSegment<MarkerPlacementMode>(
              value: MarkerPlacementMode.split,
              label: Text('Split'),
              icon: Icon(Icons.call_split),
            ),
          ],
          selected: {
            _pendingMarkerPlacementMode == MarkerPlacementMode.split
                ? MarkerPlacementMode.split
                : MarkerPlacementMode.single,
          },
          onSelectionChanged: (selection) {
            final nextMode = selection.first;
            setState(() {
              _pendingMarkerPlacementMode = nextMode;
              _rebuildPendingMarkerPosition();
            });
          },
        ),
      ],
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
    final noteMarkers = _noteMarkers[note.id] ?? [];
    return Scrollbar(
      child: SingleChildScrollView(
        child: Stack(
          children: [
            Container(
              key: _noteContentKey,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    note.title,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
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
                      onLinkTap: (url, _) => _handleMarkdownLinkTap(url, l10n),
                      headingAnchorRegistry: _noteAnchorRegistry,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                  // Add subnotes if present
                  if (note.subNotes.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(
                      l10n.subNotes,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
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
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.bold,
                                            ),
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
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
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
            if (noteMarkers.isNotEmpty)
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      children: noteMarkers.expand((marker) {
                        final rects =
                            marker.normalizedRects ??
                            (marker.normalizedRect != null
                                ? [marker.normalizedRect!]
                                : []);
                        return rects.map((rect) {
                          return Positioned(
                            left: rect.x * constraints.maxWidth,
                            top: rect.y * constraints.maxHeight,
                            child: InNoteMarkerBadge(
                              index: marker.index,
                              color: marker.type == MarkerType.annotation
                                  ? Colors.pink[200]!
                                  : Colors.blue,
                              onTap: () => _handleMarkerTap(marker),
                            ),
                          );
                        });
                      }).toList(),
                    );
                  },
                ),
              ),
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
          _activeImageTransform = transformController;
          final imageWidget = source.bytes != null
              ? Image.memory(source.bytes!)
              : Image.file(source.file);

          return LayoutBuilder(
            builder: (context, constraints) {
              final markers = _attachmentMarkers[_activeAttachmentPath] ?? [];
              return InteractiveViewer(
                transformationController: transformController,
                minScale: 0.1,
                maxScale: 4,
                constrained: true,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: Stack(
                    children: [
                      Positioned.fill(child: imageWidget),
                      ...markers.expand((marker) {
                        final rects =
                            marker.normalizedRects ??
                            (marker.normalizedRect != null
                                ? [marker.normalizedRect!]
                                : []);
                        return rects.map((rect) {
                          return Positioned(
                            left: rect.x * constraints.maxWidth,
                            top: rect.y * constraints.maxHeight,
                            child: InNoteMarkerBadge(
                              index: marker.index,
                              color: marker.type == MarkerType.annotation
                                  ? Colors.pink[200]!
                                  : Colors.blue,
                              onTap: () => _handleMarkerTap(marker),
                            ),
                          );
                        });
                      }),
                    ],
                  ),
                ),
              );
            },
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
                markers: _attachmentMarkers[_activeAttachmentPath] ?? [],
                onMarkerTap: (marker) => _handleMarkerTap(marker),
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
    final isPdf = attachment.toLowerCase().endsWith('.pdf');
    final pdfOutline = isPdf ? _pdfOutlines[attachment] : null;
    final hasOutline = pdfOutline != null && pdfOutline.isNotEmpty;
    final isActive = attachment == _activeAttachmentPath;

    return _AttachmentOutlineItem(
      attachment: attachment,
      noteIndex: noteIndex,
      depth: depth,
      isPdf: isPdf,
      hasOutline: hasOutline,
      isActive: isActive,
      pdfOutline: pdfOutline,
      currentPage: isPdf ? _pdfCurrentPages[attachment] : null,
      onTap: () {
        setState(() {
          _activeNoteIndex = noteIndex;
          _activeAttachmentPath = attachment;
        });
        _loadMarkersForAttachment(attachment);
        Navigator.pop(context);
      },
      onNodeTap: (node) {
        setState(() {
          _activeNoteIndex = noteIndex;
          _activeAttachmentPath = attachment;
        });
        _loadMarkersForAttachment(attachment);
        Navigator.pop(context);
        _navigateToPdfOutlineDestination(attachment, node);
      },
      onResolvePageNumber: (node) async {
        // Try to access pageNumber directly from the destination
        if (node.dest != null) {
          return node.dest!.pageNumber;
        }
        return null;
      },
    );
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

  IconData _iconForAttachment(String path) {
    final ext = path.split('.').last.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) {
      return Icons.image;
    } else if (['mp4', 'mov', 'avi'].contains(ext)) {
      return Icons.movie;
    } else if (['mp3', 'wav', 'm4a'].contains(ext)) {
      return Icons.audiotrack;
    } else if (ext == 'pdf') {
      return Icons.picture_as_pdf;
    }
    return Icons.insert_drive_file;
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
                    _loadMarkersForNote(notes[i].id);
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
                        _loadMarkersForNote(linkedNote.id);
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
                          _loadMarkersForAttachment(attachment);
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
      final finalPath = await FileUtils.resolvePortableAttachmentPath(path);
      await FileUtils.openFile(finalPath, context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.failedToOpenAttachment(e.toString()))),
      );
    }
  }

  Future<void> _deleteMarker(InNoteMarker marker) async {
    try {
      final note = _conversationNotes[_activeNoteIndex];

      if (_activeAttachmentPath != null) {
        final attachment = await _resolveAttachment(_activeAttachmentPath!);
        if (attachment != null) {
          await _noteMarkerService.deleteMarkerForAttachment(
            attachment.id,
            marker.id,
          );
        }
      } else {
        await _noteMarkerService.deleteMarkerForNote(note.id, marker.id);
      }

      if (mounted) {
        setState(() {
          if (_activeAttachmentPath != null) {
            _attachmentMarkers[_activeAttachmentPath!]?.removeWhere(
              (m) => m.id == marker.id,
            );
          } else {
            _noteMarkers[note.id]?.removeWhere((m) => m.id == marker.id);
          }
        });

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Marker deleted.')));
      }
    } catch (e) {
      LoggerService.error('Failed to delete marker: $e', error: e);
    }
  }

  Future<void> _handleMarkerTap(InNoteMarker marker) async {
    if (marker.type == MarkerType.annotation) {
      final annotation = await _noteAnnotationService.getAnnotation(marker.id);
      if (annotation == null || !mounted) return;
      final isInScratchpad = _scratchpadItems.any((m) => m.id == marker.id);
      final result = await showAnnotationPreview(
        context,
        annotation,
        isInScratchpad: isInScratchpad,
      );
      if (!mounted) return;
      if (result == AnnotationPreviewResult.addToScratchpad) {
        setState(() {
          _scratchpadItems.add(
            ConversationMessage(
              id: annotation.id,
              conversationId: 'scratchpad',
              content: annotation.content,
              type: MessageType.user,
              timestamp: annotation.createdAt,
              attachmentPaths: annotation.attachmentPaths,
            ),
          );
        });
      } else if (result == AnnotationPreviewResult.removed) {
        await _deleteAnnotationMarker(marker);
      }
    } else {
      final deleted = await showInNoteMarkerPreview(
        context,
        marker,
        onFocusConversation: _focusMarkerConversation,
      );
      if (deleted == true) {
        _deleteMarker(marker);
      }
    }
  }

  Future<void> _focusMarkerConversation(
    String conversationId,
    String markerMessageId,
  ) async {
    if (!mounted) return;
    setState(() {
      _isScratchpadMode = false;
      _isAiPanelExpanded = true;
      _initialMessageIdForBranchSwitch = markerMessageId;
    });
    await _switchConversation(conversationId, preserveDocumentState: true);
  }

  Future<void> _deleteAnnotationMarker(InNoteMarker marker) async {
    try {
      if (_activeAttachmentPath != null) {
        final attachment = await _resolveAttachment(_activeAttachmentPath!);
        if (attachment != null) {
          await _noteMarkerService.deleteMarkerForAttachment(
            attachment.id,
            marker.id,
          );
        }
      } else {
        final note = widget.notes[_activeNoteIndex];
        await _noteMarkerService.deleteMarkerForNote(note.id, marker.id);
      }
      await _noteAnnotationService.deleteAnnotation(marker.id);

      if (mounted) {
        setState(() {
          _scratchpadItems.removeWhere((m) => m.id == marker.id);
          if (_activeAttachmentPath != null) {
            _attachmentMarkers[_activeAttachmentPath!]?.removeWhere(
              (m) => m.id == marker.id,
            );
          } else {
            final note = widget.notes[_activeNoteIndex];
            _noteMarkers[note.id]?.removeWhere((m) => m.id == marker.id);
          }
        });
      }
    } catch (e) {
      LoggerService.error('Failed to delete annotation marker: $e', error: e);
    }
  }

  Future<void> _handleMarkdownLinkTap(String url, AppLocalizations l10n) async {
    // Intra-document anchor links are handled by InteractiveCheckboxMarkdown
    // when a HeadingAnchorRegistry is wired up. Anything still reaching here
    // either points at no matching heading or at a markdown widget without a
    // registry (chat/scratchpad). Either way, don't try to launch externally.
    if (url.startsWith('#')) return;
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

  Future<void> _loadMarkersForAttachment(String attachmentPath) async {
    final attachment = await _resolveAttachment(attachmentPath);
    if (attachment == null) return;
    final markers = await _noteMarkerService.getMarkersForAttachment(
      attachment.id,
    );
    if (mounted) {
      setState(() {
        _attachmentMarkers[attachmentPath] = markers;
      });
    }
  }

  Future<void> _loadMarkersForNote(String noteId) async {
    final markers = await _noteMarkerService.getMarkersForNote(noteId);
    if (mounted) {
      setState(() {
        _noteMarkers[noteId] = markers;
      });
    }
  }

  Future<int> _nextMarkerIndex() async {
    if (_activeAttachmentPath != null) {
      final attachmentPath = _activeAttachmentPath!;
      final cachedMarkers = _attachmentMarkers[attachmentPath];
      if (cachedMarkers != null && cachedMarkers.isNotEmpty) {
        return cachedMarkers.map((marker) => marker.index).reduce(max) + 1;
      }

      final attachment = await _resolveAttachment(attachmentPath);
      if (attachment == null) return 1;
      final persistedMarkers = await _noteMarkerService.getMarkersForAttachment(
        attachment.id,
      );
      if (persistedMarkers.isEmpty) return 1;
      return persistedMarkers.map((marker) => marker.index).reduce(max) + 1;
    }

    final note = _conversationNotes[_activeNoteIndex];
    final cachedMarkers = _noteMarkers[note.id];
    if (cachedMarkers != null && cachedMarkers.isNotEmpty) {
      return cachedMarkers.map((marker) => marker.index).reduce(max) + 1;
    }

    final persistedMarkers = await _noteMarkerService.getMarkersForNote(
      note.id,
    );
    if (persistedMarkers.isEmpty) return 1;
    return persistedMarkers.map((marker) => marker.index).reduce(max) + 1;
  }

  Future<void> _saveInNoteMarker(
    String messageId,
    String conversationId,
    InNoteMarkerPosition position,
  ) async {
    try {
      final nextIndex = await _nextMarkerIndex();
      if (_activeAttachmentPath != null) {
        final attachment = await _resolveAttachment(_activeAttachmentPath!);
        if (attachment == null) return;
        final marker = InNoteMarker.forAttachment(
          index: nextIndex,
          page: position.page ?? 0,
          normalizedRect: position.normalizedRect,
          normalizedRects: position.normalizedRects,
          conversationId: conversationId,
          messageId: messageId,
        );
        await _noteMarkerService.saveMarkerForAttachment(attachment.id, marker);
      } else {
        final note = _conversationNotes[_activeNoteIndex];
        final marker = InNoteMarker.forNote(
          index: nextIndex,
          charStart: 0,
          charEnd: 0,
          normalizedRect: position.normalizedRect,
          normalizedRects: position.normalizedRects,
          conversationId: conversationId,
          messageId: messageId,
        );
        await _noteMarkerService.saveMarkerForNote(note.id, marker);
      }
      if (mounted) {
        setState(() {});
        if (_activeAttachmentPath != null) {
          _loadMarkersForAttachment(_activeAttachmentPath!);
        } else {
          _loadMarkersForNote(_conversationNotes[_activeNoteIndex].id);
        }
      }
    } catch (e) {
      LoggerService.error('Failed to save in-note marker: $e', error: e);
    }
  }

  Future<void> _saveAnnotationMarker(
    String markerId,
    String content,
    List<String> attachmentPaths,
    InNoteMarkerPosition position,
  ) async {
    try {
      final nextIndex = await _nextMarkerIndex();
      final portableAttachmentPaths =
          await ConversationAttachmentService.promoteAttachmentPathsToPersistent(
            paths: attachmentPaths,
            noteId: _currentNoteIdForAnnotationSave,
          );

      if (_activeAttachmentPath != null) {
        final attachment = await _resolveAttachment(_activeAttachmentPath!);
        if (attachment == null) return;
        final marker = InNoteMarker.forAttachment(
          id: markerId,
          index: nextIndex,
          page: position.page ?? 0,
          normalizedRect: position.normalizedRect,
          normalizedRects: position.normalizedRects,
          // Annotation markers are not linked to a conversation; the shared
          // markerId UUID links to NoteAnnotation instead.
          conversationId: '',
          messageId: '',
          type: MarkerType.annotation,
        );
        await _noteMarkerService.saveMarkerForAttachment(attachment.id, marker);
        await _noteAnnotationService.saveAnnotation(
          NoteAnnotation(
            id: markerId,
            attachmentId: attachment.id,
            content: content,
            attachmentPaths: portableAttachmentPaths,
            createdAt: DateTime.now(),
          ),
        );
      } else {
        final note = _conversationNotes[_activeNoteIndex];
        final marker = InNoteMarker.forNote(
          id: markerId,
          index: nextIndex,
          charStart: 0,
          charEnd: 0,
          normalizedRect: position.normalizedRect,
          normalizedRects: position.normalizedRects,
          // Annotation markers are not linked to a conversation; the shared
          // markerId UUID links to NoteAnnotation instead.
          conversationId: '',
          messageId: '',
          type: MarkerType.annotation,
        );
        await _noteMarkerService.saveMarkerForNote(note.id, marker);
        await _noteAnnotationService.saveAnnotation(
          NoteAnnotation(
            id: markerId,
            noteId: note.id,
            content: content,
            attachmentPaths: portableAttachmentPaths,
            createdAt: DateTime.now(),
          ),
        );
      }
      if (mounted) {
        setState(() {
          final scratchpadIndex = _scratchpadItems.indexWhere(
            (item) => item.id == markerId,
          );
          if (scratchpadIndex != -1) {
            _scratchpadItems[scratchpadIndex] =
                _scratchpadItems[scratchpadIndex].copyWith(
                  attachmentPaths: portableAttachmentPaths,
                );
          }
        });
        if (_activeAttachmentPath != null) {
          _loadMarkersForAttachment(_activeAttachmentPath!);
        } else {
          _loadMarkersForNote(_conversationNotes[_activeNoteIndex].id);
        }
      }
    } catch (e) {
      LoggerService.error('Failed to save annotation marker: $e', error: e);
    }
  }

  /// Adapter so ChatPanel's onSendUserPrompt callback can drive the
  /// immersive screen's existing send pipeline. Sets the controller
  /// text then runs the standard _sendMessage chain.
  Future<void> _sendMessageWithText(String prompt) async {
    _messageController.text = prompt;
    await _sendMessage();
  }

  Future<void> _continueAfterExistingUserPrompt(String conversationId) async {
    final activeConfig =
        _selectedModel ?? context.read<AppProvider>().modelConfig;
    final generationContext = GenerationContext();
    if (_selectedModel != null) {
      generationContext.modelOverride = _selectedModel;
    }
    final requestId = generationContext.ensureRequestId();
    _currentRequestId = requestId;
    final isVisibleConversation = _conversation?.id == conversationId;
    setState(() {
      _isSending = true;
      _isAborting = false;
      if (isVisibleConversation) {
        _streamingContent = '';
        _isStreaming = true;
      }
    });

    try {
      final conversation = await _conversationService.getConversation(
        conversationId,
      );
      final noteIds = conversation?.noteIds ?? const <String>[];
      final notes = <Note>[];
      for (final id in noteIds) {
        final note = await _databaseService.getNote(id);
        if (note != null) notes.add(note);
      }
      final messages = await _conversationService.getConversationMessages(
        conversationId,
      );
      final latestUser = messages.lastWhere(
        (m) => m.type == MessageType.user,
        orElse: () => throw StateError(
          'No persisted user prompt found for $conversationId',
        ),
      );
      final response = await _generateAiResponse(
        latestUser.content,
        const <PlatformFile>[],
        generationContext,
        messageHistory: messages,
        contextNotes: notes,
        requestForkTitle: ConversationTitleDirective.shouldRequestTitle(
          conversation,
        ),
        onStreamChunk: (() {
          final titleStreamFilter = ConversationTitleStreamFilter();
          return (String chunk) {
            final visibleChunk = titleStreamFilter.addChunk(chunk);
            if (visibleChunk.isEmpty) return;
            if (!mounted || !isVisibleConversation) return;
            setState(() {
              _streamingContent += visibleChunk;
              _isStreaming = true;
            });
            _scrollToBottom();
          };
        })(),
      );
      await _conversationService.addAIResponse(
        conversationId: conversationId,
        content: response.content,
        metadata: response.metadata,
        modelUsed:
            response.metadata?['modelUsed'] as String? ?? activeConfig?.id,
      );
      if (!mounted) return;
      if (isVisibleConversation) {
        setState(() {
          _streamingContent = '';
          _isStreaming = false;
        });
        _chatPanelKey.currentState?.reload();
        _scrollToBottom();
      }
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
        'Error continuing immersive conversation: $e',
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
          if (isVisibleConversation) {
            _streamingContent = '';
            _isStreaming = false;
          }
        });
      }
      _cancelledRequestIds.remove(requestId);
    }
  }

  Future<void> _sendMessage() async {
    final trimmed = _messageController.text.trim();
    if (trimmed.isEmpty &&
        _pendingAttachments.isEmpty &&
        _drawingActions.isEmpty) {
      return;
    }

    if (_isPenMode && _drawingActions.isNotEmpty) {
      await _confirmDrawing(silent: true);
    }

    final activeConfig =
        _selectedModel ?? context.read<AppProvider>().modelConfig;
    final pendingAttachments = List<PlatformFile>.from(_pendingAttachments);
    final localAttachmentWarning =
        await LocalModelAttachmentConstraintService.analyzeForGemma4(
          config: activeConfig,
          prompt: trimmed,
          attachments: pendingAttachments,
        );
    if (!mounted) return;
    if (localAttachmentWarning != null) {
      final result = await LocalModelAttachmentWarningDialog.show(
        context,
        currentModel: activeConfig,
        warning: localAttachmentWarning,
      );
      if (!mounted) return;
      if (result == null || result is LocalModelAttachmentWarningStop) return;
      if (result is LocalModelAttachmentWarningContinue &&
          result.modelOverride != null) {
        _selectedModel = result.modelOverride;
      }
    }

    // Check tool orchestration capability before sending
    if (!mounted) return;
    final hasTools =
        _selectedBuiltInTools.isNotEmpty || _selectedMcpEndpointIds.isNotEmpty;
    final toolCheckConfig =
        _selectedModel ?? context.read<AppProvider>().modelConfig;
    final supportsOrchestration =
        toolCheckConfig?.customCapabilitiesObject?.supportsToolOrchestration ??
        true;
    if (hasTools && !supportsOrchestration) {
      final result = await ToolOrchestrationWarningDialog.show(
        context,
        toolCheckConfig,
      );
      if (!mounted) return;
      if (result == null || result is ToolOrchestrationStop) return;
      if (result is ToolOrchestrationContinue && result.modelOverride != null) {
        _selectedModel = result.modelOverride;
      }
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
        final preferredModel = await getIt<ModelSelector>()
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
        final pendingPos = _pendingMarkerPosition;
        _clearPendingMarkerState();

        final markerId = const Uuid().v4();
        final transientAttachmentPaths = attachments
            .where((f) => f.path != null)
            .map((f) => f.path!)
            .toList();

        final message = ConversationMessage(
          id: markerId,
          conversationId: 'scratchpad',
          content: content,
          type: MessageType.user,
          timestamp: DateTime.now(),
          attachmentPaths: transientAttachmentPaths,
        );

        setState(() {
          _scratchpadItems.add(message);
          _isSending = false;
        });

        if (pendingPos != null) {
          await _saveAnnotationMarker(
            markerId,
            content,
            transientAttachmentPaths,
            pendingPos,
          );
        }

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
      _chatPanelKey.currentState?.reload();
      _scrollToBottom();

      // Save in-note marker if a drawing was confirmed before this send
      if (_pendingMarkerPosition != null) {
        final pendingPos = _pendingMarkerPosition!;
        _clearPendingMarkerState();
        await _saveInNoteMarker(userMessage.id, _conversation!.id, pendingPos);
      }

      final titleStreamFilter = ConversationTitleStreamFilter();
      final response = await _generateAiResponse(
        content,
        attachments,
        generationContext,
        requestForkTitle: ConversationTitleDirective.shouldRequestTitle(
          _conversation,
        ),
        onStreamChunk: (chunk) {
          final visibleChunk = titleStreamFilter.addChunk(chunk);
          if (visibleChunk.isEmpty) return;
          if (mounted) {
            setState(() {
              _streamingContent += visibleChunk;
              _isStreaming = true;
            });
            _scrollToBottom();
          }
        },
      );
      final aiMessage = await _conversationService.addAIResponse(
        conversationId: _conversation!.id,
        content: response.content,
        metadata: response.metadata,
        modelUsed: response.metadata?['modelUsed'] as String?,
      );

      if (!mounted) return;
      setState(() {
        _streamingContent = '';
        _isStreaming = false;
        _messages.add(aiMessage);
      });
      _chatPanelKey.currentState?.reload();
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
          _streamingContent = '';
          _isStreaming = false;
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
    GenerationContext generationContext, {
    void Function(String chunk)? onStreamChunk,
    List<ConversationMessage>? messageHistory,
    List<Note>? contextNotes,
    bool requestForkTitle = false,
  }) async {
    final requestId = generationContext.ensureRequestId();
    final notesForContext = contextNotes ?? _conversationNotes;
    final promptBuilder = ConversationPromptBuilder(_databaseService);
    final systemMessage = await _buildSystemPrompt(
      contextNotes: notesForContext,
      requestForkTitle: requestForkTitle,
    );

    // Get current PDF page for window mode context filtering
    final currentPdfPage = _activeAttachmentPath != null
        ? _pdfCurrentPages[_activeAttachmentPath]
        : null;

    final contextMessage = await promptBuilder.buildNoteContextMessage(
      notesForContext,
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

    final currentModelId = getIt<ModelSelector>().currentModelConfig?.id;

    final conversationMessages = await promptBuilder.buildConversationMessages(
      messages: messageHistory ?? _messages,
      currentModelId: currentModelId,
      latestUserAttachments: latestAttachments,
    );
    messages.addAll(conversationMessages);

    final request = PromptRequest(
      systemMessage: systemMessage,
      contextMessages: contextMessage == null ? const [] : [contextMessage],
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
      activeToolsProvider: _buildActiveToolsMap,
      enableTools: activeTools.isNotEmpty || _selectedModelFeatures.isNotEmpty,
      executeTool: (serviceName, toolName, params, context) async {
        return _runWithToolStatus(serviceName, toolName, () async {
          // Handle AI Tools
          if (_aiToolBundles.containsKey(serviceName)) {
            final runtime = await _getAiToolRuntime(serviceName);
            return runtime.invoke(toolName, params, context);
          }

          // Handle System Tools (native tools from AgentService)
          if (serviceName == BuiltInToolsService.systemToolsServiceKey) {
            final agentService = this.context.read<AgentService>();
            final nativeTool = agentService.nativeTools
                .where((t) => t.name == toolName)
                .firstOrNull;
            if (nativeTool != null) {
              final result = await nativeTool.execute(params);
              return result is String ? result : result.toString();
            }
            return 'Error: System tool "$toolName" not found';
          }

          if (serviceName == ChatToolSession.skillToolsServiceKey) {
            if (toolName == 'load_skill') {
              final result = await _conversationService.loadSkillTool.execute(
                params,
              );
              final resultStr = result is String ? result : result.toString();
              final skillKey =
                  (params['noteId'] as String? ?? '').trim().isNotEmpty
                  ? (params['noteId'] as String).trim()
                  : (params['skillRef'] as String? ?? '').trim();
              if (skillKey.isNotEmpty && result is String) {
                await _conversationService.handleLoadSkillResult(
                  skillKey,
                  resultStr,
                );
              }
              return resultStr;
            }
            if (_conversationService.skillDiscoveredNativeToolNames.contains(
              toolName,
            )) {
              final agentService = this.context.read<AgentService>();
              final nativeTool = agentService.nativeTools
                  .where((t) => t.name == toolName)
                  .firstOrNull;
              if (nativeTool != null) {
                final result = await nativeTool.execute(params);
                return result is String ? result : result.toString();
              }
              return 'Error: Native tool "$toolName" not found';
            }
            for (final entry
                in _conversationService.skillDiscoveredBundles.entries) {
              if (entry.value.toolDefinitions.any(
                (definition) => definition.toolName == toolName,
              )) {
                final runtime = await _getSkillAiToolRuntime(
                  entry.key,
                  entry.value,
                );
                return runtime.invoke(toolName, params, context);
              }
            }
            final endpointName =
                _conversationService.skillToolEndpointNames[toolName];
            final endpointId =
                _conversationService.skillToolEndpointIds[toolName];
            if (endpointName != null && endpointId != null) {
              return McpToolIntegrationService.executeToolCall(
                serviceName: endpointName,
                toolName: toolName,
                parameters: params,
                enabledEndpointIds: [..._selectedMcpEndpointIds, endpointId],
                generationContext: context,
              );
            }
            return 'Error: Skill tool "$toolName" not found';
          }

          // Handle MCP Tools
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
      onStreamChunk: onStreamChunk,
    );

    if (_cancelledRequestIds.contains(requestId)) {
      throw const ConversationCancelledException();
    }

    return response;
  }

  Future<PromptMessage> _buildSystemPrompt({
    List<Note>? contextNotes,
    bool requestForkTitle = false,
  }) async {
    final notesForContext = contextNotes ?? _conversationNotes;
    final lines = <String>[
      'Engage in a focused conversation grounded in the selected notes and attachments.',
      'Reference the note titles when citing content and prefer concise, direct answers.',
      'Format your responses using markdown.',
    ];
    if (requestForkTitle) {
      lines.add(ConversationTitleDirective.promptInstruction);
    }

    if (_hasAnyTools) {
      lines.add(
        'The user has enabled external tools (MCP services or user-defined AI tools). Prefer calling them when they can improve accuracy before responding.',
      );
    }

    if (notesForContext.isEmpty) {
      lines.add(
        'No note text is attached inline. Use enabled tools when they can retrieve the needed note or workflow context.',
      );
    }

    final taskContext = lines.join('\n');

    final combinedTools = _buildActiveToolsMap();
    final budget = await _getChatPromptBudget();
    final mcpToolsPrompt = McpToolIntegrationService.buildMcpSystemPrompt(
      combinedTools,
      maxBudgetTokens: budget,
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
    if (_conversationService.skillsEnabled &&
        _conversationService.skillIndex.isNotEmpty) {
      final isLocalModel =
          getIt<ModelSelector>().currentModel?.usesNativeToolDeclarations ??
          false;
      final skillIndexPrompt = getIt<SkillService>().buildSkillIndexPrompt(
        _conversationService.skillIndex,
        maxBudgetTokens: budget,
        forLocalModel: isLocalModel,
      );
      if (skillIndexPrompt.trim().isNotEmpty) {
        contextBuffer
          ..writeln()
          ..write(skillIndexPrompt.trim());
      }
      final defaultActions = getIt<SkillService>()
          .buildDefaultActionPromptSection(_conversationService.skillIndex);
      if (defaultActions.isNotEmpty) {
        contextBuffer
          ..writeln()
          ..writeln()
          ..write(defaultActions);
      }
    }

    return SystemPromptBuilder.build(
      taskContext: contextBuffer.toString(),
      guidelines: [
        'Highlight referenced note sections explicitly when possible.',
        if (notesForContext.isNotEmpty) AIPrompts.relationshipGuidelines,
        if (notesForContext.isNotEmpty)
          AIPrompts.promptInjectionProtectionGuidelines,
      ],
      now: _sessionStart,
      needTimeInContext: false,
    );
  }

  Future<int> _getChatPromptBudget() async {
    try {
      return await getIt<ContextManagerService>().getModelContextBudget();
    } catch (_) {
      return _selectedModel?.maxInputTokens ??
          getIt<ModelSelector>().currentModelConfig?.maxInputTokens ??
          100000;
    }
  }

  Future<List<PlatformFile>> _loadConversationAttachments(
    ConversationMessage message,
    List<PlatformFile> latestUserAttachments,
  ) async {
    return ConversationPromptBuilder(_databaseService).loadMessageAttachments(
      message: message,
      messageHistory: _messages,
      latestUserAttachments: latestUserAttachments,
    );
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

  Future<bool> _switchConversation(
    String conversationId, {
    bool preserveDocumentState = false,
  }) async {
    final previousNoteId = _noteOrder.isNotEmpty
        ? _noteOrder[_activeNoteIndex.clamp(0, _noteOrder.length - 1)]
        : null;
    final previousAttachmentPath = _activeAttachmentPath;

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

      String? nextActiveAttachmentPath;
      int nextActiveNoteIndex = 0;
      final nextNoteOrder = conversationNotes.isNotEmpty
          ? conversationNotes.map((note) => note.id).toList()
          : (_noteOrder.isNotEmpty
                ? List<String>.from(_noteOrder)
                : _initialNotesById.keys.toList());

      if (preserveDocumentState &&
          previousNoteId != null &&
          nextNoteOrder.contains(previousNoteId)) {
        nextActiveNoteIndex = nextNoteOrder.indexOf(previousNoteId);
        final activeNote = conversationNotes.firstWhere(
          (note) => note.id == previousNoteId,
          orElse: () => _initialNotesById[previousNoteId]!,
        );
        if (previousAttachmentPath != null &&
            activeNote.attachmentPaths.contains(previousAttachmentPath)) {
          nextActiveAttachmentPath = previousAttachmentPath;
        }
      } else if (nextNoteOrder.isNotEmpty) {
        nextActiveNoteIndex = min(_activeNoteIndex, nextNoteOrder.length - 1);
      }

      setState(() {
        if (!preserveDocumentState) {
          _resetPdfState();
          _disposeImageResources();
        }
        _conversation = result.conversation;
        _hasAssociatedConversations = true;
        _messages
          ..clear()
          ..addAll(result.messages);
        _conversationNotes = conversationNotes;
        for (final note in conversationNotes) {
          _initialNotesById[note.id] = note;
        }
        _noteOrder = nextNoteOrder;
        _activeNoteIndex = nextActiveNoteIndex;
        _activeAttachmentPath = preserveDocumentState
            ? nextActiveAttachmentPath
            : null;
      });

      // Load markers for the now-active document.
      if (_activeAttachmentPath != null) {
        _loadMarkersForAttachment(_activeAttachmentPath!);
      } else if (_noteOrder.isNotEmpty) {
        _loadMarkersForNote(_noteOrder[_activeNoteIndex]);
      }

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
    required this.markers,
    required this.onMarkerTap,
    this.onDocumentReady,
    this.isNightMode = false,
  });

  final _AttachmentSource source;
  final double availableHeight;
  final Map<String, int> currentPageMap;
  final Map<String, int> totalPageMap;
  final Map<String, PdfViewerController> controllerMap;
  final void Function(String message) onError;
  final List<InNoteMarker> markers;
  final void Function(InNoteMarker) onMarkerTap;
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
          backgroundColor: widget.isNightMode ? Colors.white : Colors.grey,
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
          pageOverlaysBuilder: (context, pageRectInViewer, page) {
            // page.pageNumber is 1-indexed; our markers store 0-indexed page
            final pageMarkers = widget.markers
                .where((m) => m.page == page.pageNumber - 1)
                .toList();
            return pageMarkers.expand((marker) {
              final rects =
                  marker.normalizedRects ??
                  (marker.normalizedRect != null
                      ? [marker.normalizedRect!]
                      : []);
              return rects.map((rect) {
                return Positioned(
                  left: rect.x * pageRectInViewer.width,
                  top: rect.y * pageRectInViewer.height,
                  child: InNoteMarkerBadge(
                    index: marker.index,
                    color: marker.type == MarkerType.annotation
                        ? Colors.pink[200]!
                        : Colors.blue,
                    onTap: () => widget.onMarkerTap(marker),
                  ),
                );
              });
            }).toList();
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

class _AttachmentOutlineItem extends StatefulWidget {
  final String attachment;
  final int noteIndex;
  final int depth;
  final bool isPdf;
  final bool hasOutline;
  final bool isActive;
  final int? currentPage;
  final List<PdfOutlineNode>? pdfOutline;
  final VoidCallback onTap;
  final Function(PdfOutlineNode) onNodeTap;
  final Future<int?> Function(PdfOutlineNode) onResolvePageNumber;

  const _AttachmentOutlineItem({
    required this.attachment,
    required this.noteIndex,
    required this.depth,
    required this.isPdf,
    required this.hasOutline,
    required this.isActive,
    required this.currentPage,
    required this.pdfOutline,
    required this.onTap,
    required this.onNodeTap,
    required this.onResolvePageNumber,
  });

  @override
  State<_AttachmentOutlineItem> createState() => _AttachmentOutlineItemState();
}

class _AttachmentOutlineItemState extends State<_AttachmentOutlineItem> {
  bool _isExpanded = false;
  PdfOutlineNode? _activeNode;

  @override
  void initState() {
    super.initState();
    _findActiveNode();
  }

  @override
  void didUpdateWidget(_AttachmentOutlineItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentPage != oldWidget.currentPage ||
        widget.pdfOutline != oldWidget.pdfOutline) {
      _findActiveNode();
    }
  }

  Future<void> _findActiveNode() async {
    if (widget.pdfOutline == null || widget.currentPage == null) {
      if (mounted && _activeNode != null) setState(() => _activeNode = null);
      return;
    }

    final flatList = <MapEntry<PdfOutlineNode, int>>[];

    Future<void> traverse(List<PdfOutlineNode> nodes) async {
      for (final node in nodes) {
        final page = await widget.onResolvePageNumber(node);
        if (page != null) {
          flatList.add(MapEntry(node, page));
        }
        if (node.children.isNotEmpty) {
          await traverse(node.children);
        }
      }
    }

    await traverse(widget.pdfOutline!);
    flatList.sort((a, b) => a.value.compareTo(b.value));

    PdfOutlineNode? active;
    final current = widget.currentPage!;

    for (int i = 0; i < flatList.length; i++) {
      final entry = flatList[i];
      final page = entry.value;

      if (page <= current) {
        if (i + 1 < flatList.length) {
          final nextPage = flatList[i + 1].value;
          // Provide a small buffer or strictly less
          if (current < nextPage) {
            active = entry.key;
            break;
          }
        } else {
          active = entry.key;
        }
      }
    }

    if (mounted && _activeNode != active) {
      setState(() => _activeNode = active);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.attachment.split(Platform.pathSeparator).last;
    final leftPadding = 16.0 + (widget.depth * 32);
    final theme = Theme.of(context);
    final highlightColor = theme.colorScheme.primaryContainer.withValues(
      alpha: 0.3,
    );

    if (!widget.hasOutline) {
      return ListTile(
        contentPadding: EdgeInsets.only(left: leftPadding, right: 16),
        leading: Icon(_iconForAttachment(widget.attachment)),
        title: Text(fileName, overflow: TextOverflow.ellipsis),
        tileColor: widget.isActive ? highlightColor : null,
        onTap: widget.onTap,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              _isExpanded = !_isExpanded;
            });
          },
          child: Container(
            color: widget.isActive ? highlightColor : null,
            padding: EdgeInsets.only(
              left: leftPadding,
              right: 16,
              top: 12,
              bottom: 12,
            ),
            child: Row(
              children: [
                Icon(
                  _iconForAttachment(widget.attachment),
                  color: theme.iconTheme.color,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    fileName,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
                Icon(
                  _isExpanded ? Icons.expand_less : Icons.expand_more,
                  color: theme.iconTheme.color?.withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
        ),
        if (_isExpanded)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.only(
                  left: leftPadding + 24,
                  right: 16,
                ),
                leading: const Icon(Icons.visibility, size: 20),
                title: Text('View PDF', style: theme.textTheme.bodyMedium),
                onTap: widget.onTap,
              ),
              ..._buildPdfOutlineItems(
                attachmentPath: widget.attachment,
                nodes: widget.pdfOutline!,
                noteIndex: widget.noteIndex,
                depth: 0,
                context: context,
              ),
            ],
          ),
      ],
    );
  }

  IconData _iconForAttachment(String path) {
    final ext = path.split('.').last.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) {
      return Icons.image;
    } else if (['mp4', 'mov', 'avi'].contains(ext)) {
      return Icons.movie;
    } else if (['mp3', 'wav', 'm4a'].contains(ext)) {
      return Icons.audiotrack;
    } else if (ext == 'pdf') {
      return Icons.picture_as_pdf;
    }
    return Icons.insert_drive_file;
  }

  List<Widget> _buildPdfOutlineItems({
    required String attachmentPath,
    required List<PdfOutlineNode> nodes,
    required int noteIndex,
    required int depth,
    required BuildContext context,
  }) {
    final widgets = <Widget>[];
    final leftPadding = 80.0 + (depth * 16);
    final theme = Theme.of(context);

    for (final node in nodes) {
      final isActiveSection = _activeNode == node;

      widgets.add(
        ListTile(
          contentPadding: EdgeInsets.only(left: leftPadding, right: 16),
          leading: const Icon(Icons.bookmark_outline, size: 18),
          title: Text(
            node.title,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isActiveSection ? theme.colorScheme.primary : null,
              fontWeight: isActiveSection ? FontWeight.bold : null,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => widget.onNodeTap(node),
        ),
      );

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
}

/// Transient position captured at draw-confirm time, cleared after save.
class InNoteMarkerPosition {
  final NormalizedRect normalizedRect;
  final List<NormalizedRect>? normalizedRects;
  final int? page; // null for text notes
  const InNoteMarkerPosition({
    required this.normalizedRect,
    this.normalizedRects,
    this.page,
  });
}

class _MarkerRectComputation {
  final List<NormalizedRect> rects;
  final int? page;

  const _MarkerRectComputation({required this.rects, this.page});
}

class _RecallAnnotationsDialog extends StatefulWidget {
  final List<NoteAnnotation> annotations;
  final Set<String> scratchpadIds;

  const _RecallAnnotationsDialog({
    required this.annotations,
    required this.scratchpadIds,
  });

  @override
  State<_RecallAnnotationsDialog> createState() =>
      _RecallAnnotationsDialogState();
}

class _RecallAnnotationsDialogState extends State<_RecallAnnotationsDialog> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Recall Annotations'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: widget.annotations.length,
          itemBuilder: (context, index) {
            final ann = widget.annotations[index];
            final alreadyIn = widget.scratchpadIds.contains(ann.id);
            return CheckboxListTile(
              enabled: !alreadyIn,
              value: alreadyIn ? true : _selected.contains(ann.id),
              onChanged: alreadyIn
                  ? null
                  : (checked) {
                      setState(() {
                        if (checked == true) {
                          _selected.add(ann.id);
                        } else {
                          _selected.remove(ann.id);
                        }
                      });
                    },
              title: Text(
                ann.content,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: alreadyIn ? theme.disabledColor : null,
                ),
              ),
              subtitle: Text(
                alreadyIn
                    ? 'Already in scratchpad'
                    : _formatDate(ann.createdAt),
                style: theme.textTheme.labelSmall,
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected.toList()),
          child: const Text('Add'),
        ),
      ],
    );
  }

  String _formatDate(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    return '${diff.inMinutes}m ago';
  }
}
