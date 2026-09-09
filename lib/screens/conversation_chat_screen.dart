import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import '../widgets/drawing_editor.dart';
import '../widgets/approval_dialog.dart';
import '../models/conversation.dart';
import '../models/conversation_branch_summary.dart';
import '../models/chip_action.dart';
import '../models/tool_iteration_prompt.dart';
import '../models/note.dart';
import '../models/agent_task.dart';
import '../models/mcp_endpoint.dart';
import '../models/generation_context.dart';
import '../models/model_config.dart';
import '../services/conversation_service.dart';
import '../services/chip_tap_handler.dart';
import '../services/model_selector.dart';
import '../services/service_locator.dart';
import '../services/space_scope_service.dart';
import '../services/prompts/space_scope_prompt.dart';
import '../services/attachment_preprocessor.dart';
import '../services/local_model_attachment_constraint_service.dart';
import '../services/logger_service.dart';
import '../services/prompts/ai_prompts.dart';
import '../services/mcp_service.dart';
import '../services/mcp_tool_integration_service.dart';
import '../services/ai_tool_service.dart';
import '../services/approval_service.dart';
import '../services/prompts/prompt_models.dart';
import '../services/prompts/system_prompt_builder.dart';
import '../services/prompts/prompt_configuration_service.dart';
import '../services/prompts/registrations/chat_prompt_configuration.dart';
import '../services/prompts/note_prompt_builder.dart';
import '../services/database_service.dart';
import '../services/conversation_settings_service.dart';
import '../services/conversation_prompt_builder.dart';
import '../widgets/chip_aware_ai_message_content.dart';
import '../utils/file_utils.dart';
import '../utils/conversation_title_directive.dart';
import '../utils/date_utils.dart';
import '../l10n/app_localizations.dart';
import '../services/conversation_ai_engine.dart';
import 'note_selection_dialog.dart';
import 'note_detail_screen.dart';
import 'conversation_tree_screen.dart';
import 'immersive_note_screen.dart';
import 'note_action_app_selection_screen.dart';
import 'settings_screen.dart';
import '../widgets/tag_selection_dialog.dart';
import '../providers/app_provider.dart';
import '../services/user_app_service.dart';
import '../models/user_app.dart';
import '../mixins/note_action_mixin.dart';
import '../widgets/chat_message_action_row.dart';
import '../widgets/message_branch_strip.dart';
import '../widgets/active_tool_count_badge.dart';
import '../widgets/model_selector_button.dart';
import '../services/agent_service.dart';
import '../services/background_agent_service.dart';
import '../services/built_in_tools_service.dart';
import '../services/context_manager_service.dart';
import '../services/skill_service.dart';
import '../services/tools/note_tools.dart';
import '../services/tools/tool_outcome.dart';
import '../services/tools/tool_param_validator.dart';
import '../services/sql_query_service.dart';
import '../widgets/agent_plan_review_widget.dart';
import '../widgets/agent_task_tree_widget.dart';
import '../widgets/attachment_preview_tile.dart';
import '../widgets/local_model_attachment_warning_dialog.dart';
import '../widgets/tool_orchestration_warning_dialog.dart';
import '../services/fork_service.dart';

class ConversationChatScreen extends StatefulWidget {
  final String? conversationId;
  final List<String>? initialNoteIds;
  final ModelConfig? initialModelOverride;
  final String? initialMessageId;
  final bool skillsEnabled;

  const ConversationChatScreen({
    super.key,
    this.conversationId,
    this.initialNoteIds,
    this.initialModelOverride,
    this.initialMessageId,
    this.skillsEnabled = true,
  });

  @override
  State<ConversationChatScreen> createState() => _ConversationChatScreenState();
}

class _ConversationChatScreenState extends State<ConversationChatScreen>
    with NoteActionMixin<ConversationChatScreen>, WidgetsBindingObserver {
  ConversationService get _conversationService => getIt<ConversationService>();
  final ForkService _forkService = ForkService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode();
  final ConversationAiEngine _aiEngine = const ConversationAiEngine();

  Conversation? _conversation;
  List<ConversationMessage> _messages = [];
  List<Note> _notes = [];
  Map<String, List<ConversationBranchSummary>> _branchesByParent = const {};
  bool _isLoading = false;
  bool _isSending = false;
  bool _isAborting = false;
  String _streamingContent = '';
  bool _isStreaming = false;
  String? _currentRequestId;
  final Set<String> _cancelledRequestIds = {};
  final List<PlatformFile> _attachedFiles = [];
  List<String> _conversationTags = [];
  final DateTime _conversationStartTime = DateTime.now();

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
  int _maxToolIterations = ConversationSettingsService.defaultMaxToolIterations;
  ToolIterationPrompt? _iterationPrompt;

  // Model Features support
  final Set<String> _selectedModelFeatures = {};
  ModelConfig? _selectedModel;

  // Built-in Tools
  final Set<String> _selectedBuiltInTools = {};

  // System Tools (native tools from AgentService)
  final Set<String> _selectedSystemTools = {};

  // Agent Skills
  bool _skillsEnabled = false;
  int _skillCount = 0;
  bool?
  _lastOrchestrationSupport; // tracks model's capability to detect changes

  bool _hasInitialized = false;
  bool _waitingForAgentResult = false;
  AgentService? _agentService;
  StreamSubscription<String>? _forkSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedModel = widget.initialModelOverride;
    // Skills start disabled; _initSkillsWithModelCheck runs after first frame
    // when BuildContext is available to read the active model's capabilities.
    _skillsEnabled = false;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _initSkillsWithModelCheck(),
    );
    _loadMcpEndpoints();
    _loadIterationPreference();
    _setupSqlWriteApprovalCallback();
    _forkSub = _forkService.forkCreatedStream.listen(_onForkCreated);
    // Listener managed in didChangeDependencies
  }

  /// Sets up the unified approval callback for agentic mode.
  /// Shows a dialog when the agent tries to execute sensitive operations.
  void _setupSqlWriteApprovalCallback() {
    // Register unified approval callback
    ApprovalService.onApprovalRequest = (request) async {
      if (!mounted) {
        throw StateError('Conversation screen is not mounted');
      }
      return await ApprovalDialog.showWithContext(context, request);
    };

    // Keep legacy callback for backwards compatibility
    RunSqlTool.onWriteApprovalRequest = (sql, queryType) async {
      if (!mounted) return false;
      final result = await ApprovalService.requestSqlWriteApproval(
        sql: sql,
        queryType: queryType,
        queryTypeDescription: getIt<SqlQueryService>().getQueryTypeDescription(
          queryType,
        ),
        source: 'Agent',
      );
      return result;
    };
  }

  /// Rebuilds the conversation service's skill index when the Space scope
  /// moved, then republishes the count this screen shows.
  ///
  /// The screen caches only the count, but that count is a scope-derived view
  /// of the same index: leaving it stale tells the user "6 skills available"
  /// in a Space that can reach two of them.
  ///
  /// No staleness guard of its own, on purpose, and **nothing returns before
  /// the rebuild**. `ensureSkillIndex()` already returns the cached index
  /// untouched when the scope has not moved, and the count comparison below
  /// already suppresses a pointless `setState`, so a staleness check here was
  /// redundant *and* invertible: flipping its one `!` made the screen rebuild
  /// only when it was already fresh, which fed the previous Space's skills to
  /// the model (the prompt reads the cached `skillIndex` getter, so this call
  /// is what makes it fresh) with nothing to catch it. Awaiting the rebuild
  /// first leaves no polarity that can suppress it.
  ///
  /// The `skillsEnabled` check below guards the *count*, not the rebuild:
  /// while skills are off, `ensureSkillIndex()` answers with an empty map but
  /// `_skillCount` holds the size of the whole skill library
  /// ([_initSkillsWithModelCheck]), and zeroing it would hide the chip that
  /// turns skills on.
  Future<void> _refreshSkillIndexIfScopeChanged() async {
    final index = await _conversationService.ensureSkillIndex();
    if (!mounted) return;
    if (!_conversationService.skillsEnabled) return;
    if (index.length != _skillCount) {
      setState(() => _skillCount = index.length);
    }
  }

  void _initSkillsWithModelCheck() {
    if (!mounted) return;
    final modelConfig =
        _selectedModel ?? context.read<AppProvider>().modelConfig;
    final supportsOrchestration =
        modelConfig?.customCapabilitiesObject?.supportsToolOrchestration ??
        true;
    _lastOrchestrationSupport = supportsOrchestration;
    final enable = widget.skillsEnabled && supportsOrchestration;
    if (enable) {
      setState(() => _skillsEnabled = true);
      _conversationService.enableSkills().then((_) {
        if (mounted) {
          setState(() => _skillCount = _conversationService.skillIndex.length);
        }
      });
    } else {
      _conversationService.disableSkills();
      getIt<SkillService>().buildSkillIndex().then((index) {
        if (mounted) setState(() => _skillCount = index.length);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh model features when app resumes (e.g., after model configuration change)
      _loadModelFeatures();
      // Stop background service when returning to app (agent continues in foreground)
      BackgroundAgentService.stop();
      // Clear background callback - UI will show progress instead
      _agentService?.onProgressUpdate = null;
    } else if (state == AppLifecycleState.paused) {
      // Start background service if agent is running when app goes to background
      final agentService = _agentService;
      if (agentService != null &&
          agentService.isRunning &&
          _conversation != null) {
        // Wire up progress updates to background notification
        agentService.onProgressUpdate = (status) {
          if (BackgroundAgentService.isRunningInBackground) {
            BackgroundAgentService.updateProgress(status);
            // Check for completion
            if (status == 'Agent completed' || !agentService.isRunning) {
              BackgroundAgentService.markComplete(status);
            }
          }
        };
        BackgroundAgentService.startBackgroundExecution(
          conversationId: _conversation!.id,
          objective: agentService.currentObjective ?? 'Agent task',
        );
      }
    }
  }

  ModelConfig? _previousModelConfig;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Manage AgentService listener safely
    final newAgentService = context.watch<AgentService>();
    if (_agentService != newAgentService) {
      _agentService?.removeListener(_onAgentStateChange);
      _agentService = newAgentService;
      _agentService?.addListener(_onAgentStateChange);
    }

    if (!_hasInitialized) {
      _hasInitialized = true;
      _initializeConversation();
    }

    final appProvider = context.watch<AppProvider>();
    if (_previousModelConfig != appProvider.modelConfig) {
      _previousModelConfig = appProvider.modelConfig;
      // Refresh model features when model config changes
      _loadModelFeatures();
    }

    // Re-evaluate skills if the active model's orchestration capability changed.
    final modelConfig = context.read<AppProvider>().modelConfig;
    final nowSupports =
        modelConfig?.customCapabilitiesObject?.supportsToolOrchestration ??
        true;
    if (_lastOrchestrationSupport != null &&
        _lastOrchestrationSupport != nowSupports) {
      _initSkillsWithModelCheck();
    }
    _lastOrchestrationSupport = nowSupports;
  }

  Future<void> _initializeConversation() async {
    setState(() => _isLoading = true);

    try {
      if (widget.conversationId != null) {
        // Load existing conversation
        final conversationWithMessages = await _conversationService
            .getConversationWithFullHistory(widget.conversationId!);
        if (conversationWithMessages != null) {
          _conversation = conversationWithMessages.conversation;
          _messages = conversationWithMessages.messages;
          _notes = await _conversationService.getConversationNotes(
            widget.conversationId!,
          );
          _branchesByParent = await _loadBranchSummaries(
            widget.conversationId!,
          );
          await _refreshConversationTags();

          // Validate note references and show alert if any are missing
          final missingNoteIds = await _conversationService
              .validateConversationNotes(widget.conversationId!);
          if (missingNoteIds.isNotEmpty && mounted) {
            _showMissingNotesAlert(missingNoteIds);
          }
        }
      } else {
        // This is a new conversation, so we'll load any initial notes but not create the
        // conversation entity until the first message is sent.
        if (widget.initialNoteIds != null &&
            widget.initialNoteIds!.isNotEmpty) {
          _notes = await _conversationService.getNotesByIds(
            widget.initialNoteIds!,
          );
        }
        _branchesByParent = const {};
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error initializing conversation: $e')),
        );
      }
    } finally {
      await _loadAiTools();
      if (mounted) {
        // Initialize model features from config
        _loadModelFeatures();
        setState(() => _isLoading = false);
        if (widget.initialMessageId != null) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToMessage(widget.initialMessageId!),
          );
        }
        // Sync with agent state (update executor) now that we are initialized
        _onAgentStateChange();
      }
    }
  }

  void _loadModelFeatures() {
    // Clear selected features when model changes - user must explicitly toggle them on
    setState(() {
      _selectedModelFeatures.clear();
    });
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
      setState(() {
        _availableMcpEndpoints = endpointsWithTools;
      });
    } catch (e) {
      LoggerService.error('Error loading MCP endpoints: $e');
    }
  }

  Future<void> _loadIterationPreference() async {
    final value = await ConversationSettingsService.getMaxToolIterations();
    if (!mounted) return;
    setState(() {
      _maxToolIterations = value;
    });
  }

  Future<void> _refreshConversationTags() async {
    if (_conversation == null) {
      if (mounted && _conversationTags.isNotEmpty) {
        setState(() {
          _conversationTags = [];
        });
      }
      return;
    }

    try {
      final tags = await _conversationService.getConversationTagNames(
        _conversation!.id,
      );
      if (!mounted) return;
      setState(() {
        _conversationTags = tags;
      });
    } catch (e) {
      LoggerService.error('Error loading conversation tags: $e', error: e);
    }
  }

  Future<Map<String, List<ConversationBranchSummary>>> _loadBranchSummaries(
    String conversationId,
  ) async {
    try {
      return await _conversationService.getAllForkPointBranches(conversationId);
    } catch (e) {
      LoggerService.error('Error loading conversation branches: $e', error: e);
      return const {};
    }
  }

  Future<void> _refreshBranchSummaries() async {
    final conversationId = _conversation?.id;
    if (conversationId == null) {
      if (mounted && _branchesByParent.isNotEmpty) {
        setState(() {
          _branchesByParent = const {};
        });
      }
      return;
    }

    final branches = await _loadBranchSummaries(conversationId);
    if (!mounted || _conversation?.id != conversationId) return;
    setState(() {
      _branchesByParent = branches;
    });
  }

  Future<void> _onForkCreated(String parentMessageId) async {
    final conversationId = _conversation?.id;
    if (conversationId == null) return;
    final branches = await _loadBranchSummaries(conversationId);
    if (!mounted || _conversation?.id != conversationId) return;
    setState(() {
      _branchesByParent = branches;
    });
  }

  List<ConversationBranchSummary> _branchesFor(String forkPointMessageId) {
    final siblingBranches =
        _branchesByParent[forkPointMessageId] ??
        const <ConversationBranchSummary>[];
    if (siblingBranches.isEmpty) return const [];
    final conversation = _conversation;
    if (conversation == null) return siblingBranches;
    if (siblingBranches.any((b) => b.conversationId == conversation.id)) {
      return siblingBranches;
    }
    final active = ConversationBranchSummary(
      conversationId: conversation.id,
      title: conversation.title,
      forkPointMessageId: forkPointMessageId,
      firstChildMessageId: forkPointMessageId,
      noteIds: conversation.noteIds,
    );
    return [active, ...siblingBranches];
  }

  bool _areChipsExpected() {
    return _conversationService.skillsEnabled &&
        _conversationService.skillIndex.values.any(
          (skill) => skill.defaultAction != null,
        );
  }

  Future<bool> _switchConversationInPlace(
    String conversationId, {
    String? scrollToMessageId,
  }) async {
    try {
      final loaded = await _conversationService.getConversationWithFullHistory(
        conversationId,
      );
      if (loaded == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not load forked conversation')),
          );
        }
        return false;
      }

      final notes = await _conversationService.getConversationNotes(
        conversationId,
      );
      final missingNoteIds = await _conversationService
          .validateConversationNotes(conversationId);
      final branches = await _loadBranchSummaries(conversationId);

      if (!mounted) return false;
      setState(() {
        _conversation = loaded.conversation;
        _messages = loaded.messages;
        _notes = notes;
        _branchesByParent = branches;
        _streamingContent = '';
        _isStreaming = false;
      });
      await _refreshConversationTags();
      if (missingNoteIds.isNotEmpty && mounted) {
        _showMissingNotesAlert(missingNoteIds);
      }
      if (mounted) {
        _onAgentStateChange();
        if (scrollToMessageId == null) {
          _scrollToBottom();
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToMessage(scrollToMessageId);
          });
        }
      }
      return mounted;
    } catch (e) {
      LoggerService.error('Error loading forked conversation: $e', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading forked conversation: $e')),
        );
      }
      return false;
    }
  }

  Future<void> _showConversationTagsDialog() async {
    if (_conversation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Create the conversation before adding tags.'),
        ),
      );
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final appProvider = context.read<AppProvider>();
    final selectedTags = await showDialog<List<String>>(
      context: context,
      builder: (context) => TagSelectionDialog(
        title: l10n.manageTags,
        description: 'Select tags for "${_conversation!.title}":',
        initialSelectedTags: _conversationTags,
        allowCreateNew: true,
        allowEmptySelection: true,
        confirmLabelBuilder: (count) {
          if (count == 0) return l10n.clearTags;
          return l10n.applyTagsWithCount(count);
        },
      ),
    );

    if (selectedTags == null) return;

    try {
      await _conversationService.setConversationTags(
        _conversation!.id,
        selectedTags,
      );
      await appProvider.refreshTags();
      await _refreshConversationTags();
      if (!mounted) return;
      final message = selectedTags.isEmpty ? 'Tags cleared' : 'Tags updated';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      LoggerService.error('Error updating conversation tags: $e', error: e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error updating tags: $e')));
    }
  }

  Future<void> _removeTag(String tagName) async {
    if (_conversation == null) return;

    try {
      await _conversationService.removeTagFromConversation(
        _conversation!.id,
        tagName,
      );
      await _refreshConversationTags();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Tag "$tagName" removed')));
    } catch (e) {
      LoggerService.error('Error removing tag: $e', error: e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error removing tag: $e')));
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

    // Add Skill tools when skills are enabled
    if (_conversationService.skillsEnabled) {
      final skillTools = <McpTool>[];
      final loadSkillTool = _conversationService.loadSkillTool;
      skillTools.add(
        McpTool(
          name: loadSkillTool.name,
          description: loadSkillTool.description,
          inputSchema: loadSkillTool.inputSchema,
        ),
      );
      for (final t in _conversationService.skillDiscoveredTools) {
        if (!skillTools.any((s) => s.name == t.name)) {
          skillTools.add(t);
        }
      }
      combined[_skillToolsServiceKey] = skillTools;
    }

    return combined;
  }

  /// Service key used to route skill tool calls in the executeTool callback.
  static const String _skillToolsServiceKey = 'SkillTools';

  Future<int?> _handleIterationsExhausted(int exhaustedLimit) async {
    if (!mounted) return null;
    final prompt = ToolIterationPrompt(exhaustedIterations: exhaustedLimit);
    setState(() {
      _iterationPrompt = prompt;
      _toolExecutionStatus = null;
    });

    final result = await prompt.completer.future;
    if (!mounted) {
      return result;
    }
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

  /// Gets or creates an [AiToolRuntime] for a skill-discovered user_defined tool.
  ///
  /// Unlike [_getAiToolRuntime], this uses the provided [bundle] directly rather
  /// than looking it up from [_aiToolBundles].
  Future<AiToolRuntime> _getSkillAiToolRuntime(
    String serviceName,
    AiToolAppBundle bundle,
  ) async {
    final existing = _aiToolRuntimes[serviceName];
    if (existing != null) {
      return existing;
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
      queryTypeDescription: getIt<SqlQueryService>().getQueryTypeDescription(
        queryType,
      ),
      source: 'AI Tool',
    );
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.isEmpty && _attachedFiles.isEmpty) return;

    // Capture ScaffoldMessenger and Navigator before any async operations
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final content = _messageController.text;
    final attachments = List<PlatformFile>.from(_attachedFiles);

    final activeConfig =
        _selectedModel ?? context.read<AppProvider>().modelConfig;
    final localAttachmentWarning =
        await LocalModelAttachmentConstraintService.analyzeForGemma4(
          config: activeConfig,
          prompt: content,
          attachments: attachments,
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

    String? requestId;
    GenerationContext? generationContext;
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
        final noteIdSet = <String>{
          ..._notes.map((note) => note.id),
          if (widget.initialNoteIds != null) ...widget.initialNoteIds!,
        };
        final newConversation = await _conversationService.createConversation(
          title: title.length > 50 ? '${title.substring(0, 50)}...' : title,
          noteIds: noteIdSet.toList(),
          // Files the conversation into the Space it was started in, so the
          // conversation tree finds it there again.
          tags: SpaceScopeService.shared().stampTags,
        );
        if (!mounted) return;
        setState(() {
          _conversation = newConversation;
          _conversationTags = [];
        });
        await _refreshConversationTags();
        if (noteIdSet.isNotEmpty) {
          // Reload notes to ensure the newly created conversation pulls latest context
          final updatedNotes = await _conversationService.getConversationNotes(
            newConversation.id,
          );
          setState(() {
            _notes = updatedNotes;
          });
        }
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
      generationContext = GenerationContext();
      if (_selectedModel != null) {
        generationContext.modelOverride = _selectedModel;
      }
      // Note: Capability detection is now handled in ConversationAiEngine
      requestId = generationContext.ensureRequestId();
      _currentRequestId = requestId;

      // Check for Agent Tool
      if (_selectedBuiltInTools.contains(BuiltInToolsService.agentToolId)) {
        final agentService = context.read<AgentService>();

        // SINGLETON GUARD: Check if we can start a new agent here
        if (!agentService.canStartNewAgent(_conversation!.id)) {
          // Show conflict dialog
          final result = await _showAgentConflictDialog(agentService);

          if (result == 'switch') {
            final targetId = agentService.boundConversationId;
            if (targetId != null && mounted) {
              // Use pushReplacement to switch to the active conversation
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (_) =>
                      ConversationChatScreen(conversationId: targetId),
                ),
              );
              return; // Stop flow
            }
          } else if (result == 'abort') {
            agentService.abortCurrentTask();
            // Continue execution below...
          } else {
            // Cancel or dismissed
            setState(() {
              _isSending = false;
              _currentRequestId = null;
            });
            return; // Stop flow
          }
        }

        // Bind to this conversation now that we are clear
        agentService.bindToConversation(_conversation!.id);

        // Fetch available tools for the agent based on *current selection*
        final activeTools = _buildActiveToolsMap();

        // Gather Context
        final noteBuilder = NotePromptBuilder(DatabaseService());
        final noteContext = await noteBuilder.buildNoteContext(_notes);
        final noteAttachments = await noteBuilder.loadNoteAttachments(_notes);

        final historyBuffer = StringBuffer();
        final historyAttachments = <PlatformFile>[];

        // Gather history (last 10 messages)
        final relevantMessages = _messages.length > 10
            ? _messages.sublist(_messages.length - 10)
            : _messages;

        for (final msg in relevantMessages) {
          historyBuffer.writeln(
            '${msg.type.name.toUpperCase()}: ${msg.content}',
          );
          // Load attachments for this message
          final msgAttachments = await _loadConversationAttachments(msg, []);
          historyAttachments.addAll(msgAttachments);
        }

        // Include current message attachments if not already added
        if (attachments.isNotEmpty) {
          historyAttachments.addAll(attachments);
        }

        final combinedContext =
            '''
Associated Notes Context:
$noteContext

Recent Conversation History:
$historyBuffer
''';

        final allAttachments = [...noteAttachments, ...historyAttachments];

        // Trigger planning (fire and forget from UI perspective, handled by service listener)
        setState(() {
          _waitingForAgentResult = true;
        });

        agentService.generatePlan(
          content,
          activeTools: activeTools,
          executeTool: _createToolExecutor(),
          context: combinedContext,
          contextAttachments: allAttachments,
        );

        // In a real app we might want to persist this message to DB
        // For V1, we add to local list. If we want persistence, we need to save it.
        final savedMessage = await _conversationService.addAIResponse(
          conversationId: _conversation!.id,
          content: '(Agent Plan)',
          metadata: {'is_agent_plan': true},
        );

        if (!mounted) return;
        setState(() {
          _messages.add(savedMessage);
          _isSending = false;
          _currentRequestId = null;
        });
        _scrollToBottom();
        return;
      }

      await _generateAndPersistAiResponse(
        conversationId: _conversation!.id,
        prompt: content,
        attachments: attachments,
        generationContext: generationContext,
      );
    } on ConversationCancelledException {
      if (requestId != null) {
        _cancelledRequestIds.remove(requestId);
      }
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('AI request cancelled.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error sending message: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _currentRequestId = null;
          if (requestId != null) {
            _cancelledRequestIds.remove(requestId);
          }
        });
      }
    }
  }

  Future<void> _generateAndPersistAiResponse({
    required String conversationId,
    required String prompt,
    required List<PlatformFile> attachments,
    required GenerationContext generationContext,
  }) async {
    final titleStreamFilter = ConversationTitleStreamFilter();
    final aiResponse = await _generateAIResponse(
      prompt,
      attachments,
      generationContext,
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
      conversationId: conversationId,
      content: aiResponse.content,
      metadata: aiResponse.metadata,
      modelUsed: aiResponse.metadata?['modelUsed'] as String?,
    );
    if (!mounted) return;

    setState(() {
      _streamingContent = '';
      _isStreaming = false;
      _messages.add(aiMessage);
    });
    _scrollToBottom();
  }

  Future<void> _handleChipTap(
    ConversationMessage parentMessage,
    ChipAction chip,
  ) async {
    if (_conversation == null || _isSending || _isStreaming) return;
    if (!mounted) return;

    final sourceConversationId = _conversation!.id;
    final messenger = ScaffoldMessenger.of(context);
    String? requestId;

    setState(() {
      _isSending = true;
    });

    try {
      final forked = await ChipTapHandler().handle(
        parentMessageId: parentMessage.id,
        chip: chip,
        sourceConversationId: sourceConversationId,
      );
      if (!mounted || forked == null) return;

      final switched = await _switchConversationInPlace(forked.id);
      if (!mounted || !switched) return;

      final generationContext = GenerationContext();
      if (_selectedModel != null) {
        generationContext.modelOverride = _selectedModel;
      }
      requestId = generationContext.ensureRequestId();
      _currentRequestId = requestId;

      await _generateAndPersistAiResponse(
        conversationId: forked.id,
        prompt: chip.prompt,
        attachments: const <PlatformFile>[],
        generationContext: generationContext,
      );
    } on ConversationCancelledException {
      if (requestId != null) {
        _cancelledRequestIds.remove(requestId);
      }
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('AI request cancelled.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      LoggerService.error('Error handling chip tap: $e', error: e);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error handling chip: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _currentRequestId = null;
          if (requestId != null) {
            _cancelledRequestIds.remove(requestId);
          }
        });
      }
    }
  }

  Future<void> _startNewConversation() async {
    final l10n = AppLocalizations.of(context)!;
    final newConversation = await _conversationService.createConversation(
      title: l10n.newConversation,
      tags: SpaceScopeService.shared().stampTags,
    );
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) =>
              ConversationChatScreen(conversationId: newConversation.id),
        ),
      );
    }
  }

  void _openInImmersiveMode() {
    if (_notes.isEmpty) {
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ImmersiveNoteScreen(
          notes: List<Note>.from(_notes),
          initialConversation: _conversation,
          initialMessages: List<ConversationMessage>.from(_messages),
        ),
      ),
    );
  }

  Future<void> _abortRequest() async {
    if (!_isSending || _currentRequestId == null) return;

    // Capture ScaffoldMessenger before any async operations
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);

    setState(() {
      _isAborting = true;
    });

    if (_iterationPrompt != null) {
      _resolveIterationPrompt(null);
    }

    // Mark the current request as cancelled
    _cancelledRequestIds.add(_currentRequestId!);

    // Show feedback to user
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Cancelling AI request...'),
        duration: Duration(seconds: 2),
      ),
    );

    // Wait a moment for the request to be cancelled
    await Future.delayed(const Duration(milliseconds: 500));

    if (mounted) {
      setState(() {
        _isSending = false;
        _isAborting = false;
        _currentRequestId = null;
      });
    }
  }

  Future<ConversationAiResponse> _generateAIResponse(
    String userMessage,
    List<PlatformFile> attachedFiles,
    GenerationContext generationContext, {
    void Function(String chunk)? onStreamChunk,
  }) async {
    final requestId = generationContext.ensureRequestId();
    try {
      if (_cancelledRequestIds.contains(requestId)) {
        throw const ConversationCancelledException();
      }

      final request = await _buildConversationPrompt(attachedFiles);

      if (_cancelledRequestIds.contains(requestId)) {
        throw const ConversationCancelledException();
      }

      // Add model features to generation context
      if (_selectedModelFeatures.isNotEmpty) {
        generationContext.setValue(
          'modelFeatures',
          _selectedModelFeatures.toList(),
        );
      }

      final aiResponse = await _aiEngine.generate(
        request: request,
        activeTools: _buildActiveToolsMap(),
        activeToolsProvider: _buildActiveToolsMap,
        enableTools: _hasAnyTools || _selectedModelFeatures.isNotEmpty,
        executeTool: (serviceName, toolName, params, context) async {
          return _runWithToolStatus(serviceName, toolName, () async {
            // Validate against the declared schema BEFORE approval or
            // execution — the same boundary ChatToolSession.executeTool
            // applies, so all chat surfaces behave identically.
            final validation = ToolParamValidator.validateAndNormalize(
              toolName: toolName,
              params: params,
              inputSchema: _findActiveToolSchema(serviceName, toolName),
            );
            if (validation.failure != null) {
              return validation.failure!.serialize();
            }
            params = validation.params;

            // Handle AI Tools
            if (_aiToolBundles.containsKey(serviceName)) {
              final runtime = await _getAiToolRuntime(serviceName);
              final result = await runtime.invoke(toolName, params, context);
              return ToolOutcome.fromAiToolResult(toolName, result).serialize();
            }

            // Handle System Tools (native tools from AgentService)
            if (serviceName == BuiltInToolsService.systemToolsServiceKey) {
              final agentService = this.context.read<AgentService>();
              final nativeTool = agentService.nativeTools
                  .where((t) => t.name == toolName)
                  .firstOrNull;
              if (nativeTool != null) {
                final result = await nativeTool.execute(params);
                return ToolOutcome.fromNativeResult(
                  toolName,
                  result,
                ).serialize();
              }
              return ToolOutcome.failure(
                code: ToolOutcome.codeNotFound,
                message: 'System tool "$toolName" not found',
              ).serialize();
            }

            // Handle Skill Tools (load_skill + skill-discovered tools)
            if (serviceName == _skillToolsServiceKey) {
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
                return ToolOutcome.fromNativeResult(
                  toolName,
                  result,
                ).serialize();
              }
              // Skill-discovered native (builtin) tool — route to native execution
              if (_conversationService.skillDiscoveredNativeToolNames.contains(
                toolName,
              )) {
                final agentService = this.context.read<AgentService>();
                final nativeTool = agentService.nativeTools
                    .where((t) => t.name == toolName)
                    .firstOrNull;
                if (nativeTool != null) {
                  final result = await nativeTool.execute(params);
                  return ToolOutcome.fromNativeResult(
                    toolName,
                    result,
                  ).serialize();
                }
                return ToolOutcome.failure(
                  code: ToolOutcome.codeNotFound,
                  message: 'Native tool "$toolName" not found',
                ).serialize();
              }
              // Skill-discovered user_defined tool — route via AI tool bundle
              for (final entry
                  in _conversationService.skillDiscoveredBundles.entries) {
                if (entry.value.toolDefinitions.any(
                  (d) => d.toolName == toolName,
                )) {
                  final runtime = await _getSkillAiToolRuntime(
                    entry.key,
                    entry.value,
                  );
                  final result = await runtime.invoke(
                    toolName,
                    params,
                    context,
                  );
                  return ToolOutcome.fromAiToolResult(
                    toolName,
                    result,
                  ).serialize();
                }
              }
              // Skill-discovered MCP tool — use the real endpoint name
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
              return ToolOutcome.failure(
                code: ToolOutcome.codeNotFound,
                message: 'Skill tool "$toolName" not found',
              ).serialize();
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

      return aiResponse;
    } on ConversationCancelledException {
      rethrow;
    } catch (e, stackTrace) {
      LoggerService.error(
        'Error generating AI response: $e',
        error: e,
        stackTrace: stackTrace,
      );
      return const ConversationAiResponse(
        content:
            'I apologize, but I encountered an error while generating a response. Please try again.',
      );
    }
  }

  Future<PromptRequest> _buildConversationPrompt(
    List<PlatformFile> latestUserAttachments,
  ) async {
    final promptBuilder = ConversationPromptBuilder(DatabaseService());
    final contextMessage = await promptBuilder.buildNoteContextMessage(_notes);

    final currentModelId =
        _selectedModel?.id ?? getIt<ModelSelector>().currentModelConfig?.id;

    final conversationMessages = await promptBuilder.buildConversationMessages(
      messages: _messages,
      currentModelId: currentModelId,
      latestUserAttachments: latestUserAttachments,
    );

    final contextMessages = contextMessage == null
        ? <PromptMessage>[]
        : [contextMessage];
    final systemMessage = await _buildConversationSystemMessage(
      hasInlineContext:
          contextMessages.isNotEmpty || latestUserAttachments.isNotEmpty,
    );

    return PromptRequest(
      systemMessage: systemMessage,
      contextMessages: contextMessages,
      conversationMessages: conversationMessages,
    );
  }

  Future<PromptMessage> _buildConversationSystemMessage({
    required bool hasInlineContext,
  }) async {
    // The session's skill index was built when skills were enabled; the user
    // may have switched Space since. Re-check before it reaches the prompt, and
    // keep the "N available" chip honest about what this Space can actually
    // reach.
    await _refreshSkillIndexIfScopeChanged();

    final lines = <String>[
      'Engage in a multi-turn conversation grounded in the provided note context message and attachments.',
      'Treat all prior messages as immutable history for KV-cache friendly reuse.',
      'Incorporate note relationships and hierarchies when citing evidence.',
      'Use your own knowledge to clarify or extend when the notes are insufficient.',
      'You should format your response as markdown for best reading experience.',
    ];
    if (ConversationTitleDirective.shouldRequestTitle(_conversation)) {
      lines.add(ConversationTitleDirective.promptInstruction);
    }

    if (_hasAnyTools) {
      lines.add(
        'The user has enabled external tools (MCP services or user-defined AI tools). Prefer calling them when they can improve accuracy before responding.',
      );
    }

    if (_notes.isEmpty) {
      lines.add(
        'No note context is currently attached. '
        'Rely on the conversation history and your own knowledge.',
      );
      if (_hasAnyTools) {
        lines.add(
          'Tools are available if you need to look up notes or execute actions.',
        );
      }
    }

    final budget = await _getChatPromptBudget();
    final combinedTools = _buildActiveToolsMap();

    // Models with native tool declarations (e.g. local Gemma) receive tool
    // schemas directly, so the text-based tool catalog is redundant and
    // wastes token budget.
    final currentModel = getIt<ModelSelector>().currentModel;
    final isLocalModel = currentModel?.usesNativeToolDeclarations ?? false;

    // Decision 5: when a Space is active the note tools are scoped, and the
    // model is told so rather than quietly handed a subset. Only worth saying
    // where those tools exist — in chat they arrive through a loaded skill, so
    // a session without them has nothing scoped to announce. Both halves of
    // that decision live in buildChatSpaceScopeSection, where a test can reach
    // them.
    final spaceScopeSection = buildChatSpaceScopeSection(
      _conversationService.skillDiscoveredNativeToolNames,
    );
    if (spaceScopeSection.isNotEmpty) {
      lines.add(spaceScopeSection);
    }

    final taskContext = lines.join('\n');
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
    if (!isLocalModel) {
      final mcpToolsPrompt = McpToolIntegrationService.buildMcpSystemPrompt(
        combinedTools,
        maxBudgetTokens: budget,
        // Cloud chat models get per-tool declarations, so direct calls are
        // preferred (constrained decoding validates their arguments).
        preferDirectCalls: true,
      );
      if (mcpToolsPrompt.trim().isNotEmpty) {
        contextBuffer
          ..writeln()
          ..writeln(mcpToolsPrompt.trim());
      }
    }

    // Append skill index when skills are enabled
    if (_conversationService.skillsEnabled &&
        _conversationService.skillIndex.isNotEmpty) {
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
      final defaultActionSection = getIt<SkillService>()
          .buildDefaultActionPromptSection(_conversationService.skillIndex);
      if (defaultActionSection.isNotEmpty) {
        contextBuffer
          ..writeln()
          ..writeln()
          ..write(defaultActionSection);
      }
    }

    return SystemPromptBuilder.build(
      taskContext: contextBuffer.toString(),
      guidelines: [
        'Reference evidence when drawing conclusions and mention uncertainties.',
        AIPrompts.mathFormulaGuidelines,
        if (_notes.isNotEmpty) AIPrompts.relationshipGuidelines,
        if (hasInlineContext) AIPrompts.promptInjectionProtectionGuidelines,
      ],
      now: _conversationStartTime,
      needTimeInContext: false, // Precise time comes with user message.
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
    return ConversationPromptBuilder(DatabaseService()).loadMessageAttachments(
      message: message,
      messageHistory: _messages,
      latestUserAttachments: latestUserAttachments,
    );
  }

  Future<PlatformFile> _normalizePlatformFile(PlatformFile file) async {
    return ConversationPromptBuilder(
      DatabaseService(),
    ).normalizePlatformFile(file);
  }

  Future<void> _attachFiles() async {
    final l10n = AppLocalizations.of(context)!;

    // Show dialog to choose between file and URI
    final source = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.attachFile),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'file'),
            child: Row(
              children: [
                const Icon(Icons.upload_file),
                const SizedBox(width: 12),
                Text(l10n.selectFromDevice),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'uri'),
            child: Row(
              children: [
                const Icon(Icons.link),
                const SizedBox(width: 12),
                Text(l10n.enterUri),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'draw'),
            child: Row(
              children: [
                const Icon(Icons.brush),
                const SizedBox(width: 12),
                const Text('Draw'),
              ],
            ),
          ),
        ],
      ),
    );

    if (source == 'file') {
      await _pickFilesFromDevice();
    } else if (source == 'uri') {
      await _showUriInputDialog();
    } else if (source == 'draw') {
      await _openDrawingEditor();
    }
  }

  Future<String?> _showAgentConflictDialog(AgentService agentService) async {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Task in Progress'),
        content: const Text(
          'An agent task is currently running in another conversation. Do you want to switch to that task or abort it?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'abort'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Abort & Start New'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'switch'),
            child: const Text('Switch to Task'),
          ),
        ],
      ),
    );
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
        setState(() {
          _attachedFiles.add(platformFile);
        });
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

  Future<void> _pickFilesFromDevice() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: kIsWeb,
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

  Future<void> _showUriInputDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();

    final uri = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.enterUri),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: 'URI',
            hintText: 'https://example.com/file.pdf',
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) {
                Navigator.pop(context, text);
              }
            },
            child: Text(l10n.add),
          ),
        ],
      ),
    );

    if (uri != null && uri.isNotEmpty) {
      // Create a PlatformFile that represents a URI
      // We use a special convention where bytes is null and path is the URI
      // The name is extracted from the URI
      String name;
      try {
        final uriObj = Uri.parse(uri);
        if (uriObj.pathSegments.isNotEmpty) {
          name = uriObj.pathSegments.last;
        } else {
          name = 'attachment_${DateTime.now().millisecondsSinceEpoch}';
        }
      } catch (e) {
        name = uri.split('/').last;
      }

      if (name.isEmpty || !name.contains('.')) {
        // If no extension found, try to guess from common patterns or leave as is
        // But for now, just ensure it has a name
        if (name.isEmpty) {
          name = 'attachment_${DateTime.now().millisecondsSinceEpoch}';
        }
      }

      final file = PlatformFile(
        name: name,
        size: 0, // Unknown size
        path: uri,
        bytes: null,
      );

      setState(() {
        _attachedFiles.add(file);
      });
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

  Future<void> _previewAttachedFile(PlatformFile file) async {
    if (file.path != null &&
        (file.path!.startsWith('http://') ||
            file.path!.startsWith('https://'))) {
      final uri = Uri.tryParse(file.path!);
      if (uri != null && await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    }
    await FileUtils.openPlatformFile(file, context);
  }

  Widget _buildAttachedFilesSection() {
    if (_attachedFiles.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.attach_file,
                size: 16,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              ),
              const SizedBox(width: 8),
              Text(
                'Attached Files (${_attachedFiles.length})',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withOpacity(0.8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...List.generate(_attachedFiles.length, (index) {
            final file = _attachedFiles[index];
            return InkWell(
              onTap: () => _previewAttachedFile(file),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withOpacity(0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _getFileIcon(file.extension),
                      size: 16,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withOpacity(0.7),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        file.name,
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _removeAttachedFile(index),
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: Colors.red[600],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildMcpSelectionSection() {
    final l10n = AppLocalizations.of(context)!;
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

    // Get current model config to check for features
    final appProvider = context.read<AppProvider>();
    final modelConfig = appProvider.modelConfig;
    final supportsToolOrchestration =
        (_selectedModel ?? modelConfig)
            ?.customCapabilitiesObject
            ?.supportsToolOrchestration ??
        true;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _isMcpPanelExpanded = !_isMcpPanelExpanded;
              });
            },
            child: Row(
              children: [
                Icon(
                  Icons.extension,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  headerTitle,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (totalActiveCount > 0)
                  ActiveToolCountBadge(
                    count: totalActiveCount,
                    label: l10n.active,
                  ),
                const SizedBox(width: 8),
                Icon(
                  _isMcpPanelExpanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_up,
                  size: 20,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withOpacity(0.6),
                ),
              ],
            ),
          ),
          // Expandable content
          if (_isMcpPanelExpanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 250),
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
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withOpacity(0.7),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.builtInTools,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface.withOpacity(0.8),
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
                          secondary: supportsToolOrchestration
                              ? Icon(tool.icon, color: tool.color)
                              : Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Icon(tool.icon, color: tool.color),
                                    Positioned(
                                      right: -4,
                                      top: -4,
                                      child: Icon(
                                        Icons.warning_amber_rounded,
                                        size: 12,
                                        color: Colors.amber.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                _selectedBuiltInTools.add(tool.id);
                              } else {
                                _selectedBuiltInTools.remove(tool.id);
                              }
                            });
                          },
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        );
                      }),
                      const Divider(),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      children: [
                        Icon(
                          Icons.cloud,
                          size: 16,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.7),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          l10n.mcpTools,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withOpacity(0.8),
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
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurface.withOpacity(0.6),
                          ),
                        );
                      }).toList(),
                    ),
                    if (_aiToolBundles.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Icon(
                            Icons.smart_toy,
                            size: 16,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withOpacity(0.7),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.aiTools,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface.withOpacity(0.8),
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
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withOpacity(0.6),
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
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withOpacity(0.7),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'System Tools',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface.withOpacity(0.8),
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
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withOpacity(0.6),
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
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withOpacity(0.7),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Agent Skills',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface.withOpacity(0.8),
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
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              FilterChip(
                                label: Text('$_skillCount available'),
                                selected: _skillsEnabled,
                                onSelected: (selected) {
                                  setState(() => _skillsEnabled = selected);
                                  if (selected) {
                                    _conversationService.enableSkills().then((
                                      _,
                                    ) {
                                      if (mounted) {
                                        setState(
                                          () =>
                                              _skillCount = _conversationService
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
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).colorScheme.onSurface
                                            .withOpacity(0.6),
                                ),
                              ),
                              if (!supportsToolOrchestration)
                                Positioned(
                                  right: -4,
                                  top: -4,
                                  child: Icon(
                                    Icons.warning_amber_rounded,
                                    size: 12,
                                    color: Colors.amber.shade700,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ],
                    if (modelConfig?.modelFeatures != null &&
                        modelConfig!.modelFeatures!.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Icon(
                            Icons.stars,
                            size: 16,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withOpacity(0.7),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.modelFeatures,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface.withOpacity(0.8),
                                ),
                          ),
                          const Spacer(),
                          if (activeModelFeaturesCount > 0)
                            ActiveToolCountBadge(
                              count: activeModelFeaturesCount,
                              label: l10n.active,
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: modelConfig.modelFeatures!.map((feature) {
                          final isSelected = _selectedModelFeatures.contains(
                            feature,
                          );
                          String label = feature;
                          if (feature == 'google_search') {
                            label = l10n.featureGoogleSearch;
                          } else if (feature == 'code_execution') {
                            label = l10n.featureCodeExecution;
                          } else if (feature == 'web_search') {
                            label = l10n.featureWebSearch;
                          }

                          return FilterChip(
                            label: Text(label),
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
                              Icons.stars,
                              size: 16,
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withOpacity(0.6),
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
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.6),
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

  void _scrollToMessage(String messageId) {
    final idx = _messages.indexWhere((m) => m.id == messageId);
    if (idx < 0 || !_scrollController.hasClients) return;
    const estimatedItemHeight = 120.0;
    final offset = (idx * estimatedItemHeight).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  void _handleMarkdownLinkTap(String url, String _) {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      canLaunchUrl(uri).then((canLaunch) {
        if (canLaunch) {
          launchUrl(uri, mode: LaunchMode.externalApplication);
        } else if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Could not open link: $url')));
        }
      });
    } else if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Invalid URL: $url')));
    }
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
      // Capture ScaffoldMessenger and Navigator before any async operations
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);

      try {
        final forkedConversation = await _forkService.forkFromMessageInContext(
          forkFromMessageId: messageId,
          sourceConversationId: _conversation!.id,
          suggestedTitle: 'Forked conversation',
        );
        if (forkedConversation == null) {
          if (mounted) {
            messenger.showSnackBar(
              const SnackBar(content: Text('Could not fork conversation')),
            );
          }
          return;
        }

        // Navigate to the forked conversation
        if (mounted) {
          navigator.push(
            MaterialPageRoute(
              builder: (context) =>
                  ConversationChatScreen(conversationId: forkedConversation.id),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          messenger.showSnackBar(
            SnackBar(content: Text('Error forking conversation: $e')),
          );
        }
      }
    }
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
      final existingIds = _notes.map((note) => note.id).toSet();
      final newNotes = selectedNotes
          .where((note) => !existingIds.contains(note.id))
          .toList();

      if (_conversation == null) {
        if (newNotes.isEmpty) return;
        setState(() {
          _notes = [..._notes, ...newNotes];
        });
        return;
      }

      final noteIds = selectedNotes.map((note) => note.id).toList();
      await _conversationService.addNotesToConversation(
        _conversation!.id,
        noteIds,
      );
      // Reload all notes from the conversation to ensure we have the complete list
      final updatedNotes = await _conversationService.getConversationNotes(
        _conversation!.id,
      );
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
                              if (_conversation == null) {
                                return;
                              }
                              try {
                                await _conversationService
                                    .removeNotesFromConversation(
                                      _conversation!.id,
                                      [note.id],
                                    );
                              } catch (_) {
                                // If removal fails, refresh from service to reflect truth
                                final updatedNotes = await _conversationService
                                    .getConversationNotes(_conversation!.id);
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
                                builder: (context) =>
                                    NoteDetailScreen(note: note),
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

  Future<void> _clearAllNotes() async {
    if (_notes.isEmpty) return;

    final noteIds = _notes.map((note) => note.id).toList();
    if (_conversation != null) {
      await _conversationService.removeNotesFromConversation(
        _conversation!.id,
        noteIds,
      );
    }
    setState(() {
      _notes.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.newConversation)),
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
                    activeConversationIds: _conversation?.id != null
                        ? [_conversation!.id]
                        : [],
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
              } else if (value == 'add_tags') {
                _showConversationTagsDialog();
              } else if (value == 'open_immersive') {
                _openInImmersiveMode();
              } else if (value == 'note_action_apps') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) =>
                        NoteActionAppSelectionScreen(selectedNotes: _notes),
                  ),
                );
              } else if (value == 'ai_logs') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const AIDebugOverlayScreen(),
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              if (_notes.isNotEmpty)
                PopupMenuItem<String>(
                  value: 'open_immersive',
                  child: Text(l10n.immersiveMode),
                ),
              if (_notes.isNotEmpty)
                PopupMenuItem<String>(
                  value: 'note_action_apps',
                  child: Text(l10n.noteActionApps),
                ),
              if (_conversation != null)
                PopupMenuItem<String>(
                  value: 'add_tags',
                  child: Text(l10n.addTags),
                ),
              if (_messages.isNotEmpty)
                PopupMenuItem<String>(
                  value: 'new_conversation',
                  child: Text(l10n.newConversation),
                ),
              PopupMenuItem<String>(value: 'ai_logs', child: Text(l10n.aiLogs)),
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
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
          // Tags display
          if (_conversationTags.isNotEmpty)
            Container(
              width: double.infinity,
              height: 40,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: _conversationTags
                        .map(
                          (tag) => Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: Chip(
                              label: Text(
                                tag,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(fontSize: 11, height: 1.0),
                              ),
                              deleteIcon: Icon(
                                Icons.close,
                                size: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withOpacity(0.7),
                              ),
                              onDeleted: () => _removeTag(tag),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              labelPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 0,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            ),
          // Messages
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16.0),
              itemCount: _messages.length + (_isStreaming ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _messages.length && _isStreaming) {
                  return KeyedSubtree(
                    key: const ValueKey('conversation_streaming_message'),
                    child: _buildStreamingMessageCard(),
                  );
                }
                final message = _messages[index];
                return KeyedSubtree(
                  key: ValueKey(message.id),
                  child: _buildMessageCard(message),
                );
              },
            ),
          ),
          // Attached files section
          _buildAttachedFilesSection(),
          // MCP selection section
          if (_hasAvailableTools) _buildMcpSelectionSection(),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildToolExecutionIndicator(),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        focusNode: _messageFocusNode,
                        enabled: !_isSending || _isAborting,
                        decoration: InputDecoration(
                          hintText: _isAborting
                              ? l10n.cancellingRequest
                              : l10n.typeYourMessage,
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
                        minLines: 1,
                        maxLines: 10,
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
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: _isSending ? null : _sendMessage,
                            icon: _isSending
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.send),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                          if (!_isSending)
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
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
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
              icon: const Icon(Icons.stop, color: Colors.white, size: 16),
              tooltip: l10n.cancelAiRequest,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ),
        ],
      ),
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

  Widget _buildStreamingMessageCard() {
    final l10n = AppLocalizations.of(context)!;
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
                  Icons.smart_toy,
                  size: 20,
                  color: Theme.of(context).colorScheme.secondary,
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.ai,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.secondary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(_streamingContent),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageCard(ConversationMessage message) {
    final l10n = AppLocalizations.of(context)!;

    // Agent Plan Widget
    if (message.metadata?['is_agent_plan'] == true) {
      return Consumer<AgentService>(
        builder: (context, agentService, child) {
          final isExecuting = agentService.isRunning;
          final hasStartedExecution = agentService.tasks.any(
            (t) => t.status != AgentTaskStatus.pending,
          );

          return Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Column(
              children: [
                // Show tree view during/after execution
                if (hasStartedExecution)
                  AgentTaskTreeWidget(
                    onResume: () async {
                      setState(() {
                        _waitingForAgentResult = true;
                      });
                      await context.read<AgentService>().resumeExecution();
                    },
                  ),
                // Show plan review when not executing and tasks are pending
                if (!isExecuting && !hasStartedExecution)
                  AgentPlanReviewWidget(
                    onProceed: () {
                      context.read<AgentService>().executePlan();
                    },
                    onCopy: (content) => copyContentToClipboard(content),
                    onAddNote: (content) => handleAddContentToNote(
                      content: content,
                      contextNotes: _notes,
                    ),
                  ),
              ],
            ),
          );
        },
      );
    }

    final isUser = message.type == MessageType.user;
    final hasTools =
        message.metadata != null &&
        (message.metadata!.containsKey('parts_history') ||
            message.metadata!.containsKey('function_calls'));
    final branches = _branchesFor(message.id);
    final activeConversationId = _conversation?.id;

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
                if (hasTools && !isUser) ...[
                  IconButton(
                    icon: const Icon(Icons.build_circle_outlined, size: 18),
                    tooltip: 'View Tool Usage',
                    onPressed: () => _showToolDetailsDialog(message),
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  _formatTimestamp(message.timestamp),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (isUser) ...[
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
            else
              ChipAwareAiMessageContent(
                message: message,
                isStreaming: _isStreaming && message.id == _messages.last.id,
                chipsExpected: _areChipsExpected(),
                onChipTap: _isSending || _isStreaming
                    ? null
                    : (chip) => _handleChipTap(message, chip),
                onLinkTap: _handleMarkdownLinkTap,
              ),
            if (branches.isNotEmpty && activeConversationId != null)
              MessageBranchStrip(
                branches: branches,
                activeConversationId: activeConversationId,
                activeNoteIds: _conversation?.noteIds ?? const [],
                disabled: _isSending || _isStreaming,
                onSwitchBranch: (conversationId, _) async {
                  await _switchConversationInPlace(
                    conversationId,
                    scrollToMessageId: message.id,
                  );
                },
                onRenameBranch: (conversationId, title) async {
                  await _conversationService.renameConversation(
                    conversationId: conversationId,
                    title: title,
                  );
                  await _refreshBranchSummaries();
                },
              ),
            if (message.attachmentPaths.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _buildMessageAttachmentChips(message),
              ),
            if (!isUser) ...[
              const SizedBox(height: 12),
              ChatMessageActionRow(
                leading: IconButton(
                  icon: Icon(
                    Icons.apps_outlined,
                    size: 18,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withOpacity(0.6),
                  ),
                  tooltip: 'Run Note Action App',
                  onPressed: () => _openNoteActionAppsForContent(message),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
                ),
                onCopy: () => copyContentToClipboard(message.content),
                onAddNote: () => handleAddContentToNote(
                  content: message.content,
                  contextNotes: _notes,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMessageAttachmentChips(ConversationMessage message) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: message.attachmentPaths.map((path) {
        return AttachmentPreviewTile(
          key: ValueKey('${message.id}:$path'),
          attachmentPath: path,
          onTap: () => _openAttachment(path),
        );
      }).toList(),
    );
  }

  Future<void> _openAttachment(String path) async {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      final uri = Uri.tryParse(path);
      if (uri != null) {
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return;
        }
      }
    }

    String finalPath = path;
    if (!path.startsWith('/') &&
        !path.startsWith('http') &&
        !path.startsWith('gs://')) {
      finalPath = await FileUtils.getFullFilePath(path, true);
    }

    await FileUtils.openFile(finalPath, context);
  }

  void _openNoteActionAppsForContent(ConversationMessage message) {
    final content = message.content;
    final now = DateTime.now();
    // Create a temporary Note object (not saved to DB)
    final tempNote = Note(
      id: 'msg:${message.id}',
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
        builder: (context) =>
            NoteActionAppSelectionScreen(selectedNotes: [tempNote]),
      ),
    );
  }

  String _formatTimestamp(DateTime timestamp) =>
      AppDateUtils.formatRelative(timestamp, AppLocalizations.of(context)!);

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
              const Text(
                'This conversation references notes that no longer exist:',
              ),
              const SizedBox(height: 8),
              ...missingNoteIds.map(
                (noteId) => Text(
                  '• $noteId',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
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

  void _onAgentStateChange() async {
    // Safety check BEFORE accessing context or state
    if (!mounted) return;
    final agentService = _agentService;
    if (agentService == null) return;
    if (_isLoading)
      return; // Wait for initialization to complete before updating executor

    // CRITICAL FIX: Ensure AgentService uses the current, valid tool executor.
    // When switching models or navigating, this screen is disposed and recreated,
    // but AgentService persists. We must update the executor to use the NEW
    // HeadlessWebView runtimes attached to this new screen instance.
    if (agentService.isRunning || agentService.isPaused) {
      agentService.updateToolExecutor(_createToolExecutor());
    }

    // If we just attached and agent is running, we should be waiting
    if (agentService.isRunning && !_waitingForAgentResult) {
      _waitingForAgentResult = true;
    }

    if (_waitingForAgentResult &&
        !agentService.isRunning &&
        agentService.finalAnswer != null) {
      _waitingForAgentResult = false;

      final content = agentService.finalAnswer!;
      final metadata = agentService.finalMetadata ?? {};

      // Add AI response to DB
      final savedMessage = await _conversationService.addAIResponse(
        conversationId: _conversation!.id,
        content: content,
        metadata: {...metadata, 'is_agent_summary': true},
        modelUsed: metadata['modelUsed'] as String?,
      );

      if (mounted && content.trim().isNotEmpty) {
        setState(() {
          _messages.add(savedMessage);
        });
        _scrollToBottom();

        // Clear agent state so future tasks can start without conflict dialog
        // agentService.clearState();
      }
    }
  }

  /// The declared input schema for a tool in the active tool map, if any.
  /// Missing schemas disable validation for that call (fail open).
  Map<String, dynamic>? _findActiveToolSchema(
    String serviceName,
    String toolName,
  ) {
    try {
      final schema = _buildActiveToolsMap()[serviceName]
          ?.where((tool) => tool.name == toolName)
          .firstOrNull
          ?.inputSchema;
      return schema == null || schema.isEmpty ? null : schema;
    } catch (_) {
      return null;
    }
  }

  /// Creates a tool executor that captures the current context and runtimes.
  ToolExecutor _createToolExecutor() {
    return (serviceName, toolName, params, ctx) async {
      // Handle AI Tools
      if (_aiToolBundles.containsKey(serviceName)) {
        final runtime = await _getAiToolRuntime(serviceName);
        final result = await runtime.invoke(toolName, params, ctx);
        return ToolOutcome.fromAiToolResult(toolName, result).serialize();
      }
      // Handle System Tools (native tools from AgentService)
      if (serviceName == BuiltInToolsService.systemToolsServiceKey) {
        final agentService = _agentService!;
        final nativeTool = agentService.nativeTools
            .where((t) => t.name == toolName)
            .firstOrNull;
        if (nativeTool != null) {
          final result = await nativeTool.execute(params);
          return ToolOutcome.fromNativeResult(toolName, result).serialize();
        }
        return ToolOutcome.failure(
          code: ToolOutcome.codeNotFound,
          message: 'System tool "$toolName" not found',
        ).serialize();
      }
      // Handle MCP Tools
      return McpToolIntegrationService.executeToolCall(
        serviceName: serviceName,
        toolName: toolName,
        parameters: params,
        enabledEndpointIds: _selectedMcpEndpointIds.toList(),
        generationContext: ctx,
      );
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _agentService?.removeListener(_onAgentStateChange);
    _forkSub?.cancel();

    // Clean up SQL approval callback and session state
    RunSqlTool.onWriteApprovalRequest = null;
    RunSqlTool.resetSessionApproval();

    _resolveIterationPrompt(null);
    _messageController.dispose();
    _scrollController.dispose();
    _messageFocusNode.dispose();
    for (final runtime in _aiToolRuntimes.values) {
      runtime.dispose();
    }
    _aiToolRuntimes.clear();
    super.dispose();
  }
}
