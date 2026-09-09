import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/generation_context.dart';
import '../models/mcp_endpoint.dart';
import '../models/model_config.dart';
import '../models/tool_iteration_prompt.dart';
import '../models/user_app.dart';
import '../providers/app_provider.dart';
import 'agent_service.dart';
import 'ai_tool_service.dart';
import 'approval_service.dart';
import 'built_in_tools_service.dart';
import 'conversation_service.dart';
import 'conversation_settings_service.dart';
import 'logger_service.dart';
import 'mcp_service.dart';
import 'mcp_tool_integration_service.dart';
import 'service_locator.dart';
import 'skill_service.dart';
import 'sql_query_service.dart';
import 'tools/tool_outcome.dart';
import 'tools/tool_param_validator.dart';
import 'user_app_service.dart';

typedef ToolStatusLabelBuilder =
    String Function(String serviceName, String toolName);

/// Shared tool/skill selection and execution state for chat surfaces.
///
/// The dropdown chat, immersive chat, and marker chat all need the same active
/// tool map and the same SkillTools routing. Keeping it here avoids the marker
/// sheet silently omitting skills while another chat surface advertises them.
class ChatToolSession extends ChangeNotifier {
  ChatToolSession({
    this.allowAgentPlanner = false,
    this.initialSkillsEnabled = true,
    ToolStatusLabelBuilder? statusLabelBuilder,
  }) : _statusLabelBuilder = statusLabelBuilder;

  final bool allowAgentPlanner;
  final bool initialSkillsEnabled;
  final ToolStatusLabelBuilder? _statusLabelBuilder;

  static const String skillToolsServiceKey = 'SkillTools';

  List<McpEndpoint> availableMcpEndpoints = const [];
  final Set<String> selectedMcpEndpointIds = {};
  Map<String, List<McpTool>> mcpToolsByEndpoint = {};

  Map<String, AiToolAppBundle> aiToolBundles = {};
  Map<String, List<McpTool>> aiToolMcpMap = {};
  final Set<String> selectedAiToolServices = {};
  final Map<String, AiToolRuntime> _aiToolRuntimes = {};

  final Set<String> selectedBuiltInTools = {};
  final Set<String> selectedSystemTools = {};
  final Set<String> selectedModelFeatures = {};

  bool skillsEnabled = false;
  int skillCount = 0;
  bool isPanelExpanded = false;
  bool? _lastOrchestrationSupport;

  String? toolExecutionStatus;
  int maxToolIterations = ConversationSettingsService.defaultMaxToolIterations;
  ToolIterationPrompt? iterationPrompt;
  ModelConfig? selectedModel;

  bool _initialized = false;

  bool get hasAvailableTools =>
      availableMcpEndpoints.isNotEmpty ||
      aiToolBundles.isNotEmpty ||
      BuiltInToolsService.systemTools.isNotEmpty ||
      (allowAgentPlanner && BuiltInToolsService.tools.isNotEmpty) ||
      skillCount > 0 ||
      true; // model features are model-dependent and may appear after config.

  int get activeCount =>
      selectedMcpEndpointIds.length +
      selectedAiToolServices.length +
      selectedModelFeatures.length +
      selectedBuiltInTools.length +
      selectedSystemTools.length +
      (skillsEnabled ? 1 : 0);

  Future<void> initialize(BuildContext context) async {
    if (_initialized) return;
    _initialized = true;
    await Future.wait([
      _loadIterationPreference(),
      loadMcpEndpoints(),
      loadAiTools(context),
      initializeSkillsForModel(context),
    ]);
  }

  Future<void> refreshForModel(BuildContext context) async {
    selectedModelFeatures.clear();
    final supports = _supportsToolOrchestration(context);
    if (_lastOrchestrationSupport != supports) {
      await initializeSkillsForModel(context);
    }
    _lastOrchestrationSupport = supports;
    notifyListeners();
  }

  Future<void> initializeSkillsForModel(BuildContext context) async {
    final supports = _supportsToolOrchestration(context);
    _lastOrchestrationSupport = supports;
    final enable = initialSkillsEnabled && supports;
    if (enable) {
      try {
        await setSkillsEnabled(true);
      } catch (e) {
        skillsEnabled = false;
        skillCount = 0;
        LoggerService.warning('Unable to enable chat skills: $e');
      }
    } else {
      getIt<ConversationService>().disableSkills();
      final index = getIt.isRegistered<SkillService>()
          ? await getIt<SkillService>().buildSkillIndex()
          : const <String, SkillMetadata>{};
      skillsEnabled = false;
      skillCount = index.length;
      notifyListeners();
    }
  }

  bool _supportsToolOrchestration(BuildContext context) {
    AppProvider? appProvider;
    try {
      appProvider = context.read<AppProvider>();
    } catch (_) {
      appProvider = null;
    }
    final modelConfig = selectedModel ?? appProvider?.modelConfig;
    return modelConfig?.customCapabilitiesObject?.supportsToolOrchestration ??
        true;
  }

  Future<void> _loadIterationPreference() async {
    maxToolIterations =
        await ConversationSettingsService.getMaxToolIterations();
    notifyListeners();
  }

  Future<void> loadMcpEndpoints() async {
    if (!getIt.isRegistered<McpService>()) {
      availableMcpEndpoints = const [];
      notifyListeners();
      return;
    }
    try {
      final endpoints = await getIt<McpService>().getEndpoints();
      final withTools = <McpEndpoint>[];
      for (final endpoint in endpoints) {
        final cache = await getIt<McpService>().getCachedTools(endpoint.id);
        if (cache != null && cache.tools.isNotEmpty) {
          withTools.add(endpoint);
        }
      }
      availableMcpEndpoints = withTools;
      notifyListeners();
    } catch (e) {
      LoggerService.error('Error loading MCP endpoints: $e');
    }
  }

  Future<void> updateMcpTools() async {
    if (selectedMcpEndpointIds.isEmpty) {
      mcpToolsByEndpoint = {};
      notifyListeners();
      return;
    }
    try {
      mcpToolsByEndpoint = await McpToolIntegrationService.getAvailableTools(
        selectedMcpEndpointIds.toList(),
      );
      notifyListeners();
    } catch (e) {
      LoggerService.error('Error updating MCP tools: $e');
    }
  }

  Future<void> loadAiTools(BuildContext context) async {
    AppProvider? appProvider;
    try {
      appProvider = context.read<AppProvider>();
    } catch (_) {
      appProvider = null;
    }
    if (appProvider == null) {
      aiToolBundles = {};
      aiToolMcpMap = {};
      notifyListeners();
      return;
    }
    final aiApps = appProvider.userApps
        .where((app) => app.type == UserAppType.aiTool)
        .toList();
    final bundles = <String, AiToolAppBundle>{};
    final mcpMap = <String, List<McpTool>>{};

    for (final app in aiApps) {
      if (app.selectedRevisionId == null) continue;
      try {
        final revision = await getIt<UserAppService>().getAppRevision(
          app.selectedRevisionId!,
        );
        if (revision == null) continue;
        final bundle = await AiToolService.loadAppBundle(
          app: app,
          revision: revision,
        );
        if (bundle == null || bundle.toolDefinitions.isEmpty) continue;
        bundles[bundle.serviceName] = bundle;
        mcpMap[bundle.serviceName] = bundle.toMcpTools();
      } catch (e) {
        LoggerService.error('Failed to load AI tool "${app.name}": $e');
      }
    }

    final removed = _aiToolRuntimes.keys
        .where((service) => !bundles.containsKey(service))
        .toList(growable: false);
    for (final service in removed) {
      _aiToolRuntimes.remove(service)?.dispose();
    }

    aiToolBundles = bundles;
    aiToolMcpMap = mcpMap;
    selectedAiToolServices.removeWhere(
      (service) => !mcpMap.containsKey(service),
    );
    notifyListeners();
  }

  void setSelectedModel(ModelConfig? model) {
    selectedModel = model;
    notifyListeners();
  }

  void togglePanel() {
    isPanelExpanded = !isPanelExpanded;
    notifyListeners();
  }

  Future<void> toggleMcpEndpoint(String id, bool selected) async {
    if (selected) {
      selectedMcpEndpointIds.add(id);
    } else {
      selectedMcpEndpointIds.remove(id);
    }
    notifyListeners();
    await updateMcpTools();
  }

  void toggleAiToolService(String serviceName, bool selected) {
    if (selected) {
      selectedAiToolServices.add(serviceName);
    } else {
      selectedAiToolServices.remove(serviceName);
      _aiToolRuntimes.remove(serviceName)?.dispose();
    }
    notifyListeners();
  }

  void toggleSystemTool(String id, bool selected) {
    if (selected) {
      selectedSystemTools.add(id);
    } else {
      selectedSystemTools.remove(id);
    }
    notifyListeners();
  }

  void toggleBuiltInTool(String id, bool selected) {
    if (selected) {
      selectedBuiltInTools.add(id);
    } else {
      selectedBuiltInTools.remove(id);
    }
    notifyListeners();
  }

  void toggleModelFeature(String feature, bool selected) {
    if (selected) {
      selectedModelFeatures.add(feature);
    } else {
      selectedModelFeatures.remove(feature);
    }
    notifyListeners();
  }

  Future<void> setSkillsEnabled(bool selected) async {
    skillsEnabled = selected;
    notifyListeners();
    if (selected) {
      await getIt<ConversationService>().enableSkills();
      skillCount = getIt<ConversationService>().skillIndex.length;
    } else {
      getIt<ConversationService>().disableSkills();
    }
    notifyListeners();
  }

  Map<String, List<McpTool>> buildActiveToolsMap(BuildContext context) {
    final combined = <String, List<McpTool>>{};
    combined.addAll(mcpToolsByEndpoint);

    for (final service in selectedAiToolServices) {
      final tools = aiToolMcpMap[service];
      if (tools != null && tools.isNotEmpty) combined[service] = tools;
    }

    if (allowAgentPlanner && selectedBuiltInTools.isNotEmpty) {
      final builtInTools = selectedBuiltInTools
          .map((id) => BuiltInToolsService.getToolById(id))
          .where((tool) => tool != null)
          .map(
            (tool) => McpTool(
              name: tool!.name,
              description: tool.description,
              inputSchema: {},
            ),
          )
          .toList();
      if (builtInTools.isNotEmpty) combined['Built-in'] = builtInTools;
    }

    if (selectedSystemTools.isNotEmpty) {
      final agentService = context.read<AgentService>();
      final systemTools = selectedSystemTools
          .map((id) {
            final nativeTool = agentService.nativeTools
                .where((tool) => tool.name == id)
                .firstOrNull;
            if (nativeTool == null) return null;
            return McpTool(
              name: nativeTool.name,
              description: nativeTool.description,
              inputSchema: nativeTool.inputSchema,
            );
          })
          .whereType<McpTool>()
          .toList();
      if (systemTools.isNotEmpty) {
        combined[BuiltInToolsService.systemToolsServiceKey] = systemTools;
      }
    }

    final conversations = getIt<ConversationService>();
    if (conversations.skillsEnabled) {
      final skillTools = <McpTool>[
        McpTool(
          name: conversations.loadSkillTool.name,
          description: conversations.loadSkillTool.description,
          inputSchema: conversations.loadSkillTool.inputSchema,
        ),
      ];
      for (final tool in conversations.skillDiscoveredTools) {
        if (!skillTools.any((existing) => existing.name == tool.name)) {
          skillTools.add(tool);
        }
      }
      combined[skillToolsServiceKey] = skillTools;
    }

    return combined;
  }

  bool hasAnyTools(BuildContext context) =>
      buildActiveToolsMap(context).isNotEmpty;

  Future<String> executeTool(
    BuildContext context,
    String serviceName,
    String toolName,
    Map<String, dynamic> params,
    GenerationContext generationContext,
  ) {
    return runWithToolStatus(serviceName, toolName, () async {
      // Validate against the tool's declared schema BEFORE approval or
      // execution: structurally invalid calls must trigger neither approval
      // dialogs nor side effects, and the model needs a path-specific error
      // instead of a raw type-cast failure from deep inside a tool.
      // Normalization coerces double-encoded/misplaced arguments, so the
      // returned params — not the raw ones — are what get executed.
      final validation = ToolParamValidator.validateAndNormalize(
        toolName: toolName,
        params: params,
        inputSchema: _findToolSchema(context, serviceName, toolName),
      );
      if (validation.failure != null) {
        return validation.failure!.serialize();
      }
      final effectiveParams = validation.params;

      if (aiToolBundles.containsKey(serviceName)) {
        final runtime = await _getAiToolRuntime(context, serviceName);
        final result = await runtime.invoke(
          toolName,
          effectiveParams,
          generationContext,
        );
        return ToolOutcome.fromAiToolResult(toolName, result).serialize();
      }

      if (serviceName == BuiltInToolsService.systemToolsServiceKey) {
        final agentService = context.read<AgentService>();
        final nativeTool = agentService.nativeTools
            .where((tool) => tool.name == toolName)
            .firstOrNull;
        if (nativeTool != null) {
          final result = await nativeTool.execute(effectiveParams);
          return ToolOutcome.fromNativeResult(toolName, result).serialize();
        }
        return ToolOutcome.failure(
          code: ToolOutcome.codeNotFound,
          message: 'System tool "$toolName" not found',
        ).serialize();
      }

      if (serviceName == skillToolsServiceKey) {
        return _executeSkillTool(
          context,
          toolName,
          effectiveParams,
          generationContext,
        );
      }

      return McpToolIntegrationService.executeToolCall(
        serviceName: serviceName,
        toolName: toolName,
        parameters: effectiveParams,
        enabledEndpointIds: selectedMcpEndpointIds.toList(),
        generationContext: generationContext,
      );
    });
  }

  /// The declared input schema for a tool in the active tool map, if any.
  /// Missing schemas disable validation for that call (fail open).
  Map<String, dynamic>? _findToolSchema(
    BuildContext context,
    String serviceName,
    String toolName,
  ) {
    try {
      final tools = buildActiveToolsMap(context)[serviceName];
      final schema = tools
          ?.where((tool) => tool.name == toolName)
          .firstOrNull
          ?.inputSchema;
      return schema == null || schema.isEmpty ? null : schema;
    } catch (_) {
      return null;
    }
  }

  Future<String> _executeSkillTool(
    BuildContext context,
    String toolName,
    Map<String, dynamic> params,
    GenerationContext generationContext,
  ) async {
    final conversations = getIt<ConversationService>();
    if (toolName == 'load_skill') {
      final result = await conversations.loadSkillTool.execute(params);
      final resultStr = result is String ? result : result.toString();
      final skillKey = (params['noteId'] as String? ?? '').trim().isNotEmpty
          ? (params['noteId'] as String).trim()
          : (params['skillRef'] as String? ?? '').trim();
      if (skillKey.isNotEmpty && result is String) {
        await conversations.handleLoadSkillResult(skillKey, resultStr);
        notifyListeners();
      }
      return resultStr;
    }

    if (conversations.skillDiscoveredNativeToolNames.contains(toolName)) {
      final agentService = context.read<AgentService>();
      final nativeTool = agentService.nativeTools
          .where((tool) => tool.name == toolName)
          .firstOrNull;
      if (nativeTool != null) {
        final result = await nativeTool.execute(params);
        return ToolOutcome.fromNativeResult(toolName, result).serialize();
      }
      return ToolOutcome.failure(
        code: ToolOutcome.codeNotFound,
        message: 'Native tool "$toolName" not found',
      ).serialize();
    }

    for (final entry in conversations.skillDiscoveredBundles.entries) {
      if (entry.value.toolDefinitions.any((def) => def.toolName == toolName)) {
        final runtime = await _getRuntimeForBundle(
          context,
          entry.key,
          entry.value,
        );
        final result = await runtime.invoke(toolName, params, generationContext);
        return ToolOutcome.fromAiToolResult(toolName, result).serialize();
      }
    }

    final endpointName = conversations.skillToolEndpointNames[toolName];
    final endpointId = conversations.skillToolEndpointIds[toolName];
    if (endpointName != null && endpointId != null) {
      return McpToolIntegrationService.executeToolCall(
        serviceName: endpointName,
        toolName: toolName,
        parameters: params,
        enabledEndpointIds: [...selectedMcpEndpointIds, endpointId],
        generationContext: generationContext,
      );
    }
    return ToolOutcome.failure(
      code: ToolOutcome.codeNotFound,
      message: 'Skill tool "$toolName" not found',
    ).serialize();
  }

  Future<String> runWithToolStatus(
    String serviceName,
    String toolName,
    Future<String> Function() action,
  ) async {
    final status =
        _statusLabelBuilder?.call(serviceName, toolName) ??
        '$serviceName -> $toolName';
    toolExecutionStatus = status;
    notifyListeners();
    try {
      return await action();
    } finally {
      if (toolExecutionStatus == status) {
        toolExecutionStatus = null;
        notifyListeners();
      }
    }
  }

  Future<AiToolRuntime> _getAiToolRuntime(
    BuildContext context,
    String serviceName,
  ) async {
    final existing = _aiToolRuntimes[serviceName];
    if (existing != null) return existing;
    final bundle = aiToolBundles[serviceName];
    if (bundle == null) throw Exception('AI tool not available: $serviceName');
    return _getRuntimeForBundle(context, serviceName, bundle);
  }

  Future<AiToolRuntime> _getRuntimeForBundle(
    BuildContext context,
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

  Future<bool> _handleModificationRequest(
    dynamic source,
    String noteId,
    Map<String, dynamic> modification,
  ) {
    return ApprovalService.requestNoteModificationApproval(
      noteId: noteId,
      modification: modification,
      source: 'AI Tool',
    );
  }

  Future<bool> _handleSqlWriteApprovalRequest(
    dynamic source,
    String sql,
    SqlQueryType queryType,
  ) {
    return ApprovalService.requestSqlWriteApproval(
      sql: sql,
      queryType: queryType,
      queryTypeDescription: getIt<SqlQueryService>().getQueryTypeDescription(
        queryType,
      ),
      source: 'AI Tool',
    );
  }

  Future<int?> handleIterationsExhausted(int exhaustedLimit) async {
    final prompt = ToolIterationPrompt(exhaustedIterations: exhaustedLimit);
    iterationPrompt = prompt;
    toolExecutionStatus = null;
    notifyListeners();
    final result = await prompt.completer.future;
    if (identical(iterationPrompt, prompt)) {
      iterationPrompt = null;
      notifyListeners();
    }
    return result;
  }

  void resolveIterationPrompt(int? value) {
    final prompt = iterationPrompt;
    if (prompt == null) return;
    prompt.resolve(value);
    if (identical(iterationPrompt, prompt)) {
      iterationPrompt = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    for (final runtime in _aiToolRuntimes.values) {
      runtime.dispose();
    }
    _aiToolRuntimes.clear();
    super.dispose();
  }
}
