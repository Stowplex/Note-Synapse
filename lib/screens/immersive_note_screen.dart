import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../models/conversation.dart';
import '../models/mcp_endpoint.dart';
import '../models/note.dart';
import '../models/user_app.dart';
import '../providers/app_provider.dart';
import '../services/ai_tool_service.dart';
import '../services/conversation_service.dart';
import '../services/conversation_ai_engine.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import '../services/mcp_service.dart';
import '../services/mcp_tool_integration_service.dart';
import '../services/prompts/ai_prompts.dart';
import '../services/prompts/note_prompt_builder.dart';
import '../services/prompts/prompt_models.dart';
import '../services/prompts/prompt_configuration_service.dart';
import '../services/prompts/registrations/chat_prompt_configuration.dart';
import '../services/prompts/system_prompt_builder.dart';
import '../services/user_app_service.dart';
import '../utils/file_type_utils.dart';
import '../utils/file_utils.dart';
import '../utils/native_capture_utils.dart';
import '../utils/synapse_temp_utils.dart';
import '../widgets/interactive_checkbox_markdown.dart';
import '../mixins/note_action_mixin.dart';
import '../widgets/chat_message_action_row.dart';
import '../widgets/active_tool_count_badge.dart';
import 'conversation_tree_screen.dart';
import 'conversation_chat_screen.dart';
import 'note_selection_dialog.dart';

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
    with TickerProviderStateMixin, NoteActionMixin<ImmersiveNoteScreen> {
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
  final Map<String, PDFViewController> _pdfControllers = {};
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

  // MCP support
  List<McpEndpoint> _availableMcpEndpoints = [];
  final Set<String> _selectedMcpEndpointIds = {};
  Map<String, List<McpTool>> _mcpToolsByEndpoint = {};
  bool _isMcpPanelExpanded = false; // Collapsed by default

  // AI tool support
  Map<String, AiToolAppBundle> _aiToolBundles = {};
  Map<String, List<McpTool>> _aiToolMcpMap = {};
  final Set<String> _selectedAiToolServices = {};
  final Map<String, AiToolRuntime> _aiToolRuntimes = {};
  String? _toolExecutionStatus;
  final List<Offset> _penStrokePoints = [];
  int _activeNoteIndex = 0;
  String? _activeAttachmentPath;
  final DateTime _sessionStart = DateTime.now();
  static const double _aiHandleHeight = 76.0;
  static const double _aiHandleWidth = 420.0;
  static const double _aiPanelHeightFraction = 0.45;
  static const double _aiLandscapePanelFraction = 0.4;
  static const double _aiHandleMargin = 12.0;
  static const double _aiHandlePadding = 12.0;
  static const double _aiHandleControlWidth = 44.0;
  static const double _aiHandleControlGap = 8.0;
  double _aiHandleFraction = 0.75;
  bool _isAiPanelExpanded = false;
  _AiPanelSide _aiPanelSide = _AiPanelSide.bottom;
  bool _isHandleDragFromComposerArea = false;

  @override
  void initState() {
    super.initState();
    _initialNotesById = {for (final note in widget.notes) note.id: note};
    _noteOrder = widget.notes.map((note) => note.id).toList();
    _conversationNotes = List<Note>.from(widget.notes);

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
    });
  }

  @override
  void dispose() {
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

  Map<String, List<McpTool>> _buildActiveToolsMap() {
    final combined = <String, List<McpTool>>{};
    combined.addAll(_mcpToolsByEndpoint);

    for (final service in _selectedAiToolServices) {
      final tools = _aiToolMcpMap[service];
      if (tools != null && tools.isNotEmpty) {
        combined[service] = tools;
      }
    }

    return combined;
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
    );
    _aiToolRuntimes[serviceName] = runtime;
    return runtime;
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
              if (_conversation != null)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (value) {
                    if (value == 'open_chat') {
                      _openConversationInChatMode();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem<String>(
                      value: 'open_chat',
                      child: Text(l10n.openInChatMode),
                    ),
                  ],
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
                            painter: _FreeformStrokePainter(
                              _penStrokePoints.isEmpty
                                  ? null
                                  : List<Offset>.from(_penStrokePoints),
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
    if (isLandscape) {
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
    final effectiveSide = _effectivePanelSide(false);

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

    final handleWidth = min(size.width - (_aiHandleMargin * 2), _aiHandleWidth);
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
    final effectiveSide = _effectivePanelSide(true);

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

    final handleWidth = min(size.width - (_aiHandleMargin * 2), _aiHandleWidth);

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
    final maxWidth = min(totalWidth * 0.6, available);

    return _clampToRange(
      totalWidth * _aiLandscapePanelFraction,
      minWidth,
      maxWidth,
    );
  }

  _AiPanelSide _effectivePanelSide(bool isLandscape) {
    if (isLandscape) {
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

  _AiPanelSide _normalizePanelSide(_AiPanelSide side, bool isLandscape) {
    if (isLandscape) {
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
    if (_pendingAttachments.isEmpty) {
      return _aiHandleHeight;
    }
    final attachmentRows = (_pendingAttachments.length / 2).ceil();
    return _aiHandleHeight + attachmentRows * 32.0;
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
      child: _toolExecutionStatus == null
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
                    IconButton(
                      icon: Icon(
                        Icons.brush,
                        color: _isPenMode ? theme.colorScheme.primary : null,
                      ),
                      tooltip: l10n.annotate,
                      onPressed: () {
                        setState(() {
                          _isPenMode = !_isPenMode;
                          _penStrokePoints.clear();
                        });
                      },
                    ),
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        focusNode: _messageFocusNode,
                        maxLines: 6,
                        minLines: 3,
                        decoration: InputDecoration.collapsed(
                          hintText: l10n.askAiHint,
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
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSendControl(AppLocalizations l10n) {
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

    return IconButton(
      icon: const Icon(Icons.send),
      tooltip: l10n.send,
      onPressed: _sendMessage,
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
          if (_availableMcpEndpoints.isNotEmpty || _aiToolBundles.isNotEmpty)
            _buildMcpSelectionSection(l10n),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: _buildConversationList(l10n),
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
    final totalActiveCount = activeMcpCount + activeLocalCount;
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
          if (_isMcpPanelExpanded) ...[
            const SizedBox(height: 8),
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
                      color: theme.colorScheme.onSurface.withOpacity(0.8),
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
                          : theme.colorScheme.onSurface.withOpacity(0.6),
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
                      color: theme.colorScheme.onSurface.withOpacity(0.8),
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
                          : theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                  );
                }).toList(),
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
        ],
      ),
    );
  }

  void _expandAiPanel(_AiPanelSide side, Size canvasSize) {
    final isLandscape = canvasSize.width > canvasSize.height;
    final normalizedSide = _normalizePanelSide(side, isLandscape);

    setState(() {
      _isAiPanelExpanded = true;
      _aiPanelSide = normalizedSide;

      if (isLandscape) {
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
                if (isUser)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: SelectableText(
                          message.content,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
          avatar: Icon(
            _iconForAttachment(file.path ?? file.name),
            size: 18,
          ),
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
                originalContent: note.content,
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
                                originalContent: subNote.content,
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
                controllerMap: _pdfControllers,
                onError: (message) => LoggerService.error(message),
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
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 48, right: 16),
                    leading: Icon(_iconForAttachment(attachment)),
                    title: Text(
                      attachment.split(Platform.pathSeparator).last,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      setState(() {
                        _activeNoteIndex = i;
                        _activeAttachmentPath = attachment;
                      });
                      Navigator.pop(context);
                    },
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
    final requestId = DateTime.now().millisecondsSinceEpoch.toString();
    _currentRequestId = requestId;

    _messageController.clear();
    setState(() {
      _pendingAttachments.clear();
    });

    try {
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
        requestId,
      );
      final aiMessage = await _conversationService.addAIResponse(
        conversationId: _conversation!.id,
        content: response.content,
        metadata: response.metadata,
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
    String requestId,
  ) async {
    final noteBuilder = NotePromptBuilder(_databaseService);
    final systemMessage = _buildSystemPrompt();
    final contextMessage = await noteBuilder.buildContextMessage(
      _conversationNotes,
    );

    final messages = <PromptMessage>[];
    for (final message in _messages) {
      final role = message.type == MessageType.user
          ? PromptRole.user
          : PromptRole.assistant;

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
          content: message.content,
          attachments: attachments,
          metadata: message.metadata,
        ),
      );

      // Add tool results from previous assistant message
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

    messages.add(
      PromptMessage(
        role: PromptRole.user,
        content: userMessage,
        attachments: latestAttachments,
      ),
    );

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

    final response = await _aiEngine.generate(
      request: request,
      activeTools: activeTools,
      enableTools: activeTools.isNotEmpty,
      executeTool: (serviceName, toolName, params) async {
        return _runWithToolStatus(serviceName, toolName, () async {
          if (_aiToolBundles.containsKey(serviceName)) {
            final runtime = await _getAiToolRuntime(serviceName);
            return runtime.invoke(toolName, params);
          }

          return McpToolIntegrationService.executeToolCall(
            serviceName: serviceName,
            toolName: toolName,
            parameters: params,
            enabledEndpointIds: _selectedMcpEndpointIds.toList(),
          );
        });
      },
      isCancelled: () => _cancelledRequestIds.contains(requestId),
      requestId: requestId,
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
      _penStrokePoints
        ..clear()
        ..add(localPosition);
    });
  }

  void _handlePenPanUpdate(DragUpdateDetails details) {
    final renderObject = _noteBoundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return;
    final localPosition = renderObject.globalToLocal(details.globalPosition);
    setState(() {
      final lastPoint = _penStrokePoints.isEmpty ? null : _penStrokePoints.last;
      if (lastPoint == null ||
          (lastPoint - localPosition).distanceSquared > 1) {
        _penStrokePoints.add(localPosition);
      }
    });
  }

  Future<void> _handlePenPanEnd() async {
    if (_penStrokePoints.length < 2) {
      _resetPenStroke();
      return;
    }

    final strokePoints = List<Offset>.from(_penStrokePoints);
    final bounds = _computeStrokeBounds(strokePoints);
    _resetPenStroke();

    if (bounds.width < 12 || bounds.height < 12) {
      return;
    }

    try {
      final croppedBytes = await _captureStroke(strokePoints, bounds);
      final result = await SynapseTempUtils.saveTempData(
        mimeType: 'image/png',
        bytes: croppedBytes,
      );
      final file = result.file;
      final platformFile = PlatformFile(
        name: 'annotation_${DateTime.now().millisecondsSinceEpoch}.png',
        path: file.path,
        size: croppedBytes.length,
        bytes: croppedBytes,
      );

      if (mounted) {
        setState(() {
          _pendingAttachments.add(platformFile);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Annotation added to attachments.')),
        );
      }
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to capture annotation: $e',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to capture annotation: $e')),
        );
      }
    }
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
    _pdfControllers.clear();
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
          _noteOrder = conversationNotes
              .map((note) => note.id)
              .toList(growable: false);
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

  Future<Uint8List> _captureStroke(List<Offset> points, Rect bounds) async {
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
    if (Platform.isIOS) {
      final Offset boundaryOrigin = renderObject.localToGlobal(Offset.zero);
      final Offset captureOrigin =
          boundaryOrigin + Offset(cappedRect.left, cappedRect.top);
      regionBytes = await NativeCaptureUtils.captureRegion(
        x: captureOrigin.dx * devicePixelRatio,
        y: captureOrigin.dy * devicePixelRatio,
        width: cappedRect.width * devicePixelRatio,
        height: cappedRect.height * devicePixelRatio,
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

    final List<Offset> scaledPoints = points
        .map(
          (point) => Offset(
            (point.dx - cappedRect.left) * devicePixelRatio,
            (point.dy - cappedRect.top) * devicePixelRatio,
          ),
        )
        .toList();

    if (scaledPoints.length >= 2) {
      final Path strokePath = _FreeformStrokePainter.buildPath(scaledPoints);
      final double strokeWidth = max(4.0, 2.0 * devicePixelRatio);

      final Paint glowPaint = Paint()
        ..color = Colors.redAccent.withOpacity(0.18)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = strokeWidth * 2;

      final Paint strokePaint = Paint()
        ..color = Colors.redAccent
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = strokeWidth;

      canvas.drawPath(strokePath, glowPaint);
      canvas.drawPath(strokePath, strokePaint);
    }

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
      return _AttachmentSource(
        file: file,
        extension: extension,
        originalPath: file.path,
      );
    } catch (e) {
      LoggerService.warning('Failed to load attachment $path: $e');
      return null;
    }
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
}

class _AttachmentSource {
  _AttachmentSource({
    required this.file,
    required this.extension,
    required this.originalPath,
    this.bytes,
  });

  final File file;
  final Uint8List? bytes;
  final String extension;
  final String originalPath;

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
  });

  final _AttachmentSource source;
  final double availableHeight;
  final Map<String, int> currentPageMap;
  final Map<String, int> totalPageMap;
  final Map<String, PDFViewController> controllerMap;
  final void Function(String message) onError;

  @override
  State<_PdfDocumentView> createState() => _PdfDocumentViewState();
}

class _PdfDocumentViewState extends State<_PdfDocumentView>
    with AutomaticKeepAliveClientMixin {
  late Future<String> _pdfPathFuture;
  String? _resolvedPath;
  Widget? _cachedView;

  String get _cacheKey => widget.source.cacheKey;

  @override
  void initState() {
    super.initState();
    _pdfPathFuture = _resolvePdfPath();
  }

  @override
  void didUpdateWidget(covariant _PdfDocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.cacheKey != widget.source.cacheKey) {
      _pdfPathFuture = _resolvePdfPath();
      _resolvedPath = null;
      _cachedView = null;
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
        if (_cachedView == null || _resolvedPath != filePath) {
          _resolvedPath = filePath;
          _cachedView = _buildPdfView(filePath);
        }

        return _cachedView!;
      },
    );
  }

  Widget _buildPdfView(String filePath) {
    widget.currentPageMap.putIfAbsent(_cacheKey, () => 0);

    return PDFView(
      key: ValueKey('${_cacheKey}_pdf_view'),
      filePath: filePath,
      autoSpacing: false,
      pageFling: false,
      pageSnap: false,
      enableSwipe: true,
      swipeHorizontal: false,
      fitPolicy: FitPolicy.BOTH,
      preventLinkNavigation: false,
      onViewCreated: (controller) async {
        widget.controllerMap[_cacheKey] = controller;
        final storedPage = widget.currentPageMap[_cacheKey] ?? 0;
        try {
          final currentPage = await controller.getCurrentPage();
          if (currentPage != storedPage) {
            await controller.setPage(storedPage);
          }
        } catch (e) {
          widget.onError('Unable to set initial PDF page: $e');
        }
      },
      onRender: (pages) {
        if (pages != null) {
          widget.totalPageMap[_cacheKey] = pages;
          final stored = widget.currentPageMap[_cacheKey];
          if (stored != null && stored >= pages) {
            widget.currentPageMap[_cacheKey] = pages - 1;
          }
        }
      },
      onPageChanged: (page, total) {
        if (page != null) {
          widget.currentPageMap[_cacheKey] = page;
        }
        if (total != null) {
          widget.totalPageMap[_cacheKey] = total;
        }
      },
      onError: (error) {
        widget.onError('PDFView error: $error');
      },
      onPageError: (page, error) {
        widget.onError('PDFView page error ($page): $error');
      },
      backgroundColor: Colors.transparent,
    );
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    widget.controllerMap.remove(_cacheKey);
    super.dispose();
  }
}

class _FreeformStrokePainter extends CustomPainter {
  _FreeformStrokePainter(List<Offset>? points)
    : _points = points == null ? null : List<Offset>.unmodifiable(points);

  final List<Offset>? _points;

  @override
  void paint(Canvas canvas, Size size) {
    final points = _points;
    if (points == null || points.length < 2) return;

    final path = buildPath(points);

    final glowPaint = Paint()
      ..color = Colors.redAccent.withOpacity(0.18)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 8;

    final strokePaint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 3;

    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, strokePaint);
  }

  static Path buildPath(List<Offset> points) {
    final path = Path();
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
  bool shouldRepaint(covariant _FreeformStrokePainter oldDelegate) {
    return !listEquals(oldDelegate._points, _points);
  }
}

enum _AiPanelSide { top, bottom, left, right }
